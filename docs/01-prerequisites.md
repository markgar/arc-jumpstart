# Prerequisites

## Azure access

You need:

- An Azure subscription where you can create resource groups, networking, optional Bastion, Premium SSDs, and a nested-virtualization-capable VM.
- Permission to register resource providers.
- The subscription feature `Microsoft.Compute/UseStandardSecurityType`, required to deploy the nested-virtualization host without Trusted Launch.
- A tenant account that can create an Azure Migrate project and assign its managed identity the preview discovery role.
- Azure CLI with the Bicep CLI installed.

Check the tools:

```bash
az version
az bicep version
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
  Microsoft.RecoveryServices \
  Microsoft.DataReplication \
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
subscription and time. Windows Server 2022 is used because it is currently
listed in the Azure Migrate Hyper-V replication support matrix. Confirm that:

1. The size is available in your chosen region.
2. Your regional vCPU quota can accommodate it.
3. The selected size exposes nested virtualization.

The lab also creates a 1 TiB Premium SSD, optional Azure Bastion, a public IP for Bastion, and normal networking resources. Stop or deallocate the host when not in use. Deallocation stops compute billing but not disk, Bastion, or public IP charges.

The lab supports an optional daily Azure auto-shutdown schedule for the outer
host. Always ask the operator whether to enable it and for the intended local
time and time zone. Do not enable it silently: shutdown can interrupt active
assessment, replication, test migration or cutover work.

## Credentials

Copy `deploy.env.example` to an owner-only file outside the repository and set
`ENV_FILE` to its absolute path. On macOS,
`$HOME/.config/arc-jumpstart/lab.env` is a convenient example, not a required
destination. Use unique passwords for:

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

The wrapper supports Bash on macOS, Linux, or WSL and requires:

- `az`
- `python3`
- normal POSIX command-line tools

No repository dependencies are installed globally.

After configuring `deploy.env`, run:

```bash
./scripts/validate.sh
ENV_FILE=/absolute/private/path/lab.env ./scripts/preflight.sh infra
```

The first command performs source validation. The second checks the authenticated subscription, provider registration, regional VM SKU restrictions, and source-image reachability. Regional quota is subscription-specific; confirm the available **Standard ESv5 Family vCPUs** in Azure Quotas before deploying.

Then start the complete infrastructure build:

```bash
ENV_FILE=/absolute/private/path/lab.env ./scripts/deploy.sh all
```

Keep that process running in its terminal. From another terminal, use
`./scripts/lab.sh build-status` for a one-shot progress report. Do not start a
second deployment when the first terminal is quiet.
