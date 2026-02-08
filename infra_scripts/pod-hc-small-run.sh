#!/usr/bin/env bash
set -euo pipefail

# Small remote training run for nanoGPT HyperConnections.
# Designed to be executed on a GPU pod via `lium exec <pod> --script infra_scripts/pod-hc-small-run.sh`.
#
# Configuration is via environment variables (so callers don't have to fight shell quoting):
# - RUN_ID: run identifier (default: pr-hc-small-<timestamp>)
# - REPO_DIR: repo path on the pod (default: /root/work/mHC-manifold-constrained-hyper-connections)
# - OUT_ROOT: output root (default: $OPS_REMOTE_OUTPUTS_DIR or /mnt/pod_artifacts/outputs)
# - CONFIG: config file under examples/nanogpt/ (default: config/train_fineweb10B_hc.py)
# - MAX_ITERS: training iterations (default: 50)
# - NPROC: torchrun processes (default: 8)
# - BATCH_SIZE: batch size per step (default: 8)
# - BLOCK_SIZE: block size (default: 256)
# - GRAD_ACCUM: gradient accumulation steps BEFORE division by world size (default: 8)
# - EVAL_INTERVAL: eval cadence (default: 10)
# - EVAL_ITERS: eval batches (default: 1)
# - LOG_INTERVAL: log cadence (default: 1)
# - WANDB_PROJECT: (default: mhc-nanogpt-dev)
#
# W&B behavior:
# - If WANDB credentials are available (WANDB_API_KEY or ~/.netrc), W&B logging is enabled.
# - Otherwise wandb_log=False and WANDB_MODE=disabled.

timestamp() {
  date +%Y%m%d-%H%M%S
}

RUN_ID="${RUN_ID:-pr-hc-small-$(timestamp)}"
REPO_DIR="${REPO_DIR:-/root/work/mHC-manifold-constrained-hyper-connections}"
OUT_ROOT="${OUT_ROOT:-${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}}"
CONFIG="${CONFIG:-config/train_fineweb10B_hc.py}"

MAX_ITERS="${MAX_ITERS:-50}"
NPROC="${NPROC:-8}"
BATCH_SIZE="${BATCH_SIZE:-8}"
BLOCK_SIZE="${BLOCK_SIZE:-256}"
GRAD_ACCUM="${GRAD_ACCUM:-8}"
EVAL_INTERVAL="${EVAL_INTERVAL:-10}"
EVAL_ITERS="${EVAL_ITERS:-1}"
LOG_INTERVAL="${LOG_INTERVAL:-1}"
WANDB_PROJECT="${WANDB_PROJECT:-mhc-nanogpt-dev}"

RUN_DIR="$OUT_ROOT/$RUN_ID"
NANOGPT_DIR="$REPO_DIR/examples/nanogpt"
PY="$REPO_DIR/.venv/bin/python"

mkdir -p "$RUN_DIR"

export RUN_ID REPO_DIR RUN_DIR CONFIG NPROC MAX_ITERS

has_valid_wandb_netrc() {
  [[ -f "$HOME/.netrc" ]] || return 1
  python3 - <<'PY'
import netrc

try:
    n = netrc.netrc()
    auth = n.authenticators('api.wandb.ai')
except Exception:
    auth = None

raise SystemExit(0 if auth else 1)
PY
}

ensure_wandb_creds() {
  # Preferred durable mechanism: ~/.netrc.
  # If the pod has a persisted key script on /mnt, run it to write ~/.netrc.
  if [[ -f "/mnt/set-wandb-api-key.sh" ]]; then
    bash /mnt/set-wandb-api-key.sh || true
  fi

  # Back-compat: if the /mnt script only exports the key, source it and write ~/.netrc.
  if [[ -z "${WANDB_API_KEY:-}" ]] && ! has_valid_wandb_netrc && [[ -f "/mnt/set-wandb-api-key.sh" ]]; then
    # shellcheck source=/dev/null
    source /mnt/set-wandb-api-key.sh || true
  fi

  # If we have a key in this shell, persist it to ~/.netrc so future non-interactive runs work
  # without relying on environment propagation (e.g. tmux server env).
  if [[ -n "${WANDB_API_KEY:-}" ]]; then
    python3 - <<'PY'
import os
import pathlib
import re

key = os.environ.get('WANDB_API_KEY')
if not key:
    raise SystemExit(0)

netrc_path = pathlib.Path.home() / '.netrc'
text = netrc_path.read_text() if netrc_path.exists() else ''
lines = text.splitlines()

out = []
i = 0
machine_re = re.compile(r'^\s*machine\s+\S+')
target_re = re.compile(r'^\s*machine\s+api\.wandb\.ai\b')

while i < len(lines):
    if target_re.match(lines[i]) or 'api.wandb.ai' in lines[i]:
        i += 1
        while i < len(lines) and not machine_re.match(lines[i]):
            i += 1
        continue
    out.append(lines[i])
    i += 1

out.extend([
    'machine api.wandb.ai',
    '  login user',
    f'  password {key}',
])

netrc_path.write_text('\n'.join(out).rstrip() + '\n')
netrc_path.chmod(0o600)
PY

    # Avoid leaking into process env / tmux server env; netrc is sufficient.
    unset WANDB_API_KEY
  fi
}

ensure_wandb_creds || true

if [[ ! -x "$PY" ]]; then
  echo "ERROR: venv python not found at $PY" >&2
  echo "Expected repo at: $REPO_DIR" >&2
  exit 1
fi

if [[ ! -d "$NANOGPT_DIR" ]]; then
  echo "ERROR: nanogpt dir missing at $NANOGPT_DIR" >&2
  exit 1
fi

# Ensure at least 1 val + 1 train shard present (symlinked into repo data dir).
DATA_DIR="$NANOGPT_DIR/data/fineweb10B"
mkdir -p /mnt/data/fineweb10B /mnt/hf
export HF_HOME="${HF_HOME:-/mnt/hf}"

has_shards() {
  compgen -G "$DATA_DIR/fineweb_val_*.bin" >/dev/null \
    && compgen -G "$DATA_DIR/fineweb_train_*.bin" >/dev/null
}

if ! has_shards; then
  echo "FineWeb shards missing; downloading 1 train shard + 1 val shard..." >&2
  cd "$DATA_DIR"
  "$PY" download.py 1
  cp -n fineweb_val_000000.bin /mnt/data/fineweb10B/ || true
  cp -n fineweb_train_000001.bin /mnt/data/fineweb10B/ || true
  rm -f fineweb_val_000000.bin fineweb_train_000001.bin
  ln -sf /mnt/data/fineweb10B/fineweb_val_000000.bin fineweb_val_000000.bin
  ln -sf /mnt/data/fineweb10B/fineweb_train_000001.bin fineweb_train_000001.bin
fi

# Record run metadata (no secrets)
cd "$REPO_DIR"
"$PY" - <<PY
import json, os, subprocess, time
repo = os.environ['REPO_DIR']
run_dir = os.environ['RUN_DIR']
def sh(*args):
  return subprocess.check_output(list(args), text=True).strip()
meta = {
  'run_id': os.environ['RUN_ID'],
  'ts': int(time.time()),
  'pod_hostname': os.environ.get('HOSTNAME',''),
  'git_commit': sh('git','-C',repo,'rev-parse','HEAD'),
  'git_branch': sh('git','-C',repo,'rev-parse','--abbrev-ref','HEAD'),
  'config': os.environ['CONFIG'],
  'nproc': int(os.environ['NPROC']),
  'max_iters': int(os.environ['MAX_ITERS']),
}
with open(os.path.join(run_dir,'run_metadata.json'),'w') as f:
  json.dump(meta, f, indent=2, sort_keys=True)
PY

WANDB_LOG="False"
WANDB_MODE="disabled"
if [[ -n "${WANDB_API_KEY:-}" ]]; then
  WANDB_LOG="True"
  WANDB_MODE="online"
elif has_valid_wandb_netrc; then
  WANDB_LOG="True"
  WANDB_MODE="online"
fi

echo "WANDB_MODE=$WANDB_MODE (wandb_log=$WANDB_LOG)"

CMD=(
  "HF_HOME=$HF_HOME"
  "WANDB_MODE=$WANDB_MODE"
  "WANDB_RESUME=allow"
  "WANDB_RUN_ID=$RUN_ID"
  "WANDB_DIR=$RUN_DIR/wandb"
  "WANDB_CACHE_DIR=/mnt/wandb-cache"
  "WANDB_CONFIG_DIR=/mnt/wandb-config"
  "$PY"
  "-m"
  "torch.distributed.run"
  "--standalone"
  "--nproc_per_node=$NPROC"
  "train.py"
  "$CONFIG"
  "max_iters=$MAX_ITERS"
  "eval_interval=$EVAL_INTERVAL"
  "eval_iters=$EVAL_ITERS"
  "log_interval=$LOG_INTERVAL"
  "batch_size=$BATCH_SIZE"
  "block_size=$BLOCK_SIZE"
  "gradient_accumulation_steps=$GRAD_ACCUM"
  "wandb_log=$WANDB_LOG"
  "wandb_project=\"$WANDB_PROJECT\""
  "wandb_run_name=\"$RUN_ID\""
  "out_dir=\"$RUN_DIR\""
)

printf '%s\n' "${CMD[*]}" > "$RUN_DIR/command.sh"
chmod +x "$RUN_DIR/command.sh"

cd "$NANOGPT_DIR"

SESSION="hc-$RUN_ID"
mkdir -p /mnt/wandb-cache /mnt/wandb-config "$RUN_DIR/wandb"

if command -v tmux >/dev/null 2>&1; then
  tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION" || true
  tmux new-session -d -s "$SESSION" "bash -lc '$RUN_DIR/command.sh 2>&1 | tee $RUN_DIR/stdout.log'"
  echo "STARTED_TMUX_SESSION=$SESSION"
else
  bash -lc "$RUN_DIR/command.sh 2>&1 | tee $RUN_DIR/stdout.log"
fi

echo "RUN_ID=$RUN_ID"
echo "RUN_DIR=$RUN_DIR"
ls -la "$RUN_DIR" | sed -n '1,40p'
