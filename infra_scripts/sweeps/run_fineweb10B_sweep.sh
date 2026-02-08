#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/../load_project_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$script_dir/../load_project_env.sh"
fi

usage() {
  cat <<'EOF'
Usage: run_fineweb10B_sweep.sh [options]

Options:
  --csv <path>          Sweep CSV (default: infra_scripts/sweeps/fineweb10B_full_sweep.csv)
  --workdir <path>      Repo root (default: $OPS_REMOTE_REPO or /root/work/mHC-manifold-constrained-hyper-connections)
  --out-root <path>     Output root (default: $OPS_REMOTE_OUTPUTS_DIR or /mnt/pod_artifacts/outputs)
  --data-dir <path>     FineWeb data dir (default: /mnt/data/fineweb10B)
  --wandb-group <name>  W&B group label (default: fineweb10B-sweep-YYYYMMDD)
  --device <dev>        Force device override (e.g., cuda, mps, cpu)
  --match <substr>      Only run rows whose run_id contains this substring
  --start-at <run_id>   Skip until the given run_id is reached
  --limit <n>           Stop after running N rows (0 = no limit)
  --force               Run even if summary.json exists
  --dry-run             Print commands only
  --no-wandb            Disable W&B logging
  -h, --help            Show this help
EOF
}

CSV="${CSV:-infra_scripts/sweeps/fineweb10B_full_sweep.csv}"
WORKDIR="${WORKDIR:-${OPS_REMOTE_REPO:-/root/work/mHC-manifold-constrained-hyper-connections}}"
OUT_ROOT="${OUT_ROOT:-${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}}"
DATA_DIR="${DATA_DIR:-/mnt/data/fineweb10B}"
WANDB_GROUP="${WANDB_GROUP:-fineweb10B-sweep-$(date +%Y%m%d)}"
WANDB_LOG_PY="${WANDB_LOG_PY:-True}"
DEVICE=""
MATCH=""
START_AT=""
LIMIT=0
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)
      CSV="$2"
      shift 2
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --out-root)
      OUT_ROOT="$2"
      shift 2
      ;;
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --wandb-group)
      WANDB_GROUP="$2"
      shift 2
      ;;
    --device)
      DEVICE="$2"
      shift 2
      ;;
    --match)
      MATCH="$2"
      shift 2
      ;;
    --start-at)
      START_AT="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-wandb)
      WANDB_LOG_PY="False"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$CSV" ]]; then
  echo "Missing CSV: $CSV"
  exit 1
fi

PYTHON="${PYTHON:-$WORKDIR/.venv/bin/python}"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="${PYTHON:-python}"
fi

strip_quotes() {
  local value="$1"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

python_bool() {
  # Normalize truthy/falsy strings to Python literals.
  case "${1,,}" in
    true|1|yes|y) echo "True";;
    false|0|no|n) echo "False";;
    *) echo "$1";;
  esac
}

summary_ok() {
  local path="$1"
  python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, "r"))
except Exception:
    sys.exit(2)
sys.exit(0 if data.get("ok") is True else 1)
PY
}

backup_run_files() {
  local run_dir="$1"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"

  for f in stdout.log summary.json; do
    if [[ -f "$run_dir/$f" ]]; then
      mv "$run_dir/$f" "$run_dir/$f.bak-$stamp"
    fi
  done
}

run_count=0
started=false
if [[ -z "$START_AT" ]]; then
  started=true
fi

while IFS=, read -r run_id config seed overrides notes; do
  if [[ "$run_id" == "run_id" ]]; then
    continue
  fi

  run_id="$(strip_quotes "$run_id")"
  config="$(strip_quotes "$config")"
  seed="$(strip_quotes "$seed")"
  overrides="$(strip_quotes "${overrides:-}")"

  if [[ -n "$START_AT" && "$started" == "false" ]]; then
    if [[ "$run_id" == "$START_AT" ]]; then
      started=true
    else
      continue
    fi
  fi

  if [[ -n "$MATCH" && "$run_id" != *"$MATCH"* ]]; then
    continue
  fi

  if [[ "$LIMIT" -ne 0 && "$run_count" -ge "$LIMIT" ]]; then
    break
  fi

  run_dir="$OUT_ROOT/$run_id"
  summary_path="$run_dir/summary.json"

  if [[ -f "$summary_path" && "$FORCE" == "false" ]]; then
    if summary_ok "$summary_path"; then
      echo "skip: $run_id (summary.json ok=true)"
      continue
    fi

    echo "error: $run_id has summary.json but ok!=true; rerun with --force" >&2
    exit 2
  fi

  mkdir -p "$run_dir"
  if [[ "$FORCE" == "true" ]]; then
    backup_run_files "$run_dir"
  fi

  cmd=(
    "$PYTHON" "train.py" "$config"
    "out_dir=$run_dir"
    "data_dir=$DATA_DIR"
    "seed=$seed"
    "wandb_log=$WANDB_LOG_PY"
    "wandb_group=$WANDB_GROUP"
    "wandb_run_name=$run_id"
  )

  if [[ -n "$DEVICE" ]]; then
    cmd+=("device=$DEVICE")
  fi

  if [[ -n "$overrides" ]]; then
    read -r -a overrides_arr <<< "$overrides"
    cmd+=("${overrides_arr[@]}")
  fi

  echo "run: $run_id"
  echo "  config: $config"
  echo "  out: $run_dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  cmd:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    run_count=$((run_count + 1))
    continue
  fi

  (
    cd "$WORKDIR/examples/nanogpt"
    "${cmd[@]}" > "$run_dir/stdout.log" 2>&1
  )

  if [[ ! -f "$summary_path" ]]; then
    echo "error: missing summary.json for $run_id"
    exit 1
  fi

  if ! summary_ok "$summary_path"; then
    echo "error: summary.json ok!=true for $run_id" >&2
    exit 1
  fi

  run_count=$((run_count + 1))
done < "$CSV"

echo "completed: $run_count runs"
