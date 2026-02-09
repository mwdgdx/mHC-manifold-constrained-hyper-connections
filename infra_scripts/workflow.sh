#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CONFIG_PATH="${WORKFLOW_CONFIG:-${SCRIPT_DIR}/workflow.env}"

WF_RC_SENTINEL="__WF_RC__"

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "wf: $*" >&2
}

require_var() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    die "missing required config: $name (set it in ${CONFIG_PATH})"
  fi
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

shell_escape() {
  # bash-specific escaping for safe `bash -lc <cmd>` transport.
  printf '%q' "$1"
}

load_config() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    die "config file not found: ${CONFIG_PATH}"
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
}

remote_id() {
  # Prefer Lium target if configured; fallback to ssh host alias.
  if [[ -n "${LIUM_TARGET:-}" ]]; then
    echo "lium:${LIUM_TARGET}"
    return 0
  fi
  if [[ -n "${OPS_DEFAULT_HOST:-}" ]]; then
    echo "ssh:${OPS_DEFAULT_HOST}"
    return 0
  fi
  die "set either LIUM_TARGET (preferred) or OPS_DEFAULT_HOST in ${CONFIG_PATH}"
}

remote_exec_raw() {
  local cmd="$1"
  local rid
  rid="$(remote_id)"

  if [[ "$rid" == lium:* ]]; then
    command -v lium >/dev/null 2>&1 || die "lium CLI not found on PATH"
    local target="${rid#lium:}"
    local wrapped
    wrapped="$cmd"$'\n'"rc=\$?; echo ${WF_RC_SENTINEL}=\$rc; exit \$rc"

    local out
    out="$(lium exec "$target" "bash -lc $(shell_escape "$wrapped")" 2>&1 || true)"

    local remote_rc=""
    while IFS= read -r line; do
      if [[ "$line" == "${WF_RC_SENTINEL}="* ]]; then
        remote_rc="${line#${WF_RC_SENTINEL}=}"
        remote_rc="${remote_rc//$'\r'/}"
        continue
      fi
      printf '%s\n' "$line"
    done <<<"$out"

    # If the sentinel never appeared, the remote command likely never ran.
    [[ -n "$remote_rc" ]] || return 1
    [[ "$remote_rc" == "0" ]] || return "$remote_rc"
    return 0
  fi

  local host="${rid#ssh:}"
  ssh "$host" "bash -lc $(shell_escape "$cmd")"
}

remote_exec_env() {
  # Run a command after sourcing the remote env file.
  # This keeps remote steps consistent with config-driven values.
  require_var REMOTE_ENV_PATH
  local cmd="$1"
  # Auto-export variables from the env file so subprocesses (python, tmux panes)
  # can reliably read the workflow config.
  remote_exec_raw "set -euo pipefail; set -a; source \"$REMOTE_ENV_PATH\"; set +a; $cmd"
}

remote_mkdir_p() {
  local path="$1"
  remote_exec_raw "mkdir -p $(shell_escape "$path")"
}

remote_upload() {
  local local_path="$1"
  local remote_path="$2"
  local rid
  rid="$(remote_id)"

  if [[ "$rid" == lium:* ]]; then
    command -v lium >/dev/null 2>&1 || die "lium CLI not found on PATH"
    local target="${rid#lium:}"
    local out
    out="$(lium scp "$target" "$local_path" "$remote_path" 2>&1 || true)"
    local ok=1
    while IFS= read -r line; do
      printf '%s\n' "$line"
      case "$line" in
        Failed:*|Error:*|"No pods match targets"*|"No active pods"*|"Failed to upload"*) ok=0 ;;
      esac
    done <<<"$out"
    [[ "$ok" == 1 ]] || return 1
    remote_exec_raw "test -e $(shell_escape "$remote_path")"
    return 0
  fi

  local host="${rid#ssh:}"
  scp "$local_path" "${host}:${remote_path}"
}

remote_download() {
  local remote_path="$1"
  local local_path="$2"
  local rid
  rid="$(remote_id)"

  if [[ "$rid" == lium:* ]]; then
    command -v lium >/dev/null 2>&1 || die "lium CLI not found on PATH"
    local target="${rid#lium:}"
    local out
    out="$(lium scp "$target" "$remote_path" "$local_path" -d 2>&1 || true)"
    local ok=1
    while IFS= read -r line; do
      printf '%s\n' "$line"
      case "$line" in
        Failed:*|Error:*|"No pods match targets"*|"No active pods"*|"Failed to download"*) ok=0 ;;
      esac
    done <<<"$out"
    [[ "$ok" == 1 ]] || return 1
    [[ -e "$local_path" ]] || return 1
    return 0
  fi

  local host="${rid#ssh:}"
  scp "${host}:${remote_path}" "$local_path"
}

config_sync() {
  load_config
  require_var REMOTE_ENV_PATH
  remote_mkdir_p "$(dirname -- "$REMOTE_ENV_PATH")"
  remote_upload "$CONFIG_PATH" "$REMOTE_ENV_PATH"
  remote_exec_raw "chmod 600 $(shell_escape "$REMOTE_ENV_PATH") || true"
  log "synced config to ${REMOTE_ENV_PATH} on $(remote_id)"
}

cmd_help() {
  cat <<'EOF'
Usage: infra_scripts/workflow.sh <command> [args]

Config:
  - Default: infra_scripts/workflow.env
  - Override: WORKFLOW_CONFIG=/path/to/file

Commands (local entrypoints):
  pod-up                     Create a pod via lium (optional)
  pod-wait                   Wait until the pod is reachable over SSH
  pod-delete                 Delete the current pod (LIUM_TARGET)
  pod-butter                 Create pod and recreate if SSH >5min
  pod-status                 Check pod reachability and /mnt mount
  config-sync                Upload config to REMOTE_ENV_PATH (default /mnt/project.env)
  bootstrap                  Install prereqs (optional) + run BOOTSTRAP_SCRIPT/WANDB_SETUP_SCRIPT if present
  checkout                   Clone repo + checkout branch/PR + create venv + install deps + validate data/output dirs

  task-run                    Run a tracked remote task in tmux (state machine + logs)
  task-status                 Show task status and tail logs
  task-wait                   Block until a task completes (success/fail/timeout)
  task-list                   List recent tasks

  sweep-csv-template         Create a starter sweep CSV at SWEEP_CSV (local)
  workflow-sync              Deprecated (git is source of truth; no repo sync)
  sweep-start                Upload sweep CSV + start a sequential torchrun sweep in tmux
  sweep-status               Summarize sweep progress from SWEEP_CSV + outputs root
  fetch-run <run_id>         Fetch a single run directory into LOCAL_ARTIFACTS_DIR/<run_id>/

Commands (remote/internal):
  _sweep_run_all             Runs the sweep sequentially (used by tmux window)
  _sweep_status              Prints progress summary (used by sweep-status)
EOF
}

validate_id() {
  local kind="$1"
  local id="$2"
  if [[ -z "$id" ]]; then
    die "missing ${kind} id"
  fi
  if [[ ! "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    die "invalid ${kind} id: ${id} (allowed: [A-Za-z0-9._-], max 128 chars, must start alnum)"
  fi
}

b64_encode() {
  # Cross-platform base64 encoding (removes newlines).
  printf '%s' "$1" | base64 | tr -d '\n'
}

ts_prefix() {
  python3 -u -c $'import sys\nfrom datetime import datetime\n\nfor line in sys.stdin:\n    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")\n    sys.stdout.write(f"[{ts}] {line}")\n    sys.stdout.flush()'
}

cmd_task_run() {
  load_config
  config_sync
  require_var OPS_REMOTE_OUTPUTS_DIR

  local task_id=""
  local task_cmd=""
  local timeout_secs="${TASK_TIMEOUT_SECS:-0}"
  local tmux_session="${WF_TMUX_SESSION:-wf}"
  local workdir=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        task_id="$2"
        shift 2
        ;;
      --cmd)
        task_cmd="$2"
        shift 2
        ;;
      --timeout-secs)
        timeout_secs="$2"
        shift 2
        ;;
      --tmux-session)
        tmux_session="$2"
        shift 2
        ;;
      --workdir)
        workdir="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      *)
        die "unknown arg for task-run: $1"
        ;;
    esac
  done

  validate_id "task" "$task_id"
  [[ -n "$task_cmd" ]] || die "task-run requires --cmd"

  if [[ ! "$timeout_secs" =~ ^[0-9]+$ ]]; then
    die "--timeout-secs must be an integer (seconds), got: $timeout_secs"
  fi

  local cmd_b64
  cmd_b64="$(b64_encode "$task_cmd")"

  local remote_script
  remote_script+=$(cat <<EOF
TASK_ID=$(shell_escape "$task_id")
TASK_TMUX_SESSION=$(shell_escape "$tmux_session")
TASK_TIMEOUT_SECS=$(shell_escape "$timeout_secs")
TASK_WORKDIR=$(shell_escape "$workdir")
TASK_FORCE=$(shell_escape "$force")
TASK_CMD_B64=$(shell_escape "$cmd_b64")
EOF
)

  remote_script+=$'\n'

  remote_script+=$(cat <<'EOF'
tasks_root="$OPS_REMOTE_OUTPUTS_DIR/_tasks"
task_dir="$tasks_root/$TASK_ID"

mkdir -p "$tasks_root"

if [[ -d "$task_dir" ]]; then
  if [[ "$TASK_FORCE" == 1 ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    mv "$task_dir" "${task_dir}.bak-${ts}"
  else
    echo "task already exists: $task_dir (use --force to overwrite)" >&2
    exit 2
  fi
fi

mkdir -p "$task_dir"

cmd_path="$task_dir/command.sh"
runner_path="$task_dir/run.sh"
stdout_path="$task_dir/stdout.log"
status_path="$task_dir/status.json"

export TASK_ID TASK_TMUX_SESSION TASK_TIMEOUT_SECS TASK_WORKDIR TASK_FORCE TASK_CMD_B64
export REMOTE_ENV_PATH
export task_dir cmd_path status_path

python3 - <<'PY'
import base64
import json
import os
import time

task_dir = os.environ["task_dir"]
cmd_path = os.environ["cmd_path"]
status_path = os.environ["status_path"]
cmd_b64 = os.environ["TASK_CMD_B64"]
workdir = os.environ.get("TASK_WORKDIR", "")
timeout_secs = int(os.environ.get("TASK_TIMEOUT_SECS", "0") or "0")
tmux_session = os.environ.get("TASK_TMUX_SESSION", "")

cmd = base64.b64decode(cmd_b64.encode("utf-8")).decode("utf-8")

with open(cmd_path, "w") as f:
    f.write("#!/usr/bin/env bash\n")
    f.write("set -euo pipefail\n")
    f.write("source \"%s\"\n" % os.environ.get("REMOTE_ENV_PATH", "/mnt/project.env"))
    if workdir:
        f.write("cd \"%s\"\n" % workdir)
    f.write(cmd)
    f.write("\n")

os.chmod(cmd_path, 0o755)

status = {
    "task_id": os.environ.get("TASK_ID", ""),
    "state": "pending",
    "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    "timeout_secs": timeout_secs,
    "tmux_session": tmux_session,
    "command_path": cmd_path,
    "stdout_log": os.path.join(task_dir, "stdout.log"),
}

with open(status_path, "w") as f:
    json.dump(status, f, indent=2, sort_keys=True)
PY

cat >"$runner_path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

source "${REMOTE_ENV_PATH:-/mnt/project.env}"

task_dir="$1"
cmd_path="$task_dir/command.sh"
stdout_path="$task_dir/stdout.log"
status_path="$task_dir/status.json"
timeout_secs="${TASK_TIMEOUT_SECS:-0}"

if [[ -n "${2:-}" ]]; then
  timeout_secs="$2"
fi

ts_prefix() {
  python3 -u -c $'import sys\nfrom datetime import datetime\n\nfor line in sys.stdin:\n    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")\n    sys.stdout.write(f"[{ts}] {line}")\n    sys.stdout.flush()'
}

python3 - <<'PY' "$status_path"
import json
import sys
import time

path = sys.argv[1]
with open(path, "r") as f:
    st = json.load(f)
st["state"] = "running"
st["started_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
with open(path, "w") as f:
    json.dump(st, f, indent=2, sort_keys=True)
PY

{
  echo "== preflight =="
  date
  echo "whoami=$(whoami)"
  echo "hostname=$(hostname)"
  echo "pwd=$(pwd)"
  echo "task_dir=$task_dir"
  echo "cmd_path=$cmd_path"
  echo "timeout_secs=$timeout_secs"
  command -v timeout >/dev/null 2>&1 || echo "warn: timeout not found"
  command -v python3 >/dev/null 2>&1 || echo "warn: python3 not found"
  command -v tmux   >/dev/null 2>&1 || echo "warn: tmux not found"
  echo "== /mnt =="
  ls -la /mnt | head -n 20 || true
  echo "== run =="
} 2>&1 | ts_prefix | tee -a "$stdout_path"

set +e
set -o pipefail

if [[ "$timeout_secs" != 0 ]]; then
  timeout --signal=TERM --kill-after=30s "$timeout_secs" bash "$cmd_path" 2>&1 | ts_prefix | tee -a "$stdout_path"
  rc=${PIPESTATUS[0]}
else
  bash "$cmd_path" 2>&1 | ts_prefix | tee -a "$stdout_path"
  rc=${PIPESTATUS[0]}
fi

set -e

state="failed"
if [[ "$rc" == 0 ]]; then
  state="success"
elif [[ "$rc" == 124 ]]; then
  state="timed_out"
fi

python3 - <<'PY' "$status_path" "$state" "$rc"
import json
import sys
import time

path, state, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, "r") as f:
    st = json.load(f)
st["state"] = state
st["exit_code"] = rc
st["ended_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
with open(path, "w") as f:
    json.dump(st, f, indent=2, sort_keys=True)
PY

exit "$rc"
SH

chmod +x "$runner_path"

command -v tmux >/dev/null 2>&1 || { echo "tmux is required for task-run (run bootstrap first)" >&2; exit 3; }

tmux has-session -t "$TASK_TMUX_SESSION" 2>/dev/null || tmux new-session -d -s "$TASK_TMUX_SESSION" -n overview
tmux set-option -t "$TASK_TMUX_SESSION" remain-on-exit on

window_base="task-$TASK_ID"
window="$window_base"
for i in $(seq 1 50); do
  if tmux list-windows -t "$TASK_TMUX_SESSION" -F '#{window_name}' | grep -qx "$window"; then
    window="${window_base}-$i"
  else
    break
  fi
done

export window status_path

python3 - <<'PY'
import json
import os
import time

status_path = os.environ["status_path"]
with open(status_path, "r") as f:
    st = json.load(f)
st["tmux_window"] = os.environ.get("window", "")
st["tmux_session"] = os.environ.get("TASK_TMUX_SESSION", "")
with open(status_path, "w") as f:
    json.dump(st, f, indent=2, sort_keys=True)
PY
run_cmd="bash \"$runner_path\" \"$task_dir\" \"$TASK_TIMEOUT_SECS\""
tmux new-window -t "$TASK_TMUX_SESSION" -n "$window" "bash -lc $(printf %q "$run_cmd")"

echo "task_id=$TASK_ID"
echo "task_dir=$task_dir"
echo "tmux=tmux attach -t $TASK_TMUX_SESSION"
echo "window=$window"
EOF
)

  remote_exec_env "$remote_script"
}

cmd_task_status() {
  load_config
  config_sync
  require_var OPS_REMOTE_OUTPUTS_DIR

  local task_id=""
  local tail_lines=80

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        task_id="$2"
        shift 2
        ;;
      --tail-lines)
        tail_lines="$2"
        shift 2
        ;;
      *)
        die "unknown arg for task-status: $1"
        ;;
    esac
  done

  validate_id "task" "$task_id"

  local remote_script=""
  remote_script+=$(cat <<EOF
TASK_ID=$(shell_escape "$task_id")
TAIL_LINES=$(shell_escape "$tail_lines")
EOF
)
  remote_script+=$'\n'

  remote_script+=$(cat <<'EOF'
task_dir="$OPS_REMOTE_OUTPUTS_DIR/_tasks/$TASK_ID"

echo "task_dir=$task_dir"

if [[ -f "$task_dir/status.json" ]]; then
  echo '--- status.json ---'
  cat "$task_dir/status.json"
else
  echo 'missing status.json'
fi

if [[ -f "$task_dir/stdout.log" ]]; then
  echo '--- tail stdout.log ---'
  tail -n "$TAIL_LINES" "$task_dir/stdout.log"
else
  echo 'missing stdout.log'
fi

echo '--- attach ---'
echo "tmux attach -t ${WF_TMUX_SESSION:-wf}"
EOF
)

  remote_exec_env "$remote_script"
}

cmd_task_list() {
  load_config
  config_sync
  require_var OPS_REMOTE_OUTPUTS_DIR

  remote_exec_env 'root="$OPS_REMOTE_OUTPUTS_DIR/_tasks"; mkdir -p "$root"; python3 - <<PY "$root"
import json
import os
import sys

root = sys.argv[1]
ids = sorted([d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))])

print("task_id\tstate\tstarted_at\tended_at")
for task_id in ids[-50:]:
    st_path = os.path.join(root, task_id, "status.json")
    if not os.path.exists(st_path):
        print(f"{task_id}\tmissing\t\t")
        continue
    try:
        with open(st_path, "r") as f:
            st = json.load(f)
        print(
            f"{task_id}\t{st.get('state','')}\t{st.get('started_at','')}\t{st.get('ended_at','')}"
        )
    except Exception:
        print(f"{task_id}\tparse_error\t\t")
PY'
}

cmd_task_wait() {
  load_config
  config_sync
  require_var OPS_REMOTE_OUTPUTS_DIR

  local task_id=""
  local timeout_secs=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        task_id="$2"
        shift 2
        ;;
      --timeout-secs)
        timeout_secs="$2"
        shift 2
        ;;
      *)
        die "unknown arg for task-wait: $1"
        ;;
    esac
  done

  validate_id "task" "$task_id"
  if [[ ! "$timeout_secs" =~ ^[0-9]+$ ]]; then
    die "--timeout-secs must be an integer (seconds), got: $timeout_secs"
  fi

  local remote_script=""
  remote_script+=$(cat <<EOF
TASK_ID=$(shell_escape "$task_id")
TIMEOUT_SECS=$(shell_escape "$timeout_secs")
EOF
)

  remote_script+=$'\n'

  remote_script+=$(cat <<'EOF'
task_dir="$OPS_REMOTE_OUTPUTS_DIR/_tasks/$TASK_ID"
status="$task_dir/status.json"

start="$(date +%s)"

while true; do
  if [[ -f "$status" ]]; then
    state="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state",""))' "$status" 2>/dev/null || true)"
    rc="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("exit_code",0))' "$status" 2>/dev/null || echo 0)"

    if [[ "$state" == success ]]; then
      exit 0
    fi
    if [[ "$state" == timed_out ]]; then
      exit 124
    fi
    if [[ "$state" == failed ]]; then
      exit "$rc"
    fi
  fi

  if [[ "$TIMEOUT_SECS" != 0 ]]; then
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= TIMEOUT_SECS )); then
      echo "timeout waiting for task" >&2
      exit 2
    fi
  fi

  sleep 5
done
EOF
)

  remote_exec_env "$remote_script"
}

cmd_pod_wait() {
  load_config

  local max_timeout_secs=480
  local timeout_secs=480
  local interval_secs=15
  local show_status_every=60

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout-secs)
        timeout_secs="$2"
        shift 2
        ;;
      --interval-secs)
        interval_secs="$2"
        shift 2
        ;;
      --show-status-every)
        show_status_every="$2"
        shift 2
        ;;
      *)
        die "unknown arg for pod-wait: $1"
        ;;
    esac
  done

  if (( timeout_secs > max_timeout_secs )); then
    log "clamping pod-wait timeout from ${timeout_secs}s to ${max_timeout_secs}s"
    timeout_secs="$max_timeout_secs"
  fi

  local start
  start="$(date +%s)"
  local last_status_ts="$start"

  while true; do
    # Don't spam output from lium when SSH isn't ready.
    if out="$(remote_exec_raw 'echo pod-ready' 2>&1)"; then
      log "pod is reachable"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= timeout_secs )); then
      log "last remote error (trimmed):"
      printf '%s\n' "$out" | sed -n '1,12p' >&2 || true
      die "timed out waiting for pod SSH after ${timeout_secs}s"
    fi

    if (( now - last_status_ts >= show_status_every )); then
      last_status_ts="$now"
      if command -v lium >/dev/null 2>&1; then
        log "lium ps (status snapshot):"
        lium ps || true
      fi
    fi

    log "waiting for pod SSH... (${elapsed}s elapsed)"
    sleep "$interval_secs"
  done
}

cmd_pod_delete() {
  load_config
  command -v lium >/dev/null 2>&1 || die "lium CLI not found on PATH"

  if [[ -z "${LIUM_TARGET:-}" ]]; then
    die "pod-delete requires LIUM_TARGET in ${CONFIG_PATH}"
  fi

  log "deleting pod: ${LIUM_TARGET}"
  if ! lium rm "${LIUM_TARGET}"; then
    log "lium rm failed; falling back to lium rm --all"
    lium rm --all
  fi
}

cmd_pod_butter() {
  # Butter policy:
  # - create a cheap pod
  # - wait up to 5 minutes for SSH
  # - if not reachable, delete and retry
  load_config
  command -v lium >/dev/null 2>&1 || die "lium CLI not found on PATH"

  local retries=3
  local wait_secs=300

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --retries)
        retries="$2"
        shift 2
        ;;
      --wait-secs)
        wait_secs="$2"
        shift 2
        ;;
      *)
        die "unknown arg for pod-butter: $1"
        ;;
    esac
  done

  for attempt in $(seq 1 "$retries"); do
    log "butter attempt ${attempt}/${retries}"

    # Best-effort cleanup of any previous pod with the same target.
    if [[ -n "${LIUM_TARGET:-}" ]]; then
      lium rm "${LIUM_TARGET}" >/dev/null 2>&1 || true
    fi

    cmd_pod_up

    if cmd_pod_wait --timeout-secs "$wait_secs"; then
      cmd_pod_status
      return 0
    fi

    log "pod not reachable after ${wait_secs}s; deleting and retrying"
    cmd_pod_delete || true
    sleep 5
  done

  die "failed to get a reachable pod after ${retries} attempts"
}

cmd_workflow_sync() {
  load_config
  config_sync
  cmd_checkout
  log "workflow-sync is deprecated: remote repo is updated via git checkout/pull"
}

cmd_pod_up() {
  load_config
  command -v lium >/dev/null 2>&1 || die "lium CLI not found on PATH"

  require_var LIUM_POD_NAME
  require_var LIUM_GPU
  require_var LIUM_COUNT

  local -a args
  args=(up)

  if [[ -n "${LIUM_EXECUTOR_ID:-}" ]]; then
    if [[ "${LIUM_EXECUTOR_ID}" =~ ^[0-9]+$ ]]; then
      die "refusing numeric LIUM_EXECUTOR_ID=${LIUM_EXECUTOR_ID}; use GPU filters (LIUM_GPU/LIUM_COUNT) or set a full executor UUID/HUID"
    fi
    args+=("$LIUM_EXECUTOR_ID")
  else
    args+=(--gpu "$LIUM_GPU" --count "$LIUM_COUNT")
    if [[ -n "${LIUM_COUNTRY:-}" ]]; then
      args+=(--country "$LIUM_COUNTRY")
    fi
    if [[ -n "${LIUM_PORTS:-}" ]]; then
      args+=(--ports "$LIUM_PORTS")
    fi
  fi

  args+=(--name "$LIUM_POD_NAME")

  if [[ -n "${LIUM_TTL:-}" ]]; then
    args+=(--ttl "$LIUM_TTL")
  fi

  if [[ -n "${LIUM_VOLUME:-}" ]]; then
    args+=(--volume "$LIUM_VOLUME")
  fi

  if is_truthy "${LIUM_YES:-0}"; then
    args+=(--yes)
  fi

  log "running: lium ${args[*]}"
  lium "${args[@]}"

  cat <<EOF

Next:
- Set LIUM_TARGET in ${CONFIG_PATH} (recommended: set it to \"${LIUM_POD_NAME}\")
- Then run: bash infra_scripts/workflow.sh pod-status
EOF
}

cmd_pod_status() {
  load_config
  log "local lium ps:"
  if command -v lium >/dev/null 2>&1; then
    lium ps || true
  else
    log "(lium CLI not found locally; skipping lium ps)"
  fi

  config_sync
  remote_exec_raw 'echo "[remote] whoami=$(whoami)"; echo "[remote] hostname=$(hostname)"; ls -la /mnt || true'
}

cmd_bootstrap() {
  load_config
  config_sync

  remote_exec_env 'command -v tmux >/dev/null 2>&1 || echo "tmux missing"; command -v git >/dev/null 2>&1 || echo "git missing"; command -v python3 >/dev/null 2>&1 || echo "python3 missing"'

  if is_truthy "${AUTO_INSTALL_PREREQS:-0}"; then
    remote_exec_env 'missing=0; for b in git tmux rsync curl python3; do command -v "$b" >/dev/null 2>&1 || missing=1; done; if [[ "$missing" == 1 ]]; then if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y $APT_PACKAGES; else echo "missing prereqs but apt-get unavailable"; exit 2; fi; fi'
  fi

  if [[ -n "${BOOTSTRAP_SCRIPT:-}" ]]; then
    # External helpers on /mnt are best-effort. They may assume a specific shell
    # state; don't let them break the workflow.
    remote_exec_env 'if [[ -f "$BOOTSTRAP_SCRIPT" ]]; then bash "$BOOTSTRAP_SCRIPT" || echo "warn: BOOTSTRAP_SCRIPT failed (continuing)"; else echo "skip: BOOTSTRAP_SCRIPT not found"; fi'
  fi

  if [[ -n "${WANDB_SETUP_SCRIPT:-}" ]]; then
    if is_truthy "${SWEEP_WANDB:-0}" || is_truthy "${RUN_WANDB_SETUP:-0}"; then
      remote_exec_env 'if [[ -f "$WANDB_SETUP_SCRIPT" ]]; then bash "$WANDB_SETUP_SCRIPT"; else echo "skip: WANDB_SETUP_SCRIPT not found"; fi'
    else
      log "skip: WANDB_SETUP_SCRIPT (SWEEP_WANDB=0 and RUN_WANDB_SETUP=0)"
    fi
  fi
}

cmd_checkout() {
  load_config
  config_sync

  require_var OPS_REMOTE_REPO
  require_var OPS_REMOTE_OUTPUTS_DIR
  require_var DATA_DIR
  require_var HF_HOME

  remote_exec_env '
mkdir -p "$OPS_REMOTE_OUTPUTS_DIR" "$DATA_DIR" "$HF_HOME"
mkdir -p "$(dirname -- "$OPS_REMOTE_REPO")"

if [[ ! -d "$OPS_REMOTE_REPO/.git" ]]; then
  if [[ -z "${REPO_URL:-}" ]]; then
    echo "REPO_URL is empty"
    exit 2
  fi
  git clone "$REPO_URL" "$OPS_REMOTE_REPO"
fi

 cd "$OPS_REMOTE_REPO"
 git fetch origin --prune

 dirty="$(git status --porcelain --untracked-files=no)"
 if [[ -n "$dirty" ]]; then
   if [[ "${CHECKOUT_FORCE_CLEAN:-0}" == 1 ]]; then
     echo "warn: repo has tracked modifications; resetting (CHECKOUT_FORCE_CLEAN=1)"
     git reset --hard HEAD
   else
     echo "error: repo has tracked modifications (refusing to proceed):"
     echo "$dirty"
     echo "set CHECKOUT_FORCE_CLEAN=1 to reset tracked files"
     exit 4
   fi
 fi

if [[ -n "${CHECKOUT_PR:-}" ]]; then
  git fetch origin "pull/${CHECKOUT_PR}/head:pr-${CHECKOUT_PR}"
  git checkout "pr-${CHECKOUT_PR}"
  else
    branch="${CHECKOUT_BRANCH:-main}"
    git show-ref --verify --quiet "refs/remotes/origin/$branch" || {
      echo "error: origin/$branch not found (did you push it?)"
      exit 6
    }
    git checkout -B "$branch" "origin/$branch"
  fi

 if [[ -n "${EXPECT_GIT_SHA:-}" ]]; then
   actual="$(git rev-parse HEAD)"
   if [[ "$actual" != "$EXPECT_GIT_SHA" ]]; then
     echo "error: repo HEAD mismatch"
     echo "expected: $EXPECT_GIT_SHA"
     echo "actual:   $actual"
     exit 5
   fi
 fi

py="${REMOTE_PYTHON_BIN:-python3}"
venv="$OPS_REMOTE_REPO/.venv"

recreate=0
if [[ "${VENV_RECREATE:-0}" == 1 ]]; then
  recreate=1
fi

if [[ -x "$venv/bin/python" ]]; then
  torch_file="$("$venv/bin/python" -c "import torch; print(torch.__file__)" 2>/dev/null || true)"
  if [[ -z "$torch_file" ]]; then
    recreate=1
  elif [[ "$torch_file" == "$venv"* ]]; then
    recreate=1
  fi
fi

if [[ "$recreate" == 1 ]]; then
  rm -rf "$venv"
fi

if [[ ! -x "$venv/bin/python" ]]; then
  "$py" -m venv --system-site-packages "$venv"
fi

# Enforced contract: image must provide GPU-enabled torch; workflow will NOT install torch.
"$venv/bin/python" - <<PY
import os
import torch

v = torch.__version__.split("+")[0]
parts = v.split(".")
ver = tuple(int(x) for x in parts[:3])

print(
    "torch",
    torch.__version__,
    "cuda",
    getattr(torch.version, "cuda", None),
    "avail",
    torch.cuda.is_available(),
    "file",
    torch.__file__,
)

if ver < (2, 3, 0):
    raise SystemExit(f"torch too old: {torch.__version__} (need >=2.3.0)")

if not torch.cuda.is_available():
    raise SystemExit("torch.cuda.is_available() is False; need GPU-enabled torch baked into image")

venv = os.environ.get("VIRTUAL_ENV", "")
tf = torch.__file__
if venv and tf.startswith(venv + os.sep):
    raise SystemExit(f"torch is installed inside venv: {tf} (not allowed)")
PY

"$venv/bin/python" -m pip install -U pip
"$venv/bin/python" -m pip install -e "$OPS_REMOTE_REPO[examples]"

# Post-check: ensure pip did not install torch into the venv.
"$venv/bin/python" - <<PY
import os
import torch

venv = os.environ.get("VIRTUAL_ENV", "")
tf = torch.__file__
print("torch_source", tf)

if venv and tf.startswith(venv + os.sep):
    raise SystemExit(f"pip installed torch into venv: {tf} (not allowed)")
PY

 if ls "$DATA_DIR"/fineweb_train_*.bin >/dev/null 2>&1 && ls "$DATA_DIR"/fineweb_val_*.bin >/dev/null 2>&1; then
   echo "fineweb shards present"
 else
   if [[ "${DOWNLOAD_FINEWEB:-0}" == 1 ]]; then
     download_dir="$DATA_DIR"
     if mount | grep -q "^s3fs on /mnt "; then
       if [[ "$DATA_DIR" == /mnt/* ]]; then
         download_dir="/root/data/_staging_fineweb10B"
         mkdir -p "$download_dir"
         echo "note: DATA_DIR is on /mnt (s3fs); staging FineWeb download to $download_dir"
       fi
     fi

     FINEWEB10B_LOCAL_DIR="$download_dir" "$venv/bin/python" "$OPS_REMOTE_REPO/examples/nanogpt/data/fineweb10B/download.py" 1

     if [[ "$download_dir" != "$DATA_DIR" ]]; then
       mkdir -p "$DATA_DIR"
       for f in "$download_dir"/fineweb_train_*.bin "$download_dir"/fineweb_val_*.bin; do
         [[ -f "$f" ]] || continue
         cp -f "$f" "$DATA_DIR/$(basename "$f")"
       done
       echo "copied staged FineWeb shards into $DATA_DIR"
     fi
   else
     echo "fineweb shards missing; set DOWNLOAD_FINEWEB=1 in config to auto-download"
     exit 3
   fi
 fi

target="$OPS_REMOTE_REPO/examples/nanogpt/data/fineweb10B"
mkdir -p "$target"
for f in "$DATA_DIR"/fineweb_train_*.bin "$DATA_DIR"/fineweb_val_*.bin; do
  ln -sf "$f" "$target/$(basename "$f")"
done
echo "linked fineweb shards into $target"
'
}

local_csv_path() {
  load_config
  require_var SWEEP_CSV

  if [[ "$SWEEP_CSV" = /* ]]; then
    echo "$SWEEP_CSV"
    return 0
  fi
  echo "${REPO_ROOT}/${SWEEP_CSV}"
}

remote_csv_path() {
  load_config
  require_var SWEEP_CSV
  require_var OPS_REMOTE_REPO

  if [[ "$SWEEP_CSV" = /* ]]; then
    echo "$SWEEP_CSV"
    return 0
  fi
  echo "${OPS_REMOTE_REPO}/${SWEEP_CSV}"
}

cmd_sweep_csv_template() {
  load_config
  local csv
  csv="$(local_csv_path)"
  mkdir -p "$(dirname -- "$csv")"

  if [[ -f "$csv" ]]; then
    die "refusing to overwrite existing CSV: $csv"
  fi

  cat >"$csv" <<'EOF'
run_id,config,seed,overrides,notes
mhc-6l-seed0,config/train_fineweb10B_mhc.py,0,"max_iters=20 eval_interval=10 eval_iters=5","smoke"
EOF

  log "wrote: $csv"
}

cmd_sweep_start() {
  load_config
  config_sync
  cmd_checkout

  local csv_local
  csv_local="$(local_csv_path)"
  if [[ ! -f "$csv_local" ]]; then
    die "sweep CSV missing: $csv_local (run: bash infra_scripts/workflow.sh sweep-csv-template)"
  fi

  require_var OPS_REMOTE_OUTPUTS_DIR

  # Keep the remote git checkout immutable: never write the sweep CSV into $OPS_REMOTE_REPO.
  # Upload it to outputs manifests and run from that absolute path.
  remote_exec_env 'mkdir -p "$OPS_REMOTE_OUTPUTS_DIR/_manifests"'
  local csv_remote_latest
  csv_remote_latest="$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-latest.csv"
  remote_upload "$csv_local" "$csv_remote_latest"
  remote_exec_env "ts=\"\$(date +%Y%m%d-%H%M%S)\"; cp -f \"$csv_remote_latest\" \"$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-\${ts}.csv\"; cp -f \"$REMOTE_ENV_PATH\" \"$OPS_REMOTE_OUTPUTS_DIR/_manifests/workflow-\${ts}.env\""

  require_var SWEEP_TMUX_SESSION

  local tmux_cmd
  tmux_cmd="$(cat <<EOF
session="\$SWEEP_TMUX_SESSION"
tmux has-session -t "\$session" 2>/dev/null || tmux new-session -d -s "\$session" -n overview
tmux set-option -t "\$session" remain-on-exit on
tmux list-windows -t "\$session" -F "#{window_name}" | grep -qx "sweep" && tmux kill-window -t "\$session":sweep 2>/dev/null || true
run_cmd="cd \"$OPS_REMOTE_REPO\" && WORKFLOW_CONFIG=\"$REMOTE_ENV_PATH\" bash infra_scripts/workflow.sh _sweep_run_all --csv \"$csv_remote_latest\""
tmux new-window -t "\$session" -n sweep "bash -lc \$(printf %q \"\$run_cmd\")"
echo "tmux attach -t \$session"
EOF
)"
  remote_exec_env "$tmux_cmd"
}

strip_quotes() {
  local s="$1"
  s="${s#\"}"
  s="${s%\"}"
  echo "$s"
}

summary_ok() {
  local path="$1"
  python3 - <<'PY' "$path"
import json, sys
p = sys.argv[1]
try:
    with open(p, "r") as f:
        obj = json.load(f)
    ok = obj.get("ok") is True
    print("true" if ok else "false")
except Exception:
    print("parse_error")
PY
}

detect_visible_gpu_count() {
  # Determine how many GPUs are visible to this process.
  # Preference order:
  # 1) CUDA_VISIBLE_DEVICES (explicit visibility)
  # 2) nvidia-smi (system visibility)
  # 3) torch.cuda.device_count() via repo venv
  local venv_python="$1"

  if [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
    local count=0
    local part
    IFS=',' read -r -a parts <<<"${CUDA_VISIBLE_DEVICES}"
    for part in "${parts[@]}"; do
      part="${part//[[:space:]]/}"
      [[ -n "$part" ]] || continue
      count=$((count + 1))
    done
    echo "$count"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    local n
    n="$(nvidia-smi -L 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
    if [[ -n "$n" && "$n" =~ ^[0-9]+$ ]]; then
      echo "$n"
      return 0
    fi
  fi

  "$venv_python" - <<'PY'
import torch
print(torch.cuda.device_count())
PY
}

cmd__sweep_run_all() {
  load_config
  require_var OPS_REMOTE_REPO
  require_var OPS_REMOTE_OUTPUTS_DIR
  require_var DATA_DIR
  require_var HF_HOME

  local sweep_dry_run="${SWEEP_DRY_RUN:-0}"

  local csv_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --csv) csv_arg="$2"; shift 2 ;;
      *) die "unknown arg for _sweep_run_all: $1" ;;
    esac
  done

  local csv
  if [[ -n "$csv_arg" ]]; then
    if [[ "$csv_arg" = /* ]]; then
      csv="$csv_arg"
    else
      csv="$OPS_REMOTE_REPO/$csv_arg"
    fi
  else
    require_var SWEEP_CSV
    csv="$(remote_csv_path)"
  fi
  [[ -f "$csv" ]] || die "remote sweep CSV not found: $csv"

  local wandb_log="False"
  if is_truthy "${SWEEP_WANDB:-0}"; then
    wandb_log="auto"
  fi

  local wandb_group="${WANDB_GROUP:-}"
  if [[ -z "$wandb_group" ]]; then
    wandb_group="sweep-$(date +%Y%m%d)"
  fi

  local venv_python="$OPS_REMOTE_REPO/.venv/bin/python"
  [[ -x "$venv_python" ]] || die "venv python not found or not executable: $venv_python (run: bash infra_scripts/workflow.sh checkout)"

  local nproc_per_node
  nproc_per_node="$(detect_visible_gpu_count "$venv_python")"
  if [[ ! "$nproc_per_node" =~ ^[0-9]+$ || "$nproc_per_node" -le 0 ]]; then
    die "no GPUs visible (CUDA_VISIBLE_DEVICES='${CUDA_VISIBLE_DEVICES:-}'; nproc_per_node='$nproc_per_node')"
  fi

  local run_timeout_secs="${RUN_TIMEOUT_SECS:-0}"
  if [[ ! "$run_timeout_secs" =~ ^[0-9]+$ ]]; then
    die "RUN_TIMEOUT_SECS must be an integer (seconds), got: $run_timeout_secs"
  fi

  local run_out_mode="${RUN_OUT_MODE:-durable}"
  case "$run_out_mode" in
    durable|local_sync) ;;
    *) die "RUN_OUT_MODE must be one of: durable, local_sync (got: $run_out_mode)" ;;
  esac

  local out_local_root="${RUN_OUT_LOCAL_ROOT:-$OPS_REMOTE_REPO/examples/nanogpt/out}"
  local sync_interval_secs="${SYNC_INTERVAL_SECS:-60}"
  if [[ ! "$sync_interval_secs" =~ ^[0-9]+$ || "$sync_interval_secs" == 0 ]]; then
    die "SYNC_INTERVAL_SECS must be a positive integer (seconds), got: $sync_interval_secs"
  fi

  local line
  local started=0
  local ran=0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == run_id,* ]] && continue
    [[ "$line" == \#* ]] && continue

    if [[ -n "${SWEEP_MATCH:-}" ]]; then
      case "$line" in
        *"$SWEEP_MATCH"*) : ;;
        *) continue ;;
      esac
    fi

    IFS=, read -r run_id config seed overrides notes <<<"$line"
    run_id="$(strip_quotes "${run_id:-}")"
    config="$(strip_quotes "${config:-}")"
    seed="$(strip_quotes "${seed:-0}")"
    overrides="$(strip_quotes "${overrides:-}")"

    [[ -n "$run_id" ]] || die "empty run_id in CSV line: $line"
    [[ -n "$config" ]] || die "empty config in CSV line: $line"

    if [[ -n "${SWEEP_START_AT:-}" && "$started" == 0 ]]; then
      if [[ "$run_id" == "$SWEEP_START_AT" ]]; then
        started=1
      else
        continue
      fi
    fi

    if [[ -n "${SWEEP_LIMIT:-}" && "$ran" -ge "$SWEEP_LIMIT" ]]; then
      break
    fi

    local run_dir="$OPS_REMOTE_OUTPUTS_DIR/$run_id"
    mkdir -p "$run_dir"

    local train_out_dir="$run_dir"
    local local_out_dir=""
    local sync_enabled="0"

    if [[ "$run_out_mode" == "local_sync" ]]; then
      [[ -n "$out_local_root" ]] || die "RUN_OUT_LOCAL_ROOT must be set when RUN_OUT_MODE=local_sync"
      local_out_dir="$out_local_root/$run_id"

      # If the "local" root is on /mnt, syncing is unnecessary and slower.
      if [[ "$local_out_dir" == "/mnt/"* || "$local_out_dir" == "$OPS_REMOTE_OUTPUTS_DIR"* ]]; then
        echo "warn: RUN_OUT_MODE=local_sync but RUN_OUT_LOCAL_ROOT is on /mnt; writing directly to durable out_dir"
      else
        mkdir -p "$local_out_dir"
        train_out_dir="$local_out_dir"
        sync_enabled="1"
      fi
    fi

    if [[ -f "$run_dir/summary.json" && "${SWEEP_FORCE:-0}" != 1 ]]; then
      if [[ "$(summary_ok "$run_dir/summary.json")" == "true" ]]; then
        echo "skip: $run_id (summary ok=true)"
        continue
      fi
      die "refusing to proceed: $run_id has summary.json with ok!=true (set SWEEP_FORCE=1 to rerun)"
    fi

    echo "run: $run_id (ddp nproc_per_node=$nproc_per_node)"
    cd "$OPS_REMOTE_REPO/examples/nanogpt"

    # Persist the exact command for reproducibility/debugging.
    {
      echo "#!/usr/bin/env bash"
      echo "set -euo pipefail"
      echo "cd \"$OPS_REMOTE_REPO/examples/nanogpt\""
      echo "export HF_HOME=\"$HF_HOME\""
      if [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
        echo "export CUDA_VISIBLE_DEVICES=\"${CUDA_VISIBLE_DEVICES}\""
      fi
      echo "PYTHONUNBUFFERED=1 \"$venv_python\" -m torch.distributed.run --standalone --nproc_per_node=\"$nproc_per_node\" train.py \"$config\" \\" 
      echo "  out_dir=\"$train_out_dir\" \\"
      echo "  data_dir=\"$DATA_DIR\" \\"
      echo "  seed=\"$seed\" \\"
      echo "  wandb_log=\"$wandb_log\" \\"
      echo "  wandb_group=\"$wandb_group\" \\"
      echo "  wandb_run_name=\"$run_id\" \\"
      if [[ -n "${WANDB_PROJECT:-}" ]]; then
        echo "  wandb_project=\"$WANDB_PROJECT\" \\"
      fi
      if [[ -n "${overrides:-}" ]]; then
        echo "  $overrides"
      fi
    } >"$run_dir/command.sh"
    chmod +x "$run_dir/command.sh" 2>/dev/null || true

    status_path="$run_dir/status.json"
    summary_path="$run_dir/summary.json"
    stdout_log="$run_dir/stdout.log"

    : >"$stdout_log"
    {
      echo "== run_start =="
      date
      echo "run_id=$run_id"
      echo "config=$config"
      echo "seed=$seed"
      echo "dry_run=$sweep_dry_run"
      echo "timeout_secs=$run_timeout_secs"
      echo "run_out_mode=$run_out_mode"
      echo "train_out_dir=$train_out_dir"
      echo "durable_out_dir=$run_dir"
      echo "sync_enabled=$sync_enabled"
      if [[ "$sync_enabled" == 1 ]]; then
        echo "sync_interval_secs=$sync_interval_secs"
      fi
      echo "cuda_visible_devices=${CUDA_VISIBLE_DEVICES:-}"
      echo "workdir=$OPS_REMOTE_REPO/examples/nanogpt"
    } 2>&1 | ts_prefix | tee -a "$stdout_log"

    python3 - <<'PY' "$run_id" "$config" "$seed" "$status_path" "$wandb_group" "$wandb_log" "$run_timeout_secs" "$run_out_mode" "$train_out_dir" "$run_dir" "$sync_enabled" "$sync_interval_secs"
import json, os, sys, time

(
    run_id,
    config,
    seed,
    status_path,
    wandb_group,
    wandb_log,
    run_timeout_secs,
    run_out_mode,
    train_out_dir,
    durable_out_dir,
    sync_enabled,
    sync_interval_secs,
) = sys.argv[1:]
try:
    seed_i = int(seed)
except Exception:
    seed_i = seed

st = {
    "state": "running",
    "run_id": run_id,
    "config": config,
    "seed": seed_i,
    "wandb_group": wandb_group,
    "wandb_log": wandb_log,
    "run_timeout_secs": int(run_timeout_secs),
    "run_out_mode": run_out_mode,
    "train_out_dir": train_out_dir,
    "durable_out_dir": durable_out_dir,
    "sync_enabled": (sync_enabled == "1"),
    "sync_interval_secs": int(sync_interval_secs),
    "started_at": time.strftime("%Y-%m-%d %H:%M:%S"),
}

os.makedirs(os.path.dirname(status_path), exist_ok=True)
with open(status_path, "w") as f:
    json.dump(st, f, indent=2, sort_keys=True)
PY

    sync_pid=""
    sync_log="$run_dir/sync.log"

    if [[ "$sync_enabled" == 1 ]]; then
      command -v rsync >/dev/null 2>&1 || die "rsync not found; run bootstrap"
      : >"$sync_log"
      {
        echo "== sync_start =="
        date
        echo "src=$train_out_dir"
        echo "dst=$run_dir"
        echo "interval_secs=$sync_interval_secs"
      } 2>&1 | ts_prefix | tee -a "$sync_log"

      (
        set -euo pipefail
        while true; do
          rsync -a --delete --delay-updates --partial \
            --exclude 'stdout.log' \
            --exclude 'status.json' \
            --exclude 'summary.json' \
            --exclude 'command.sh' \
            --exclude 'sync.log' \
            "$train_out_dir/" "$run_dir/" \
            2>&1 | ts_prefix >>"$sync_log" || true
          sleep "$sync_interval_secs"
        done
      ) &
      sync_pid=$!
    fi

    set +e
    set -o pipefail

    if is_truthy "$sweep_dry_run"; then
      {
        echo "== dry_run =="
        echo "skipping train execution (SWEEP_DRY_RUN=$sweep_dry_run)"
      } 2>&1 | ts_prefix | tee -a "$stdout_log"
      rc=0
    else
      if [[ "$run_timeout_secs" != 0 ]]; then
        command -v timeout >/dev/null 2>&1 || die "timeout not found; set RUN_TIMEOUT_SECS=0 or install coreutils"
        timeout --signal=TERM --kill-after=30s "$run_timeout_secs" \
          env HF_HOME="$HF_HOME" PYTHONUNBUFFERED=1 \
          "$venv_python" -m torch.distributed.run --standalone --nproc_per_node="$nproc_per_node" train.py "$config" \
            out_dir="$train_out_dir" \
            data_dir="$DATA_DIR" \
            seed="$seed" \
            wandb_log="$wandb_log" \
            wandb_group="$wandb_group" \
            wandb_run_name="$run_id" \
            ${WANDB_PROJECT:+wandb_project="$WANDB_PROJECT"} \
            $overrides \
          2>&1 | ts_prefix | tee -a "$stdout_log"
        rc=${PIPESTATUS[0]}
      else
        env HF_HOME="$HF_HOME" PYTHONUNBUFFERED=1 \
          "$venv_python" -m torch.distributed.run --standalone --nproc_per_node="$nproc_per_node" train.py "$config" \
            out_dir="$train_out_dir" \
            data_dir="$DATA_DIR" \
            seed="$seed" \
            wandb_log="$wandb_log" \
            wandb_group="$wandb_group" \
            wandb_run_name="$run_id" \
            ${WANDB_PROJECT:+wandb_project="$WANDB_PROJECT"} \
            $overrides \
          2>&1 | ts_prefix | tee -a "$stdout_log"
        rc=${PIPESTATUS[0]}
      fi
    fi

    set -e

    state="failed"
    if [[ "$rc" == 0 ]]; then
      state="success"
    elif [[ "$rc" == 124 ]]; then
      state="timed_out"
    fi

    if [[ -n "$sync_pid" ]]; then
      kill "$sync_pid" 2>/dev/null || true
      wait "$sync_pid" 2>/dev/null || true

      rsync -a --delete --delay-updates --partial \
        --exclude 'stdout.log' \
        --exclude 'status.json' \
        --exclude 'summary.json' \
        --exclude 'command.sh' \
        --exclude 'sync.log' \
        "$train_out_dir/" "$run_dir/" \
        2>&1 | ts_prefix >>"$sync_log" || true

      {
        echo "== sync_end =="
        date
      } 2>&1 | ts_prefix | tee -a "$sync_log"
    fi

    python3 - <<'PY' "$status_path" "$summary_path" "$state" "$rc"
import json, os, sys, time

status_path, summary_path, state, rc = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

st = {}
try:
    with open(status_path, "r") as f:
        st = json.load(f)
except Exception:
    st = {}

st["state"] = state
st["exit_code"] = rc
st["ended_at"] = time.strftime("%Y-%m-%d %H:%M:%S")

os.makedirs(os.path.dirname(status_path), exist_ok=True)
with open(status_path, "w") as f:
    json.dump(st, f, indent=2, sort_keys=True)

summary = dict(st)
summary["ok"] = (state == "success")
summary["finished_at"] = st.get("ended_at")
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
PY

    {
      echo "== run_end =="
      date
      echo "state=$state"
      echo "exit_code=$rc"
    } 2>&1 | ts_prefix | tee -a "$stdout_log"

    if [[ "$rc" != 0 ]]; then
      die "train.py exited non-zero for $run_id (rc=$rc, state=$state)"
    fi

    ok="$(summary_ok "$summary_path")"
    if [[ "$ok" != "true" ]]; then
      die "summary ok!=true for $run_id ($ok)"
    fi
    ran=$((ran + 1))
  done <"$csv"
}

cmd__sweep_status() {
  load_config
  require_var OPS_REMOTE_OUTPUTS_DIR

  local csv_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --csv) csv_arg="$2"; shift 2 ;;
      *) die "unknown arg for _sweep_status: $1" ;;
    esac
  done

  local csv
  if [[ -n "$csv_arg" ]]; then
    csv="$csv_arg"
  else
    require_var SWEEP_CSV
    csv="$(remote_csv_path)"
  fi
  if [[ ! -f "$csv" ]]; then
    local latest="$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-latest.csv"
    if [[ -f "$latest" ]]; then
      csv="$latest"
    else
      die "remote sweep CSV not found: $csv"
    fi
  fi

  local ok=0 failed=0 in_progress=0 missing=0 parse_error=0 total=0
  local started=0
  local line

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == run_id,* ]] && continue
    [[ "$line" == \#* ]] && continue

    if [[ -n "${SWEEP_MATCH:-}" ]]; then
      case "$line" in
        *"$SWEEP_MATCH"*) : ;;
        *) continue ;;
      esac
    fi

    IFS=, read -r run_id _rest <<<"$line"
    run_id="$(strip_quotes "${run_id:-}")"
    [[ -n "$run_id" ]] || continue

    if [[ -n "${SWEEP_START_AT:-}" && "$started" == 0 ]]; then
      if [[ "$run_id" == "$SWEEP_START_AT" ]]; then
        started=1
      else
        continue
      fi
    fi

    total=$((total + 1))
    local run_dir="$OPS_REMOTE_OUTPUTS_DIR/$run_id"
    if [[ ! -d "$run_dir" ]]; then
      missing=$((missing + 1))
      continue
    fi
    if [[ ! -f "$run_dir/summary.json" ]]; then
      in_progress=$((in_progress + 1))
      continue
    fi

    s="$(summary_ok "$run_dir/summary.json")"
    if [[ "$s" == "true" ]]; then
      ok=$((ok + 1))
    elif [[ "$s" == "false" ]]; then
      failed=$((failed + 1))
    else
      parse_error=$((parse_error + 1))
    fi
  done <"$csv"

  echo "total=$total ok=$ok failed=$failed in_progress=$in_progress missing_dir=$missing parse_error=$parse_error"
}

cmd_sweep_status() {
  load_config
  config_sync
  remote_exec_env 'csv_latest="$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-latest.csv"; cd "$OPS_REMOTE_REPO" && if [[ -f "$csv_latest" ]]; then WORKFLOW_CONFIG="$REMOTE_ENV_PATH" bash infra_scripts/workflow.sh _sweep_status --csv "$csv_latest"; else WORKFLOW_CONFIG="$REMOTE_ENV_PATH" bash infra_scripts/workflow.sh _sweep_status; fi'
  remote_exec_env 'echo "attach:"; echo "tmux attach -t $SWEEP_TMUX_SESSION"; tmux ls || true'
}

cmd_fetch_run() {
  load_config
  config_sync
  require_var OPS_REMOTE_OUTPUTS_DIR
  require_var LOCAL_ARTIFACTS_DIR

  local run_id="${1:-}"
  [[ -n "$run_id" ]] || die "usage: fetch-run <run_id>"

  local tmp_remote="/tmp/${run_id}.tar.gz"
  local tmp_local="${LOCAL_ARTIFACTS_DIR}/${run_id}.tar.gz"
  mkdir -p "$LOCAL_ARTIFACTS_DIR"

  remote_exec_env "tar -C \"$OPS_REMOTE_OUTPUTS_DIR\" -czf \"$tmp_remote\" \"$run_id\""
  remote_download "$tmp_remote" "$tmp_local"
  tar -xzf "$tmp_local" -C "$LOCAL_ARTIFACTS_DIR"
  rm -f "$tmp_local"
  remote_exec_env "rm -f \"$tmp_remote\" || true"
  log "fetched: ${LOCAL_ARTIFACTS_DIR}/${run_id}/"
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help|-h|--help) cmd_help ;;
    pod-up) cmd_pod_up "$@" ;;
    pod-wait) cmd_pod_wait "$@" ;;
    pod-delete) cmd_pod_delete "$@" ;;
    pod-butter) cmd_pod_butter "$@" ;;
    pod-status) cmd_pod_status "$@" ;;
    config-sync) config_sync "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    checkout) cmd_checkout "$@" ;;
    task-run) cmd_task_run "$@" ;;
    task-status) cmd_task_status "$@" ;;
    task-wait) cmd_task_wait "$@" ;;
    task-list) cmd_task_list "$@" ;;
    sweep-csv-template) cmd_sweep_csv_template "$@" ;;
    workflow-sync) cmd_workflow_sync "$@" ;;
    sweep-start) cmd_sweep_start "$@" ;;
    sweep-status) cmd_sweep_status "$@" ;;
    fetch-run) cmd_fetch_run "$@" ;;
    _sweep_run_all) cmd__sweep_run_all "$@" ;;
    _sweep_status) cmd__sweep_status "$@" ;;
    *)
      die "unknown command: $cmd (run: bash infra_scripts/workflow.sh help)"
      ;;
  esac
}

main "$@"
