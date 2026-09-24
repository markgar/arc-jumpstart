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

```powershell
az version
az bicep version
az extension add --name resource-graph
```

Register the providers used across the infrastructure and labs:

```powershell
$providers = @(
    'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage',
    'Microsoft.Authorization', 'Microsoft.ManagedIdentity', 'Microsoft.DevTestLab',
    'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration',
    'Microsoft.HybridConnectivity', 'Microsoft.AzureArcData',
    'Microsoft.OffAzure', 'Microsoft.Migrate', 'Microsoft.Sql',
    'Microsoft.KeyVault', 'Microsoft.Insights'
)
foreach ($provider in $providers) {
    az provider register --namespace $provider --wait
    if ($LASTEXITCODE -ne 0) { throw "Provider registration failed: $provider" }
}
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

Stage `40` assigns 6 virtual processors to `JS-SQL-01`, 8 each to
`JS-SQL-AG-01` and `JS-SQL-AG-02`, and 2 each to the DC and Ubuntu guests.
That is 26 assigned guest virtual processors on the default 16-vCPU host:
intentional CPU overcommit, not 26 dedicated host cores. Concurrent SQL work
can contend for CPU and take longer; choose a larger nested-virtualization-capable
host if this contention is unacceptable, with corresponding quota and cost.
This topology applies to new builds; stage `40` does not resize existing guests
on a retry.

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

Create an owner-only copy of `deploy.env.example` with `init-config.ps1` outside
the repository and set `ENV_FILE` to its absolute path. On Windows, macOS,
Linux, or WSL2,
use the visible `$HOME/ArcJumpstart/lab.env` location for new labs, not a hidden
folder. Use unique
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

Use **PowerShell 7 and Azure CLI** on Windows, macOS or Linux. Install Azure
CLI's Bicep component with `az bicep install`; `az graph query` for the later
modeling exercise also needs `az extension add --name resource-graph`. The new
PowerShell entry points do not require WSL2 or an Az PowerShell module.

Open PowerShell 7 in this repository's checkout and verify:

```powershell
$PSVersionTable.PSVersion
az version
az bicep version
```

See Microsoft's [PowerShell 7 installation instructions](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
and [Azure CLI installation instructions](https://learn.microsoft.com/cli/azure/install-azure-cli)
for the chosen OS. The agent uses the interactive Azure CLI **user** identity,
not a service principal. Run the PowerShell entry points and Azure CLI in the
same operating system; do not mix Windows executables with WSL paths.

Create the private configuration template outside the repository:

```powershell
./scripts/init-config.ps1
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
```

`init-config.ps1` restricts the visible folder and file to the current owner
(Windows ACL or Unix modes `700`/`600`) and never overwrites a file. Edit it
privately; replace `CHANGEME` values without sending passwords to the agent in
chat. Use the exact existing file path instead when recovering an existing lab.
See [configuration location and access](../README.md#find-your-lab-configuration-and-passwords).

After authentication and approval for the Azure target, cost and licensing
scope, run these commands in order; stop if any fails:

```powershell
az login
./scripts/validate.ps1
./scripts/preflight.ps1 infra
./scripts/deploy.ps1 all
```

Preflight checks the authenticated target, registrations, regional SKU
restrictions and source reachability. It does not verify subscription-specific
VM-family and regional vCPU quota; confirm both before deployment. Keep
deployment in its own terminal. From another PowerShell 7 terminal with the
same `ENV_FILE`, use `./scripts/lab.ps1 build-status` for one-shot progress; do
not start another build because the first is quiet. Follow the bootstrap
runbook's scoped recovery rules instead of replaying `all` against a
promoted domain.
