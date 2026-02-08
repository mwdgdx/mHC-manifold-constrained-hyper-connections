#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/load_project_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$script_dir/load_project_env.sh"
fi

usage() {
  cat <<'EOF'
Usage: pod-smoke-run.sh [options]

Options:
  --workdir <path>        Repo path (default: $OPS_REMOTE_REPO or /root/work/mHC-manifold-constrained-hyper-connections)
  --config <path>         Train config (default: examples/nanogpt/config/train_fineweb10B_mhc.py)
  --run-id <id>           Run id (default: pr-smoke-<timestamp>)
  --out-root <path>       Output root (default: $OPS_REMOTE_OUTPUTS_DIR or /mnt/pod_artifacts/outputs)
  --out-local <path>      Training out_dir (default: <out-root>/<run-id>)
  --max-iters <n>          (default: 20)
  --eval-interval <n>      (default: 10)
  --eval-iters <n>         (default: 5)
  --batch-size <n>         (default: 8)
  --block-size <n>         (default: 256)
  --wandb-log <auto|true|false> (default: auto)
  --wandb-project <name>   (default: mhc-smoke)
  --wandb-group <name>     (default: smoke)
  --wandb-job-type <name>  (default: smoke)
  --wandb-run-name <name>  (default: <run-id>)
  --no-tmux               Run in foreground
  --watch-interval <sec>  (default: 120)
  -h, --help              Show this help
EOF
}

WORKDIR="${WORKDIR:-${OPS_REMOTE_REPO:-/root/work/mHC-manifold-constrained-hyper-connections}}"
CONFIG="${CONFIG:-$WORKDIR/examples/nanogpt/config/train_fineweb10B_mhc.py}"
RUN_ID="${RUN_ID:-pr-smoke-$(date +%Y%m%d-%H%M%S)}"
OUT_ROOT="${OUT_ROOT:-${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}}"
OUT_LOCAL="${OUT_LOCAL:-}"

MAX_ITERS="${MAX_ITERS:-20}"
EVAL_INTERVAL="${EVAL_INTERVAL:-10}"
EVAL_ITERS="${EVAL_ITERS:-5}"
BATCH_SIZE="${BATCH_SIZE:-8}"
BLOCK_SIZE="${BLOCK_SIZE:-256}"

WANDB_LOG="${WANDB_LOG:-auto}"
WANDB_PROJECT="${WANDB_PROJECT:-mhc-smoke}"
WANDB_GROUP="${WANDB_GROUP:-smoke}"
WANDB_JOB_TYPE="${WANDB_JOB_TYPE:-smoke}"
WANDB_RUN_NAME="${WANDB_RUN_NAME:-$RUN_ID}"

TMUX_MODE=1
WATCH_INTERVAL="${WATCH_INTERVAL:-120}"

ensure_wandb_netrc() {
  # Prefer ~/.netrc for non-interactive sessions. If a persistent key export
  # exists on /mnt, source it and write/update ~/.netrc.
  if [[ -z "${WANDB_API_KEY:-}" && -f "/mnt/set-wandb-api-key.sh" ]]; then
    # shellcheck source=/dev/null
    source /mnt/set-wandb-api-key.sh || true
  fi

  if [[ -z "${WANDB_API_KEY:-}" ]]; then
    return 0
  fi

  "$PYTHON" - <<'PY'
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

  # Don't leak into tmux server env; netrc is sufficient.
  unset WANDB_API_KEY
}

has_wandb_creds() {
  [[ -n "${WANDB_API_KEY:-}" ]] && return 0
  [[ -f "$HOME/.netrc" ]] || return 1
  "$PYTHON" - <<'PY'
import netrc

try:
    n = netrc.netrc()
    auth = n.authenticators('api.wandb.ai')
except Exception:
    auth = None

raise SystemExit(0 if auth else 1)
PY
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --out-root) OUT_ROOT="$2"; shift 2 ;;
    --out-local) OUT_LOCAL="$2"; shift 2 ;;
    --max-iters) MAX_ITERS="$2"; shift 2 ;;
    --eval-interval) EVAL_INTERVAL="$2"; shift 2 ;;
    --eval-iters) EVAL_ITERS="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --block-size) BLOCK_SIZE="$2"; shift 2 ;;
    --wandb-log) WANDB_LOG="$2"; shift 2 ;;
    --wandb-project) WANDB_PROJECT="$2"; shift 2 ;;
    --wandb-group) WANDB_GROUP="$2"; shift 2 ;;
    --wandb-job-type) WANDB_JOB_TYPE="$2"; shift 2 ;;
    --wandb-run-name) WANDB_RUN_NAME="$2"; shift 2 ;;
    --watch-interval) WATCH_INTERVAL="$2"; shift 2 ;;
    --no-tmux) TMUX_MODE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

PYTHON="$WORKDIR/.venv/bin/python"
if [[ ! -x "$PYTHON" ]]; then
  echo "Missing venv: $PYTHON" >&2
  exit 2
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Config not found: $CONFIG" >&2
  exit 2
fi

DATA_DIR="${DATA_DIR:-/mnt/data/fineweb10B}"
train_shard=$(ls "$DATA_DIR"/fineweb_train_*.bin 2>/dev/null | head -n 1 || true)
val_shard=$(ls "$DATA_DIR"/fineweb_val_*.bin 2>/dev/null | head -n 1 || true)
if [[ -z "$train_shard" || -z "$val_shard" ]]; then
  echo "FineWeb shards missing in $DATA_DIR" >&2
  exit 2
fi

run_dir="$WORKDIR/examples/nanogpt"
RUN_DIR="$OUT_ROOT/$RUN_ID"

if [[ -z "$OUT_LOCAL" ]]; then
  OUT_LOCAL="$RUN_DIR"
fi

mkdir -p "$OUT_LOCAL" "$RUN_DIR"

if [[ "$WANDB_LOG" == "auto" ]]; then
  ensure_wandb_netrc || true
  if has_wandb_creds; then
    WANDB_LOG_VALUE=True
  else
    WANDB_LOG_VALUE=False
  fi
elif [[ "$WANDB_LOG" == "true" ]]; then
  ensure_wandb_netrc || true
  if ! has_wandb_creds; then
    echo "wandb_log=true requested but no credentials found." >&2
    echo "Fix: run /mnt/bootstrap-pod.sh (should write ~/.netrc), or run: python -m wandb login" >&2
    exit 2
  fi
  WANDB_LOG_VALUE=True
else
  WANDB_LOG_VALUE=False
fi

WANDB_MODE_VALUE="disabled"
if [[ "$WANDB_LOG_VALUE" == "True" ]]; then
  WANDB_MODE_VALUE="online"
fi

mkdir -p "/mnt/wandb-cache" "/mnt/wandb-config" "$RUN_DIR/wandb"

cmd=(
  env
  "WANDB_MODE=$WANDB_MODE_VALUE"
  "WANDB_RESUME=allow"
  "WANDB_RUN_ID=$RUN_ID"
  "WANDB_DIR=$RUN_DIR/wandb"
  "WANDB_CACHE_DIR=/mnt/wandb-cache"
  "WANDB_CONFIG_DIR=/mnt/wandb-config"
  "$PYTHON" "train.py" "$CONFIG"
  "data_dir=$DATA_DIR"
  "max_iters=$MAX_ITERS"
  "eval_interval=$EVAL_INTERVAL"
  "eval_iters=$EVAL_ITERS"
  "batch_size=$BATCH_SIZE"
  "block_size=$BLOCK_SIZE"
  "wandb_log=$WANDB_LOG_VALUE"
  "wandb_project=$WANDB_PROJECT"
  "wandb_group=$WANDB_GROUP"
  "wandb_job_type=$WANDB_JOB_TYPE"
  "wandb_run_name=$WANDB_RUN_NAME"
  "out_dir=$OUT_LOCAL"
)

cmd_str=""
for arg in "${cmd[@]}"; do
  cmd_str+=$(printf ' %q' "$arg")
done
cmd_str=${cmd_str# }

stdout_log="$RUN_DIR/stdout.log"
watch_log="$RUN_DIR/watch.log"
sync_log="$RUN_DIR/sync.log"

if [[ "$TMUX_MODE" == "1" ]]; then
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux not found. Install it or rerun with --no-tmux." >&2
    exit 2
  fi

  session="smoke-$RUN_ID"
  watch_session="watch-$RUN_ID"
  tmux new -d -s "$session" "cd $run_dir && $cmd_str > $stdout_log 2>&1"

  watch_cmd="while tmux has-session -t $session 2>/dev/null; do date >> $watch_log; tail -n 20 $stdout_log >> $watch_log 2>/dev/null || true; echo '---' >> $watch_log; sleep $WATCH_INTERVAL; done; if [[ $OUT_LOCAL != $RUN_DIR ]]; then $WORKDIR/infra_scripts/pod-sync.sh --out-local $OUT_LOCAL --out-root $OUT_ROOT --run-id $RUN_ID >> $sync_log 2>&1; fi; date >> $watch_log; echo DONE >> $watch_log"
  tmux new -d -s "$watch_session" "bash -lc $(printf %q "$watch_cmd")"

  cat <<EOF
Run started.
  session: $session
  watch session: $watch_session
  stdout log: $stdout_log
  watch log: $watch_log
  run dir: $RUN_DIR
EOF
  exit 0
fi

(cd "$run_dir" && "${cmd[@]}" > "$stdout_log" 2>&1)
if [[ "$OUT_LOCAL" != "$RUN_DIR" ]]; then
  "$WORKDIR/infra_scripts/pod-sync.sh" --out-local "$OUT_LOCAL" --out-root "$OUT_ROOT" --run-id "$RUN_ID" >> "$sync_log" 2>&1
fi

cat <<EOF
Run completed.
  stdout log: $stdout_log
  run dir: $RUN_DIR
EOF
