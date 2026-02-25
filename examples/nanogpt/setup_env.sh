#!/usr/bin/env bash
# =============================================================================
# setup_env.sh — One-time environment setup for mHC experiments
#
# Usage:
#   source setup_env.sh        # interactive: prompts for wandb config
#   source setup_env.sh --skip # non-interactive: use defaults / existing env
#
# After sourcing, just run:
#   ./run_all.sh
# =============================================================================

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

# --------------- wandb setup -------------------------------------------------

if [[ "${1:-}" == "--skip" ]]; then
    echo "Skipping interactive setup (--skip)."
else
    # Check if wandb is installed
    if ! python -c "import wandb" 2>/dev/null; then
        echo "wandb not found. Installing..."
        pip install wandb
    fi

    # Check if already logged in
    if python -c "import wandb; wandb.api.api_key" 2>/dev/null; then
        echo "wandb: already logged in."
    else
        echo "wandb: not logged in."
        echo "  Get your API key from: https://wandb.ai/authorize"
        echo ""
        wandb login
    fi

    echo ""

    # Project name
    read -rp "wandb project name [mhc-nanogpt]: " _PROJ
    export WANDB_PROJECT="${_PROJ:-mhc-nanogpt}"

    # Entity (team/user)
    read -rp "wandb entity (team or username, leave empty for default): " _ENTITY
    if [ -n "$_ENTITY" ]; then
        export WANDB_ENTITY="$_ENTITY"
    fi

    # GPU count override
    read -rp "Number of GPUs to use [${_DETECTED_GPUS}]: " _NPROC
    export NPROC="${_NPROC:-${_DETECTED_GPUS}}"
fi

# --------------- Apply defaults for non-interactive --------------------------

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
echo "Next steps:"
echo "  ./run_all.sh          # run 6-layer ablations"
echo "  ./run_all.sh --48l    # run 48-layer ablations"
echo "  ./run_all.sh --all    # run all"
echo "========================="
echo ""
