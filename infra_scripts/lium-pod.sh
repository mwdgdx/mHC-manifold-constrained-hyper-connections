#!/usr/bin/env bash
set -euo pipefail

POD_NAME="${LIUM_POD_NAME:-my-gpu-pod}"
DEFAULT_GPU="${LIUM_DEFAULT_GPU:-A100}"
DEFAULT_VOLUME_NAME="${LIUM_DEFAULT_VOLUME:-my_volume}"
BACKUP_PATH="${LIUM_BACKUP_PATH:-/root}"
BACKUP_RETENTION="${LIUM_BACKUP_RETENTION:-7}"
SSH_HOST_DEFAULT="lium"
WORKSPACE_PATH="${LIUM_WORKSPACE_PATH:-/mnt}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: lium-pod.sh <command> [options]

Commands:
  ls [GPU_TYPE]           List available GPUs (optionally filter by type)
  up [--gpu TYPE] [--name NAME] [--count N] [--config EXECUTOR] [--country CC]
                            Create a new pod
  ps                      List your active pods
  ssh [POD]               SSH into a pod
  shutdown [POD]          Backup and remove pod (safe shutdown)
  resume [POD]            Restore pod from latest backup
  backups [POD]           List available backups for a pod
  
Options:
  --gpu TYPE              GPU type: A100, H100, L4, RTX4090, etc. (default: $DEFAULT_GPU)
  --name NAME             Pod name (default: $POD_NAME)
  --count N               Number of GPUs (default: 1)
  --config EXECUTOR       Executor from lium ls (index, id, or huid); ignores --gpu/--country/--count
  --volume NAME           Attach existing volume by name (default: $DEFAULT_VOLUME_NAME)
  --volume-id ID          Attach existing volume by HUID
  --no-volume             Do not attach a persistent volume
  --country CC            Country filter: US, JP, DE, etc.
  --ttl DURATION          Auto-terminate after duration (e.g., 4h, 1d)
  -y, --yes               Skip confirmations

Environment:
  LIUM_POD_NAME           Default pod name (default: my-gpu-pod)
  LIUM_DEFAULT_GPU        Default GPU type (default: A100)
  LIUM_DEFAULT_VOLUME     Default volume name (default: my_volume)
  LIUM_BACKUP_PATH        Path to backup (default: /root)
  LIUM_BACKUP_RETENTION   Backup retention days (default: 7)
  LIUM_WORKSPACE_PATH     Workspace path inside pod (default: /mnt)

Examples:
  lium-pod.sh ls                      # List all available GPUs
  lium-pod.sh ls A100                 # List only A100s
  lium-pod.sh up --gpu A100 --count 1 # Create 1x A100 pod (attaches default volume)
  lium-pod.sh up --gpu A100 --no-volume
  lium-pod.sh up --gpu H100 --ttl 4h  # Create H100, auto-stop in 4 hours
  lium-pod.sh up --config 1 --name dev  # Use an exact executor; do not pass --count
  lium-pod.sh up --name dev --volume data
  lium-pod.sh ps                      # Show your pods
  lium-pod.sh ssh my-pod              # SSH into pod
  lium-pod.sh shutdown my-pod         # Backup and remove
  lium-pod.sh resume my-pod           # Restore from backup
EOF
}

check_lium() {
  if ! command -v lium &>/dev/null; then
    log_error "Lium CLI not found. Install with: pip install lium.io (Python >= 3.9)"
    log_info "Then run: lium init"
    exit 1
  fi
}

get_lium_python() {
  local lium_path
  lium_path="$(command -v lium)"
  local shebang
  read -r shebang < "$lium_path"
  if [[ "$shebang" != "#!"* ]]; then
    return 1
  fi
  echo "${shebang#\#!}"
}

get_pod_ssh_details() {
  local pod="$1"
  local lium_python
  lium_python="$(get_lium_python)" || return 1

  "$lium_python" - <<PY
import shlex

from lium.sdk.client import Lium


def parse_ssh_cmd(raw: str):
    tokens = shlex.split(raw)
    if tokens and tokens[0] == "ssh":
        tokens = tokens[1:]

    port = None
    dest = None
    opts_with_arg = {"-p", "-i", "-o", "-F", "-J", "-L", "-R", "-D", "-l"}

    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in opts_with_arg:
            if tok == "-p" and i + 1 < len(tokens):
                port = tokens[i + 1]
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        dest = tok
        break

    if not dest:
        return None, None, None

    if "@" in dest:
        user, host = dest.split("@", 1)
    else:
        user, host = "root", dest

    return user, host, port or "22"

pod_name = "$pod"
lium = Lium()
pods = lium.ps()
match = next((p for p in pods if p.name == pod_name or p.huid == pod_name or p.id == pod_name), None)

if not match or not match.ssh_cmd:
    raise SystemExit(1)

user, host, port = parse_ssh_cmd(match.ssh_cmd)
if not host or not port:
    raise SystemExit(1)

print(f"USER={user}")
print(f"HOST={host}")
print(f"PORT={port}")
PY
}

get_volume_id_by_name() {
  local volume_name="$1"
  local lium_python
  lium_python="$(get_lium_python)" || return 1

  "$lium_python" - <<PY
from lium.sdk.client import Lium

name = "$volume_name"
lium = Lium()
volumes = lium.volumes()
match = next((v for v in volumes if v.name == name or v.huid == name or v.id == name), None)

if not match:
    raise SystemExit(1)

print(match.huid or match.id)
PY
}

resolve_ssh_identity_file() {
  local candidate
  for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  local config_key
  config_key="$(lium config get ssh.key_path 2>/dev/null || true)"
  if [[ -n "$config_key" && -f "$config_key" ]]; then
    echo "$config_key"
    return 0
  fi

  return 1
}

update_ssh_config() {
  local pod="$1"
  local host_alias="$SSH_HOST_DEFAULT"
  local config_file="$HOME/.ssh/config"

  mkdir -p "$HOME/.ssh"
  touch "$config_file"

  local details=""
  local attempt=1
  local max_attempts=10

  while true; do
    if details="$(get_pod_ssh_details "$pod")"; then
      break
    fi

    if [[ $attempt -ge $max_attempts ]]; then
      log_warn "Could not resolve SSH details for pod: $pod"
      return 1
    fi

    attempt=$((attempt + 1))
    sleep 3
  done

  local ssh_user=""
  local ssh_host=""
  local ssh_port=""

  while IFS='=' read -r key value; do
    case "$key" in
      USER) ssh_user="$value" ;;
      HOST) ssh_host="$value" ;;
      PORT) ssh_port="$value" ;;
    esac
  done <<< "$details"

  if [[ -z "$ssh_host" || -z "$ssh_port" ]]; then
    log_warn "Missing SSH host or port for pod: $pod"
    return 1
  fi

  local identity_file
  if ! identity_file="$(resolve_ssh_identity_file)"; then
    log_warn "No SSH identity file found"
    return 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  awk -v host="$host_alias" '
    BEGIN { skip=0 }
    $1=="Host" {
      skip=0
      for (i=2; i<=NF; i++) {
        if ($i==host) { skip=1; next }
      }
    }
    skip==0 { print }
  ' "$config_file" > "$tmp_file"

  cat >> "$tmp_file" <<EOF
Host $host_alias
  HostName $ssh_host
  User $ssh_user
  Port $ssh_port
  IdentityFile $identity_file
  IdentitiesOnly yes
  ServerAliveInterval 60
  ServerAliveCountMax 120
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF

  mv "$tmp_file" "$config_file"
  log_success "SSH config updated (~/.ssh/config) for Host $host_alias"
}

cmd_ls() {
  local gpu_type="${1:-}"
  
  if [[ -n "$gpu_type" ]]; then
    log_info "Listing available $gpu_type GPUs..."
    lium ls "$gpu_type"
  else
    log_info "Listing all available GPUs..."
    lium ls
  fi
}

cmd_ps() {
  log_info "Your active pods:"
  lium ps
}

cmd_up() {
  local gpu="$DEFAULT_GPU"
  local name="$POD_NAME"
  local count="1"
  local count_set="false"
  local country=""
  local ttl=""
  local yes_flag=""
  local volume_name=""
  local volume_id=""
  local no_volume="false"
  local executor_config=""
  local gpu_set="false"
  local country_set="false"
  
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gpu) gpu="$2"; gpu_set="true"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --count) count="$2"; count_set="true"; shift 2 ;;
      --config) executor_config="$2"; shift 2 ;;
      --volume) volume_name="$2"; shift 2 ;;
      --volume-id) volume_id="$2"; shift 2 ;;
      --no-volume) no_volume="true"; shift ;;
      --country) country="$2"; country_set="true"; shift 2 ;;
      --ttl) ttl="$2"; shift 2 ;;
      -y|--yes) yes_flag="--yes"; shift ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -n "$volume_name" && -n "$volume_id" ]]; then
    log_error "Use either --volume or --volume-id, not both"
    exit 1
  fi

  if [[ "$no_volume" == "true" ]]; then
    volume_name=""
    volume_id=""
  elif [[ -z "$volume_name" && -z "$volume_id" && -n "$DEFAULT_VOLUME_NAME" ]]; then
    volume_name="$DEFAULT_VOLUME_NAME"
  fi

  local cmd=(lium up)
  if [[ -n "$executor_config" ]]; then
    if [[ "$gpu_set" == "true" || "$country_set" == "true" || "$count_set" == "true" ]]; then
      log_warn "Ignoring --gpu/--country/--count when using --config"
    fi
    log_info "Creating pod: $name (Executor: $executor_config)"
    cmd+=("$executor_config" --name "$name")
  else
    log_info "Creating pod: $name (GPU: $gpu)"
    cmd+=(--gpu "$gpu" --name "$name")
    [[ -n "$country" ]] && cmd+=(--country "$country")
    [[ -n "$count" ]] && cmd+=(--count "$count")
  fi

  if [[ -n "$volume_id" ]]; then
    cmd+=(--volume "id:$volume_id")
  elif [[ -n "$volume_name" ]]; then
    volume_id="$(get_volume_id_by_name "$volume_name")" || true
    if [[ -z "$volume_id" ]]; then
      log_error "Volume not found: $volume_name"
      log_info "Create it with: lium volumes new $volume_name"
      exit 1
    fi
    cmd+=(--volume "id:$volume_id")
  fi

  [[ -n "$ttl" ]] && cmd+=(--ttl "$ttl")
  [[ -n "$yes_flag" ]] && cmd+=($yes_flag)
  
  "${cmd[@]}"
  
  if [[ $? -eq 0 ]]; then
    log_success "Pod created: $name"
    update_ssh_config "$name" || log_warn "SSH config update failed"
    echo ""
    log_info "Workspace: $WORKSPACE_PATH"
    log_info "Connect with: ssh $SSH_HOST_DEFAULT"
    log_info "Stop with:    lium-pod.sh shutdown $name"
  fi
}

cmd_ssh() {
  local pod="${1:-$POD_NAME}"
  log_info "Connecting to $pod..."
  lium ssh "$pod"
}

cmd_shutdown() {
  local pod="${1:-$POD_NAME}"
  local yes_flag=""
  
  shift || true
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y|--yes) yes_flag="yes"; shift ;;
      *) shift ;;
    esac
  done
  
  log_info "Shutting down pod: $pod"
  
  local lium_python
  lium_python="$(get_lium_python)" || lium_python=""

  if [[ -n "$lium_python" ]]; then
    if ! "$lium_python" - <<PY 2>/dev/null
from lium.sdk.client import Lium
pod_name = "$pod"
lium = Lium()
pods = lium.ps()
match = next((p for p in pods if p.name == pod_name or p.huid == pod_name or p.id == pod_name), None)
if not match:
    raise SystemExit(1)
PY
    then
      log_error "Pod not found: $pod"
      exit 1
    fi
  else
    if ! lium ps 2>/dev/null | grep -q "$pod"; then
      log_error "Pod not found: $pod"
      exit 1
    fi
  fi
  
  log_info "Creating backup before shutdown..."
  if lium bk now "$pod" --name "shutdown-$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
    log_success "Backup created"
  else
    log_warn "Backup may have failed or not configured. Continuing..."
  fi
  
  if [[ -n "$yes_flag" ]]; then
    lium rm "$pod" --yes
  else
    echo ""
    read -p "Remove pod $pod? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      lium rm "$pod" --yes
    else
      log_info "Aborted"
      exit 0
    fi
  fi
  
  log_success "Pod $pod shut down"
  log_info "Resume later with: lium-pod.sh resume $pod"
}

cmd_resume() {
  local pod="${1:-$POD_NAME}"
  
  log_info "Looking for backups for: $pod"
  
  local backups
  backups=$(lium bk logs "$pod" 2>/dev/null || echo "")
  
  if [[ -z "$backups" ]]; then
    log_warn "No backups found for $pod"
    log_info "Creating fresh pod instead..."
    cmd_up --name "$pod"
    return
  fi
  
  echo ""
  echo "Available backups:"
  echo "$backups"
  echo ""
  
  log_info "To restore, first create a new pod, then restore:"
  echo ""
  echo "  1. lium up --gpu $DEFAULT_GPU --name $pod"
  echo "  2. lium bk restore $pod <BACKUP_ID> $BACKUP_PATH"
  echo ""
  log_info "Or create fresh pod: lium-pod.sh up --name $pod"
}

cmd_backups() {
  local pod="${1:-$POD_NAME}"
  
  log_info "Backups for: $pod"
  lium bk logs "$pod" 2>/dev/null || log_warn "No backups found or pod doesn't exist"
}

cmd_setup_backup() {
  local pod="${1:-$POD_NAME}"
  
  log_info "Setting up automatic backups for: $pod"
  lium bk set "$pod" "$BACKUP_PATH" --frequency 6 --retention "$BACKUP_RETENTION"
  log_success "Backups configured: every 6 hours, $BACKUP_RETENTION day retention"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi
  
  check_lium
  
  local cmd="$1"
  shift
  
  case "$cmd" in
    ls|list)
      cmd_ls "$@"
      ;;
    up|create|start)
      cmd_up "$@"
      ;;
    ps|pods|status)
      cmd_ps "$@"
      ;;
    ssh|connect)
      cmd_ssh "$@"
      ;;
    shutdown|stop|down|finalize)
      cmd_shutdown "$@"
      ;;
    resume|restore)
      cmd_resume "$@"
      ;;
    backups|bk)
      cmd_backups "$@"
      ;;
    setup-backup)
      cmd_setup_backup "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      log_error "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
