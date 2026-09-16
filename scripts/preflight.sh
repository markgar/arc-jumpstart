#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$repo_root/deploy.env}"
profile="${1:-infra}"

case "$profile" in
  infra|full) ;;
  *)
    echo "Usage: scripts/preflight.sh [infra|full]" >&2
    exit 1
    ;;
esac

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file. Copy deploy.env.example to deploy.env first." >&2
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
    [[ "$line" == *=* ]] || {
      echo "Invalid line in $env_file: expected KEY=value." >&2
      exit 1
    }
    key="${line%%=*}"
    value="${line#*=}"
    printf -v "$key" '%s' "$value"
  done < "$env_file"
}

load_env_file

for variable_name in AZURE_SUBSCRIPTION_ID AZURE_LOCATION HOST_VM_SIZE IMAGE_SOURCE_URL SQL_DOWNLOAD_URL; do
  if [[ -z "${!variable_name:-}" || "${!variable_name}" == "CHANGEME" ]]; then
    echo "$variable_name must be set in $env_file." >&2
    exit 1
  fi
done

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
if [[ "$(az account show --query user.type --output tsv)" != "user" ]]; then
  echo "Sign in to Azure CLI as an interactive user." >&2
  exit 1
fi

required_providers=(
  Microsoft.Compute
  Microsoft.Network
  Microsoft.Storage
  Microsoft.Authorization
  Microsoft.ManagedIdentity
)

if [[ "$profile" == "full" ]]; then
  required_providers+=(
    Microsoft.HybridCompute
    Microsoft.GuestConfiguration
    Microsoft.HybridConnectivity
    Microsoft.AzureArcData
    Microsoft.OffAzure
    Microsoft.Migrate
    Microsoft.RecoveryServices
    Microsoft.DataReplication
    Microsoft.KeyVault
    Microsoft.Insights
  )
fi

failed=false
for provider in "${required_providers[@]}"; do
  state="$(az provider show --namespace "$provider" --query registrationState --output tsv 2>/dev/null || true)"
  if [[ "$state" == "Registering" ]]; then
    echo "Provider registration is propagating: $provider"
  elif [[ "$state" != "Registered" ]]; then
    echo "Provider not registered: $provider ($state)"
    failed=true
  fi
done

standard_security_feature="$(az feature show \
  --namespace Microsoft.Compute \
  --name UseStandardSecurityType \
  --query properties.state \
  --output tsv 2>/dev/null || true)"
if [[ "$standard_security_feature" == "Registering" ]]; then
  echo "Feature registration is propagating: Microsoft.Compute/UseStandardSecurityType"
elif [[ "$standard_security_feature" != "Registered" ]]; then
  echo "Feature not registered: Microsoft.Compute/UseStandardSecurityType ($standard_security_feature)" >&2
  failed=true
fi

sku_restrictions="$(az vm list-skus \
  --location "$AZURE_LOCATION" \
  --resource-type virtualMachines \
  --size "$HOST_VM_SIZE" \
  --query "[0].restrictions[?type == 'Location'].reasonCode" \
  --output tsv 2>/dev/null || true)"
if [[ -n "$sku_restrictions" ]]; then
  echo "$HOST_VM_SIZE is restricted in $AZURE_LOCATION: $sku_restrictions" >&2
  failed=true
elif [[ -z "$(az vm list-skus --location "$AZURE_LOCATION" --resource-type virtualMachines --size "$HOST_VM_SIZE" --query '[0].name' --output tsv)" ]]; then
  echo "$HOST_VM_SIZE is not available in $AZURE_LOCATION." >&2
  failed=true
fi

IMAGE_SOURCE_URL="$IMAGE_SOURCE_URL" \
SQL_DOWNLOAD_URL="$SQL_DOWNLOAD_URL" \
IMAGE_SOURCE_SAS_TOKEN="${IMAGE_SOURCE_SAS_TOKEN:-}" \
WINDOWS_IMAGE_FILE_NAME="${WINDOWS_IMAGE_FILE_NAME:-ArcBox-Win2K22.vhdx}" \
LINUX_IMAGE_FILE_NAME="${LINUX_IMAGE_FILE_NAME:-ArcBox-Ubuntu-01.vhdx}" \
python3 - <<'PY' || failed=true
import os
import sys
import urllib.error
import urllib.request

base = os.environ["IMAGE_SOURCE_URL"].rstrip("/")
token = os.environ["IMAGE_SOURCE_SAS_TOKEN"].lstrip("?")
downloads = []
for name in (
    os.environ["WINDOWS_IMAGE_FILE_NAME"],
    os.environ["LINUX_IMAGE_FILE_NAME"],
):
    url = f"{base}/{name}" + (f"?{token}" if token else "")
    downloads.append((name, url))
downloads.append(("SQL Server 2025 Enterprise Developer media source", os.environ["SQL_DOWNLOAD_URL"]))
for name, url in downloads:
    request = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            size = int(response.headers.get("Content-Length", "0"))
            print(f"Download reachable: {name} ({size / 1024**3:.1f} GiB)")
    except (urllib.error.URLError, TimeoutError) as error:
        print(f"Download unavailable: {name}: {error}", file=sys.stderr)
        sys.exit(1)
PY

echo
echo "Cost gate: this lab can run a $HOST_VM_SIZE VM, a 1-TiB Premium SSD,"
echo "Azure Bastion, migration replication storage/network, and test/migrated VMs."
echo "Review current prices and quota in $AZURE_LOCATION before deploying."

if [[ "$failed" == true ]]; then
  exit 1
fi

echo "Azure target preflight completed for the $profile profile."
