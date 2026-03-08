#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p logs

echo "=== Starting HC run at $(date) ==="
torchrun --standalone --nproc_per_node=8 train.py \
  config/train_c4_hc_1.7B.py \
  batch_size=2 \
  gradient_accumulation_steps=32 \
  grad_clip=50.0 \
  wandb_run_name="hc-1.7B-randinit-no-wd-clip50" \
  2>&1 | tee "logs/hc_${TIMESTAMP}.log"

echo ""
echo "=== Starting mHC run at $(date) ==="
torchrun --standalone --nproc_per_node=8 train.py \
  config/train_c4_hc_1.7B.py \
  batch_size=2 \
  gradient_accumulation_steps=32 \
  grad_clip=50.0 \
  mhc=True \
  wandb_run_name="mhc-1.7B-randinit-no-wd-clip50" \
  2>&1 | tee "logs/mhc_${TIMESTAMP}.log"

echo ""
echo "=== All done at $(date) ==="
echo "Logs:"
echo "  HC:  logs/hc_${TIMESTAMP}.log"
echo "  mHC: logs/mhc_${TIMESTAMP}.log"
  