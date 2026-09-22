# Prerequisites

## Azure access

You need:

- An Azure subscription where you can create resource groups, networking, optional Bastion, Premium SSDs, and a nested-virtualization-capable VM.
- Permission to register resource providers.
- The subscription feature `Microsoft.Compute/UseStandardSecurityType`, required to deploy the nested-virtualization host without Trusted Launch.
- A tenant account that can create an Azure Migrate project and assign its managed identity the preview discovery role.
- Permission to create Azure SQL Managed Instance and its delegated subnet for
  the final workshop activity.
- Azure CLI with the Bicep CLI installed.
- The Azure CLI Resource Graph extension for the modeling export.

Check the tools:

```bash
az version
az bicep version
az extension add --name resource-graph
```

Register the providers used across the infrastructure and labs:

```bash
for provider in \
  Microsoft.Compute \
  Microsoft.Network \
  Microsoft.Storage \
  Microsoft.Authorization \
  Microsoft.ManagedIdentity \
  Microsoft.HybridCompute \
  Microsoft.GuestConfiguration \
  Microsoft.HybridConnectivity \
  Microsoft.AzureArcData \
  Microsoft.OffAzure \
  Microsoft.Migrate \
  Microsoft.Sql \
  Microsoft.KeyVault \
  Microsoft.Insights
do
  az provider register --namespace "$provider" --wait
done
```

## Capacity and quota

The suggested host is Windows Server 2022 on `Standard_E16s_v7` with 16 vCPUs
and 128 GiB RAM in `westus2`. These are overridable starting points that avoid
known subscription restrictions encountered with the earlier East US 2 /
E16s_v5 combination; availability, quota, capacity, and pricing still vary by
subscription and time. Confirm that:

1. The size is available in your chosen region.
2. Your regional vCPU quota can accommodate it.
3. The selected size exposes nested virtualization.

The prerequisite lab creates a 1 TiB Premium SSD, optional Azure Bastion, a
public IP for Bastion, and normal networking resources. The migration activity
also creates a temporary SQL managed instance and storage account after a
separate cost decision. Stop or deallocate the host when not in use.
Deallocation stops host compute billing but not disk, Bastion, public IP,
storage, or SQL Managed Instance charges.

The lab supports an optional daily Azure auto-shutdown schedule for the outer
host. Always ask the operator whether to enable it and for the intended local
time and time zone. Do not enable it silently: shutdown can interrupt active
assessment, inventory collection, backup, or migration work.

## Credentials

Copy `deploy.env.example` to an owner-only file outside the repository and set
`ENV_FILE` to its absolute path. On macOS, Linux, or WSL2,
`$HOME/.config/arc-jumpstart/lab.env` is a convenient location. Use unique
passwords for:

- The outer Hyper-V host.
- Directory Services Restore Mode.
- The SQL Server domain service account.

The Microsoft Jumpstart VHDX images currently use `Administrator` / `JS123!!` for Windows and `jumpstart` / `JS123!!` for Ubuntu. Put the Windows password in `NESTED_WINDOWS_PASSWORD`. These are lab credentials in externally maintained images; do not expose this environment to untrusted networks or reuse the passwords elsewhere.

The environment file is parsed as data rather than executed as a shell script.
Enter literal `KEY=value` lines without `export` or surrounding quotes;
characters such as `$`, backticks, spaces, and `!` remain part of the value.

The deployment wrapper intentionally requires an interactive Azure user identity. Service-principal execution is outside the scope of this guided lab.

## Windows setup and activation

The nested Windows image must be Windows Server 2022 Standard or Datacenter
(build `20348`), without SQL already installed. Stage `40` selects the
edition-matching, Microsoft-published KMS client setup key for the answer file;
it rejects other builds and editions instead of guessing a key. After first
boot, each guest must reach the Azure public-cloud KMS endpoint
`azkms.core.windows.net` on TCP `1688` and report an activated Windows license
before the stage continues.

These public setup keys are not purchased licenses and do not grant usage
rights. Confirm the Windows licensing terms applicable to your subscription,
images and nested guests. SQL Developer licensing is separate. This activation
configuration targets Azure public cloud, not an arbitrary on-premises host or
sovereign-cloud endpoint.

Do not substitute an AVMA key merely because the outer VM is an activated
Datacenter Hyper-V host. In the live Azure lab, AVMA accepted the setup key but
activation failed with `0xC004FD02`; the documented Azure KMS path activated the
same disposable guest successfully. See Microsoft's
[Azure AVMA error guidance](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-vm-activation-error-0xc004fd01-0xc004fd02)
and [KMS client keys](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys).

## SQL installation media and licensing

Stage `45` installs SQL Server 2025 Enterprise Developer on clean Windows guests; it does not clone a preconfigured SQL installation. Set `SQL_DOWNLOAD_URL` to the Microsoft media source URL in `deploy.env.example`. The host downloads the SQL media and Microsoft prerequisites; allow HTTPS access to `go.microsoft.com`, `aka.ms`, and their Microsoft download redirect destinations. Installers are not redistributed by this repository. Running the stage accepts the installer EULAs. Developer edition is licensed for non-production development, testing, and training only.

## Workstation

The full workflow requires a consistent Linux-style execution environment:

- macOS
- Linux
- WSL2 on Windows

The deployment, preflight and lab-management wrappers are Bash programs that
use POSIX process, path, permission and signal semantics. Native Windows,
Git Bash, MSYS2 and Cygwin are not supported deployment runtimes. The wrappers
reject those environments before reading configuration or changing Azure.
Do not mix Windows Azure CLI or Windows Python with Bash running in WSL.

Install these tools in the same supported environment:

- Azure CLI (`az`) and its Bicep component
- Python 3 (`python3`)
- Git and normal POSIX command-line tools
- ShellCheck for complete Bash validation
- PowerShell 7 (`pwsh`) for the optional PowerShell parser and regression tests

No repository package install is required. Verify the effective tools, not
similarly named Windows executables inherited onto `PATH`:

```bash
uname -s
command -v az python3 git
az version
az bicep version
python3 --version
git --version
command -v shellcheck || echo "ShellCheck validation will be skipped."
command -v pwsh || echo "PowerShell validation will be skipped."
```

### Windows: required WSL2 setup

For Windows 10, Microsoft requires version 2004/build 19041 or later for the
current one-command WSL installation; Windows 11 is also supported. The
workstation must permit hardware virtualization and the Windows optional
features used by WSL2. On a managed work laptop, obtain organizational approval
before enabling those features.

From an **Administrator PowerShell** window:

```powershell
wsl --install
```

This enables WSL and Virtual Machine Platform, installs Ubuntu by default and
may report that a restart is required. Restart Windows before continuing. Then
open Ubuntu once, create its Linux user, and confirm from PowerShell that the
distribution is using WSL version 2:

```powershell
wsl --list --verbose
```

If WSL is already installed but Ubuntu is not, use `wsl --list --online` and
`wsl --install -d Ubuntu`. Follow Microsoft's
[WSL installation guide](https://learn.microsoft.com/windows/wsl/install) for
older Windows builds, Store restrictions or installation errors.

Inside Ubuntu, install the Linux tools. Use your organization's approved
package sources and Microsoft's current
[Azure CLI Linux instructions](https://learn.microsoft.com/cli/azure/install-azure-cli-linux)
and
[PowerShell on Ubuntu instructions](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu):

```bash
sudo apt update
sudo apt install -y ca-certificates curl git python3 shellcheck
# Install Linux Azure CLI. Install Linux PowerShell 7 for complete validation.
az version
az bicep install
```

Clone the repository into the WSL filesystem, such as
`~/src/arc-jumpstart`, rather than `/mnt/c/...`. Microsoft recommends storing
project files on the same operating system as the tools that operate on them;
this also preserves Linux permissions and avoids cross-filesystem path and
performance problems.

Keep the environment file in the WSL home directory, not in the Windows
checkout or repository:

```bash
mkdir -p "$HOME/.config/arc-jumpstart"
install -m 600 deploy.env.example "$HOME/.config/arc-jumpstart/lab.env"
export ENV_FILE="$HOME/.config/arc-jumpstart/lab.env"
```

Edit the file inside WSL and retain mode `600`. A Windows `chmod` result on
NTFS is not an equivalent owner-only ACL guarantee.

### Windows without WSL2

Without WSL2, this repository does not support provisioning or operating the
lab from that workstation. Do not run `preflight.sh`, `deploy.sh` or `lab.sh`
from Git Bash and do not translate the commands ad hoc into PowerShell.

For source-only contribution checks, Git Bash with native Windows Azure CLI and
Python 3 may run:

```bash
./scripts/validate.sh
```

That mode compiles Bicep and runs the platform-applicable Bash/Python tests,
plus ShellCheck and PowerShell checks when those commands are available.
Deployment-wrapper integration tests are skipped because that runtime is
intentionally unsupported. This does not prove the deployment runtime. If
organizational policy prevents WSL2, use an approved Linux/macOS workstation
or Linux development VM for preflight, deployment and lab management. Keep the
environment file on that execution host with owner-only permissions.

After configuring the private `ENV_FILE`, run:

```bash
./scripts/validate.sh
ENV_FILE=/absolute/private/path/lab.env ./scripts/preflight.sh infra
```

The first command performs source validation. The second checks the
authenticated subscription, provider registration, regional VM SKU
restrictions, and source-image reachability. Regional quota is
subscription-specific; confirm the relevant VM-family and regional vCPU quota
for `HOST_VM_SIZE` before deploying.

Then start the complete infrastructure build:

```bash
ENV_FILE=/absolute/private/path/lab.env ./scripts/deploy.sh all
```

Keep that process running in its terminal. From another terminal, use
`./scripts/lab.sh build-status` for a one-shot progress report. Do not start a
second deployment when the first terminal is quiet.
