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

_DATA_DIR="${_SETUP_ROOT}/data/fineweb10B"

if ls "${_DATA_DIR}"/fineweb_train_*.bin &>/dev/null 2>&1; then
    _N_SHARDS=$(ls "${_DATA_DIR}"/fineweb_train_*.bin 2>/dev/null | wc -l)
    echo "  Found ${_N_SHARDS} training shard(s) in ${_DATA_DIR}."
else
    echo "  No training data found."
    echo "  Shard options:"
    echo "    9   = smoke test (~1.8B tokens, fast download)"
    echo "    103 = full FineWeb10B (~10B tokens)"
    echo ""

    if [[ "${1:-}" != "--skip" ]]; then
        read -rp "  How many shards to download? [9]: " _N_SHARDS_DL
        _N_SHARDS_DL="${_N_SHARDS_DL:-9}"
        echo "  Downloading ${_N_SHARDS_DL} shard(s)..."
        python "${_DATA_DIR}/download.py" "${_N_SHARDS_DL}"
    else
        echo "  Skipped (--skip). Download manually before training:"
        echo "    cd ${_DATA_DIR} && python download.py 9"
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
