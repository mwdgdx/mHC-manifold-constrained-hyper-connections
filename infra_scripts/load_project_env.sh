#!/usr/bin/env bash
set -euo pipefail

# Sources project-level environment if present.
#
# Precedence (lowest -> highest):
# - /mnt/project.env
# - <repo>/infra_scripts/project.env
# - OPS_PROJECT_ENV

_script_dir() {
  cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_try_source() {
  local path="$1"
  if [[ -f "$path" ]]; then
    # shellcheck disable=SC1090
    source "$path"
  fi
}

_try_source "/mnt/project.env"

repo_env="$(_script_dir)/project.env"
_try_source "$repo_env"

if [[ -n "${OPS_PROJECT_ENV:-}" ]]; then
  _try_source "$OPS_PROJECT_ENV"
fi
