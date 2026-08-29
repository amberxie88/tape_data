#!/bin/bash
# Push one dataset directory of this repo to GitHub in <2GB waves.
#
# Generalization of push_waves.sh (which was hardcoded to 0825_1433_tape). Works for
# any dataset laid out as <dataset>/<group>/traj_N/..., so it handles both
#   0825_1433_tape/trajectories.zarr/traj_N        (one group)
#   0821_1609_rhpnp/{trajectories.zarr,deleted_trajs}/traj_N   (several groups)
#
# Two constraints drive the design:
#  1. GitHub blocks any push over 2GB, so trajs are batched into size-targeted waves.
#  2. This box has less free disk than the datasets need as git objects, so after each
#     wave is confirmed on the remote we delete that wave's loose blobs. Peak extra
#     disk is therefore ONE wave, not the whole dataset.
#
# TRAP that dictates the prune scope: `git write-tree` validates every entry of every
# tree it REBUILDS. Adding traj_N rebuilds the root tree and the group tree, so blobs
# referenced directly by those (README.md, .gitattributes, <group>/.zgroup, ...) must
# stay present or the commit dies with "invalid object ... Error building trees".
# Already-committed traj_*/ subtrees are never rebuilt, so their blobs are safe to drop.
# Hence: prune ONLY blobs under traj_*/, and re-materialize any missing non-traj blob
# before committing (content is unchanged in the worktree, so SHAs come back identical).
#
# Usage: bash push_dataset_waves.sh <dataset-dir> [target_raw_bytes_per_wave]
set -uo pipefail

REPO=/home/ubuntu/tape_data
DATASET=${1:?usage: push_dataset_waves.sh <dataset-dir> [target_raw_bytes_per_wave]}
TARGET_RAW=${2:-1900000000}        # ~1.9GB raw -> ~1.4GB of objects at the measured 0.74
MAX_OBJ_KIB=$((1800 * 1024))       # refuse to push a wave whose objects exceed 1.8GB
MIN_FREE_KIB=$((4 * 1024 * 1024))  # abort if / drops under 4GB free
LOG="$REPO/push_waves.log"

export GIT_SSH_COMMAND="ssh -i /home/ubuntu/.ssh/id_ed25519 -o StrictHostKeyChecking=no"
cd "$REPO" || exit 1
say() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

[ -d "$DATASET" ] || { say "FATAL: no such dataset dir: $DATASET"; exit 1; }

# ---- enumerate units (traj dirs) and their raw sizes -------------------------
mapfile -t UNITS < <(find "$DATASET" -mindepth 2 -maxdepth 2 -type d -name 'traj_*' | sort)
[ "${#UNITS[@]}" -gt 0 ] || { say "FATAL: no traj_* dirs under $DATASET"; exit 1; }
say "=== $DATASET: ${#UNITS[@]} traj dirs, target $((TARGET_RAW / 1000000))MB raw/wave ==="

# ---- wave 0: everything not inside a traj dir (.zgroup, stray metadata) ------
mapfile -t META < <(find "$DATASET" -type f -not -path '*/traj_*/*' | sort)
if [ "${#META[@]}" -gt 0 ]; then
  git add -- "${META[@]}" || { say "FAIL: git add metadata"; exit 1; }
  if ! git diff --cached --quiet HEAD; then
    git commit -q -m "$DATASET: add zarr metadata (${#META[@]} files)" \
      || { say "FAIL: commit metadata"; exit 1; }
    git -c pack.useSparse=false push --no-thin origin main >>"$LOG" 2>&1 \
      || { say "FAIL: push metadata"; exit 1; }
    say "metadata committed+pushed (${#META[@]} files)"
  else
    say "metadata already committed"
  fi
fi

# ---- greedily pack units into size-targeted waves ---------------------------
wave=0; idx=0; n=${#UNITS[@]}
while [ "$idx" -lt "$n" ]; do
  wave=$((wave + 1))
  batch=(); raw=0
  while [ "$idx" -lt "$n" ]; do
    u="${UNITS[$idx]}"
    sz=$(du -sb "$u" | cut -f1)
    # always take at least one unit, even if it alone exceeds the target
    if [ "${#batch[@]}" -gt 0 ] && [ "$((raw + sz))" -gt "$TARGET_RAW" ]; then break; fi
    batch+=("$u"); raw=$((raw + sz)); idx=$((idx + 1))
  done
  first=$(basename "${batch[0]}"); last=$(basename "${batch[-1]}")
  tag="wave $wave (${#batch[@]} trajs, $first..$last)"

  # ---- already on the remote? ------------------------------------------------
  need=0
  for u in "${batch[@]}"; do
    git rev-parse -q --verify "origin/main:$u" >/dev/null 2>&1 || { need=1; break; }
  done
  if [ "$need" -eq 0 ]; then say "skip $tag (already on origin/main)"; continue; fi

  # ---- disk guard -----------------------------------------------------------
  free=$(df --output=avail / | tail -1)
  if [ "$free" -lt "$MIN_FREE_KIB" ]; then
    say "ABORT: only $((free / 1024))MB free on /, under the $((MIN_FREE_KIB / 1024))MB floor"; exit 1
  fi

  say "$tag : staging $((raw / 1000000))MB raw"
  git add -- "${batch[@]}" || { say "FAIL: git add $tag"; exit 1; }

  # ---- re-materialize non-traj blobs the tree rebuild will validate ---------
  git ls-files -- ':!*/traj_*/*' | while read -r f; do
    sha=$(git ls-files -s -- "$f" | awk '{print $2}')
    [ -f ".git/objects/${sha:0:2}/${sha:2}" ] || git hash-object -w "$f" >/dev/null
  done

  # ---- size guard: loose objects are this wave's payload -------------------
  objkib=$(git count-objects -v | awk '/^size:/{print $2}')
  say "$tag : $((objkib / 1024))MB of objects, $(git diff --cached --name-only HEAD | wc -l) files staged"
  if [ "$objkib" -gt "$MAX_OBJ_KIB" ]; then
    say "ABORT: $tag is $((objkib / 1024))MB, over the $((MAX_OBJ_KIB / 1024))MB cap - lower TARGET_RAW"; exit 1
  fi

  if git diff --cached --quiet HEAD; then
    say "$tag : nothing staged, skipping commit"
  else
    git commit -q -m "$DATASET: add $first..$last (wave $wave)" || { say "FAIL: commit $tag"; exit 1; }
  fi

  # ---- push with retries ---------------------------------------------------
  ok=0
  for attempt in 1 2 3; do
    say "$tag : push attempt $attempt"
    if git -c pack.useSparse=false push --no-thin origin main >>"$LOG" 2>&1; then ok=1; break; fi
    say "$tag : push attempt $attempt FAILED, retrying in 20s"; sleep 20
  done
  [ "$ok" -eq 1 ] || { say "FAIL: push $tag after 3 attempts"; exit 1; }

  # ---- verify on remote, then reclaim disk ---------------------------------
  git fetch -q origin main || { say "FAIL: fetch after push"; exit 1; }
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { say "FAIL: origin/main != HEAD after push, not pruning"; exit 1; }
  for u in "${batch[@]}"; do
    git rev-parse -q --verify "origin/main:$u" >/dev/null 2>&1 \
      || { say "FAIL: $u missing from origin/main tree, not pruning"; exit 1; }
  done

  before=$(git count-objects -v | awk '/^size:/{print $2}')
  for u in "${batch[@]}"; do
    git ls-tree -r HEAD --format='%(objecttype) %(objectname)' "$u"
  done | awk '$1=="blob"{print substr($2,1,2)"/"substr($2,3)}' \
    | while read -r p; do rm -f ".git/objects/$p"; done
  find .git/objects -type d -empty -delete 2>/dev/null
  after=$(git count-objects -v | awk '/^size:/{print $2}')
  say "$tag : PUSHED ok, pruned $(((before - after) / 1024))MB, .git now $(du -sm .git | cut -f1)MB, / free $(($(df --output=avail / | tail -1) / 1024 / 1024))GB"
done

say "=== $DATASET done: origin/main = $(git rev-parse --short origin/main), $wave waves ==="
