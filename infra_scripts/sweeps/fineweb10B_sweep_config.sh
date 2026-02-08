#!/usr/bin/env bash

# FineWeb10B sweep defaults (no secrets)
#
# This file is meant to be *boring*.
# Edit it once, then run the one-click script.

export SWEEP_WORKDIR="/root/work/mHC-manifold-constrained-hyper-connections"
export SWEEP_BRANCH="integrate/research-unified"
export SWEEP_OUT_ROOT="/mnt/pod_artifacts/outputs"
export SWEEP_DATA_DIR="/mnt/data/fineweb10B"
export SWEEP_CSV="infra_scripts/sweeps/fineweb10B_full_sweep.csv"

# Use all GPUs on an 8x node
export SWEEP_SHARDS=8

# Default: run without W&B for reliability. Flip to true only when ~/.netrc is present.
export SWEEP_WANDB=false

# tmux session name you attach to
export SWEEP_TMUX_SESSION="sweeps"
