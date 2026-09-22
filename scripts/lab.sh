#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$repo_root/deploy.env}"

source "$repo_root/scripts/runtime.sh"
require_deployment_runtime

if [[ "${1:-}" == stage-log || "${1:-}" == stage-progress || "${1:-}" == build-status || "${1:-}" == inventory ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for this command." >&2
    exit 1
  fi
fi

if [[ "${1:-}" == stage-log || "${1:-}" == stage-progress || "${1:-}" == build-status ]]; then
  viewer_args=(--env-file "$env_file")
  if [[ "${1:-}" == stage-progress || "${1:-}" == build-status ]]; then
    viewer_args+=(--progress)
  fi
  if [[ "${1:-}" == build-status ]]; then
    viewer_args+=(--auto)
  fi
  exec python3 "$repo_root/scripts/show-stage-log.py" "${viewer_args[@]}" -- "${2:-}"
fi

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file." >&2
  exit 1
fi

load_setting() {
  local requested_key="$1"
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$key" == "$requested_key" ]]; then
      printf '%s' "$value"
      return
    fi
  done < "$env_file"
}

subscription_id="$(load_setting AZURE_SUBSCRIPTION_ID)"
resource_group="$(load_setting AZURE_RESOURCE_GROUP)"
name_prefix="$(load_setting NAME_PREFIX)"
host_name="${name_prefix}-host"

if [[ -z "$subscription_id" || -z "$resource_group" || -z "$name_prefix" ]]; then
  echo "AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, and NAME_PREFIX are required in $env_file." >&2
  exit 1
fi

az account set --subscription "$subscription_id"

case "${1:-}" in
  status)
    az vm get-instance-view \
      --resource-group "$resource_group" \
      --name "$host_name" \
      --query "{name:name,powerState:instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]}" \
      --output table
    ;;
  stop)
    az vm deallocate --resource-group "$resource_group" --name "$host_name" --output none
    ;;
  start)
    az vm start --resource-group "$resource_group" --name "$host_name" --output none
    ;;
  inventory)
    arc_resource_group="$(load_setting ARC_RESOURCE_GROUP)"
    if [[ -z "$arc_resource_group" ]]; then
      arc_resource_group="${resource_group}-arc"
    fi
    inventory_args=(
      --subscription "$subscription_id"
      --resource-group "$arc_resource_group"
    )
    if [[ -n "${2:-}" ]]; then
      inventory_args+=(--output-dir "$2")
    fi
    exec python3 "$repo_root/scripts/export-arc-inventory.py" "${inventory_args[@]}"
    ;;
  delete-infra)
    if [[ "${2:-}" != "$resource_group" ]]; then
      echo "Confirm deletion by running: scripts/lab.sh delete-infra $resource_group" >&2
      exit 1
    fi
    az group delete --name "$resource_group" --yes
    ;;
  *)
    echo "Usage: scripts/lab.sh <status|stop|start|build-status|stage-progress|stage-log|inventory|delete-infra>" >&2
    exit 1
    ;;
esac
