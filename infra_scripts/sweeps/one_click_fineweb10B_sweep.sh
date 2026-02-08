#!/usr/bin/env bash
set -euo pipefail

# One-click FineWeb10B sweep launcher (pod-side)
#
# Goal: one command to bootstrap and start the sweep, with everything persisted to /mnt.
#
# Requirements:
# - Run this INSIDE the pod.
# - /mnt is mounted (persistent volume).

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

# shellcheck disable=SC1091
source "$script_dir/fineweb10B_sweep_config.sh"

if [[ -f "$repo_root/infra_scripts/load_project_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$repo_root/infra_scripts/load_project_env.sh"
fi

WORKDIR="${SWEEP_WORKDIR}"
BRANCH="${SWEEP_BRANCH}"
OUT_ROOT="${SWEEP_OUT_ROOT}"
DATA_DIR="${SWEEP_DATA_DIR}"
CSV="${SWEEP_CSV}"
SHARDS="${SWEEP_SHARDS}"
WANDB="${SWEEP_WANDB}"
SESSION="${SWEEP_TMUX_SESSION}"

mkdir -p "$OUT_ROOT"

echo "[sweep] workdir=$WORKDIR"
echo "[sweep] branch=$BRANCH"
echo "[sweep] out_root=$OUT_ROOT"
echo "[sweep] data_dir=$DATA_DIR"
echo "[sweep] csv=$CSV"
echo "[sweep] shards=$SHARDS"
echo "[sweep] wandb=$WANDB"
echo "[sweep] tmux_session=$SESSION"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git tmux rsync python3-venv

mkdir -p "$(dirname "$WORKDIR")"
if [[ ! -d "$WORKDIR/.git" ]]; then
  git clone https://github.com/tokenbender/mHC-manifold-constrained-hyper-connections.git "$WORKDIR"
fi

git -C "$WORKDIR" fetch origin
git -C "$WORKDIR" checkout "$BRANCH"
git -C "$WORKDIR" pull --ff-only origin "$BRANCH"

# Ensure a project env exists on the volume (optional; safe defaults)
if [[ ! -f /mnt/project.env ]]; then
  cp "$WORKDIR/infra_scripts/project.env.example" /mnt/project.env
  echo "[sweep] wrote /mnt/project.env (edit if needed)"
fi

# Bootstrap venv + deps + ensure shards exist
source "$WORKDIR/infra_scripts/pod-fastpath.sh" --workdir "$WORKDIR" --data-dir "$DATA_DIR" --out-root "$OUT_ROOT" --branch "$BRANCH" --download-fineweb

# Snapshot the manifest into OUT_ROOT for provenance
cp -f "$WORKDIR/$CSV" "$OUT_ROOT/fineweb10B_full_sweep.csv"

if [[ "$WANDB" == "true" ]]; then
  no_wandb=""
else
  no_wandb="--no-wandb"
fi

echo "[sweep] starting tmux session"

tmux new -d -s "$SESSION" "bash -lc 'echo sweeps started; exec bash'" 2>/dev/null || true

bash "$WORKDIR/infra_scripts/sweeps/start_fineweb10B_sweep_tmux.sh" \
  --csv "$WORKDIR/$CSV" \
  --workdir "$WORKDIR" \
  --out-root "$OUT_ROOT" \
  --data-dir "$DATA_DIR" \
  --wandb-group "${WANDB_GROUP:-fineweb10B-sweep-$(date +%Y%m%d)}" \
  --shards "$SHARDS" \
  --session "$SESSION" \
  $no_wandb

echo "[sweep] started"
echo "[sweep] attach: tmux attach -t $SESSION"
echo "[sweep] status:  python3 $WORKDIR/infra_scripts/sweeps/sweep_status.py"
