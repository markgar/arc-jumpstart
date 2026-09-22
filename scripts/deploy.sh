#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$repo_root/deploy.env}"
temporary_files=()
images_submitted=false
image_previous_run_start_time=''

source "$repo_root/scripts/runtime.sh"
require_deployment_runtime

cleanup() {
  if (( ${#temporary_files[@]} > 0 )); then
    rm -f "${temporary_files[@]}"
  fi
  if [[ "$images_submitted" == true ]]; then
    echo "Stage 30 was submitted independently and may outlive this wrapper. Inspect stage30-images before retrying; do not start a competing download." >&2
  fi
}
trap cleanup EXIT

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file. Copy deploy.env.example to an owner-only file and set ENV_FILE to its absolute path." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "Azure CLI and python3 are required." >&2
  exit 1
fi

load_env_file() {
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      echo "Invalid line in $env_file: expected KEY=value." >&2
      exit 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      AZURE_SUBSCRIPTION_ID|AZURE_LOCATION|AZURE_RESOURCE_GROUP|NAME_PREFIX|\
      HOST_ADMIN_USERNAME|HOST_ADMIN_PASSWORD|NESTED_WINDOWS_PASSWORD|\
      SAFE_MODE_PASSWORD|SQL_SERVICE_ACCOUNT_PASSWORD|DEPLOY_BASTION|\
      AUTO_SHUTDOWN_ENABLED|AUTO_SHUTDOWN_TIME|AUTO_SHUTDOWN_TIME_ZONE|\
      PREPARE_ARC_LAUNCHERS|ARC_RESOURCE_GROUP|ARC_LOCATION|\
      HOST_VM_SIZE|HOST_DATA_DISK_SIZE_GB|IMAGE_SOURCE_URL|\
      IMAGE_SOURCE_SAS_TOKEN|WINDOWS_IMAGE_FILE_NAME|SQL_DOWNLOAD_URL|\
      LINUX_IMAGE_FILE_NAME)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        echo "Unknown setting in $env_file: $key" >&2
        exit 1
        ;;
    esac
  done < "$env_file"
}

load_env_file

requested_stage="${1:-}"
required_values=(
  AZURE_SUBSCRIPTION_ID
  AZURE_LOCATION
  AZURE_RESOURCE_GROUP
  NAME_PREFIX
)
if [[ "$requested_stage" != bastion && "$requested_stage" != auto-shutdown ]]; then
  required_values+=(
    HOST_ADMIN_USERNAME
    HOST_ADMIN_PASSWORD
    NESTED_WINDOWS_PASSWORD
    SAFE_MODE_PASSWORD
    SQL_SERVICE_ACCOUNT_PASSWORD
  )
fi

for variable_name in "${required_values[@]}"; do
  if [[ -z "${!variable_name:-}" || "${!variable_name}" == "CHANGEME" ]]; then
    echo "$variable_name must be set in $env_file." >&2
    exit 1
  fi
done

ARC_RESOURCE_GROUP="${ARC_RESOURCE_GROUP:-${AZURE_RESOURCE_GROUP}-arc}"
ARC_LOCATION="${ARC_LOCATION:-$AZURE_LOCATION}"

if [[ "$requested_stage" == all || "$requested_stage" == auto-shutdown ]]; then
  for variable_name in AUTO_SHUTDOWN_ENABLED AUTO_SHUTDOWN_TIME AUTO_SHUTDOWN_TIME_ZONE; do
    if [[ -z "${!variable_name:-}" || "${!variable_name}" == "CHANGEME" ]]; then
      echo "$variable_name must be explicitly set in $env_file for $requested_stage." >&2
      exit 1
    fi
  done
fi

if [[ "$requested_stage" == arc-launchers || \
      ("$requested_stage" == all && "${PREPARE_ARC_LAUNCHERS:-true}" == true) ]]; then
  for variable_name in ARC_RESOURCE_GROUP ARC_LOCATION; do
    if [[ -z "${!variable_name:-}" || "${!variable_name}" == "CHANGEME" ]]; then
      echo "$variable_name must be set in $env_file for arc-launchers." >&2
      exit 1
    fi
  done
fi

if [[ "$requested_stage" != bastion && "$requested_stage" != auto-shutdown ]]; then
  PASSWORD_HOST="$HOST_ADMIN_PASSWORD" \
  PASSWORD_DSRM="$SAFE_MODE_PASSWORD" \
  PASSWORD_SQL_SERVICE="$SQL_SERVICE_ACCOUNT_PASSWORD" \
  python3 - <<'PY'
import os
import string
import sys

for name, value in {
    "HOST_ADMIN_PASSWORD": os.environ["PASSWORD_HOST"],
    "SAFE_MODE_PASSWORD": os.environ["PASSWORD_DSRM"],
    "SQL_SERVICE_ACCOUNT_PASSWORD": os.environ["PASSWORD_SQL_SERVICE"],
}.items():
    classes = sum((
        any(character.islower() for character in value),
        any(character.isupper() for character in value),
        any(character.isdigit() for character in value),
        any(character in string.punctuation or character.isspace() for character in value),
    ))
    if len(value) < 8 or classes < 3:
        print(f"{name} must be at least 8 characters and use at least three character classes.", file=sys.stderr)
        sys.exit(1)
PY
fi

if [[ -z "$requested_stage" ]]; then
  echo "Usage: scripts/deploy.sh <00|10|20|30|40|45|50|60|20-30|all|bastion|auto-shutdown|arc-launchers>" >&2
  exit 1
fi

stages=(00 10 20 30 40 45 50 60)
case "$requested_stage" in
  00|10|20|30|40|45|50|60) stages=("$requested_stage") ;;
  20-30) stages=(20 30) ;;
  all) ;;
  bastion|auto-shutdown|arc-launchers) stages=() ;;
  *)
    echo "Unknown stage: $requested_stage" >&2
    exit 1
    ;;
esac

case "${PREPARE_ARC_LAUNCHERS:-true}" in
  true|false) ;;
  *)
    echo "PREPARE_ARC_LAUNCHERS must be true or false." >&2
    exit 1
    ;;
esac

case "${DEPLOY_BASTION:-true}" in
  true|false) ;;
  *)
    echo "DEPLOY_BASTION must be true or false." >&2
    exit 1
    ;;
esac

if [[ "$requested_stage" == all || "$requested_stage" == auto-shutdown ]]; then
  case "$AUTO_SHUTDOWN_ENABLED" in
    true|false) ;;
    *)
      echo "AUTO_SHUTDOWN_ENABLED must be true or false." >&2
      exit 1
      ;;
  esac
  if [[ ! "$AUTO_SHUTDOWN_TIME" =~ ^([01][0-9]|2[0-3])[0-5][0-9]$ ]]; then
    echo "AUTO_SHUTDOWN_TIME must use 24-hour HHmm format." >&2
    exit 1
  fi
fi

stage_directory() {
  case "$1" in
    00) printf '00-foundation' ;;
    10) printf '10-hyperv-host' ;;
    20) printf '20-host-network' ;;
    30) printf '30-images' ;;
    40) printf '40-nested-vms' ;;
    45) printf '45-sql-install' ;;
    50) printf '50-domain' ;;
    60) printf '60-sql-ag' ;;
  esac
}

stage_script() {
  case "$1" in
    10) printf '10-init-host.ps1' ;;
    20) printf '20-host-network.ps1' ;;
    30) printf '30-download-images.ps1' ;;
    40) printf '40-create-nested-vms.ps1' ;;
    45) printf '45-install-sql.ps1' ;;
    50) printf '50-configure-domain.ps1' ;;
    60) printf '60-configure-sql-ag.ps1' ;;
  esac
}

stage_command() {
  case "$1" in
    10) printf 'stage10-init-host' ;;
    20) printf 'stage20-host-network' ;;
    30) printf 'stage30-images' ;;
    40) printf 'stage40-nested-vms' ;;
    45) printf 'stage45-sql-install' ;;
    50) printf 'stage50-domain' ;;
    60) printf 'stage60-sql-ag' ;;
  esac
}

export AZURE_CORE_ONLY_SHOW_ERRORS=true
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
if [[ "$(az account show --query user.type --output tsv)" != "user" ]]; then
  echo "This interactive lab requires Azure CLI authentication as a user, not a service principal." >&2
  exit 1
fi
az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" --output none

foundation_deployment="arc-jumpstart-00-foundation"

read_foundation_output() {
  local output_name="$1"
  local value
  value="$(az deployment group show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$foundation_deployment" \
    --query "properties.outputs.${output_name}.value" \
    --output tsv 2>/dev/null || true)"
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s\n' "$value"
    return
  fi

  case "$output_name" in
    hostSubnetId)
      az network vnet subnet show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --vnet-name "${NAME_PREFIX}-vnet" \
        --name snet-host \
        --query id \
        --output tsv
      ;;
    *)
      echo "Foundation output $output_name is unavailable." >&2
      exit 1
      ;;
  esac
}

deployment_succeeded() {
  local deployment_name="$1"
  [[ "$(az deployment group show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$deployment_name" \
    --query properties.provisioningState \
    --output tsv 2>/dev/null || true)" == "Succeeded" ]]
}

require_deployment() {
  local stage="$1"
  local deployment_name
  deployment_name="arc-jumpstart-$(stage_directory "$stage")"
  if ! deployment_succeeded "$deployment_name"; then
    echo "Stage $stage must complete successfully before this stage can run." >&2
    exit 1
  fi
}

require_foundation_core() {
  if [[ "$(az network vnet show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "${NAME_PREFIX}-vnet" \
    --query provisioningState \
    --output tsv 2>/dev/null || true)" != "Succeeded" ]]; then
    echo "The foundation virtual network must complete before this deployment can run." >&2
    exit 1
  fi
}

require_predecessors() {
  case "$1" in
    10) require_foundation_core ;;
    20) require_deployment 10 ;;
    30) require_deployment 10 ;;
    40)
      require_deployment 20
      require_deployment 30
      require_run_command_succeeded 'stage30-images'
      ;;
    45) require_deployment 40 ;;
    50)
      require_deployment 45
      require_run_command_succeeded 'stage45-sql-install'
      ;;
    60) require_deployment 50 ;;
  esac
}

run_command_status() {
  local command_name="$1"
  az vm run-command show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --vm-name "${NAME_PREFIX}-host" \
    --name "$command_name" \
    --expand instanceView \
    --query "[instanceView.executionState, to_string(instanceView.exitCode), instanceView.startTime] | join('|', @)" \
    --output tsv 2>/dev/null || true
}

require_run_command_succeeded() {
  local command_name="$1"
  local status
  status="$(run_command_status "$command_name")"
  if [[ "$status" != Succeeded\|0\|* ]]; then
    echo "Run Command $command_name has not completed successfully (status: ${status:-unknown})." >&2
    exit 1
  fi
}

wait_for_run_command() {
  local command_name="$1"
  local previous_start_time="${2:-}"
  local attempts=0
  local status state exit_code start_time
  while true; do
    status="$(run_command_status "$command_name")"
    IFS='|' read -r state exit_code start_time <<EOF
$status
EOF
    if [[ -z "$start_time" || "$start_time" == "$previous_start_time" ]]; then
      state='Pending'
    fi
    case "$state" in
      Succeeded)
        if [[ "$exit_code" == "0" ]]; then
          return
        fi
        echo "Run Command $command_name exited with code $exit_code." >&2
        exit 1
        ;;
      Failed|Canceled|TimedOut)
        echo "Run Command $command_name ended in state $state with exit code $exit_code." >&2
        exit 1
        ;;
    esac
    attempts=$((attempts + 1))
    if (( attempts % 10 == 0 )); then
      echo "Waiting for Run Command $command_name (${state:-unknown})..."
    fi
    if (( attempts >= 600 )); then
      echo "Timed out waiting for Run Command $command_name." >&2
      exit 1
    fi
    sleep 30
  done
}

write_stage_parameters() {
  local stage="$1"
  local parameter_file="$2"
  PARAM_STAGE="$stage" \
  PARAM_LOCATION="$AZURE_LOCATION" \
  PARAM_NAME_PREFIX="$NAME_PREFIX" \
  PARAM_RUN_ID="$run_id" \
  PARAM_HOST_SUBNET_ID="$host_subnet_id" \
  PARAM_HOST_VM_SIZE="${HOST_VM_SIZE:-Standard_E16s_v7}" \
  PARAM_HOST_ADMIN_USERNAME="$HOST_ADMIN_USERNAME" \
  PARAM_HOST_ADMIN_PASSWORD="$HOST_ADMIN_PASSWORD" \
  PARAM_HOST_DATA_DISK_SIZE_GB="${HOST_DATA_DISK_SIZE_GB:-1024}" \
  PARAM_SET_STANDARD_SECURITY_TYPE="${set_standard_security_type:-true}" \
  PARAM_IMAGE_SOURCE_URL="${IMAGE_SOURCE_URL:-https://jumpstartprodsg.blob.core.windows.net/arcbox/prod}" \
  PARAM_IMAGE_SOURCE_SAS_TOKEN="${IMAGE_SOURCE_SAS_TOKEN:-}" \
  PARAM_WINDOWS_IMAGE_FILE_NAME="${WINDOWS_IMAGE_FILE_NAME:-ArcBox-Win2K22.vhdx}" \
  PARAM_SQL_DOWNLOAD_URL="${SQL_DOWNLOAD_URL:-}" \
  PARAM_LINUX_IMAGE_FILE_NAME="${LINUX_IMAGE_FILE_NAME:-ArcBox-Ubuntu-01.vhdx}" \
  PARAM_NESTED_WINDOWS_PASSWORD="$NESTED_WINDOWS_PASSWORD" \
  PARAM_SAFE_MODE_PASSWORD="$SAFE_MODE_PASSWORD" \
  PARAM_SQL_SERVICE_ACCOUNT_PASSWORD="$SQL_SERVICE_ACCOUNT_PASSWORD" \
  python3 - "$parameter_file" <<'PY'
import json
import os
import sys

stage = os.environ["PARAM_STAGE"]
parameters = {
    "location": {"value": os.environ["PARAM_LOCATION"]},
    "namePrefix": {"value": os.environ["PARAM_NAME_PREFIX"]},
    "runId": {"value": os.environ["PARAM_RUN_ID"]},
}

if stage == "10":
    parameters.update({
        "hostSubnetId": {"value": os.environ["PARAM_HOST_SUBNET_ID"]},
        "hostVmSize": {"value": os.environ["PARAM_HOST_VM_SIZE"]},
        "adminUsername": {"value": os.environ["PARAM_HOST_ADMIN_USERNAME"]},
        "adminPassword": {"value": os.environ["PARAM_HOST_ADMIN_PASSWORD"]},
        "dataDiskSizeGB": {"value": int(os.environ["PARAM_HOST_DATA_DISK_SIZE_GB"])},
        "setStandardSecurityType": {"value": os.environ["PARAM_SET_STANDARD_SECURITY_TYPE"].lower() == "true"},
    })
elif stage == "40":
    parameters.update({
        "nestedWindowsPassword": {"value": os.environ["PARAM_NESTED_WINDOWS_PASSWORD"]},
        "windowsImageFileName": {"value": os.environ["PARAM_WINDOWS_IMAGE_FILE_NAME"]},
        "linuxImageFileName": {"value": os.environ["PARAM_LINUX_IMAGE_FILE_NAME"]},
    })
elif stage == "45":
    if not os.environ["PARAM_SQL_DOWNLOAD_URL"]:
        sys.exit("SQL_DOWNLOAD_URL must be set for stage 45.")
    parameters.update({
        "nestedWindowsPassword": {"value": os.environ["PARAM_NESTED_WINDOWS_PASSWORD"]},
        "sqlDownloadUrl": {"value": os.environ["PARAM_SQL_DOWNLOAD_URL"]},
    })
elif stage == "50":
    parameters.update({
        "nestedWindowsPassword": {"value": os.environ["PARAM_NESTED_WINDOWS_PASSWORD"]},
        "safeModePassword": {"value": os.environ["PARAM_SAFE_MODE_PASSWORD"]},
        "sqlServiceAccountPassword": {"value": os.environ["PARAM_SQL_SERVICE_ACCOUNT_PASSWORD"]},
    })
elif stage == "60":
    parameters.update({
        "nestedWindowsPassword": {"value": os.environ["PARAM_NESTED_WINDOWS_PASSWORD"]},
        "sqlServiceAccountPassword": {"value": os.environ["PARAM_SQL_SERVICE_ACCOUNT_PASSWORD"]},
    })

if stage == "30":
    image_files = ";".join([
        os.environ["PARAM_WINDOWS_IMAGE_FILE_NAME"],
        os.environ["PARAM_LINUX_IMAGE_FILE_NAME"],
    ])
    parameters.update({
        "imageSourceUrl": {"value": os.environ["PARAM_IMAGE_SOURCE_URL"]},
        "imageFileNames": {"value": image_files},
        "imageSourceSasToken": {"value": os.environ["PARAM_IMAGE_SOURCE_SAS_TOKEN"]},
    })

document = {
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": parameters,
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(document, stream)
PY
}

wait_for_vm_agent() {
  local vm_name="$1"
  local attempts=0
  local power_state agent_status
  while true; do
    power_state="$(az vm get-instance-view \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --name "$vm_name" \
      --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" \
      --output tsv 2>/dev/null || true)"
    agent_status="$(az vm get-instance-view \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --name "$vm_name" \
      --query "instanceView.vmAgent.statuses[0].code" \
      --output tsv 2>/dev/null || true)"
    if [[ "$power_state" == "PowerState/running" && "$agent_status" == "ProvisioningState/succeeded" ]]; then
      return
    fi
    attempts=$((attempts + 1))
    if (( attempts >= 60 )); then
      echo "Timed out waiting for VM agent on $vm_name." >&2
      exit 1
    fi
    sleep 15
  done
}

deploy_foundation() {
  echo "==> Stage 00: foundation"
  az deployment group create \
    --name "$foundation_deployment" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$repo_root/infra/stages/00-foundation/main.bicep" \
    --parameters \
      location="$AZURE_LOCATION" \
      namePrefix="$NAME_PREFIX" \
    --output table
}

deploy_bastion() {
  echo "==> Optional Bastion: submitting independently (not waiting for provisioning)"
  az deployment group create \
    --name arc-jumpstart-bastion \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$repo_root/infra/stages/bastion/main.bicep" \
    --parameters location="$AZURE_LOCATION" namePrefix="$NAME_PREFIX" \
    --no-wait \
    --output none
}

deploy_auto_shutdown() {
  require_deployment 10
  echo "==> Optional auto-shutdown: ${AUTO_SHUTDOWN_ENABLED} at ${AUTO_SHUTDOWN_TIME} (${AUTO_SHUTDOWN_TIME_ZONE})"
  az deployment group create \
    --name arc-jumpstart-auto-shutdown \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$repo_root/infra/stages/auto-shutdown/main.bicep" \
    --parameters \
      location="$AZURE_LOCATION" \
      namePrefix="$NAME_PREFIX" \
      enabled="$AUTO_SHUTDOWN_ENABLED" \
      shutdownTime="$AUTO_SHUTDOWN_TIME" \
      timeZoneId="$AUTO_SHUTDOWN_TIME_ZONE" \
    --output table
}

deploy_arc_launchers() {
  require_deployment 60
  echo "==> Arc launchers: preparing dedicated resource group and guest desktops"
  az group create \
    --name "$ARC_RESOURCE_GROUP" \
    --location "$ARC_LOCATION" \
    --tags ArcSQLServerExtensionDeployment=LicenseOnly \
    --output none

  local parameter_file run_id
  umask 077
  parameter_file="$(mktemp "${TMPDIR:-/tmp}/arc-jumpstart-parameters.XXXXXX")"
  temporary_files+=("$parameter_file")
  run_id="$(date -u +%Y%m%d%H%M%S)"

  PARAM_LOCATION="$AZURE_LOCATION" \
  PARAM_NAME_PREFIX="$NAME_PREFIX" \
  PARAM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID" \
  PARAM_ARC_RESOURCE_GROUP="$ARC_RESOURCE_GROUP" \
  PARAM_ARC_LOCATION="$ARC_LOCATION" \
  PARAM_NESTED_WINDOWS_PASSWORD="$NESTED_WINDOWS_PASSWORD" \
  PARAM_RUN_ID="$run_id" \
  python3 - "$parameter_file" <<'PY'
import json
import os
import sys

document = {
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "location": {"value": os.environ["PARAM_LOCATION"]},
        "namePrefix": {"value": os.environ["PARAM_NAME_PREFIX"]},
        "subscriptionId": {"value": os.environ["PARAM_SUBSCRIPTION_ID"]},
        "arcResourceGroup": {"value": os.environ["PARAM_ARC_RESOURCE_GROUP"]},
        "arcLocation": {"value": os.environ["PARAM_ARC_LOCATION"]},
        "nestedWindowsPassword": {"value": os.environ["PARAM_NESTED_WINDOWS_PASSWORD"]},
        "runId": {"value": os.environ["PARAM_RUN_ID"]},
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(document, stream)
PY

  az deployment group create \
    --name arc-jumpstart-arc-launchers \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$repo_root/infra/stages/arc-launchers/main.bicep" \
    --parameters "@$parameter_file" \
    --output table
}

deploy_script_stage() {
  local stage="$1"
  local completion_mode="${2:-wait}"
  local stage_directory
  local script_file
  stage_directory="$(stage_directory "$stage")"
  script_file="$(stage_script "$stage")"
  local host_subnet_id run_id previous_run_status previous_run_start_time
  local set_standard_security_type

  host_subnet_id="$(read_foundation_output hostSubnetId)"
  set_standard_security_type=true
  if [[ "$stage" == "10" ]] && az vm show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "${NAME_PREFIX}-host" \
    --output none 2>/dev/null; then
    set_standard_security_type=false
  fi
  run_id="$(date -u +%Y%m%d%H%M%S)"
  previous_run_start_time=''
  if [[ "$stage" == "30" || "$stage" == "45" ]]; then
    previous_run_status="$(run_command_status "$(stage_command "$stage")")"
    previous_run_start_time="${previous_run_status##*|}"
  fi

  local parameter_file
  umask 077
  parameter_file="$(mktemp "${TMPDIR:-/tmp}/arc-jumpstart-parameters.XXXXXX")"
  temporary_files+=("$parameter_file")
  write_stage_parameters "$stage" "$parameter_file"

  echo "==> Stage $stage: $stage_directory"
  az deployment group create \
    --name "arc-jumpstart-$stage_directory" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$repo_root/infra/stages/$stage_directory/main.bicep" \
    --parameters "@$parameter_file" \
    --output table

  echo "Host transcript: C:\\ArcJumpstart\\Logs\\${script_file%.ps1}-${run_id}.log"

  if [[ "$stage" == "10" ]]; then
    echo "Restarting the Hyper-V host to activate the installed roles..."
    az vm restart \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --name "${NAME_PREFIX}-host" \
      --output none
    wait_for_vm_agent "${NAME_PREFIX}-host"
  elif [[ "$stage" == "30" || "$stage" == "45" ]]; then
    if [[ "$stage" == "30" && "$completion_mode" == defer ]]; then
      image_previous_run_start_time="$previous_run_start_time"
      images_submitted=true
      echo "Image downloads are running independently; configuring the nested network while they continue."
    else
      echo "Waiting for the stage $stage Run Command to complete..."
      wait_for_run_command "$(stage_command "$stage")" "$previous_run_start_time"
    fi
  fi
}

bastion_notice=''
if [[ "$requested_stage" == bastion ]]; then
  require_foundation_core
  deploy_bastion
  echo "Bastion request accepted. Azure will continue provisioning it; no monitoring or wait is required by the build."
  exit 0
fi

if [[ "$requested_stage" == auto-shutdown ]]; then
  deploy_auto_shutdown
  exit 0
fi

if [[ "$requested_stage" == arc-launchers ]]; then
  deploy_arc_launchers
  exit 0
fi

for stage in "${stages[@]}"; do
  if [[ "$stage" == "00" ]]; then
    deploy_foundation
    if [[ "${DEPLOY_BASTION:-true}" == true ]]; then
      if deploy_bastion; then
        bastion_notice="Bastion submitted to Azure independently. The build does not monitor or wait for it."
      else
        bastion_notice="WARNING: Optional Bastion submission failed; the lab build continues without it. Inspect the Azure error above and retry separately: ./scripts/deploy.sh bastion"
        echo "$bastion_notice" >&2
      fi
    fi
  elif [[ "$stage" == "20" && ("$requested_stage" == all || "$requested_stage" == 20-30) ]]; then
    require_predecessors 30
    deploy_script_stage 30 defer
    require_predecessors 20
    deploy_script_stage 20
  elif [[ "$stage" == "30" && "$images_submitted" == true ]]; then
    echo "Joining the image download started alongside stage 20..."
    wait_for_run_command stage30-images "$image_previous_run_start_time"
    images_submitted=false
  else
    require_predecessors "$stage"
    deploy_script_stage "$stage"
    if [[ "$stage" == "10" && "$requested_stage" == all ]]; then
      deploy_auto_shutdown
    fi
  fi
done

if [[ -n "$bastion_notice" ]]; then
  echo "$bastion_notice"
fi

if [[ "$requested_stage" == all && "${PREPARE_ARC_LAUNCHERS:-true}" == true ]]; then
  deploy_arc_launchers
fi
