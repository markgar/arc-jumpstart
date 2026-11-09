# Prerequisites

## Azure access

You need:

- An Azure subscription where you can create resource groups, networking, optional Bastion, Premium SSDs, and a nested-virtualization-capable VM.
- Permission to register resource providers.
- Permission to create container-scoped role assignments for the host managed
  identity and signed-in upload user, in addition to infrastructure Contributor
  access. Contributor alone cannot create these role assignments.
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
    'Microsoft.OffAzure', 'Microsoft.Migrate', 'Microsoft.Sql', 'Microsoft.DataMigration',
    'Microsoft.KeyVault', 'Microsoft.Insights'
)
foreach ($provider in $providers) {
    az provider register --namespace $provider --wait
    if ($LASTEXITCODE -ne 0) { throw "Provider registration failed: $provider" }
}
```

`deploy.ps1 all` and `deploy.ps1 00` automatically register
`Microsoft.DataMigration` in the configured subscription with `--wait`.
This prepares for optional Azure Database Migration Service exercises without
creating a migration service or starting a migration. `preflight.ps1 full`
includes this provider in its existing registration checks.

## Capacity and quota

The suggested host is Windows Server 2025 Datacenter Gen2 on `Standard_E16s_v7` with 16 vCPUs
and 128 GiB RAM in `westus2`. These are overridable starting points that avoid
known subscription restrictions encountered with the earlier East US 2 /
E16s_v5 combination; availability, quota, capacity, and pricing still vary by
subscription and time. Confirm that:

1. The size is available in your chosen region.
2. Your regional vCPU quota can accommodate it.
3. The selected size exposes nested virtualization.

The host uses the standard Marketplace image
`MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest`,
not a custom image. Nested Windows guests are built separately from Evaluation
ISO media. The ordinary non-Hotpatch image supports manual patching; Hotpatch
images require platform-managed patching and are not the host default.

Stage `40` assigns 6 virtual processors each to `JS-SQL-01`,
`JS-SQL-AG-01` and `JS-SQL-AG-02`, 4 each to `JS-RETAIL-01` and
`JS-INSIGHT-01`, and 2 each to the DC and Ubuntu guests.
The default reserved appliance VM `JS-MIGRATE-01` adds 8 vCPUs and 16 GiB RAM.
That is 38 assigned guest virtual processors and 60 GiB startup RAM on the
default 16-vCPU / 128-GiB host: intentional CPU overcommit, not 38 dedicated host cores. Concurrent SQL/SSAS work
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
The foundation also creates a private SQL media account, Private Endpoint and
private DNS resources. Endpoint and DNS charges apply even with no uploaded
media; storage capacity charges apply after upload. The separate media group
is retained when the disposable infrastructure group is deleted.

The lab supports an optional daily Azure auto-shutdown schedule for the outer
host. Always ask the operator whether to enable it and for the intended local
time and time zone. Do not enable it silently: shutdown can interrupt active
assessment, inventory collection, backup, or migration work.

## Credentials

Create an owner-only copy of `deploy.env.example` with `init-config.ps1` outside
the repository and set `ENV_FILE` to its absolute path. On Windows, macOS,
Linux, or WSL2,
use the visible `$HOME/ArcJumpstart/<root>.env` location for new labs, not a hidden
folder. Use unique
passwords for:

- The outer Hyper-V host.
- Directory Services Restore Mode.
- The SQL Server domain service account.

All new nested Windows guests use `Administrator` / `JS123!!`
(`NESTED_WINDOWS_PASSWORD=JS123!!`). This is a public lab-only credential;
do not expose the guests to untrusted networks or reuse it for the host, DSRM,
SQL service, or other environments. Existing lab recovery keeps its saved
credentials and does not reset them.

With the default `IMAGE_MODE=installation-media`, Windows setup assigns that
fixed password. Supply `LINUX_SSH_PUBLIC_KEY` for the optional Ubuntu `jumpstart` account;
password login is disabled. Never supply or upload your SSH private key.
Legacy Jumpstart VHDX images use `Administrator` / `JS123!!` for Windows
and `jumpstart` / `JS123!!` for Ubuntu.

The environment file is parsed as data rather than executed as a shell script.
Enter literal `KEY=value` lines without `export` or surrounding quotes;
characters such as `$`, backticks, spaces, and `!` remain part of the value.

The deployment wrapper intentionally requires an interactive Azure user identity. Service-principal execution is outside the scope of this guided lab.

## Windows setup and activation

The default `installation-media` mode requires the English x64 Windows
Server 2025 Evaluation ISO. The default official source uses host-side Microsoft
HTTPS and Setup-signature verification (`WINDOWS_ISO_SHA256=auto`), then records
and rechecks the SHA-256 in its protected cache. A custom ISO source still needs
an approved checksum; `auto` is not a general checksum bypass. Register and
review the terms at the
[Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025).
The builder selects Datacenter Evaluation with Desktop Experience (26100),
omits product keys, and verifies activated `TIMEBASED_EVAL` licensing with
positive remaining time on every Windows guest. Evaluation lasts 180 days;
internet activation is required within the first 10 days. Expiration is not
silently repaired, rearmed, or converted to KMS/retail licensing.

The following KMS contract applies only to legacy `IMAGE_MODE=jumpstart`
with `WINDOWS_SERVER_VERSION=2022`. The prebuilt nested Windows image must be Windows Server 2022 Standard or Datacenter
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

Alternatively, choose `SQL_EDITION_MODE=licensed` and supply authorized,
pre-keyed SQL Server 2025 Standard and Enterprise ISOs. There is no Standard
Evaluation substitute: the automation rejects Developer/Evaluation when a
commercial edition is assigned. Possessing media or an embedded key does not
establish license rights; approve the applicable terms and entitlements.
The private upload helper runs on the host after stage `10`, using the operator's
Azure identity, not a storage key or SAS. The workstation has no implicit
private connectivity. See the
[licensed-media workflow and current ingress limitation](../scripts/README.md#licensed-sql-media).

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
$env:ENV_FILE = $null # Clear a previous lab's override before creating a new file.
./scripts/init-config.ps1 -ResourceGroupRoot rg-arc-jumpstart-v2
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/rg-arc-jumpstart-v2.env'
```

Replace the example root with the approved name; initialization uses
`<root>.env`, `AZURE_RESOURCE_GROUP=<root>-infra`, and
`ARC_RESOURCE_GROUP=<root>-arc`.
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
