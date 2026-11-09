---
name: arc-jumpstart
description: Build, monitor, recover, and hand off the Azure Arc Jumpstart environment in this repository. Use when a user wants to create or operate the lab, reports a failed stage or Bastion/RDP trouble (including "my Bastion is not working well now"), or needs guidance for Arc setup, assessment, inventory modeling, or a simple SQL Managed Instance migration.
license: MIT
---

# Arc Jumpstart operator

Use the repository runbooks as the source of truth. This skill guides the
workflow; it does not replace the repository's Bicep and PowerShell
implementation.

## Start safely

1. Read `AGENTS.md`, `docs/00-agent-bootstrap.md`, `infra/README.md`, and
   `scripts/README.md`.
2. Determine whether the request is for a new deployment, recovery of an
   existing lab, lifecycle management, Arc handoff, or workshop activity.
3. Use PowerShell 7 and Azure CLI from the same host OS on Windows, macOS or
   Linux. WSL2 is not required for the PowerShell entry points.
4. Confirm the approved Azure subscription, dedicated resource group, region,
   cost scope, and auto-shutdown decision before provisioning.
   Explicitly ask whether to use default SQL Developer or the user's own
   authorized pre-keyed SQL Server 2025 Standard and Enterprise ISOs; record
   `SQL_EDITION_MODE=licensed` for the latter.
5. Use a private `ENV_FILE` outside the repository. For new labs, use
   `init-config.ps1 -ResourceGroupRoot <root>` to create
   `$HOME/ArcJumpstart/<root>.env` in a visible,
   owner-only folder. Preserve an existing lab's exact path; never silently
   move it. Never print, commit, overwrite, or infer credentials.
   Clear a previous lab's `ENV_FILE` override before initializing a new filename,
   then set it to the actual new path printed by the script.
   New configurations use `<root>-infra` and `<root>-arc` resource groups.
   Do not rename or retarget existing labs.

If required information is missing, ask only for that information. Apply the
documented defaults for routine choices.

New labs use the ordinary Azure Marketplace Windows Server 2025 Datacenter
Gen2 (`2025-datacenter-g2`) host, not a custom image or Hotpatch SKU.
Keep manual patching and controlled host restarts. For default `IMAGE_MODE=installation-media`,
use the approved Windows Server 2025
Evaluation source (host-side publisher verification or an approved checksum),
the pinned Ubuntu 22.04.5 ISO when Linux is included, the fixed public lab-only
Windows guest password `JS123!!`, and the operator's Linux SSH public key.
Keep host/DSRM/SQL service passwords unique and strong.
New private configurations also generate one 52-character `SQL_SA_PASSWORD`.
Use that same saved password for all four Database Engines, installed in mixed
mode with `sa` enabled and Windows admins retained; SSAS has no `sa` login.
Never print it, generate separate per-guest values, rotate it on retry, or
implicitly convert an existing Windows-only instance.
`INCLUDE_APPLIANCE_VM=true` reserves `JS-MIGRATE-01` with 8 vCPUs / 16 GiB RAM
as an unused workgroup Windows VM: no SQL, domain join, Arc launchers, or
appliance installation/registration. Existing files without version/appliance
settings retain Server 2022 and no appliance VM; do not change a running lab.
No Jumpstart images or
user-hosted blobs are required. Follow the
[media preparation/recovery contract](../../scripts/README.md#installation-media-images).
This mode is experimental until all clean-build gates pass. Do not convert
Evaluation to KMS/retail or reset its evaluation period.

## New deployment

From the repository root, use the same private `ENV_FILE` for every command:

```powershell
./scripts/validate.ps1
./scripts/preflight.ps1 infra
./scripts/deploy.ps1 all
```

Do not start the next command if the prior one failed. Set `$env:ENV_FILE` to
the absolute private path in the deployment terminal before running them.
Run the deployment in a dedicated visible terminal or asynchronous process so
the conversation remains responsive. Record the exact command, `ENV_FILE`
path, and process identity. Do not poll continuously or launch a second
deployment because the first is quiet.

Use one-shot progress checks only when useful:

```powershell
./scripts/lab.ps1 build-status
```

### User-supplied SQL media

When the user already uploaded authorized SQL media, ask whether to reuse that
account. Set both `SQL_MEDIA_RESOURCE_GROUP` and `SQL_MEDIA_ACCOUNT_NAME` only
with explicit approval. The existing account settings and uploads are not
redeployed; the new host gets private read access. `all` validates the existing
media after stage `10` and continues without another upload handoff.

With new media storage, licensed mode intentionally pauses after host/private-storage preparation.
Tell the user before deployment, then at the pause give the actual host name,
storage account, media resource group and `sql-media` container URL from the
foundation outputs. Ask which upload route they want:

- On the outer host, open `Upload licensed SQL media.cmd`, select both ISOs,
  and complete user authentication; the launcher publishes its manifest.
- Upload directly to the container root using approved private access. Keep
  the original Microsoft SQL Server 2025 Standard/Enterprise ISO filenames,
  or use `SQL2025-Standard.iso` and `SQL2025-Enterprise.iso`, exactly one each.

Guide the chosen route. Do not require user-written JSON, reupload existing
root ISOs, expose storage publicly, or add workstation networking just for media.
After the user reports completion, run `deploy.ps1 continue` asynchronously
using the same `ENV_FILE`. It reads an existing manifest or creates the missing
one after validating and hashing root uploads. The operator's existing Azure
sign-in authorizes publication via protected parameters; host identity stays
read-only. Missing/ambiguous/invalid files are actionable input corrections,
not reasons to rebuild Windows. Follow the
[licensed-media runbook](../../scripts/README.md#licensed-sql-media).

## Recovery

- Inspect the first failing gate.
- Use `stage-progress` for an active stage and `stage-log` after it is terminal.
- Follow the recovery boundary in `docs/02-sql-ag-lessons.md` and
  `docs/06-troubleshooting-cleanup.md`.
- Resume only the affected stage and required successors.
- Never rerun `deploy.ps1 all` against an already promoted domain.
- Preserve working guests, disks, databases, identities, and active operations
  unless the user explicitly approves a scoped rebuild or deletion.

### Bastion disconnects after Windows first login

If the Hyper-V host's Bastion RDP session drops or becomes unstable, ask:
"At first login, did Windows ask 'Do you want to allow your PC to be
discoverable by other PCs and devices on this network?' What did you select:
Yes, No, or nothing?" In one observed session, selecting **Yes** was followed
by an immediate disconnect and a successful reconnection; this does not prove
the prompt caused other Bastion failures. **Yes** chooses a discoverable
**Private** network; **No** chooses the less-discoverable **Public** profile.
The profile affects Windows Firewall rules and may affect RDP (TCP 3389).

1. If Bastion provisioning itself failed, use
   [Bastion troubleshooting](../../docs/06-troubleshooting-cleanup.md#bastion-is-slow-or-failed);
   do not change the host profile. If RDP reconnected, avoid changing a
   working host merely because the prompt appeared.
2. For continued RDP trouble after the prompt, inspect the host's current
   network profile and the effective Windows Firewall RDP rules for that
   profile, then check the VM NIC/subnet NSG's TCP 3389 access from
   `AzureBastionSubnet`. Do not infer the current profile from the answer
   alone or treat the prompt as a confirmed root cause.
3. Before a user-approved profile change, ensure alternate Azure Run Command
   access and that RDP is allowed for the intended profile; changing the
   active host interface can drop Bastion again. If **Yes** changed the host
   to Private and returning to Public is appropriate, follow the targeted
   [host profile recovery steps](../../docs/06-troubleshooting-cleanup.md#bastion-is-slow-or-failed)
   and verify reconnection. Never blanket-disable Windows Firewall or change
   Azure networking to compensate for an unverified profile issue.

## User handoff and workshop boundary

Infrastructure automation stops after stage `60` and Arc launcher staging. The
agent must not connect Arc: the user opens the launcher and completes
device-code authentication with their own Azure identity. Service-principal and
unattended Arc onboarding are out of scope.

After Arc and Arc-enabled SQL inventory are healthy, guide the assessment,
Resource Graph export, modeling, and single-database SQL Managed Instance
migration only when requested. Do not start assessment collectors, provision a
managed instance, migrate data, or delete resources without the required user
decision and cost/destructive-action approval.

Use `docs/03-arc-onboarding.md` for the user-authenticated handoff,
`docs/04-assessment.md` for assessment and inventory modeling, and
`docs/05-migration.md` for the single-database migration.

## Completion

Verify the ready-environment contract in `docs/00-agent-bootstrap.md`. Report
non-secret resource identifiers, readiness evidence, skipped validation, and
any unproven outcomes. Point the user to Arc setup, assessment/modeling, or the
single-database migration guide as appropriate.

Explicitly include **Your lab configuration and passwords** in the final
user-facing handoff. Verify the configuration file exists, give its actual full
absolute path (not `$HOME`, `~`, or a placeholder), and explain how to find and
view it. On macOS, provide Finder **Go to Folder** instructions and **Open With
TextEdit**. On native Windows, provide the full File Explorer path and **Open
With Notepad**; on WSL, provide both the WSL path and Windows path using the
actual distro/user. On Linux, provide file
manager/text editor instructions. Identify any remote execution host and its
approved access method. Never display the contents; warn that the file contains
passwords and must not be shared or committed. Follow the detailed handoff
contract in `docs/00-agent-bootstrap.md`; a terminal log or documentation link
alone does not satisfy it.
