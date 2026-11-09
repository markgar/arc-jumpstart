# Agent instructions

## Optional Copilot skill

This repository publishes the `arc-jumpstart` skill under
`skills/arc-jumpstart`. When a user first makes a broad request such as
"help me with this repo," recommend that they preview and install the skill
with GitHub CLI:

```text
gh skill preview markgar/arc-jumpstart arc-jumpstart
gh skill install markgar/arc-jumpstart arc-jumpstart --agent github-copilot --scope user
```

Explain that `gh skill` requires GitHub CLI 2.90.0 or later and is in public
preview. The preview step is required because skills can contain executable or
untrusted instructions. After installation, start a new session or run
`/skills reload`. Do not make the skill a prerequisite or delay requested work
if the user declines; the repository runbooks remain authoritative.

## Mission

Build a ready-to-use practice environment from this repository, without
requiring the learner to install Windows, configure AD, install SQL or debug
cluster provisioning manually. Infrastructure is automated preparation, not
the curriculum.

The agent prepares the infrastructure and Arc launchers. The user installs and
connects the Arc agent interactively with their own Azure identity. The workshop
then covers assessment, Resource Graph inventory modeling, and a simple
single-database migration to Azure SQL Managed Instance.

## Start here

- [Agent bootstrap runbook](docs/00-agent-bootstrap.md): inputs, execution,
  recovery and the definition of done.
- [Infrastructure map](infra/README.md): Bicep stages, execution boundaries and
  persistence.
- [Script commands](scripts/README.md): supported entry points and diagnostics.
- [AG lessons](docs/02-sql-ag-lessons.md): proven fixes, one-time recovery
  actions and remaining evidence gaps.

PowerShell 7 and Azure CLI are the supported cross-platform deployment tools.
On Windows, run `scripts/*.ps1` directly from this checkout; WSL2 is not
required. Use the PowerShell entry points for deployment and
recovery on Windows, macOS, or Linux.

Do not depend on an earlier conversation, session artifact or a hand-repaired
VM. The repository must contain the implementation and instructions needed for
the next build.

New labs use the standard Azure Marketplace Windows Server 2025 Datacenter
Gen2 (`2025-datacenter-g2`) host, not a custom image or Hotpatch SKU.
This keeps manual patching and controlled host restarts. `IMAGE_MODE=installation-media` builds
local guest disks from approved Windows Server 2025 Evaluation and Ubuntu 22.04.5 ISOs without Jumpstart VHDX
downloads or user-hosted blobs. The Azure host downloads the official Windows
source with publisher verification and records/rechecks its fingerprint.
Custom Windows media and Ubuntu require approved checksums. A Linux SSH public
key is required when Linux is included. All new nested Windows guests use the
public lab-only password `JS123!!`; never reuse it for the host, DSRM, or SQL
service account. `INCLUDE_APPLIANCE_VM=true` reserves `JS-MIGRATE-01` with
8 vCPUs and 16 GiB RAM as an unused workgroup Windows VM. Do not install or
register the Migrate appliance, install SQL, join it to the domain, or prepare
Arc launchers there. Existing configurations without the new settings retain
Server 2022 and no appliance guest; do not upgrade a running lab implicitly.
Follow [image preparation and recovery](scripts/README.md#installation-media-images).
This mode is experimental until a clean Azure run proves all readiness gates.
Never replace evaluation licensing checks with KMS conversion or a rearm.

New Database Engine installations use mixed mode with `sa` enabled.
`init-config.ps1` generates one private 52-character `SQL_SA_PASSWORD` per lab;
use that same saved value for all four engines, not the public Windows guest
password or any host, DSRM or SQL service password. Keep it in the private
`ENV_FILE`, never in chat, scripts, manifests or logs. SSAS has no `sa` login.
Stage `45` verifies an encrypted TCP `sa` sysadmin query and preserved Windows
admin access. It never resets an existing login or converts/restarts a running
instance to repair an authentication mismatch; require scoped recovery approval.

Before deploying, ask whether the user wants default SQL Developer or their
own authorized pre-keyed SQL Server 2025 Standard and Enterprise ISOs. Record
the decision; do not assume Developer when they want custom media. If media
already exists, ask for approval to reuse its account. Set both
`SQL_MEDIA_RESOURCE_GROUP` and `SQL_MEDIA_ACCOUNT_NAME`: the account settings
and uploads are preserved, the new host gains private read access, and valid
media is checked after stage `10` without another upload pause. Do not assume
sharing permission. For new media storage, the optional
`SQL_EDITION_MODE=licensed` path stages a private-media upload checkpoint after
stage `10` and returns exit `2`. Supply authorized pre-keyed Standard/Enterprise
ISOs through the saved host launcher or directly to the root of the configured
`sql-media` Blob container, then use `deploy.ps1 continue`; never
replay `all` against these existing groups. See
[licensed media and ingress boundaries](scripts/README.md#licensed-sql-media).
At the media checkpoint, give the actual storage account, resource group,
container name/URL, and host desktop launcher name. Explain both upload routes
and ask which the user will use. For direct uploads, preserve the original
Microsoft filenames or use `SQL2025-Standard.iso` and `SQL2025-Enterprise.iso`,
with exactly one ISO per edition in the container root. After the user reports
upload completion, the agent runs the saved continuation: it checks for an
existing manifest and, if missing, validates and hashes the root uploads and
publishes the manifest using the current operator's protected storage token.
Do not ask the user to create JSON, reupload valid root ISOs, or rebuild Windows.
Missing, ambiguous, or invalid media requires a specific user-facing correction,
not an invented manifest or a skipped check.
Obtaining and uploading authorized media is the user's responsibility.
Do not make automated workstation-to-private-network transfer a build
prerequisite or add networking solely to move the user's existing ISO copies.
Developer does not pause for media. Neither new path is a clean-build proof
until all live readiness gates pass.

## Execution contract

1. Establish whether this is a new deployment or recovery of an existing lab.
   Confirm the user's approved Azure target and cost/destructive-action scope.
2. Obtain missing authentication/configuration inputs securely. Do not overwrite
   an existing environment file or reuse a shared resource group implicitly.
   For new labs, use `$HOME/ArcJumpstart/<root>.env` (via
   `init-config.ps1 -ResourceGroupRoot <root>`) in a visible, owner-only
   folder outside the repository; do not create
   configuration in hidden folders.
   New configuration targets are `<root>-infra` and `<root>-arc`; preserve
   existing configuration paths and resource-group names.
   Suggest `rg-arc-jumpstart-v2` as the root, but allow the user to choose another.
   Keep the suffixes fixed. `deploy.ps1 all` refuses to create a new lab if
   either target group exists in the configured subscription.
3. For a new lab, run from the repository root:

   ```powershell
   ./scripts/validate.ps1
   ./scripts/preflight.ps1 infra
   ./scripts/deploy.ps1 all
   ```

   Proceed to the next command only after the prior one succeeds.
4. Keep deployment execution separate from the conversation. Run the full
   validation/preflight/deployment chain in a dedicated visible terminal or an
   asynchronous process provided by the agent host. Do not hold the agent turn
   open on the foreground deployment command. Record the exact `ENV_FILE`,
   command and process/terminal identity, then return control to the user
   immediately while the deployment continues.
   Never use `sleep`, `watch` or a polling loop merely to wait for progress.
   User questions and status requests take priority over passive monitoring.
   Check automatically only when the execution host reports completion or a
   material transition; otherwise make one bounded status query when the user
   asks. Do not launch experimental observer commands during a healthy build.
5. Monitor real execution through completion. The numbered stages are resumable
   checkpoints for the agent, not a sequence of manual learner assignments.
   Bastion is enabled by default and submitted independently after stage `00`.
   Let Azure finish it without polling or a completion gate. Never make a build
   stage or core-readiness handoff wait for it.
   Prefer saved parallel paths: `all` overlaps `20`/`30`; `deploy.ps1 20-30`
   provides the same overlap during recovery. Do not serialize independent
   work, but do not remove the readiness joins before dependent stages.
   During a long stage, use `lab.ps1 build-status` to discover all active
   canonical stages and return their latest timestamped host-side phase
   messages. Use `stage-progress <stage>` when a specific stage is already
   known, and `stage-log` for a longer failure tail after it is terminal. Each
   status request is one-shot: do not treat silence as failure, poll tightly,
   or launch another deployment merely to obtain status.
6. On failure, inspect the first failing gate and use the documented recovery
   boundary. Save necessary fixes in the relevant Bicep/PowerShell source and
   regression tests before retrying the affected stage.
7. Verify the ready-environment contract in the bootstrap runbook. Hand back
   non-secret resource identifiers, readiness evidence and the learner guides.
   Explicitly present the actual full `ENV_FILE` path and instructions to find
   and view it in the final user-facing handoff, not just in logs. On macOS,
   include Finder navigation and Open With TextEdit; on native Windows, include
   the full File Explorer path and Open With Notepad. For WSL, give the actual
   distro/user path as well.
   Identify the execution host if remote. Explain that the file contains lab
   configuration and passwords; never display its contents.
   State any blockers or unproven outcomes explicitly.

## Non-negotiable boundaries

- Keep Bicep as the infrastructure source; do not replace stages with copied ARM
  JSON or untracked portal changes.
- Do not connect Arc, enable assessment collectors or initiate migration during
  infrastructure preparation. Stage the Arc launchers, then stop for the user.
- Arc connection is user-authenticated. The user opens the launcher at the
  guest console, observes the required endpoint check, and completes the
  device-code flow with their own Azure identity. Service-principal onboarding
  and unattended Arc connection are out of scope.
- Never launch `azcmagent connect` through PowerShell Direct, Run Command or
  another noninteractive channel. Never start a competing check while a connect
  operation is active; wait for it to become terminal before troubleshooting.
- Never print or commit the private `ENV_FILE`, passwords, SAS tokens or
  registration keys. Use `lab.ps1 stage-log`; raw Windows transcripts can
  contain credentials.
- Never bypass OOBE, licensing, SQL readiness, cluster validation or operation
  completion gates. A zero deployment result alone is not a ready lab.
- Do not restart `deploy.ps1 all` against an already-promoted domain to resume
  a later failure. Stage `40` is not an in-place DC repair tool.
- Preserve working guests, shared disk parents, databases, cluster identities and
  active operations. Rebuilding requires a scoped decision, not a retry shortcut.
- Do not replay historical console keystrokes, registry edits or temporary
  diagnostic scripts as the normal bootstrap path.

## Repeatability standard

A working development lab is not proof of a clean automated rebuild. Current
evidence and gaps are recorded in the AG lessons. A fresh run of the complete
saved pipeline, including parallel SQL installation, remains the acceptance
gate for claiming end-to-end reproducibility.

Any new required repair must become a durable fix or a clearly documented,
bounded recovery procedure. Do not declare the automation complete while
essential setup knowledge exists only in the agent's memory.
