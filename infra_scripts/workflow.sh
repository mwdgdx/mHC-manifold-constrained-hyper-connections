#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CONFIG_PATH="${WORKFLOW_CONFIG:-${SCRIPT_DIR}/workflow.cfg}"
CANONICAL_CONFIG_PATH="${SCRIPT_DIR}/workflow.cfg"

WF_RC_SENTINEL="__WF_RC__"
WF_HEADER_EMITTED=0
WF_ACTIVE_COMMAND=""
WF_ACTIVE_CONFIG_REALPATH=""
WF_FLOW_ID=""
WF_FLOW_RUN_DIR=""
WF_FLOW_START_TS=""
WF_LAST_PHASE_EVIDENCE_PATH=""
WF_LAST_PHASE_VERDICT_PATH=""

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

file_sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  echo "unavailable"
}

resolved_transport_hint() {
  if [[ -n "${LIUM_TARGET:-}" ]]; then
    echo "lium:${LIUM_TARGET}"
    return 0
  fi
  if [[ -n "${OPS_DEFAULT_HOST:-}" ]]; then
    echo "ssh:${OPS_DEFAULT_HOST}"
    return 0
  fi
  echo "unresolved"
}

emit_constitution_header_once() {
  if [[ "${WF_HEADER_EMITTED}" == 1 ]]; then
    return 0
  fi

  local config_sha
  config_sha="$(file_sha256 "$CONFIG_PATH")"

  local mode="canonical"
  if [[ -n "${WF_ACTIVE_CONFIG_REALPATH:-}" && "$WF_ACTIVE_CONFIG_REALPATH" != "$CANONICAL_CONFIG_PATH" ]]; then
    mode="override"
  fi

  local transport
  transport="$(resolved_transport_hint)"

  log "constitution version=${WF_CONSTITUTION_VERSION:-1}"
  log "constitution active_config=${CONFIG_PATH}"
  log "constitution active_config_sha256=${config_sha}"
  log "constitution config_mode=${mode} override_enabled=${WF_ALLOW_OVERRIDE:-0}"
  log "constitution command=${WF_ACTIVE_COMMAND:-unknown} transport=${transport}"

  WF_HEADER_EMITTED=1
}

enforce_noninteractive_policy() {
  local cmd="$1"
  if ! is_truthy "${WF_REQUIRE_NONINTERACTIVE_SAFE:-1}"; then
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    return 0
  fi

  case "$cmd" in
    pod-up|pod-butter)
      if ! is_truthy "${LIUM_YES:-0}"; then
        die "noninteractive safety: ${cmd} requires LIUM_YES=1 (set in ${CONFIG_PATH})"
      fi
      ;;
  esac
}

constitution_preflight() {
  local cmd="$1"
  load_config

  if [[ "${WF_CONSTITUTION_VERSION:-1}" != "1" ]]; then
    die "unsupported WF_CONSTITUTION_VERSION=${WF_CONSTITUTION_VERSION:-unset} (expected: 1)"
  fi

  enforce_noninteractive_policy "$cmd"

  case "$cmd" in
    checkout|sweep-start|flow)
      [[ -n "${REPO_URL:-}" ]] || die "precheck: REPO_URL is required for ${cmd} (set in ${CONFIG_PATH})"
      ;;
  esac

  emit_constitution_header_once
}

resolve_local_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    echo "$path"
    return 0
  fi
  echo "${REPO_ROOT}/${path}"
}

checklist_path() {
  local configured="${WF_CHECKLIST_PATH:-infra_scripts/workflow.checklist.md}"
  resolve_local_path "$configured"
}

checklist_template() {
  cat <<'EOF'
# Workflow Checklist (auto-generated)

- [ ] P00 PRECHECK - preflight passed
- [ ] P10 PROVISION - pod created or provisioning skipped by policy
- [ ] P20 TARGET_BIND - LIUM target or fallback host resolved
- [ ] P30 POD_READY - pod status and remote reachability validated
- [ ] P40 BOOTSTRAP - prereqs/helpers completed
- [ ] P50 CHECKOUT - repo, python env, and data contracts satisfied
- [ ] P60 SWEEP - sweep launched or skipped by policy
- [ ] P70 MONITOR - sweep status validation completed
- [ ] P80 FETCH - requested artifact fetch completed or skipped
- [ ] P90 TEARDOWN - keep/delete policy applied
- [ ] P99 SUMMARY - final flow verdict emitted

## Events
EOF
}

checklist_reset_file() {
  local path="$1"
  mkdir -p "$(dirname -- "$path")"
  checklist_template >"$path"
}

checklist_mark_done() {
  local path="$1"
  local phase="$2"
  python3 - <<'PY' "$path" "$phase"
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
phase = sys.argv[2]

if not path.exists():
    raise SystemExit(f"missing checklist file: {path}")

lines = path.read_text().splitlines()
out = []
pattern = re.compile(rf"^- \[[ x]\] {re.escape(phase)}\b")
updated = False
for line in lines:
    if (not updated) and pattern.match(line):
        out.append(pattern.sub(f"- [x] {phase}", line, count=1))
        updated = True
    else:
        out.append(line)

if not updated:
    raise SystemExit(f"phase not found in checklist: {phase}")

path.write_text("\n".join(out) + "\n")
PY
}

checklist_append_event() {
  local path="$1"
  local phase="$2"
  local status="$3"
  local note="${4:-}"
  printf -- '- %s phase=%s status=%s note=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$status" "$note" >>"$path"
}

checklist_archive_and_reset_if_needed() {
  local path="$1"
  if ! is_truthy "${WF_CHECKLIST_RESET_ON_END:-1}"; then
    return 0
  fi

  cp -f "$path" "${path}.last"
  checklist_reset_file "$path"
  log "checklist reset: ${path} (last run snapshot: ${path}.last)"
}

flow_evidence_root() {
  local configured="${WF_FLOW_EVIDENCE_DIR:-artifacts/pod_logs/_flows}"
  resolve_local_path "$configured"
}

flow_init_context() {
  local root
  root="$(flow_evidence_root)"
  WF_FLOW_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  WF_FLOW_RUN_DIR="${root}/${WF_FLOW_ID}"
  WF_FLOW_START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$WF_FLOW_RUN_DIR"
}

flow_write_start_artifact() {
  local options_desc="$1"
  local start_path="${WF_FLOW_RUN_DIR}/flow.start.json"
  local config_sha
  config_sha="$(file_sha256 "$CONFIG_PATH")"

  python3 - <<'PY' "$start_path" "$WF_FLOW_ID" "$WF_FLOW_START_TS" "$CONFIG_PATH" "$config_sha" "${LIUM_TARGET:-}" "${OPS_DEFAULT_HOST:-}" "$(resolved_transport_hint)" "${REMOTE_ENV_PATH:-}" "$options_desc"
import json
import pathlib
import sys

(
    start_path,
    flow_id,
    started_at,
    config_path,
    config_sha,
    lium_target,
    fallback_host,
    transport,
    remote_env,
    options_desc,
) = sys.argv[1:]

payload = {
    "flow_id": flow_id,
    "started_at": started_at,
    "active_config_path": config_path,
    "active_config_sha256": config_sha,
    "lium_target": lium_target,
    "ops_default_host": fallback_host,
    "transport_hint": transport,
    "remote_env_path": remote_env,
    "options": options_desc,
}
pathlib.Path(start_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

flow_write_summary_artifact() {
  local rc="$1"
  local failed_phase="$2"
  local checklist_file="$3"
  local summary_path="${WF_FLOW_RUN_DIR}/flow.summary.json"
  local ended_at
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  python3 - <<'PY' "$summary_path" "$WF_FLOW_ID" "$WF_FLOW_START_TS" "$ended_at" "$rc" "$failed_phase" "$checklist_file"
import json
import pathlib
import sys

summary_path, flow_id, started_at, ended_at, rc, failed_phase, checklist_file = sys.argv[1:]
payload = {
    "flow_id": flow_id,
    "started_at": started_at,
    "ended_at": ended_at,
    "ok": rc == "0",
    "exit_code": int(rc),
    "failed_phase": failed_phase,
    "checklist_file": checklist_file,
}
pathlib.Path(summary_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

phase_has_contract() {
  local phase="$1"
  case "$phase" in
    P00|P10|P20|P30|P40|P50|P60|P70|P80|P90|P99) return 0 ;;
    *) return 1 ;;
  esac
}

phase_command_allowed() {
  local phase="$1"
  local command_name="$2"
  case "$phase" in
    P00) [[ "$command_name" == "flow-precheck" ]] ;;
    P10) [[ "$command_name" == "pod-up" || "$command_name" == "provision-policy" ]] ;;
    P20) [[ "$command_name" == "target-bind" ]] ;;
    P30) [[ "$command_name" == "pod-status" ]] ;;
    P40) [[ "$command_name" == "bootstrap" ]] ;;
    P50) [[ "$command_name" == "checkout" ]] ;;
    P60) [[ "$command_name" == "sweep-start" || "$command_name" == "sweep-status" || "$command_name" == "sweep-policy" ]] ;;
    P70) [[ "$command_name" == "sweep-wait" || "$command_name" == "sweep-status" ]] ;;
    P80) [[ "$command_name" == "fetch-policy" || "$command_name" == "fetch-all" || "$command_name" == "fetch-run" ]] ;;
    P90) [[ "$command_name" == "teardown-policy" || "$command_name" == "pod-delete" ]] ;;
    P99) [[ "$command_name" == "flow-summary" ]] ;;
    *) return 1 ;;
  esac
}

phase_default_command() {
  local phase="$1"
  case "$phase" in
    P00) printf '%s\n' "flow-precheck" ;;
    P10) printf '%s\n' "provision-policy" ;;
    P20) printf '%s\n' "target-bind" ;;
    P30) printf '%s\n' "pod-status" ;;
    P40) printf '%s\n' "bootstrap" ;;
    P50) printf '%s\n' "checkout" ;;
    P60) printf '%s\n' "sweep-policy" ;;
    P70) printf '%s\n' "sweep-status" ;;
    P80) printf '%s\n' "fetch-policy" ;;
    P90) printf '%s\n' "teardown-policy" ;;
    P99) printf '%s\n' "flow-summary" ;;
    *) printf '%s\n' "flow" ;;
  esac
}

flow_phase_validate() {
  local phase="$1"
  local phase_status="$2"
  local note="$3"
  local command_name="$4"
  local command_rc="$5"
  local fsm_before="${6:-UNAVAILABLE}"
  local fsm_after="${7:-UNAVAILABLE}"

  local evidence_path="${WF_FLOW_RUN_DIR}/phase.${phase}.evidence.json"
  local det_path="${WF_FLOW_RUN_DIR}/phase.${phase}.deterministic.json"
  local verdict_path="${WF_FLOW_RUN_DIR}/phase.${phase}.verdict.json"
  local phase_started
  phase_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local phase_ended
  phase_ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local effective_teardown="${WF_FLOW_TEARDOWN_MODE:-${WF_DEFAULT_TEARDOWN:-keep}}"

  python3 - <<'PY' "$evidence_path" "$WF_FLOW_ID" "$phase" "$phase_started" "$phase_ended" "$CONFIG_PATH" "$(file_sha256 "$CONFIG_PATH")" "${LIUM_TARGET:-}" "${OPS_DEFAULT_HOST:-}" "$(resolved_transport_hint)" "${REMOTE_ENV_PATH:-}" "$command_name" "$command_rc" "$phase_status" "$note" "$fsm_before" "$fsm_after" "${REPO_URL:-}" "$effective_teardown" "${WF_FLOW_RUN_DIR}/flow.start.json"
import json
import pathlib
import sys

(
    evidence_path,
    flow_id,
    phase,
    phase_started,
    phase_ended,
    config_path,
    config_sha,
    lium_target,
    fallback_host,
    transport,
    remote_env,
    command_name,
    command_rc,
    phase_status,
    note,
    fsm_before,
    fsm_after,
    repo_url,
    teardown_mode,
    flow_start_artifact,
) = sys.argv[1:]

phase_contracts = {
    "P00": {
        "intent": "Precheck prerequisites before any remote mutation.",
        "commands": ["flow-precheck"],
    },
    "P10": {
        "intent": "Provision pod deterministically or explicitly mark policy skip.",
        "commands": ["pod-up", "provision-policy"],
    },
    "P20": {
        "intent": "Resolve and lock a legal execution target for remaining phases.",
        "commands": ["target-bind"],
    },
    "P30": {
        "intent": "Prove remote target is reachable and pod is ready.",
        "commands": ["pod-status"],
    },
    "P40": {
        "intent": "Satisfy bootstrap prerequisites and helper initialization policy.",
        "commands": ["bootstrap"],
    },
    "P50": {
        "intent": "Checkout repository and validate torch/data contracts for training readiness.",
        "commands": ["checkout"],
    },
    "P60": {
        "intent": "Start, resume-check, or policy-skip sweep in a declared mode.",
        "commands": ["sweep-start", "sweep-status", "sweep-policy"],
    },
    "P70": {
        "intent": "Monitor sweep completion state via wait or snapshot path.",
        "commands": ["sweep-wait", "sweep-status"],
    },
    "P80": {
        "intent": "Fetch artifacts according to explicit fetch policy.",
        "commands": ["fetch-policy", "fetch-all", "fetch-run"],
    },
    "P90": {
        "intent": "Apply explicit teardown policy without implicit destruction.",
        "commands": ["teardown-policy", "pod-delete"],
    },
    "P99": {
        "intent": "Emit final summary only after all prior phases are known.",
        "commands": ["flow-summary"],
    },
}

contract = phase_contracts.get(phase, {"intent": "", "laws": [], "commands": []})

payload = {
    "flow_id": flow_id,
    "phase_id": phase,
    "started_at": phase_started,
    "ended_at": phase_ended,
    "active_config_path": config_path,
    "active_config_sha256": config_sha,
    "lium_target": lium_target,
    "ops_default_host": fallback_host,
    "transport_hint": transport,
    "remote_env_path": remote_env,
    "command_name": command_name,
    "command_rc": int(command_rc),
    "phase_status": phase_status,
    "note": note,
    "fsm_before": fsm_before,
    "fsm_after": fsm_after,
    "repo_url": repo_url,
    "teardown_mode": teardown_mode,
    "command_transcript_path": "",
    "intent_mode": "phase_contract",
    "contract_intent": contract["intent"],
    "allowed_commands": contract["commands"],
    "flow_start_artifact": flow_start_artifact,
    "command_in_contract": command_name in set(contract["commands"]),
}
pathlib.Path(evidence_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY

  local -a det_violations=()
  local det_pass=1
  if [[ "$phase_status" != "ok" ]]; then
    det_pass=0
    det_violations+=("phase_status_not_ok")
  fi
  if [[ "$command_rc" != "0" ]]; then
    det_pass=0
    det_violations+=("command_rc_non_zero")
  fi
  case "$phase" in
    P20)
      if [[ -z "${LIUM_TARGET:-}" && -z "${OPS_DEFAULT_HOST:-}" ]]; then
        det_pass=0
        det_violations+=("target_not_resolved")
      fi
      ;;
    P50|P60)
      if [[ -z "${REPO_URL:-}" ]]; then
        det_pass=0
        det_violations+=("repo_url_missing")
      fi
      ;;
    P90)
      case "$effective_teardown" in
        keep|delete) ;;
        *)
          det_pass=0
          det_violations+=("invalid_teardown_policy")
          ;;
      esac
      ;;
    P00|P10|P30|P40|P70|P80|P99)
      ;;
    *)
      det_pass=0
      det_violations+=("unknown_phase_contract")
      ;;
  esac
  if ! phase_has_contract "$phase"; then
    det_pass=0
    det_violations+=("unknown_phase_contract")
  fi
  if ! phase_command_allowed "$phase" "$command_name"; then
    det_pass=0
    det_violations+=("intent_command_mismatch")
  fi

  python3 - <<'PY' "$det_path" "$phase" "$det_pass" "${det_violations[@]-}"
import json
import pathlib
import sys

det_path = sys.argv[1]
phase = sys.argv[2]
det_pass = sys.argv[3] == "1"
violations = sys.argv[4:]

payload = {
    "phase": phase,
    "status": "pass" if det_pass else "fail",
    "pass": det_pass,
    "violations": violations,
}
pathlib.Path(det_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY

  python3 - <<'PY' "$verdict_path" "$phase" "$det_pass" "$evidence_path" "$det_path"
import json
import pathlib
import sys

(
    verdict_path,
    phase,
    det_pass,
    evidence_path,
    det_path,
) = sys.argv[1:]

payload = {
    "phase": phase,
    "deterministic": "pass" if det_pass == "1" else "fail",
    "phase_pass": det_pass == "1",
    "evidence": evidence_path,
    "deterministic_artifact": det_path,
}
pathlib.Path(verdict_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY

  WF_LAST_PHASE_EVIDENCE_PATH="$evidence_path"
  WF_LAST_PHASE_VERDICT_PATH="$verdict_path"

  local det_label="fail"
  [[ "$det_pass" == "1" ]] && det_label="pass"
  log "PHASE=${phase} DET=${det_label} VERDICT=${verdict_path}"
  [[ "$det_pass" == "1" ]]
}

flow_finalize_phase() {
  local checklist_file="$1"
  local phase="$2"
  local note="$3"
  local command_name="$4"
  local command_rc="$5"
  local fsm_before="${6:-UNAVAILABLE}"
  local fsm_after="${7:-UNAVAILABLE}"

  if ! flow_phase_validate "$phase" "ok" "$note" "$command_name" "$command_rc" "$fsm_before" "$fsm_after"; then
    checklist_append_event "$checklist_file" "$phase" "validation_failed" "$note"
    return 1
  fi

  checklist_mark_done "$checklist_file" "$phase"
  checklist_append_event "$checklist_file" "$phase" "ok" "$note"
  log "PHASE=${phase} STATUS=ok CODE=0 ARTIFACT=${WF_LAST_PHASE_EVIDENCE_PATH}"
  return 0
}

flow_record_phase_failure() {
  local checklist_file="$1"
  local phase="$2"
  local note="$3"
  local command_name="$4"
  local command_rc="$5"
  local fsm_before="${6:-UNAVAILABLE}"
  local fsm_after="${7:-UNAVAILABLE}"

  if ! flow_phase_validate "$phase" "fail" "$note" "$command_name" "$command_rc" "$fsm_before" "$fsm_after"; then
    true
  fi
  checklist_append_event "$checklist_file" "$phase" "failed" "$note"
  log "PHASE=${phase} STATUS=fail CODE=${command_rc} ARTIFACT=${WF_LAST_PHASE_EVIDENCE_PATH}"
}

upsert_config_value() {
  local file_path="$1"
  local key="$2"
  local value="$3"

  python3 - <<'PY' "$file_path" "$key" "$value"
import pathlib
import re
import sys

file_path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
path = pathlib.Path(file_path)
if not path.exists():
    raise SystemExit(f"config file does not exist: {file_path}")

raw = path.read_text().splitlines()
escaped = value.replace("\\", "\\\\").replace('"', '\\"')
newline = f'{key}="{escaped}"'
pattern = re.compile(rf'^\s*{re.escape(key)}=')

updated = False
out = []
for line in raw:
    if not updated and pattern.match(line):
        out.append(newline)
        updated = True
    else:
        out.append(line)

if not updated:
    if out and out[-1] != "":
        out.append("")
    out.append(newline)

path.write_text("\n".join(out) + "\n")
PY
}

flow_wait_for_completion() {
  local interval_secs="${WF_FLOW_WAIT_INTERVAL_SECS:-30}"
  local max_polls="${WF_FLOW_WAIT_MAX_POLLS:-240}"
  local polls=0

  [[ "$interval_secs" =~ ^[0-9]+$ ]] || die "WF_FLOW_WAIT_INTERVAL_SECS must be an integer"
  [[ "$max_polls" =~ ^[0-9]+$ ]] || die "WF_FLOW_WAIT_MAX_POLLS must be an integer"

  while true; do
    local status_out
    status_out="$(run_workflow_subcommand sweep-status)"
    printf '%s\n' "$status_out"

    local phase
    phase="$(python3 - <<'PY' "$status_out"
import re
import sys

s = sys.argv[1]
m = re.search(r"total=(\d+)\s+ok=(\d+)\s+failed=(\d+)\s+in_progress=(\d+)\s+missing_dir=(\d+)\s+parse_error=(\d+)", s)
if not m:
    print("unknown")
    raise SystemExit(0)

total, ok, failed, in_progress, missing_dir, parse_error = map(int, m.groups())
if in_progress > 0:
    print("running")
elif total > 0 and total == ok + failed and missing_dir == 0 and parse_error == 0:
    print("completed")
elif failed > 0 or parse_error > 0:
    print("stalled")
else:
    print("unknown")
PY
)"

    case "$phase" in
      completed)
        return 0
        ;;
      running)
        ;;
      stalled)
        die "flow wait: sweep stalled"
        ;;
      *)
        die "flow wait: sweep status is not converging (phase=${phase})"
        ;;
    esac

    polls=$((polls + 1))
    if (( max_polls > 0 && polls >= max_polls )); then
      die "flow wait: exceeded max polls (${max_polls})"
    fi
    sleep "$interval_secs"
  done
}

flow_fetch_all_runs() {
  local csv
  csv="$(local_csv_path)"
  [[ -f "$csv" ]] || die "flow fetch=all requires sweep CSV: $csv"

  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    run_workflow_subcommand fetch-run "$run_id"
  done < <(python3 - <<'PY' "$csv"
import csv
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("r", newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
      run_id = (row.get("run_id") or "").strip()
      if run_id:
          print(run_id)
PY
)
}

artifacts_sync_phase_for_csv() {
  local csv_path="$1"
  local artifacts_root="$2"

  python3 - <<'PY' "$csv_path" "$artifacts_root"
import csv
import pathlib
import sys

csv_path = pathlib.Path(sys.argv[1])
artifacts_root = pathlib.Path(sys.argv[2])

if not csv_path.exists():
    print("unknown")
    raise SystemExit(0)

runs = []
with csv_path.open("r", newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        run_id = (row.get("run_id") or "").strip()
        if run_id:
            runs.append(run_id)

if not runs:
    print("none")
    raise SystemExit(0)

required = ("status.json", "summary.json", "stdout.log")
for run_id in runs:
    run_dir = artifacts_root / run_id
    if not run_dir.is_dir():
        print("partial")
        raise SystemExit(0)
    for name in required:
        if not (run_dir / name).is_file():
            print("partial")
            raise SystemExit(0)

print("synced")
PY
}

run_workflow_subcommand() {
  local subcmd="$1"
  shift || true
  WORKFLOW_CONFIG="$CONFIG_PATH" bash "${SCRIPT_DIR}/workflow.sh" "$subcmd" "$@"
}

cmd_checklist_reset() {
  load_config
  local path
  path="$(checklist_path)"
  checklist_reset_file "$path"
  log "checklist reset: $path"
}

cmd_checklist_status() {
  load_config
  local path
  path="$(checklist_path)"

  if [[ ! -f "$path" ]]; then
    checklist_reset_file "$path"
  fi
  sed -n '1,200p' "$path"
}

cmd_flow() {
  load_config

  local provision_mode="auto"
  local sweep_mode="start"
  local wait_mode="false"
  local fetch_mode="none"
  local teardown_mode="${WF_DEFAULT_TEARDOWN:-keep}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provision)
        provision_mode="$2"
        shift 2
        ;;
      --provision=*)
        provision_mode="${1#*=}"
        shift
        ;;
      --sweep)
        sweep_mode="$2"
        shift 2
        ;;
      --sweep=*)
        sweep_mode="${1#*=}"
        shift
        ;;
      --wait)
        wait_mode="$2"
        shift 2
        ;;
      --wait=*)
        wait_mode="${1#*=}"
        shift
        ;;
      --fetch)
        fetch_mode="$2"
        shift 2
        ;;
      --fetch=*)
        fetch_mode="${1#*=}"
        shift
        ;;
      --teardown)
        teardown_mode="$2"
        shift 2
        ;;
      --teardown=*)
        teardown_mode="${1#*=}"
        shift
        ;;
      *)
        die "unknown arg for flow: $1"
        ;;
    esac
  done

  case "$provision_mode" in
    auto|skip) ;;
    *) die "flow --provision must be one of: auto, skip" ;;
  esac
  case "$sweep_mode" in
    start|resume|skip) ;;
    *) die "flow --sweep must be one of: start, resume, skip" ;;
  esac
  case "$wait_mode" in
    true|false) ;;
    *) die "flow --wait must be true or false" ;;
  esac
  case "$teardown_mode" in
    keep|delete) ;;
    *) die "flow --teardown must be keep or delete" ;;
  esac
  case "$fetch_mode" in
    none|all|run:*) ;;
    *) die "flow --fetch must be none, all, or run:<run_id>" ;;
  esac

  WF_FLOW_TEARDOWN_MODE="$teardown_mode"

  local checklist_file
  checklist_file="$(checklist_path)"
  checklist_reset_file "$checklist_file"
  checklist_append_event "$checklist_file" "FLOW" "start" "provision=${provision_mode} sweep=${sweep_mode} wait=${wait_mode} fetch=${fetch_mode} teardown=${teardown_mode}"

  flow_init_context
  flow_write_start_artifact "provision=${provision_mode} sweep=${sweep_mode} wait=${wait_mode} fetch=${fetch_mode} teardown=${teardown_mode}"

  local rc=0
  local failed_phase=""

  if ! flow_finalize_phase "$checklist_file" "P00" "preflight complete" "flow-precheck" "0"; then
    rc=1
    failed_phase="P00"
  fi

  if [[ "$provision_mode" == "auto" ]]; then
    if [[ "$rc" -eq 0 && -z "${LIUM_TARGET:-}" ]]; then
      if [[ ! -t 0 && ! -t 1 ]] && ! is_truthy "${LIUM_YES:-0}"; then
        rc=1
        failed_phase="P10"
        flow_record_phase_failure "$checklist_file" "P10" "noninteractive safety violation" "pod-up" "$rc"
      elif ! run_workflow_subcommand pod-up; then
        rc=$?
        failed_phase="P10"
        flow_record_phase_failure "$checklist_file" "P10" "pod-up failed" "pod-up" "$rc"
      fi

      if [[ "$rc" -eq 0 && -z "${LIUM_TARGET:-}" ]]; then
        if [[ -n "${LIUM_POD_NAME:-}" ]]; then
          upsert_config_value "$CONFIG_PATH" "LIUM_TARGET" "$LIUM_POD_NAME"
          log "flow target autobind: set LIUM_TARGET=${LIUM_POD_NAME} in ${CONFIG_PATH}"
          load_config
        else
          rc=1
          failed_phase="P10"
          flow_record_phase_failure "$checklist_file" "P10" "unable to autobind LIUM_TARGET from LIUM_POD_NAME" "target-autobind" "$rc"
        fi
      fi
    fi

    if [[ "$rc" -eq 0 ]]; then
      if ! flow_finalize_phase "$checklist_file" "P10" "pod provisioning complete" "pod-up" "0"; then
        rc=1
        failed_phase="P10"
      fi
    fi
  else
    if ! flow_finalize_phase "$checklist_file" "P10" "provision skipped by policy" "provision-policy" "0"; then
      rc=1
      failed_phase="P10"
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    if [[ -z "${LIUM_TARGET:-}" && -z "${OPS_DEFAULT_HOST:-}" ]]; then
      rc=1
      failed_phase="P20"
      flow_record_phase_failure "$checklist_file" "P20" "no LIUM target or fallback host resolved" "target-bind" "$rc"
    else
      if ! flow_finalize_phase "$checklist_file" "P20" "target resolved" "target-bind" "0"; then
        rc=1
        failed_phase="P20"
      fi
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    if run_workflow_subcommand pod-status; then
      if ! flow_finalize_phase "$checklist_file" "P30" "pod status validated" "pod-status" "0"; then
        rc=1
        failed_phase="P30"
      fi
    else
      rc=$?
      failed_phase="P30"
      flow_record_phase_failure "$checklist_file" "P30" "pod-status failed" "pod-status" "$rc"
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    if run_workflow_subcommand bootstrap; then
      if ! flow_finalize_phase "$checklist_file" "P40" "bootstrap complete" "bootstrap" "0"; then
        rc=1
        failed_phase="P40"
      fi
    else
      rc=$?
      failed_phase="P40"
      flow_record_phase_failure "$checklist_file" "P40" "bootstrap failed" "bootstrap" "$rc"
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    if run_workflow_subcommand checkout; then
      if ! flow_finalize_phase "$checklist_file" "P50" "checkout complete" "checkout" "0"; then
        rc=1
        failed_phase="P50"
      fi
    else
      rc=$?
      failed_phase="P50"
      flow_record_phase_failure "$checklist_file" "P50" "checkout failed" "checkout" "$rc"
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    if [[ "$sweep_mode" == "start" ]]; then
      if run_workflow_subcommand sweep-start; then
        if ! flow_finalize_phase "$checklist_file" "P60" "sweep start complete" "sweep-start" "0"; then
          rc=1
          failed_phase="P60"
        fi
      else
        rc=$?
        failed_phase="P60"
        flow_record_phase_failure "$checklist_file" "P60" "sweep-start failed" "sweep-start" "$rc"
      fi
    elif [[ "$sweep_mode" == "resume" ]]; then
      if run_workflow_subcommand sweep-status; then
        if ! flow_finalize_phase "$checklist_file" "P60" "sweep resume acknowledged" "sweep-status" "0"; then
          rc=1
          failed_phase="P60"
        fi
      else
        rc=$?
        failed_phase="P60"
        flow_record_phase_failure "$checklist_file" "P60" "sweep resume status check failed" "sweep-status" "$rc"
      fi
    else
      if ! flow_finalize_phase "$checklist_file" "P60" "sweep skipped by policy" "sweep-policy" "0"; then
        rc=1
        failed_phase="P60"
      fi
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    if [[ "$wait_mode" == "true" ]]; then
      if flow_wait_for_completion; then
        if ! flow_finalize_phase "$checklist_file" "P70" "waited for sweep completion" "sweep-wait" "0"; then
          rc=1
          failed_phase="P70"
        fi
      else
        rc=$?
        failed_phase="P70"
        flow_record_phase_failure "$checklist_file" "P70" "sweep wait failed" "sweep-wait" "$rc"
      fi
    else
      if run_workflow_subcommand sweep-status; then
        if ! flow_finalize_phase "$checklist_file" "P70" "monitor snapshot complete" "sweep-status" "0"; then
          rc=1
          failed_phase="P70"
        fi
      else
        rc=$?
        failed_phase="P70"
        flow_record_phase_failure "$checklist_file" "P70" "sweep-status failed" "sweep-status" "$rc"
      fi
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    case "$fetch_mode" in
      none)
        if ! flow_finalize_phase "$checklist_file" "P80" "fetch skipped by policy" "fetch-policy" "0"; then
          rc=1
          failed_phase="P80"
        fi
        ;;
      all)
        if flow_fetch_all_runs; then
          if ! flow_finalize_phase "$checklist_file" "P80" "fetched all run artifacts" "fetch-all" "0"; then
            rc=1
            failed_phase="P80"
          fi
        else
          rc=$?
          failed_phase="P80"
          flow_record_phase_failure "$checklist_file" "P80" "fetch-all failed" "fetch-all" "$rc"
        fi
        ;;
      run:*)
        local run_id="${fetch_mode#run:}"
        if [[ -z "$run_id" ]]; then
          rc=1
          failed_phase="P80"
          flow_record_phase_failure "$checklist_file" "P80" "empty run id in --fetch run:<id>" "fetch-run" "$rc"
        elif run_workflow_subcommand fetch-run "$run_id"; then
          if ! flow_finalize_phase "$checklist_file" "P80" "fetched run=${run_id}" "fetch-run" "0"; then
            rc=1
            failed_phase="P80"
          fi
        else
          rc=$?
          failed_phase="P80"
          flow_record_phase_failure "$checklist_file" "P80" "fetch-run failed for ${run_id}" "fetch-run" "$rc"
        fi
        ;;
    esac
  fi

  if [[ "$rc" -eq 0 ]]; then
    case "$teardown_mode" in
      keep)
        if ! flow_finalize_phase "$checklist_file" "P90" "teardown=keep" "teardown-policy" "0"; then
          rc=1
          failed_phase="P90"
        fi
        ;;
      delete)
        if run_workflow_subcommand pod-delete; then
          if ! flow_finalize_phase "$checklist_file" "P90" "teardown=delete" "pod-delete" "0"; then
            rc=1
            failed_phase="P90"
          fi
        else
          rc=$?
          failed_phase="P90"
          flow_record_phase_failure "$checklist_file" "P90" "pod-delete failed" "pod-delete" "$rc"
        fi
        ;;
    esac
  fi

  if [[ "$rc" -eq 0 ]]; then
    if flow_finalize_phase "$checklist_file" "P99" "flow success" "flow-summary" "0"; then
      :
    else
      rc=1
      failed_phase="P99"
      log "flow failed at phase ${failed_phase} due to phase validation"
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
  flow_record_phase_failure "$checklist_file" "${failed_phase:-UNKNOWN}" "flow halted" "$(phase_default_command "${failed_phase:-UNKNOWN}")" "$rc"
    log "flow failed at phase ${failed_phase:-UNKNOWN} (rc=${rc})"
  fi

  flow_write_summary_artifact "$rc" "$failed_phase" "$checklist_file"

  if [[ "$rc" -eq 0 ]]; then
    log "flow completed successfully"
  fi

  checklist_archive_and_reset_if_needed "$checklist_file"
  return "$rc"
}

load_config() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    die "config file not found: ${CONFIG_PATH}"
  fi
  local resolved_config="$CONFIG_PATH"
  if [[ "$resolved_config" != /* ]]; then
    resolved_config="$(cd -- "$(dirname -- "$resolved_config")" && pwd)/$(basename -- "$resolved_config")"
  fi
  WF_ACTIVE_CONFIG_REALPATH="$resolved_config"

  # shellcheck disable=SC1090
  source "$CONFIG_PATH"

  if [[ "${WF_ACTIVE_COMMAND:-}" != _* && "$WF_ACTIVE_CONFIG_REALPATH" != "$CANONICAL_CONFIG_PATH" ]]; then
    if ! is_truthy "${WF_ALLOW_OVERRIDE:-0}"; then
      die "WORKFLOW_CONFIG override blocked by constitution; use ${CANONICAL_CONFIG_PATH} or set WF_ALLOW_OVERRIDE=1 in ${CONFIG_PATH}"
    fi
  fi
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

remote_workflow_path() {
  require_var OPS_REMOTE_OUTPUTS_DIR
  echo "${OPS_REMOTE_OUTPUTS_DIR}/_control/workflow.sh"
}

ensure_remote_workflow_script() {
  load_config
  require_var OPS_REMOTE_OUTPUTS_DIR

  local remote_script
  remote_script="$(remote_workflow_path)"

  remote_mkdir_p "$(dirname -- "$remote_script")"
  remote_upload "${SCRIPT_DIR}/workflow.sh" "$remote_script"
  remote_exec_raw "chmod 700 $(shell_escape "$remote_script") || chmod +x $(shell_escape "$remote_script") || true"
}

fsm_state_file_hint() {
  if [[ -n "${WF_STATE_FILE:-}" ]]; then
    echo "$WF_STATE_FILE"
    return 0
  fi
  echo "${OPS_REMOTE_OUTPUTS_DIR}/_control/workflow_state.json"
}

fsm_get_remote_state() {
  require_var OPS_REMOTE_OUTPUTS_DIR
  local out line state
  state="INIT"
  out="$(remote_exec_env 'python3 - <<'"'"'PY'"'"'
import json
import os

path = os.environ.get("WF_STATE_FILE") or os.path.join(
    os.environ["OPS_REMOTE_OUTPUTS_DIR"], "_control", "workflow_state.json"
)
state = "INIT"
try:
    with open(path, "r") as f:
        state = json.load(f).get("state", "INIT")
except Exception:
    pass

print(f"WF_STATE={state}")
PY' || true)"

  while IFS= read -r line; do
    if [[ "$line" == WF_STATE=* ]]; then
      state="${line#WF_STATE=}"
    fi
  done <<<"$out"

  echo "$state"
}

fsm_set_remote_state() {
  require_var OPS_REMOTE_OUTPUTS_DIR
  local next_state="$1"
  local reason="${2:-}"

  local remote_cmd
  remote_cmd="$(cat <<EOF
export WF_FSM_NEXT_STATE=$(shell_escape "$next_state")
export WF_FSM_REASON=$(shell_escape "$reason")
python3 - <<'PY'
import json
import os
import pathlib
import socket
import time

path = os.environ.get("WF_STATE_FILE") or os.path.join(
    os.environ["OPS_REMOTE_OUTPUTS_DIR"], "_control", "workflow_state.json"
)
next_state = os.environ.get("WF_FSM_NEXT_STATE", "INIT")
reason = os.environ.get("WF_FSM_REASON", "")

p = pathlib.Path(path)
p.parent.mkdir(parents=True, exist_ok=True)

previous = "INIT"
if p.exists():
    try:
        previous = json.loads(p.read_text()).get("state", "INIT")
    except Exception:
        previous = "INIT"

now = int(time.time())
payload = {
    "state": next_state,
    "previous_state": previous,
    "reason": reason,
    "updated_at_unix": now,
    "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
    "host": socket.gethostname(),
}
p.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"WF_STATE={next_state}")
PY
EOF
)"

  remote_exec_env "$remote_cmd" >/dev/null
}

fsm_promote_pod_ready_if_needed() {
  if ! is_truthy "${WF_FSM_ENFORCE:-1}"; then
    return 0
  fi

  local state
  state="$(fsm_get_remote_state)"
  if [[ "$state" == "INIT" || "$state" == "POD_TERMINATED" ]]; then
    fsm_set_remote_state "POD_READY" "auto-promote: remote reachable"
  fi
}

fsm_require_state() {
  local action="$1"
  shift

  if ! is_truthy "${WF_FSM_ENFORCE:-1}"; then
    return 0
  fi

  local state
  state="$(fsm_get_remote_state)"

  local allowed
  local ok=0
  local joined=""
  for allowed in "$@"; do
    if [[ -z "$joined" ]]; then
      joined="$allowed"
    else
      joined="$joined,$allowed"
    fi

    if [[ "$state" == "$allowed" ]]; then
      ok=1
    fi
  done

  if [[ "$ok" != 1 ]]; then
    die "illegal workflow state for ${action}: current=${state} allowed=[${joined}] (hint: bash infra_scripts/workflow.sh fsm-status)"
  fi
}

fsm_update_from_sweep_summary() {
  local summary_text="$1"

  if ! is_truthy "${WF_FSM_ENFORCE:-1}"; then
    return 0
  fi

  local phase
  phase="$(python3 - <<'PY' "$summary_text"
import re
import sys

s = sys.argv[1]
m = re.search(r"total=(\d+)\s+ok=(\d+)\s+failed=(\d+)\s+in_progress=(\d+)\s+missing_dir=(\d+)\s+parse_error=(\d+)", s)
if not m:
    print("unknown")
    raise SystemExit(0)

total, ok, failed, in_progress, missing_dir, parse_error = map(int, m.groups())
if in_progress > 0:
    print("running")
elif total == ok + failed and missing_dir == 0 and parse_error == 0 and total > 0:
    print("completed")
elif failed > 0 or parse_error > 0:
    print("stalled")
else:
    print("unknown")
PY
)"

  case "$phase" in
    stalled)
      fsm_set_remote_state "SWEEP_STALLED" "sweep-status: stalled"
      ;;
    running)
      fsm_set_remote_state "SWEEP_RUNNING" "sweep-status: in progress"
      ;;
    completed)
      fsm_set_remote_state "SWEEP_COMPLETED" "sweep-status: completed"
      ;;
  esac
}

cmd_help() {
  cat <<'EOF'
Usage: infra_scripts/workflow.sh <command> [args]

Config:
  - Canonical: infra_scripts/workflow.cfg
  - Override: WORKFLOW_CONFIG=/path/to/file (blocked unless WF_ALLOW_OVERRIDE=1)

Commands (local entrypoints):
  flow                       Canonical end-to-end lifecycle with checklist gating
                             options: --provision auto|skip, --sweep start|resume|skip,
                                      --wait true|false, --fetch none|all|run:<id>,
                                      --teardown keep|delete (also accepts --key=value)
  pod-up                     Create a pod via lium (optional)
  pod-wait                   Wait until the pod is reachable over SSH
  pod-delete                 Delete the current pod (LIUM_TARGET)
  pod-butter                 Create pod and recreate if SSH >5min
  pod-status                 Check pod reachability and /mnt mount
  config-sync                Upload config to REMOTE_ENV_PATH (default /mnt/project.env)
  bootstrap                  Install prereqs (optional) + run BOOTSTRAP_SCRIPT/WANDB_SETUP_SCRIPT if present
  checkout                   Clone repo + checkout branch/PR + create venv + install deps + validate data/output dirs
  fsm-status                 Show persisted workflow state on remote
  fsm-reset [STATE]          Force workflow state (default: INIT)

  task-run                    Run a tracked remote task in tmux (state machine + logs)
  task-status                 Show task status and tail logs
  task-wait                   Block until a task completes (success/fail/timeout)
  task-list                   List recent tasks

  checklist-status            Print the live workflow checklist file
  checklist-reset             Reset workflow checklist file to unchecked template

  sweep-csv-template         Create a starter sweep CSV at SWEEP_CSV (local)
  workflow-sync              Deprecated (git is source of truth; no repo sync)
  sweep-start [--csv PATH]   Upload sweep CSV + start a sequential torchrun sweep in tmux
  sweep-status               Summarize sweep progress from SWEEP_CSV + outputs root
  sweep-watch [--tail-lines N]
                             Show progress fraction + active run + tmux liveness + active run tail
  fetch-all                  Fetch all runs listed in active SWEEP_CSV
  fetch-run <run_id>         Fetch a single run directory into LOCAL_ARTIFACTS_DIR/<run_id>/

Commands (remote/internal):
  _sweep_run_all             Runs the sweep sequentially (used by tmux window)
  _sweep_status              Prints progress summary (used by sweep-status)
EOF
}

is_known_command() {
  case "$1" in
    help|-h|--help|flow|pod-up|pod-wait|pod-delete|pod-butter|pod-status|config-sync|bootstrap|checkout|task-run|task-status|task-wait|task-list|checklist-status|checklist-reset|sweep-csv-template|workflow-sync|fsm-status|fsm-reset|sweep-start|sweep-status|sweep-watch|fetch-all|fetch-run|_sweep_run_all|_sweep_status)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
  fsm_promote_pod_ready_if_needed
  fsm_require_state "task-run" "POD_READY" "BOOTSTRAPPED" "CHECKED_OUT" "PRECHECKED" "SWEEP_LAUNCHED" "SWEEP_RUNNING" "SWEEP_STALLED" "SWEEP_COMPLETED" "ARTIFACTS_FETCHING" "ARTIFACTS_SYNCED"

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
      if [[ -n "${OPS_REMOTE_OUTPUTS_DIR:-}" && -n "${REMOTE_ENV_PATH:-}" ]]; then
        if config_sync >/dev/null 2>&1; then
          fsm_set_remote_state "POD_READY" "pod-wait: reachable" || true
        fi
      fi
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

  if [[ -n "${OPS_REMOTE_OUTPUTS_DIR:-}" && -n "${REMOTE_ENV_PATH:-}" ]]; then
    if config_sync >/dev/null 2>&1; then
      fsm_set_remote_state "POD_TERMINATED" "pod-delete: terminated" || true
    fi
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

cmd_fsm_status() {
  load_config
  config_sync
  require_var OPS_REMOTE_OUTPUTS_DIR

  local state
  state="$(fsm_get_remote_state)"
  echo "state=$state"

  remote_exec_env 'python3 - <<"PY"
import json
import os

path = os.environ.get("WF_STATE_FILE") or os.path.join(
    os.environ["OPS_REMOTE_OUTPUTS_DIR"], "_control", "workflow_state.json"
)
print(f"state_file={path}")
if os.path.exists(path):
    print("--- workflow_state.json ---")
    with open(path, "r") as f:
        print(f.read().rstrip())
else:
    print("state_file_missing=1")
PY'
}

cmd_fsm_reset() {
  load_config
  config_sync
  require_var OPS_REMOTE_OUTPUTS_DIR

  local state="${1:-INIT}"
  case "$state" in
    INIT|POD_READY|BOOTSTRAPPED|CHECKED_OUT|PRECHECKED|SWEEP_LAUNCHED|SWEEP_RUNNING|SWEEP_STALLED|SWEEP_COMPLETED|ARTIFACTS_FETCHING|ARTIFACTS_SYNCED|POD_TERMINATED) ;;
    *) die "invalid state for fsm-reset: $state" ;;
  esac

  fsm_set_remote_state "$state" "manual reset"
  echo "state=$state"
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

  if [[ -n "${OPS_REMOTE_OUTPUTS_DIR:-}" ]]; then
    fsm_set_remote_state "POD_READY" "pod-status: reachable" || true
  fi
}

cmd_bootstrap() {
  load_config
  config_sync
  fsm_promote_pod_ready_if_needed
  fsm_require_state "bootstrap" "POD_READY" "BOOTSTRAPPED" "CHECKED_OUT" "PRECHECKED" "SWEEP_STALLED" "SWEEP_COMPLETED" "ARTIFACTS_FETCHING" "ARTIFACTS_SYNCED"

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

  fsm_set_remote_state "BOOTSTRAPPED" "bootstrap complete"
}

cmd_checkout() {
  load_config
  config_sync
  fsm_promote_pod_ready_if_needed
  fsm_require_state "checkout" "POD_READY" "BOOTSTRAPPED" "CHECKED_OUT" "PRECHECKED" "SWEEP_STALLED" "SWEEP_COMPLETED" "ARTIFACTS_FETCHING" "ARTIFACTS_SYNCED"

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

  fsm_set_remote_state "CHECKED_OUT" "checkout complete"
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

  local csv_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --csv)
        [[ $# -lt 2 ]] && die "--csv requires a path"
        csv_override="$2"
        shift 2
        ;;
      *)
        die "unknown arg for sweep-start: $1"
        ;;
    esac
  done

  local csv_local
  if [[ -n "$csv_override" ]]; then
    if [[ "$csv_override" = /* ]]; then
      csv_local="$csv_override"
    else
      csv_local="${REPO_ROOT}/${csv_override}"
    fi
  else
    csv_local="$(local_csv_path)"
  fi

  if [[ ! -f "$csv_local" ]]; then
    die "sweep CSV missing: $csv_local (run: bash infra_scripts/workflow.sh sweep-csv-template)"
  fi

  config_sync
  ensure_remote_workflow_script
  cmd_checkout
  fsm_require_state "sweep-start" "CHECKED_OUT" "PRECHECKED" "SWEEP_STALLED" "SWEEP_COMPLETED" "ARTIFACTS_FETCHING" "ARTIFACTS_SYNCED"

  require_var OPS_REMOTE_OUTPUTS_DIR

  # Keep the remote git checkout immutable: never write the sweep CSV into $OPS_REMOTE_REPO.
  # Upload it to outputs manifests and run from that absolute path.
  remote_exec_env 'mkdir -p "$OPS_REMOTE_OUTPUTS_DIR/_manifests"'
  local csv_remote_latest
  csv_remote_latest="$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-latest.csv"
  remote_upload "$csv_local" "$csv_remote_latest"
  remote_exec_env "ts=\"\$(date +%Y%m%d-%H%M%S)\"; cp -f \"$csv_remote_latest\" \"$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-\${ts}.csv\"; cp -f \"$REMOTE_ENV_PATH\" \"$OPS_REMOTE_OUTPUTS_DIR/_manifests/workflow-\${ts}.env\""

  fsm_set_remote_state "PRECHECKED" "sweep-start: preflight complete"

  require_var SWEEP_TMUX_SESSION
  local workflow_remote
  workflow_remote="$(remote_workflow_path)"

  local tmux_cmd
  tmux_cmd="$(cat <<EOF
session="\$SWEEP_TMUX_SESSION"
tmux has-session -t "\$session" 2>/dev/null || tmux new-session -d -s "\$session" -n overview
tmux set-option -t "\$session" remain-on-exit on
tmux list-windows -t "\$session" -F "#{window_name}" | grep -qx "sweep" && tmux kill-window -t "\$session":sweep 2>/dev/null || true
tmux new-window -t "\$session" -n sweep "cd \"$OPS_REMOTE_REPO\" && WORKFLOW_CONFIG=\"$REMOTE_ENV_PATH\" bash \"$workflow_remote\" _sweep_run_all --csv \"$csv_remote_latest\""
tmux list-windows -t "\$session" -F "#{window_name}" | grep -qx "sweep"
echo "tmux attach -t \$session"
EOF
)"
  remote_exec_env "$tmux_cmd"
  fsm_set_remote_state "SWEEP_LAUNCHED" "sweep-start launched"
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
  ensure_remote_workflow_script
  fsm_promote_pod_ready_if_needed
  fsm_require_state "sweep-status" "CHECKED_OUT" "PRECHECKED" "SWEEP_LAUNCHED" "SWEEP_RUNNING" "SWEEP_STALLED" "SWEEP_COMPLETED" "ARTIFACTS_FETCHING" "ARTIFACTS_SYNCED"

  local workflow_remote
  workflow_remote="$(remote_workflow_path)"

  local status_out
  status_out="$(remote_exec_env "csv_latest=\"$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-latest.csv\"; cd \"$OPS_REMOTE_REPO\" && if [[ -f \"\$csv_latest\" ]]; then WORKFLOW_CONFIG=\"$REMOTE_ENV_PATH\" bash \"$workflow_remote\" _sweep_status --csv \"\$csv_latest\"; else WORKFLOW_CONFIG=\"$REMOTE_ENV_PATH\" bash \"$workflow_remote\" _sweep_status; fi")"
  printf '%s\n' "$status_out"
  fsm_update_from_sweep_summary "$status_out"

  remote_exec_env 'echo "attach:"; echo "tmux attach -t $SWEEP_TMUX_SESSION"; tmux ls || true'
}

cmd_sweep_watch() {
  load_config
  config_sync
  fsm_promote_pod_ready_if_needed
  fsm_require_state "sweep-watch" "CHECKED_OUT" "PRECHECKED" "SWEEP_LAUNCHED" "SWEEP_RUNNING" "SWEEP_STALLED" "SWEEP_COMPLETED" "ARTIFACTS_FETCHING" "ARTIFACTS_SYNCED"

  local tail_lines=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail-lines)
        tail_lines="$2"
        shift 2
        ;;
      *)
        die "unknown arg for sweep-watch: $1"
        ;;
    esac
  done

  if [[ ! "$tail_lines" =~ ^[0-9]+$ || "$tail_lines" == 0 ]]; then
    die "--tail-lines must be a positive integer"
  fi

  require_var OPS_REMOTE_OUTPUTS_DIR
  require_var SWEEP_TMUX_SESSION
  require_var SWEEP_CSV

  local csv_remote_default
  csv_remote_default="$(remote_csv_path)"

  local remote_script=""
  remote_script+=$(cat <<EOF
TAIL_LINES=$(shell_escape "$tail_lines")
CSV_REMOTE_DEFAULT=$(shell_escape "$csv_remote_default")
EOF
)
  remote_script+=$'\n'

  remote_script+=$(cat <<'EOF'
csv_latest="$OPS_REMOTE_OUTPUTS_DIR/_manifests/sweep-latest.csv"
if [[ -f "$csv_latest" ]]; then
  csv="$csv_latest"
else
  csv="$CSV_REMOTE_DEFAULT"
fi

if [[ ! -f "$csv" ]]; then
  die "remote sweep CSV not found: $csv"
fi

py_out="$(python3 - <<'PY' "$OPS_REMOTE_OUTPUTS_DIR" "$csv"
import csv as csv_mod
import io
import json
import os
import sys

outputs_root = sys.argv[1]
csv_path = sys.argv[2]

match = os.environ.get("SWEEP_MATCH", "")
start_at = os.environ.get("SWEEP_START_AT", "")
limit_raw = os.environ.get("SWEEP_LIMIT", "")
limit = None
if limit_raw:
    try:
        limit = int(limit_raw)
    except Exception:
        limit = None

total = 0
ok = 0
failed = 0
in_progress = 0
missing_dir = 0
parse_error = 0

started = not bool(start_at)
active_run = ""
active_idx = ""
active_log = ""
completed = 0

with open(csv_path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

for raw in lines:
    if not raw:
        continue
    if raw.startswith("run_id,"):
        continue
    if raw.startswith("#"):
        continue

    if match and match not in raw:
        continue

    try:
        row = next(csv_mod.reader(io.StringIO(raw)))
    except Exception:
        continue

    if not row:
        continue
    run_id = row[0].strip().strip('"')
    if not run_id:
        continue

    if not started:
        if run_id == start_at:
            started = True
        else:
            continue

    if limit is not None and total >= limit:
        break

    total += 1
    run_dir = os.path.join(outputs_root, run_id)
    summary_path = os.path.join(run_dir, "summary.json")
    status_path = os.path.join(run_dir, "status.json")
    stdout_log = os.path.join(run_dir, "stdout.log")

    status_state = ""
    if os.path.isfile(status_path):
        try:
            with open(status_path, "r", encoding="utf-8") as sf:
                status_state = str(json.load(sf).get("state", ""))
        except Exception:
            status_state = "parse_error"

    if not os.path.isdir(run_dir):
        missing_dir += 1
        continue

    if not os.path.isfile(summary_path):
        in_progress += 1
        if not active_run and status_state == "running":
            active_run = run_id
            active_idx = str(total)
            active_log = stdout_log if os.path.isfile(stdout_log) else ""
        continue

    try:
        with open(summary_path, "r", encoding="utf-8") as sf:
            summary = json.load(sf)
        if summary.get("ok") is True:
            ok += 1
        else:
            failed += 1
    except Exception:
        parse_error += 1

completed = ok + failed + parse_error

if not active_run and in_progress > 0:
    # fallback: choose first run that has directory but no summary
    started = not bool(start_at)
    for raw in lines:
        if not raw or raw.startswith("run_id,") or raw.startswith("#"):
            continue
        if match and match not in raw:
            continue
        try:
            row = next(csv_mod.reader(io.StringIO(raw)))
        except Exception:
            continue
        if not row:
            continue
        run_id = row[0].strip().strip('"')
        if not run_id:
            continue
        if not started:
            if run_id == start_at:
                started = True
            else:
                continue
        run_dir = os.path.join(outputs_root, run_id)
        summary_path = os.path.join(run_dir, "summary.json")
        if os.path.isdir(run_dir) and not os.path.isfile(summary_path):
            active_run = run_id
            active_log = os.path.join(run_dir, "stdout.log")
            break

print(f"total={total} ok={ok} failed={failed} in_progress={in_progress} missing_dir={missing_dir} parse_error={parse_error}")
print(f"progress={completed}/{total}")
print(f"current_run={active_run if active_run else '-'}")
print(f"current_index={active_idx if active_idx else '-'}")
print(f"current_log={active_log if active_log else '-'}")
PY
)"

summary_line="$(printf '%s\n' "$py_out" | sed -n '1p')"
progress_line="$(printf '%s\n' "$py_out" | sed -n '2p')"
current_run_line="$(printf '%s\n' "$py_out" | sed -n '3p')"
current_index_line="$(printf '%s\n' "$py_out" | sed -n '4p')"
current_log_line="$(printf '%s\n' "$py_out" | sed -n '5p')"

printf '%s\n' "$summary_line"
printf '%s\n' "$progress_line"
printf '%s\n' "$current_index_line"
printf '%s\n' "$current_run_line"

tmux_alive="no"
if tmux has-session -t "$SWEEP_TMUX_SESSION" 2>/dev/null; then
  tmux_alive="yes"
fi
echo "tmux_alive=$tmux_alive"
echo "attach=tmux attach -t $SWEEP_TMUX_SESSION"

current_log="${current_log_line#current_log=}"
current_run="${current_run_line#current_run=}"
echo "--- tail (last ${TAIL_LINES}) ---"
if [[ -n "$current_log" && "$current_log" != "-" && -f "$current_log" ]]; then
  echo "log=$current_log"
  tail -n "$TAIL_LINES" "$current_log"
else
  if [[ -n "$current_run" && "$current_run" != "-" ]]; then
    echo "missing log for current run: $current_run"
  else
    echo "no active run"
  fi
fi
EOF
)

  local watch_out
  watch_out="$(remote_exec_env "$remote_script")"
  printf '%s\n' "$watch_out"

  local summary_line
  summary_line="$(printf '%s\n' "$watch_out" | grep -E '^total=' | head -n 1 || true)"
  local tmux_line
  tmux_line="$(printf '%s\n' "$watch_out" | grep -E '^tmux_alive=' | head -n 1 || true)"
  local current_run_line
  current_run_line="$(printf '%s\n' "$watch_out" | grep -E '^current_run=' | head -n 1 || true)"

  local stall_eval stalled_line stall_reason_line stalled_flag stall_reason
  stall_eval="$(python3 - <<'PY' "$summary_line" "$tmux_line" "$current_run_line"
import re
import sys

summary = sys.argv[1]
tmux_line = sys.argv[2]
run_line = sys.argv[3]

stalled = "no"
reason = "-"

m = re.search(r"total=(\d+)\s+ok=(\d+)\s+failed=(\d+)\s+in_progress=(\d+)\s+missing_dir=(\d+)\s+parse_error=(\d+)", summary)
tmux_alive = tmux_line.split("=", 1)[1] if tmux_line.startswith("tmux_alive=") else "unknown"
current_run = run_line.split("=", 1)[1] if run_line.startswith("current_run=") else "-"

if m:
    _total, _ok, failed, in_progress, _missing_dir, parse_error = map(int, m.groups())
    if failed > 0 or parse_error > 0:
        stalled = "yes"
        reason = "failed_or_parse_error"
    elif in_progress > 0 and tmux_alive != "yes":
        stalled = "yes"
        reason = "tmux_not_alive"
    elif in_progress > 0 and current_run in ("", "-"):
        stalled = "yes"
        reason = "in_progress_without_active_run"

print(f"stalled={stalled}")
print(f"stall_reason={reason}")
PY
)"

  stalled_line="$(printf '%s\n' "$stall_eval" | sed -n '1p')"
  stall_reason_line="$(printf '%s\n' "$stall_eval" | sed -n '2p')"
  stalled_flag="${stalled_line#stalled=}"
  stall_reason="${stall_reason_line#stall_reason=}"
  printf '%s\n' "$stalled_line"
  printf '%s\n' "$stall_reason_line"

  if [[ "$stalled_flag" == "yes" ]]; then
    fsm_set_remote_state "SWEEP_STALLED" "sweep-watch: ${stall_reason:-stalled}" || true
  elif [[ -n "$summary_line" ]]; then
    fsm_update_from_sweep_summary "$summary_line"
  fi
}

cmd_fetch_run() {
  load_config
  config_sync
  fsm_promote_pod_ready_if_needed
  fsm_require_state "fetch-run" "CHECKED_OUT" "PRECHECKED" "SWEEP_LAUNCHED" "SWEEP_RUNNING" "SWEEP_STALLED" "SWEEP_COMPLETED" "ARTIFACTS_FETCHING" "ARTIFACTS_SYNCED"
  require_var OPS_REMOTE_OUTPUTS_DIR
  require_var LOCAL_ARTIFACTS_DIR

  local run_id="${1:-}"
  [[ -n "$run_id" ]] || die "usage: fetch-run <run_id>"

  fsm_set_remote_state "ARTIFACTS_FETCHING" "fetch-run: ${run_id}" || true

  local tmp_remote="/tmp/${run_id}.tar.gz"
  local tmp_local="${LOCAL_ARTIFACTS_DIR}/${run_id}.tar.gz"
  mkdir -p "$LOCAL_ARTIFACTS_DIR"

  if is_truthy "${FETCH_INCLUDE_CHECKPOINTS:-0}"; then
    remote_exec_env "tar -C \"$OPS_REMOTE_OUTPUTS_DIR\" -czf \"$tmp_remote\" \"$run_id\""
  else
    remote_exec_env "tar -C \"$OPS_REMOTE_OUTPUTS_DIR\" --exclude=\"$run_id/ckpt.pt\" --exclude=\"$run_id/*.ckpt\" --exclude=\"$run_id/checkpoints\" -czf \"$tmp_remote\" \"$run_id\""
  fi
  remote_download "$tmp_remote" "$tmp_local"
  tar -xzf "$tmp_local" -C "$LOCAL_ARTIFACTS_DIR"
  rm -f "$tmp_local"
  remote_exec_env "rm -f \"$tmp_remote\" || true"

  local csv_local sync_phase
  csv_local="$(local_csv_path)"
  if [[ -f "$csv_local" ]]; then
    sync_phase="$(artifacts_sync_phase_for_csv "$csv_local" "$LOCAL_ARTIFACTS_DIR")"
  else
    sync_phase="unknown"
  fi

  if [[ "$sync_phase" == "synced" ]]; then
    fsm_set_remote_state "ARTIFACTS_SYNCED" "fetch-run: local manifest artifacts synced"
  else
    fsm_set_remote_state "ARTIFACTS_FETCHING" "fetch-run: local artifacts partial"
  fi

  log "fetched: ${LOCAL_ARTIFACTS_DIR}/${run_id}/"
}

cmd_fetch_all() {
  load_config
  local csv
  csv="$(local_csv_path)"
  [[ -f "$csv" ]] || die "fetch-all requires sweep CSV: $csv"

  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    cmd_fetch_run "$run_id"
  done < <(python3 - <<'PY' "$csv"
import csv
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("r", newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        run_id = (row.get("run_id") or "").strip()
        if run_id:
            print(run_id)
PY
)
}

main() {
  local cmd="${1:-help}"
  shift || true

  WF_ACTIVE_COMMAND="$cmd"

  if ! is_known_command "$cmd"; then
    die "unknown command: $cmd (run: bash infra_scripts/workflow.sh help)"
  fi

  if [[ "$cmd" != "help" && "$cmd" != "-h" && "$cmd" != "--help" ]]; then
    constitution_preflight "$cmd"
  fi

  case "$cmd" in
    help|-h|--help) cmd_help ;;
    flow) cmd_flow "$@" ;;
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
    checklist-status) cmd_checklist_status "$@" ;;
    checklist-reset) cmd_checklist_reset "$@" ;;
    sweep-csv-template) cmd_sweep_csv_template "$@" ;;
    workflow-sync) cmd_workflow_sync "$@" ;;
    fsm-status) cmd_fsm_status "$@" ;;
    fsm-reset) cmd_fsm_reset "$@" ;;
    sweep-start) cmd_sweep_start "$@" ;;
    sweep-status) cmd_sweep_status "$@" ;;
    sweep-watch) cmd_sweep_watch "$@" ;;
    fetch-all) cmd_fetch_all "$@" ;;
    fetch-run) cmd_fetch_run "$@" ;;
    _sweep_run_all) cmd__sweep_run_all "$@" ;;
    _sweep_status) cmd__sweep_status "$@" ;;
  esac
}

main "$@"
