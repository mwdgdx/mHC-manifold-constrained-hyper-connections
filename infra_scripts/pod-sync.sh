#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/load_project_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$script_dir/load_project_env.sh"
fi

usage() {
  cat <<'EOF'
Usage: pod-sync.sh --run-id <id> [options]

Options:
  --run-id <id>         Run id (required)
  --workdir <path>      Repo path (default: $OPS_REMOTE_REPO or /root/work/mHC-manifold-constrained-hyper-connections)
  --out-root <path>     Output root (default: $OPS_REMOTE_OUTPUTS_DIR or /mnt/pod_artifacts/outputs)
  --out-local <path>    Local out dir (default: <workdir>/examples/nanogpt/out/<run-id>)
  -h, --help            Show this help
EOF
}

WORKDIR="${WORKDIR:-${OPS_REMOTE_REPO:-/root/work/mHC-manifold-constrained-hyper-connections}}"
OUT_ROOT="${OUT_ROOT:-${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}}"
RUN_ID=""
OUT_LOCAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --out-root) OUT_ROOT="$2"; shift 2 ;;
    --out-local) OUT_LOCAL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  echo "--run-id is required" >&2
  usage
  exit 2
fi

if [[ -z "$OUT_LOCAL" ]]; then
  OUT_LOCAL="$WORKDIR/examples/nanogpt/out/$RUN_ID"
fi

if [[ ! -d "$OUT_LOCAL" ]]; then
  echo "Local output dir not found: $OUT_LOCAL" >&2
  exit 2
fi

mkdir -p "$OUT_ROOT/$RUN_ID"

if command -v rsync >/dev/null 2>&1; then
  rsync -a "$OUT_LOCAL/" "$OUT_ROOT/$RUN_ID/"
else
  cp -r "$OUT_LOCAL/." "$OUT_ROOT/$RUN_ID/"
fi

echo "Synced to $OUT_ROOT/$RUN_ID"
