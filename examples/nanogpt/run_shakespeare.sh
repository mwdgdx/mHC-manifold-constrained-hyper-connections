#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run_shakespeare.sh — Taylor Kolasinski's mHC Part 1 reproduction
#
# Runs HC and mHC on TinyShakespeare (char-level, ~11M params, 24 layers)
# with 3 seeds (42, 123, 456) to match his experiment protocol.
#
# Usage:
#   ./run_shakespeare.sh                # HC + mHC, 3 seeds each
#   ./run_shakespeare.sh --hc           # HC only
#   ./run_shakespeare.sh --mhc          # mHC only
#   NPROC=1 ./run_shakespeare.sh        # single GPU / CPU
# =============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# --------------- GPU config --------------------------------------------------

if [ -z "${NPROC:-}" ]; then
    if command -v nvidia-smi &>/dev/null; then
        NPROC=$(nvidia-smi -L 2>/dev/null | wc -l)
        [ "$NPROC" -eq 0 ] && NPROC=1
    else
        NPROC=1
    fi
fi

# Shakespeare is small; gradient_accumulation_steps=1 in config.
# With multi-GPU DDP, override to NPROC for divisibility.
GRAD_ACCUM="${GRAD_ACCUM:-${NPROC}}"

export NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}"
export NCCL_P2P_LEVEL="${NCCL_P2P_LEVEL:-NVL}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"

WANDB_PROJECT="${WANDB_PROJECT:-mhc-shakespeare}"
export WANDB_PROJECT

SEEDS=(42 123 456)

# --------------- logging dir -------------------------------------------------

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR="logs/shakespeare_${TIMESTAMP}"
mkdir -p "$LOGDIR"

echo "============================================"
echo " Shakespeare char-level reproduction"
echo "  GPUs (nproc):   ${NPROC}"
echo "  grad_accum:     ${GRAD_ACCUM}"
echo "  seeds:          ${SEEDS[*]}"
echo "  wandb project:  ${WANDB_PROJECT}"
echo "  log dir:        ${LOGDIR}"
echo "============================================"
echo ""

# --------------- pre-flight --------------------------------------------------

if ! python -c "import hyper_connections" 2>/dev/null; then
    echo "ERROR: hyper_connections not installed. Run: source setup_env.sh"
    exit 1
fi

DATA_DIR="${ROOT}/data/shakespeare_char"
if [ ! -f "${DATA_DIR}/train.pt" ]; then
    echo "Preparing Shakespeare dataset..."
    python "${DATA_DIR}/prepare.py"
fi

# --------------- helpers -----------------------------------------------------

run() {
    local name="$1"
    shift
    local logfile="${LOGDIR}/${name}.log"

    echo ">>> [$(date +%H:%M:%S)] Starting: ${name}"

    if [ "$NPROC" -gt 1 ]; then
        torchrun --standalone --nproc_per_node="${NPROC}" \
            train.py "$@" gradient_accumulation_steps="${GRAD_ACCUM}" \
            2>&1 | tee "$logfile"
    else
        python train.py "$@" gradient_accumulation_steps="${GRAD_ACCUM}" \
            2>&1 | tee "$logfile"
    fi

    echo ">>> [$(date +%H:%M:%S)] Finished: ${name}  (log: ${logfile})"
    echo ""
}

# --------------- experiment runs ---------------------------------------------

run_hc() {
    for s in "${SEEDS[@]}"; do
        run "hc-d24-s${s}" config/train_shakespeare_hc.py \
            seed="${s}" wandb_run_name="hc-d24-s${s}"
    done
}

run_mhc() {
    for s in "${SEEDS[@]}"; do
        run "mhc-d24-s${s}" config/train_shakespeare_mhc.py \
            seed="${s}" wandb_run_name="mhc-d24-s${s}"
    done
}

# --------------- main --------------------------------------------------------

MODE="${1:---all}"

case "$MODE" in
    --hc)
        run_hc
        ;;
    --mhc)
        run_mhc
        ;;
    --all|*)
        run_hc
        run_mhc
        ;;
esac

echo "============================================"
echo " All Shakespeare runs complete. Logs: ${LOGDIR}"
echo "============================================"
