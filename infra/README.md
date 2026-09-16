# Infrastructure implementation

Infrastructure is automated preparation for the Arc exercises. Start with
[AGENTS.md](../AGENTS.md) and the [agent bootstrap runbook](../docs/00-agent-bootstrap.md).
Use `scripts/deploy.sh` rather than assembling ad hoc Bicep parameter files.

## Stage map

All stage entry points are resource-group-scoped Bicep templates. The wrapper
selects the configured subscription and creates/retains the dedicated resource
group before deploying them.

| Stage entry point | Host artifact / responsibility |
|---|---|
| [00-foundation](stages/00-foundation/main.bicep) | VNet, host subnet, NSG and reserved `AzureBastionSubnet` through `modules/network.bicep`. No Bastion host or public IP. |
| [bastion](stages/bastion/main.bicep) | Independent Basic Bastion and Standard public IP against the existing access subnet. Enabled by default, submitted without waiting after `00`; not a numbered-stage dependency. |
| [10-hyperv-host](stages/10-hyperv-host/main.bicep) | Azure VM, NIC and persistent data disk; [`10-init-host.ps1`](../artifacts/scripts/10-init-host.ps1) prepares the host. |
| [20-host-network](stages/20-host-network/main.bicep) | [`20-host-network.ps1`](../artifacts/scripts/20-host-network.ps1): nested switch, NAT and DHCP. |
| [30-images](stages/30-images/main.bicep) | [`30-download-images.ps1`](../artifacts/scripts/30-download-images.ps1): Windows/Linux image cache. |
| [40-nested-vms](stages/40-nested-vms/main.bicep) | [`40-create-nested-vms.ps1`](../artifacts/scripts/40-create-nested-vms.ps1): generalized Windows parent, guests, completed/activated setup, names and SIDs. |
| [45-sql-install](stages/45-sql-install/main.bicep) | [`45-install-sql.ps1`](../artifacts/scripts/45-install-sql.ps1) orchestrates [`45-install-sql-engine.ps1`](../artifacts/scripts/45-install-sql-engine.ps1) per SQL guest. |
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
run:

```bash
./scripts/validate.sh
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
