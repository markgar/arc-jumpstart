# Infrastructure implementation

Infrastructure is automated preparation for the Arc exercises. Start with
[AGENTS.md](../AGENTS.md) and the [agent bootstrap runbook](../docs/00-agent-bootstrap.md).
Use cross-platform `scripts/deploy.ps1` (PowerShell 7 and Azure CLI) rather
than assembling ad hoc Bicep parameter files.

## Stage map

All stage entry points are resource-group-scoped Bicep templates. The wrapper
selects the configured subscription and creates/retains the dedicated resource
group before deploying them.

| Stage entry point | Host artifact / responsibility |
|---|---|
| [00-foundation](stages/00-foundation/main.bicep) | VNet, host/endpoint subnets, NSG and reserved `AzureBastionSubnet`; private SQL media account in a separate retained group, private endpoint/DNS and operator upload RBAC. No Bastion host or public IP. |
| [bastion](stages/bastion/main.bicep) | Independent Basic Bastion and Standard public IP against the existing access subnet. Enabled by default, submitted without waiting after `00`; not a numbered-stage dependency. |
| [auto-shutdown](stages/auto-shutdown/main.bicep) | Independent enabled/disabled daily shutdown schedule for the existing outer host. The operator must explicitly choose the policy, time and time zone; it is applied after stage `10`. |
| [arc-launchers](stages/arc-launchers/main.bicep) | Post-build helper, enabled by default in `all`, that securely stages interactive device-code launchers on the six Windows workload guest desktops, excluding the reserved appliance VM. It creates no Arc connection and can be omitted with `PREPARE_ARC_LAUNCHERS=false`. |
| [ssms](stages/ssms/main.bicep) | Independent host-only SSMS 22 bootstrapper staging and installation, enabled after the core stages by default; opt out with `INSTALL_HOST_SSMS=false` or retry only `deploy.ps1 ssms`. No guest readiness dependency or automatic host reboot. |
| [10-hyperv-host](stages/10-hyperv-host/main.bicep) | Azure VM, NIC and persistent data disk; [`10-init-host.ps1`](../artifacts/scripts/10-init-host.ps1) prepares the host. |
| [sql-media](stages/sql-media/main.bicep) | Stages the licensed ISO upload launcher on the host or checks the private manifest using managed identity. Developer mode never pauses here. |
| [20-host-network](stages/20-host-network/main.bicep) | [`20-host-network.ps1`](../artifacts/scripts/20-host-network.ps1): nested switch, NAT and DHCP. |
| [30-images](stages/30-images/main.bicep) | [`30-download-images.ps1`](../artifacts/scripts/30-download-images.ps1): ISO downloads and local Windows/Ubuntu installer disk preparation by default, or legacy prebuilt image downloads. |
| [40-nested-vms](stages/40-nested-vms/main.bicep) | [`40-create-nested-vms.ps1`](../artifacts/scripts/40-create-nested-vms.ps1): generalized Windows parent, guests, completed/activated setup, names and SIDs. |
| [45-sql-install](stages/45-sql-install/main.bicep) | [`45-install-sql.ps1`](../artifacts/scripts/45-install-sql.ps1) orchestrates [`45-install-sql-engine.ps1`](../artifacts/scripts/45-install-sql-engine.ps1) across five guests: four Database Engines and two SSAS instances, colocated on `JS-RETAIL-01`; `JS-INSIGHT-01` has SSAS only. |
| [50-domain](stages/50-domain/main.bicep) | [`50-configure-domain.ps1`](../artifacts/scripts/50-configure-domain.ps1): AD/DNS, membership, identities and SQL access. |
| [60-sql-ag](stages/60-sql-ag/main.bicep) | [`60-configure-sql-ag.ps1`](../artifacts/scripts/60-configure-sql-ag.ps1): cluster, witness, SQL/HADR, sample databases and listener. |

Read the [deployment guide](../docs/02-deploy.md) for the full sequence and
[AG lessons](../docs/02-sql-ag-lessons.md) for the reasons behind its safeguards.

## Execution model

[`modules/hostRunCommand.bicep`](modules/hostRunCommand.bicep) targets the existing
host VM with a Managed Run Command. PowerShell is embedded with `loadTextContent`;
stage `45` also embeds its engine installer. A public script-storage account is
not required. Downloaded OS images and SQL/module packages remain separate,
documented external dependencies.

The default `installation-media` image mode embeds
[`image-media.ps1`](../artifacts/scripts/image-media.ps1) into stages `30` and `40`.
Stage `30` verifies direct ISO downloads and prepares the local Windows
Evaluation disk and Ubuntu unattended installer. After the existing `20`/`30`
join, stage `40` overlaps Ubuntu installation with Windows template preparation,
then verifies installed Ubuntu before creating the final guests. The Windows
template must complete native setup before Sysprep. Evaluation guests retain
their evaluation edition and require verified activation and remaining time,
not the default KMS client key. The source disks, receipts and host SSH key
stay under the restricted `F:\ArcJumpstart\Images\InstallationMedia` directory.
The image builder itself does not use Blob storage; the foundation's separate
private account is for optional licensed SQL media. See
[configuration and recovery](../scripts/README.md#installation-media-images);
this path needs a fresh Azure acceptance run.

New templates set `WINDOWS_SERVER_VERSION=2025`: stage `10` uses the ordinary
`MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest`
Marketplace host image, while stages `30`/`40` build Server 2025 Evaluation
guests from ISO. The host image is non-Hotpatch to preserve manual patching
and controlled restarts. No custom host image is required. Build and receipt checks
keep Server 2022 and 2025 media/parents separate; existing environments without
the version key retain Server 2022. KMS provisioning remains a legacy
Server 2022 Jumpstart path, never an Evaluation conversion.

`INCLUDE_APPLIANCE_VM=true` in new templates adds an unused `JS-MIGRATE-01`
workgroup guest with 8 vCPUs, 16 GiB RAM and an 80-GiB Windows disk on the
internal switch/DHCP network. It passes the same Windows readiness gates but
is excluded from domain joins, SQL installation and Arc launchers.
Appliance software and project registration are not provisioned. Missing
flags in existing files mean no appliance guest; do not replay stage `40`
against a promoted domain to expand it.

Each wrapper invocation supplies a new `RunId`. Sensitive parameters use Bicep
secure parameters and Run Command protected parameters. Script failures are
configured to fail the deployment. Stages `30` and `45` use asynchronous
execution, so the wrapper additionally waits for a fresh terminal script result.

Do not confuse an Azure resource write with guest readiness. Windows setup,
domain discovery, SQL queries, native cluster validation, operation receipts and
listener access supply the corresponding gates.

In `all`, stage `30` is submitted after the host restart/agent gate, then stage
`20` configures only the internal switch/NAT/DHCP while image downloads continue
on the outer host. These use distinct
[Managed Run Commands](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command-managed),
which support parallel scripts. The wrapper joins the new image execution and
checks both predecessors before `40`. It does not use concurrent Action Run
Commands or a local detached process. Stage `40` starts all clones before
waiting for individual Windows setup and overlaps their rename reboots.

Bastion is not one of those gates. The wrapper uses Azure deployment
`arc-jumpstart-bastion` with `--no-wait`, not a local background shell or a
deployment nested inside stage `00`. Azure continues provisioning it after the
submission command returns. Its template references the VNet/subnet as
`existing` resources and does not rewrite the shared VNet while the host is
being created. Submission/provisioning failures are an independently reported
access problem, never a prerequisite for stages `10`-`60`.

## Persistence and topology

- Azure network: `10.20.0.0/16`, with the host on `snet-host` by default.
- Nested network: `192.168.128.0/24` behind the host's internal Hyper-V switch/NAT.
- Persistent host data: `F:\ArcJumpstart`; do not substitute Azure temporary disk
  storage for images or guest disks.
- Licensed SQL media: `<root>-media` (or explicitly configured group), retained
  separately from infrastructure cleanup. Its endpoint/DNS link is disposable
  with the lab network; account public/shared-key access remains disabled.
- Approved existing media: set both `SQL_MEDIA_RESOURCE_GROUP` and
  `SQL_MEDIA_ACCOUNT_NAME` to reference the existing account/container without
  redeploying its policies or uploader roles. Each lab gets its own private
  endpoint/DNS and host Reader assignment. `all` checks the saved media after
  stage `10` and continues without a redundant upload pause.
- Windows guests use differencing disks backed by a locally generalized parent.
  Never rewrite a parent that has dependent disks.
- Host transcripts are under `C:\ArcJumpstart\Logs`; treat raw logs as sensitive.
- The Azure host uses explicit Standard security, and nested guests use
  Generation 2 with Secure Boot disabled for the selected migration path.

Both AG nodes live on one outer host. The lab demonstrates the configuration
and workflow, not production physical fault isolation.

## Changing infrastructure safely

Keep the Bicep stage, PowerShell artifact, wrapper parameter mapping, tests and
documentation consistent. Add or adjust the relevant regression coverage and
Run the cross-platform PowerShell path:

```powershell
./scripts/validate.ps1
```

Then exercise the affected deployment path in an approved lab. Do not infer a
successful fresh deployment from compilation or mocks alone.

The current saved domain and AG implementations produced the successful
development lab. A fresh Windows parent/clone proof also passed. The complete
clean-pipeline replay remains outstanding; see the bootstrap runbook's
[acceptance gate](../docs/00-agent-bootstrap.md#acceptance-of-the-automation-itself).

Arc resources, assessment collectors and migration execution are outside these
bootstrap stages. Their learner-facing instructions live in `docs/03` through
`docs/05`, not in an additional hidden deployment script.
