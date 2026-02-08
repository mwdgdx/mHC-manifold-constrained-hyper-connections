#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: start_fineweb10B_sweep_tmux.sh [options]

Starts N tmux sessions (one per shard) to run the FineWeb10B sweep in parallel.

Options:
  --csv <path>          Sweep CSV (default: infra_scripts/sweeps/fineweb10B_full_sweep.csv)
  --workdir <path>      Repo root (default: /root/work/mHC-manifold-constrained-hyper-connections)
  --out-root <path>     Output root (default: /mnt/pod_artifacts/outputs)
  --data-dir <path>     FineWeb data dir (default: /mnt/data/fineweb10B)
  --wandb-group <name>  W&B group label (default: fineweb10B-sweep-YYYYMMDD)
  --shards <n>          Number of shards / sessions (default: 8)
  --session <name>      Optional parent tmux session to create windows in
  --no-wandb            Disable W&B logging
  --dry-run             Print tmux commands only
  -h, --help            Show this help
EOF
}

CSV="${CSV:-infra_scripts/sweeps/fineweb10B_full_sweep.csv}"
WORKDIR="${WORKDIR:-/root/work/mHC-manifold-constrained-hyper-connections}"
OUT_ROOT="${OUT_ROOT:-/mnt/pod_artifacts/outputs}"
DATA_DIR="${DATA_DIR:-/mnt/data/fineweb10B}"
WANDB_GROUP="${WANDB_GROUP:-fineweb10B-sweep-$(date +%Y%m%d)}"
SHARDS="${SHARDS:-8}"
SESSION="${SESSION:-}"
NO_WANDB=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) CSV="$2"; shift 2;;
    --workdir) WORKDIR="$2"; shift 2;;
    --out-root) OUT_ROOT="$2"; shift 2;;
    --data-dir) DATA_DIR="$2"; shift 2;;
    --wandb-group) WANDB_GROUP="$2"; shift 2;;
    --shards) SHARDS="$2"; shift 2;;
    --session) SESSION="$2"; shift 2;;
    --no-wandb) NO_WANDB=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! [[ "$SHARDS" =~ ^[0-9]+$ ]] || [[ "$SHARDS" -lt 1 ]]; then
  echo "Invalid --shards: $SHARDS" >&2
  exit 2
fi

runner="$WORKDIR/infra_scripts/sweeps/run_fineweb10B_sweep.sh"

if [[ -n "$SESSION" && "$DRY_RUN" != "true" ]]; then
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
  fi
  tmux new -d -s "$SESSION" "bash -lc 'echo sweeps session started; exec bash'"
fi

for i in $(seq 0 $((SHARDS - 1))); do
  session="sweep-$i"
  window="shard-$i"
  args=(
    "--csv" "$CSV"
    "--workdir" "$WORKDIR"
    "--out-root" "$OUT_ROOT"
    "--data-dir" "$DATA_DIR"
    "--wandb-group" "$WANDB_GROUP"
    "--shard-index" "$i"
    "--shard-count" "$SHARDS"
    "--cuda-devices" "$i"
  )

  if [[ "$NO_WANDB" == "true" ]]; then
    args+=("--no-wandb")
  fi

  cmd=(bash "$runner" "${args[@]}")

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '%s: ' "$session"
    printf '%q ' "${cmd[@]}"
    printf '\n'
    continue
  fi

  if [[ -n "$SESSION" ]]; then
    tmux new-window -t "$SESSION" -n "$window" "cd $WORKDIR && ${cmd[*]}"
  else
    if tmux has-session -t "$session" 2>/dev/null; then
      tmux kill-session -t "$session"
    fi
    tmux new -d -s "$session" "cd $WORKDIR && ${cmd[*]}"
  fi
done

echo "Started $SHARDS sweep shards."
if [[ -n "$SESSION" ]]; then
  echo "Attach: tmux attach -t $SESSION"
else
  echo "Attach: tmux attach -t sweep-0"
fi
