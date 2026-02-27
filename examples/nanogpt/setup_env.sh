#!/usr/bin/env bash
# =============================================================================
# setup_env.sh — One-time environment setup for mHC experiments
#
# Usage:
#   source setup_env.sh        # interactive setup (run once before experiments)
#   source setup_env.sh --skip # non-interactive: use defaults / existing env
#
# After sourcing, just run:
#   ./run_all.sh
# =============================================================================

_SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SETUP_ROOT/../.." && pwd)"

# --------------- GPU detection -----------------------------------------------

if command -v nvidia-smi &>/dev/null; then
    _DETECTED_GPUS=$(nvidia-smi -L 2>/dev/null | wc -l)
else
    _DETECTED_GPUS=0
fi

echo ""
echo "=== mHC Environment Setup ==="
echo "  Detected GPUs: ${_DETECTED_GPUS}"
echo ""

# --------------- 1. Python dependencies --------------------------------------

echo "--- [1/3] Python packages ---"

if python -c "import hyper_connections" 2>/dev/null; then
    echo "  hyper_connections: already installed."
else
    echo "  Installing hyper_connections (pip install -e) ..."
    pip install -e "$_REPO_ROOT" 2>&1 | tail -3
fi

_MISSING=""
for _pkg in torch einops numpy wandb; do
    python -c "import $_pkg" 2>/dev/null || _MISSING="$_MISSING $_pkg"
done
if [ -n "$_MISSING" ]; then
    echo "  Installing missing packages:${_MISSING} ..."
    pip install ${_MISSING} 2>&1 | tail -3
else
    echo "  torch, einops, numpy, wandb: OK."
fi
echo ""

# --------------- 2. Dataset download -----------------------------------------

echo "--- [2/3] Dataset ---"

_SHAKE_DIR="${_SETUP_ROOT}/data/shakespeare_char"
_FW_DIR="${_SETUP_ROOT}/data/fineweb10B"

# Shakespeare char-level (tiny, ~1MB)
if [ -f "${_SHAKE_DIR}/train.pt" ]; then
    echo "  Shakespeare char-level: ready (${_SHAKE_DIR})"
else
    echo "  Preparing Shakespeare char-level dataset..."
    python "${_SHAKE_DIR}/prepare.py"
fi

# FineWeb10B (large, optional)
if ls "${_FW_DIR}"/fineweb_train_*.bin &>/dev/null 2>&1; then
    _N_SHARDS=$(ls "${_FW_DIR}"/fineweb_train_*.bin 2>/dev/null | wc -l)
    echo "  FineWeb10B: found ${_N_SHARDS} training shard(s)."
else
    echo "  FineWeb10B: not downloaded (optional, needed for fineweb configs)."
    echo ""
    echo "    9   shards = ~0.9B tokens, ~1.8 GB  (quick test)"
    echo "    103 shards = ~10B tokens,  ~20 GB   (full dataset)"
    echo ""

    if [[ "${1:-}" != "--skip" ]]; then
        read -rp "  Download FineWeb10B? How many shards? [skip]: " _N_SHARDS_DL
        if [ -n "${_N_SHARDS_DL}" ] && [ "${_N_SHARDS_DL}" != "skip" ]; then
            echo "  Downloading ${_N_SHARDS_DL} shard(s) from HuggingFace..."
            python "${_FW_DIR}/download.py" "${_N_SHARDS_DL}"
        else
            echo "  Skipped FineWeb10B download."
        fi
    else
        echo "  Skipped (--skip). Download manually if needed:"
        echo "    cd ${_FW_DIR} && python download.py 9"
    fi
fi
echo ""

# --------------- 3. wandb config ---------------------------------------------

echo "--- [3/3] Weights & Biases ---"

if [[ "${1:-}" == "--skip" ]]; then
    echo "  Skipping interactive wandb setup (--skip)."
else
    if python -c "import wandb; assert wandb.api.api_key" 2>/dev/null; then
        echo "  wandb: already logged in."
    else
        echo "  wandb: not logged in."
        echo "  Get your API key from: https://wandb.ai/authorize"
        echo ""
        wandb login
    fi

    echo ""
    read -rp "  wandb project name [mhc-nanogpt]: " _PROJ
    export WANDB_PROJECT="${_PROJ:-mhc-nanogpt}"

    read -rp "  wandb entity (team or username, empty = default): " _ENTITY
    if [ -n "$_ENTITY" ]; then
        export WANDB_ENTITY="$_ENTITY"
    fi

    read -rp "  Number of GPUs to use [${_DETECTED_GPUS}]: " _NPROC
    export NPROC="${_NPROC:-${_DETECTED_GPUS}}"
fi

# --------------- Apply defaults ----------------------------------------------

export WANDB_PROJECT="${WANDB_PROJECT:-mhc-nanogpt}"
export NPROC="${NPROC:-${_DETECTED_GPUS:-1}}"

# --------------- Summary -----------------------------------------------------

echo ""
echo "=== Environment Ready ==="
echo "  NPROC:         ${NPROC}"
echo "  WANDB_PROJECT: ${WANDB_PROJECT}"
echo "  WANDB_ENTITY:  ${WANDB_ENTITY:-(default)}"
echo "  WANDB_MODE:    ${WANDB_MODE:-online}"
echo ""
echo "Run experiments:"
echo "  ./run_all.sh          # 6-layer ablations"
echo "  ./run_all.sh --48l    # 48-layer ablations"
echo "  ./run_all.sh --all    # all"
echo "========================="
echo ""
