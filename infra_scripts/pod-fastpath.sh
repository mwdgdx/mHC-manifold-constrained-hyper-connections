#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/load_project_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$script_dir/load_project_env.sh"
fi

usage() {
  cat <<'EOF'
Usage: pod-fastpath.sh [options]

Options:
  --workdir <path>      Repo path on fast disk (default: /root/work/mHC-manifold-constrained-hyper-connections)
  --data-dir <path>     FineWeb data root (default: /mnt/data/fineweb10B)
  --out-root <path>     Persistent output root (default: $OPS_REMOTE_OUTPUTS_DIR or /mnt/pod_artifacts/outputs)
  --repo-url <url>      Git repo URL (default: https://github.com/tokenbender/mHC-manifold-constrained-hyper-connections.git)
  --branch <name>       Branch to checkout (optional)
  --pr <number>         GitHub PR number to checkout (optional)
  --download-fineweb    Download 1 train + 1 val shard if missing
  --ssh-dir <path>      Persisted SSH dir on /mnt (default: /mnt/.ssh if present, else /mnt/ssh)
  --no-ssh              Do not link SSH keys from /mnt into ~/.ssh
  -h, --help            Show this help

Environment overrides:
  WORKDIR, DATA_DIR, OUT_ROOT, REPO_URL, BRANCH, PR_NUMBER, DOWNLOAD_FINEWEB
  SETUP_SSH, SSH_DIR
  HF_HOME, UV_CACHE_DIR, PIP_CACHE_DIR
EOF
}

WORKDIR="${WORKDIR:-/root/work/mHC-manifold-constrained-hyper-connections}"
DATA_DIR="${DATA_DIR:-/mnt/data/fineweb10B}"
OUT_ROOT="${OUT_ROOT:-${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}}"
REPO_URL="${REPO_URL:-https://github.com/tokenbender/mHC-manifold-constrained-hyper-connections.git}"
BRANCH="${BRANCH:-}"
PR_NUMBER="${PR_NUMBER:-}"
DOWNLOAD_FINEWEB="${DOWNLOAD_FINEWEB:-0}"
SETUP_SSH="${SETUP_SSH:-1}"
SSH_DIR="${SSH_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --out-root)
      OUT_ROOT="$2"
      shift 2
      ;;
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --pr)
      PR_NUMBER="$2"
      shift 2
      ;;
    --download-fineweb)
      DOWNLOAD_FINEWEB=1
      shift
      ;;
    --no-ssh)
      SETUP_SSH=0
      shift
      ;;
    --ssh-dir)
      SSH_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$BRANCH" && -n "$PR_NUMBER" ]]; then
  echo "Use either --branch or --pr, not both" >&2
  exit 2
fi

setup_ssh_from_mnt() {
  if [[ "$SETUP_SSH" != "1" ]]; then
    return 0
  fi

  local candidate=""
  if [[ -n "$SSH_DIR" ]]; then
    candidate="$SSH_DIR"
  elif [[ -d /mnt/.ssh ]]; then
    candidate="/mnt/.ssh"
  elif [[ -d /mnt/ssh ]]; then
    candidate="/mnt/ssh"
  else
    return 0
  fi

  if [[ ! -d "$candidate" ]]; then
    echo "SSH dir not found: $candidate" >&2
    return 2
  fi

  if [[ -e "$HOME/.ssh" && ! -L "$HOME/.ssh" ]]; then
    mv "$HOME/.ssh" "$HOME/.ssh.bak-$(date +%Y%m%d-%H%M%S)"
  elif [[ -L "$HOME/.ssh" ]]; then
    rm -f "$HOME/.ssh"
  fi

  ln -s "$candidate" "$HOME/.ssh"

  chmod 700 "$candidate" 2>/dev/null || true
  if command -v find >/dev/null 2>&1; then
    find "$candidate" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
  fi

  mkdir -p "$candidate"
  touch "$candidate/known_hosts"
  if command -v ssh-keyscan >/dev/null 2>&1; then
    ssh-keyscan -H github.com >> "$candidate/known_hosts" 2>/dev/null || true
  fi
}

mkdir -p "$(dirname "$WORKDIR")"

setup_ssh_from_mnt

if [[ -d "$WORKDIR/.git" ]]; then
  git -C "$WORKDIR" fetch origin
else
  git clone "$REPO_URL" "$WORKDIR"
fi

if [[ -n "$PR_NUMBER" ]]; then
  git -C "$WORKDIR" fetch origin "pull/$PR_NUMBER/head:pr-$PR_NUMBER"
  git -C "$WORKDIR" checkout "pr-$PR_NUMBER"
elif [[ -n "$BRANCH" ]]; then
  git -C "$WORKDIR" checkout "$BRANCH"
fi

if git -C "$WORKDIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  git -C "$WORKDIR" pull
fi

if [[ ! -x "$WORKDIR/.venv/bin/python" ]]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv "$WORKDIR/.venv" --python python3
  else
    python3 -m venv "$WORKDIR/.venv"
  fi
fi

mkdir -p /mnt/hf
export HF_HOME="${HF_HOME:-/mnt/hf}"

# Keep dependency caches on fast local disk (volumes are slower)
mkdir -p "$HOME/.cache/uv" "$HOME/.cache/pip"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HOME/.cache/pip}"

if command -v uv >/dev/null 2>&1; then
  uv pip install -U pip
  uv pip install -e "$WORKDIR[examples]"
else
  "$WORKDIR/.venv/bin/python" -m pip install -U pip
  "$WORKDIR/.venv/bin/python" -m pip install -e "$WORKDIR[examples]"
fi

mkdir -p "$DATA_DIR"
mkdir -p "$OUT_ROOT"

train_shard=$(ls "$DATA_DIR"/fineweb_train_*.bin 2>/dev/null | head -n 1 || true)
val_shard=$(ls "$DATA_DIR"/fineweb_val_*.bin 2>/dev/null | head -n 1 || true)

if [[ -z "$train_shard" || -z "$val_shard" ]]; then
  if [[ "$DOWNLOAD_FINEWEB" == "1" ]]; then
    "$WORKDIR/.venv/bin/python" -m pip install -q huggingface_hub
    FINEWEB10B_LOCAL_DIR="$DATA_DIR" "$WORKDIR/.venv/bin/python" "$WORKDIR/examples/nanogpt/data/fineweb10B/download.py" 1
  else
    echo "FineWeb shards missing in $DATA_DIR" >&2
    echo "Run with --download-fineweb or set DOWNLOAD_FINEWEB=1" >&2
    exit 2
  fi
fi

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  export OPS_REMOTE_REPO="$WORKDIR"
  export OPS_DEFAULT_HOST="${OPS_DEFAULT_HOST:-lium}"
  export MHC_DATA_DIR="$DATA_DIR"
  export MHC_OUT_ROOT="$OUT_ROOT"
else
  cat <<EOF
Setup complete.

To persist environment variables in this shell:
  export OPS_REMOTE_REPO="$WORKDIR"
  export OPS_DEFAULT_HOST="${OPS_DEFAULT_HOST:-lium}"
  export MHC_DATA_DIR="$DATA_DIR"
  export MHC_OUT_ROOT="$OUT_ROOT"
EOF
fi
