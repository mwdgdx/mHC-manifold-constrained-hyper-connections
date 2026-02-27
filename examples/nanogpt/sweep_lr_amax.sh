#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sweep_lr_amax.sh — LR sweep: Amax vs learning_rate (3 seeds each)
#
# Runs HC on Shakespeare char-level with different LRs, 3 seeds per LR.
# Each run shortened to 2000 steps. Reports mean ± std of max Amax.
#
# Usage:
#   ./sweep_lr_amax.sh          # uses all available GPUs
#   ./sweep_lr_amax.sh 4        # use 4 GPUs max
# =============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

LRS=(1e-4 2e-4 3e-4 4e-4 5e-4 6e-4 7e-4 8e-4 9e-4 1e-3)
SEEDS=(42 123 456)

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

if [ ! -f "${ROOT}/data/shakespeare_char/train.pt" ]; then
    echo "Preparing Shakespeare dataset..."
    python "${ROOT}/data/shakespeare_char/prepare.py"
fi

TOTAL=$(( ${#LRS[@]} * ${#SEEDS[@]} ))
echo "============================================"
echo " LR Sweep: Amax vs learning_rate"
echo "  LRs:     ${LRS[*]}"
echo "  Seeds:   ${SEEDS[*]}"
echo "  Total:   ${TOTAL} runs"
echo "  GPUs:    ${NGPUS} (parallel)"
echo "  Steps:   2000 (shortened)"
echo "  Log dir: ${LOGDIR}"
echo "============================================"
echo ""

# Build job list
JOBS=()
for lr in "${LRS[@]}"; do
    for seed in "${SEEDS[@]}"; do
        JOBS+=("${lr}:${seed}")
    done
done

# Launch in batches of NGPUS
for ((i=0; i<${#JOBS[@]}; i+=NGPUS)); do
    batch_end=$((i + NGPUS))
    [ "$batch_end" -gt "${#JOBS[@]}" ] && batch_end=${#JOBS[@]}

    echo ">>> Launching batch $((i/NGPUS + 1)): jobs $((i+1))-${batch_end} of ${#JOBS[@]}"

    for ((j=i; j<batch_end; j++)); do
        IFS=':' read -r lr seed <<< "${JOBS[$j]}"
        gpu_id=$(( (j - i) % NGPUS ))
        logfile="${LOGDIR}/lr_${lr}_s${seed}.log"

        CUDA_VISIBLE_DEVICES=${gpu_id} python train.py \
            config/train_shakespeare_hc.py \
            learning_rate="${lr}" \
            seed="${seed}" \
            max_iters=2000 \
            lr_decay_iters=2000 \
            eval_interval=100 \
            wandb_run_name="sweep-lr${lr}-s${seed}" \
            out_dir="out-sweep/lr${lr}-s${seed}" \
            > "$logfile" 2>&1 &

        echo "    LR=${lr} seed=${seed} -> GPU ${gpu_id} (${logfile})"
    done

    echo "  Waiting for batch to finish..."
    wait
    echo "  Batch done."
    echo ""
done

# ---- Summary ----
echo "============================================"
echo " Results: Max Amax per LR (mean ± std over 3 seeds)"
echo "============================================"
printf "%-10s  %-18s  %-18s  %-10s\n" "LR" "Max_Fwd (m±s)" "Max_Bwd (m±s)" "Max_Amax"
echo "-------------------------------------------------------------------"

for lr in "${LRS[@]}"; do
    fwd_vals=()
    bwd_vals=()

    for seed in "${SEEDS[@]}"; do
        logfile="${LOGDIR}/lr_${lr}_s${seed}.log"
        if [ -f "$logfile" ]; then
            f=$(grep -oP 'Amax fwd \K[0-9.]+' "$logfile" | sort -rn | head -1)
            b=$(grep -oP 'bwd \K[0-9.]+' "$logfile" | sort -rn | head -1)
            [ -n "$f" ] && fwd_vals+=("$f")
            [ -n "$b" ] && bwd_vals+=("$b")
        fi
    done

    if [ ${#fwd_vals[@]} -gt 0 ]; then
        # Compute mean and std with python
        stats=$(python3 -c "
import sys
fwd = [${fwd_vals[*]// /,}]
bwd = [${bwd_vals[*]// /,}]
import statistics
fm, fs = statistics.mean(fwd), (statistics.stdev(fwd) if len(fwd)>1 else 0)
bm, bs = statistics.mean(bwd), (statistics.stdev(bwd) if len(bwd)>1 else 0)
mx = max(max(fwd), max(bwd))
print(f'{fm:.2f}±{fs:.2f}  {bm:.2f}±{bs:.2f}  {mx:.2f}')
")
        printf "%-10s  %-36s  %s\n" "$lr" "$stats"
    else
        printf "%-10s  NO DATA\n" "$lr"
    fi
done

echo "============================================"
echo " Logs: ${LOGDIR}"
echo " wandb: ${WANDB_PROJECT}"
echo "============================================"
