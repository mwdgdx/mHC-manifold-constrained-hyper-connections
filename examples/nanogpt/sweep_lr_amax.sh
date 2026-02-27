#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sweep_lr_amax.sh — LR sweep to find Amax vs learning_rate relationship
#
# Runs HC on Shakespeare char-level with different LRs in parallel (1 per GPU).
# Each run is shortened to 2000 steps (Amax peaks early).
#
# Usage:
#   ./sweep_lr_amax.sh          # uses all available GPUs
#   ./sweep_lr_amax.sh 4        # use 4 GPUs max
# =============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# LR values to sweep
LRS=(1e-4 2e-4 3e-4 4e-4 5e-4 6e-4 7e-4 8e-4 9e-4 1e-3)

MAX_GPUS="${1:-8}"
if command -v nvidia-smi &>/dev/null; then
    NGPUS=$(nvidia-smi -L 2>/dev/null | wc -l)
    [ "$NGPUS" -gt "$MAX_GPUS" ] && NGPUS="$MAX_GPUS"
else
    NGPUS=1
fi

export WANDB_PROJECT="${WANDB_PROJECT:-mhc-shakespeare}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR="logs/lr_sweep_${TIMESTAMP}"
mkdir -p "$LOGDIR"

# Prepare data if needed
if [ ! -f "${ROOT}/data/shakespeare_char/train.pt" ]; then
    echo "Preparing Shakespeare dataset..."
    python "${ROOT}/data/shakespeare_char/prepare.py"
fi

echo "============================================"
echo " LR Sweep: Amax vs learning_rate"
echo "  LRs:     ${LRS[*]}"
echo "  GPUs:    ${NGPUS}"
echo "  Steps:   2000 (shortened)"
echo "  Log dir: ${LOGDIR}"
echo "============================================"
echo ""

# Launch experiments, up to NGPUS in parallel
running=0
for lr in "${LRS[@]}"; do
    gpu_id=$((running % NGPUS))
    logfile="${LOGDIR}/lr_${lr}.log"

    echo ">>> Launching LR=${lr} on GPU ${gpu_id}"

    CUDA_VISIBLE_DEVICES=${gpu_id} python train.py \
        config/train_shakespeare_hc.py \
        learning_rate="${lr}" \
        max_iters=2000 \
        lr_decay_iters=2000 \
        eval_interval=100 \
        wandb_run_name="hc-d24-lr${lr}" \
        out_dir="out-sweep-lr${lr}" \
        > "$logfile" 2>&1 &

    running=$((running + 1))

    # Wait if we've filled all GPUs
    if [ "$((running % NGPUS))" -eq 0 ]; then
        echo "  Waiting for batch of ${NGPUS} to finish..."
        wait
        echo "  Batch done."
    fi
done

# Wait for any remaining
wait
echo ""

# Extract max Amax from each log
echo "============================================"
echo " Results: Max Amax per LR"
echo "============================================"
printf "%-12s %-12s %-12s\n" "LR" "Max_Fwd" "Max_Bwd"
echo "------------------------------------"

for lr in "${LRS[@]}"; do
    logfile="${LOGDIR}/lr_${lr}.log"
    if [ -f "$logfile" ]; then
        # Extract all Amax fwd/bwd values and find the max
        max_fwd=$(grep -oP 'Amax fwd \K[0-9.]+' "$logfile" | sort -rn | head -1)
        max_bwd=$(grep -oP 'bwd \K[0-9.]+' "$logfile" | sort -rn | head -1)
        printf "%-12s %-12s %-12s\n" "$lr" "${max_fwd:-N/A}" "${max_bwd:-N/A}"
    else
        printf "%-12s %-12s %-12s\n" "$lr" "MISSING" "MISSING"
    fi
done

echo "============================================"
echo " Full logs in: ${LOGDIR}"
echo "============================================"
