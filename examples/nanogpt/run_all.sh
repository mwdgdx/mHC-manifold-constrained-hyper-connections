#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run_all.sh — Run all mHC ablation experiments on multi-GPU
#
# Usage:
#   ./run_all.sh                       # 6-layer configs (default)
#   ./run_all.sh --48l                 # 48-layer configs
#   ./run_all.sh --all                 # both 6-layer and 48-layer
#   NPROC=4 ./run_all.sh              # override GPU count
#   WANDB_MODE=offline ./run_all.sh   # wandb offline mode
#
# wandb setup:
#   1. pip install wandb
#   2. wandb login                     # paste your API key from wandb.ai/authorize
#   3. (optional) export WANDB_ENTITY=your-team-name
#   4. (optional) export WANDB_PROJECT=my-project   # default: mhc-nanogpt
#
# To disable wandb entirely:
#   WANDB_MODE=disabled ./run_all.sh
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

# Config files use gradient_accumulation_steps=4 (designed for 4 GPUs).
# With DDP the code asserts: gradient_accumulation_steps % world_size == 0.
# We override to NPROC so each GPU does exactly 1 accumulation step.
# Effective batch = batch_size(32) * NPROC * 1 * block_size(1024) tokens/iter.
GRAD_ACCUM="${GRAD_ACCUM:-${NPROC}}"

# --------------- NCCL tuning (8-GPU node) ------------------------------------

export NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}"
export NCCL_P2P_LEVEL="${NCCL_P2P_LEVEL:-NVL}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"

# Uncomment if you hit NCCL timeout or InfiniBand issues:
# export NCCL_IB_DISABLE=1
# export NCCL_SOCKET_IFNAME=eth0

# --------------- wandb config ------------------------------------------------

WANDB_PROJECT="${WANDB_PROJECT:-mhc-nanogpt}"
export WANDB_PROJECT

# --------------- logging dir -------------------------------------------------

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR="logs/${TIMESTAMP}"
mkdir -p "$LOGDIR"

echo "============================================"
echo " mHC ablation runner"
echo "  GPUs (nproc):      ${NPROC}"
echo "  grad_accum_steps:  ${GRAD_ACCUM}"
echo "  effective batch:   $((32 * GRAD_ACCUM)) seqs/step"
echo "  wandb project:     ${WANDB_PROJECT}"
echo "  wandb mode:        ${WANDB_MODE:-online}"
echo "  log dir:           ${LOGDIR}"
echo "============================================"
echo ""

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

# --------------- pre-flight checks -------------------------------------------

_fail=0

if ! python -c "import hyper_connections" 2>/dev/null; then
    echo "ERROR: hyper_connections not installed."
    _fail=1
fi

DATA_DIR="${ROOT}/data/fineweb10B"
if ! ls "${DATA_DIR}"/fineweb_train_*.bin &>/dev/null 2>&1; then
    echo "ERROR: No training data in ${DATA_DIR}."
    _fail=1
fi

if [ "$_fail" -eq 1 ]; then
    echo ""
    echo "Run setup first:  source setup_env.sh"
    exit 1
fi

# --------------- experiment sets ---------------------------------------------

run_6l() {
    echo "========== 6-layer configs (~20M params) =========="
    run baseline      config/train_fineweb10B.py
    run hc            config/train_fineweb10B_hc.py
    run mhc           config/train_fineweb10B_mhc.py
    run vres          config/train_fineweb10B_vres.py
    run vres-mhc      config/train_fineweb10B_vres_mhc.py
    run cvres-mhc     config/train_fineweb10B_cvres_mhc.py
}

run_48l() {
    echo "========== 48-layer configs (~20M params) =========="
    run baseline-48l  config/train_fineweb10B_48l.py
    run hc-48l        config/train_fineweb10B_hc_48l.py
    run mhc-48l       config/train_fineweb10B_mhc_48l.py
    run vres-48l      config/train_fineweb10B_vres_48l.py
    run vres-mhc-48l  config/train_fineweb10B_vres_mhc_48l.py
    run cvres-mhc-48l config/train_fineweb10B_cvres_mhc_48l.py
}

# --------------- main --------------------------------------------------------

MODE="${1:-6l}"

case "$MODE" in
    --48l)
        run_48l
        ;;
    --all)
        run_6l
        run_48l
        ;;
    *)
        run_6l
        ;;
esac

echo "============================================"
echo " All runs complete. Logs in: ${LOGDIR}"
echo "============================================"
