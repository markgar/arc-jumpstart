# Script entry points

Run the PowerShell 7 entry points from the repository root on Windows, macOS or
Linux with Azure CLI and its Bicep component. WSL2 is not required.
These wrappers drive the Bicep stages and host-side Windows
automation; do not run the Hyper-V/AD artifacts directly on the workstation.
Run PowerShell and Azure CLI in the same operating system.

See the [agent bootstrap runbook](../docs/00-agent-bootstrap.md) for the mission,
inputs and required ready-environment outcome.

## Command reference

| Cross-platform PowerShell 7 command | Purpose |
|---|---|
| `./scripts/init-config.ps1 -ResourceGroupRoot <root>` | Creates the owner-only external `ArcJumpstart/<root>.env` template with `<root>-infra` and `<root>-arc` targets, without overwriting an existing file. |
| `./scripts/validate.ps1` | Compiles Bicep and runs PowerShell source and stage regressions. No Azure resources are created. |
| `./scripts/configure-installation-media.ps1 -SqlEditionMode licensed` | Prepares an external configuration for a fresh ISO build, preserving Azure targets/other credentials and an owner-only backup. Sets the fixed lab-only Windows password `JS123!!` and prepares the Ubuntu operator key when needed; refuses existing lab groups. |
| `./scripts/preflight.ps1 infra` / `full` | Checks Azure registrations, host SKU and media reachability. Does not create resources or register providers. |
| `./scripts/deploy.ps1 all` / `20-30` / `<stage>` | Deploys all stages or a scoped recovery stage with predecessor and Run Command gates. `all` and `00` also ensure `Microsoft.DataMigration` is registered for later use; no DMS service is created. |
| `./scripts/deploy.ps1 bastion` / `auto-shutdown` / `arc-launchers` / `ssms` | Independent access, shutdown, interactive Arc-launcher setup and host-only SSMS 22 installation. |
| `./scripts/deploy.ps1 sql-media` / `continue` | Stage the private licensed-media upload launcher, or continue the licensed-only pause after stage `10` without replaying `00`/`10`. |
| `./scripts/deploy.ps1 os-only` | Fresh-lab OS trial through stage `40`: same new-group safety checks and parallel `20`/`30` preparation, but no SQL installation, domain promotion or Arc connection. |
| `./scripts/lab.ps1 build-status` / `stage-progress 40` / `stage-log 40` | One-shot redacted stage views; live views never start a competing VM command. |
| `./scripts/dashboard.ps1 -Snapshot -Serve` | Capture existing Azure execution evidence once and display a read-only local build dashboard. Requires Node.js 20+ only for the viewer. |
| `./scripts/lab.ps1 status` / `start` / `stop` / `inventory` / `delete-infra <RG>` | Host power, modeling export and explicitly confirmed infrastructure cleanup. |
| `./scripts/check-sql-media.ps1` | Optional local HTTPS media download and length/structure/SHA-256 verification; stage `45` has its own checks. |
| `./scripts/inspect-sql-connectivity.ps1` | Read-only diagnostic of standalone SQL service/listeners, local and encrypted-loopback queries, recent SQL/TLS errors and host pre-login responses. Uses protected guest credentials; does not change services, accounts or firewall rules. |
| `./scripts/capture-sql-handshake.ps1 -Action Preflight` | Inspect existing packet monitoring and independent trace availability without starting a capture. |

For customers, use the
[single-query Resource Graph Explorer export](../docs/04-customer-arc-inventory.md)
without a lab environment file. `lab.ps1 inventory` exports the same query's
columns and full properties, scoped to the configured Arc group; its 1,000-row
guard remains a lab-only limit, not a complete customer-estate export mechanism.

From a PowerShell 7 terminal, set `$env:ENV_FILE` to the actual external file
path, sign in with `az login`, then run `validate.ps1`, `preflight.ps1 infra`,
and `deploy.ps1 all` **in order**, stopping on any failure. Keep deployment in a
separate terminal or attached asynchronous process. For a new file, use
`init-config.ps1`, then fill it privately before preflight. Do not paste the
configuration or passwords into chat.

## Read-only build dashboard

The saved deployment runner writes owner-only `<root>.build-status.json`
beside the private `ENV_FILE`. It contains selected non-secret identifiers,
redacted execution output, stage evidence and bounded recovery history, never
the configuration object. Treat the evidence as private operational data too.
Dashboard failures produce warnings without changing infrastructure behavior.

With the same `ENV_FILE` selected, run this in a separate terminal:

```powershell
./scripts/dashboard.ps1 -Serve
```

Open the printed loopback URL in a browser or Copilot's Browser canvas. The
optional viewer uses Node.js 20+ with no downloaded packages; it exposes no
deployment, restart, rebuild, Arc-connection or arbitrary-file endpoints.
It watches only the local evidence file, pushing changes without Azure polling.
Do not expose its capability URL or forward its port publicly.

For a build started before dashboard instrumentation, run
`./scripts/dashboard.ps1 -Snapshot -Serve` instead. Snapshot makes one bounded
set of control-plane reads, never a guest Run Command. It does not keep querying
Azure or reconstruct earlier attempts. Future runner invocations publish their
own changes; an already-running older invocation does not gain instrumentation.
Refresh snapshots explicitly when needed, not with a polling loop.

The dashboard distinguishes unknown, not started, running, waiting, submitted,
verified, failed, skipped and unverified evidence. An Azure deployment success
alone does not verify guest execution. Synchronous stages update at submission
and return; existing asynchronous completion checks also publish their latest
redacted output. Silence and old evidence are not failures. Networking/images
can run in parallel; Bastion remains independent, with submission not completion.
The guest matrix reflects whole-stage gates, not individual partial probes,
and does not prove a Windows-update baseline or an Arc connection.

For viewer regression checks, run `node --test dashboard/server.test.mjs`;
PowerShell evidence checks are included in `validate.ps1`.

### Progress transport proof

This is an opt-in experiment, not part of deployment or readiness. With the
same `ENV_FILE`, `./scripts/prove-progress-transport.ps1 -Mode Observe -Stage 50`
reads the existing command once and records whether output is available while
it runs. It never submits a guest or host command.

After the build is finished, `./scripts/prove-progress-transport.ps1 -Mode Canary`
refuses any nonterminal managed command, then runs two synthetic 90-second
attempts through the existing Bicep Run Command module. It changes no guests,
services, networks or disks. Each attempt emits compact versioned UTF-8 frames,
more than 13 KB of synthetic output, and a final frame. Passing requires seeing
intermediate frames while execution is running, recovering the latest frame
after the large output, matching the attempt, and native success with exit zero.
An unsuccessful proof is evidence against the transport, not a lab failure.
The named synthetic command is retained as diagnostic evidence.

The private report defaults to `<root>.transport-proof.json` beside `ENV_FILE`.
`-ReportPath` accepts another path with that suffix. To queue a canary without
polling a live deployment, supply `-AfterProcessId <PID> -CompletionLog <log>
-SuccessMarker <terminal-success-prefix>`; it waits for that exact process to
exit, requires the log's last nonempty line to begin with the success marker,
then checks that host commands are terminal. Failure or a two-hour wait timeout
does not submit a canary. Do not use this to compete with an active build.
Run `./scripts/test-progress-transport.ps1` for the local framing/gating checks.
This proof does not yet establish reboot recovery or a lossless event journal.

The first v4 canary on November 6, 2026 **did not pass**. Its native execution
succeeded, but instance-view output was capped at 4,096 bytes and the first
frame was lost before observation began. The first read occurred about 46
seconds after native start. Frames two and three were recovered only after
the recorded native end, even though that read still reported `Running`.
Therefore a `Running` label plus output is not sufficient proof of live
delivery: the experiment now compares frame observation times with the final
native end time. No second attempt was submitted after this failure. Do not
rely on instance view as a timely, lossless event stream; measure an earlier
observation path and repeated current-state snapshots before choosing it.

### SQL pre-login diagnostics

A pre-login handshake timeout is not evidence that a username or password was
rejected. With the correct lab's `ENV_FILE` selected and no active host operation,
run `./scripts/inspect-sql-connectivity.ps1`. It compares guest-local SQL access
with encrypted host access and records the existing internal-switch RSC setting.
The host probes execute as SYSTEM, so a SQL login rejection can be an expected
result after a successful handshake; they do not prove the user's domain login.
Connection pooling is disabled for these comparisons so a cached failure cannot
masquerade as a new physical connection attempt.

**New captures are currently disabled.** The experimental v4 paired `netsh` attempt timed out after
240 seconds without returning a probe result. Do not retry automatically or
claim that the eight-second watchdog or paired transport evidence has passed.
Verify both machines' trace state and owned watchdogs first; the host was
confirmed stopped with its existing `SenseNdr` configuration unchanged.
The experiment used built-in `netsh trace` on the host and `JS-SQL-01`, filtered to TCP
between `192.168.128.1` and `192.168.128.11`, with an eight-second cleanup
deadline and one four-second, pooling-disabled SQL connection attempt. The
installed `netsh` capture filters do not support TCP ports: obtain explicit
approval for **all TCP between those two IPs**, not just port 1433, before
running it. It refuses existing NetEvent sessions, packet-capture providers or
netsh traces, and never starts, stops or changes Packet Monitor, including
existing `SenseNdr` monitoring. WFP/NetEvent capture was also attempted on the
v4 SQL guest but failed at `Start-NetEventSession` with `MI RESULT 1`, before
any SQL probe; its owned sessions and watchdogs were removed.

Each trace has a 16-MiB limit, an eight-second scoped cleanup watchdog and a `finally`
cleanup path. Only the uniquely named owned sessions, providers and watchdogs
are removed. Captures stay on each Windows machine under
`C:\ArcJumpstart\Diagnostics\SqlHandshake\<unique-id>`, protected for SYSTEM and
Administrators. They may contain authentication material: do not print their
payloads, commit them or upload them to a public service. `-Action Inspect
-CaptureId <existing-id>` reads an existing attempt without another connection
or capture. The command reports cleanup and event schemas; a completed capture
does not itself establish a network root cause or successful SQL login.

Use `-Action Safety` to inspect active firewall profiles, explicit port-1433
rules and trace/watchdog state. Supplying an existing `-CaptureId` also selects
that attempt's file metadata and permits cleanup of only a trace whose path
matches that exact attempt. Without an identifier it does not stop a trace.

The diagnostic uses a separate Bicep deployment and `diagnostic-sql-connectivity`
command, never a replay of stages `50` or `60`. It refuses to overwrite a
nonterminal earlier diagnostic. Do not retry while another operation is active.
It reads only `JS-SQL-01` internally; it is not a full lab-readiness check.

## Normal automated setup

With a populated owner-only environment file outside the repository and an
authenticated Azure CLI user:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/rg-arc-jumpstart-v2.env'
./scripts/validate.ps1 &&
./scripts/preflight.ps1 infra &&
./scripts/deploy.ps1 all
```

Use the actual private path if it differs from the new-lab default. Run this
chain in a dedicated visible terminal or attached asynchronous process; leave
the conversation responsive. The PowerShell wrappers require an interactive
Azure CLI user; service-principal authentication is not supported.
Authentication, permissions and the cost envelope must be supplied/approved
before provisioning.

Bastion is enabled by default. `all` and `00` submit it independently after the
core network deployment completes, then return to the numbered sequence without
waiting for access readiness. Setting `DEPLOY_BASTION=false` omits that request.
Resuming stages `10`-`60` never submits, polls or waits for Bastion. An optional
submission error is printed as a warning without failing the core sequence;
`deploy.ps1 bastion` used on its own reports a failed submission instead of
silently succeeding. After Azure accepts the request, the build does not monitor it.
Azure retains any later provisioning errors in the independent deployment;
they are not reflected in the exit code of a successful submission.

The wrappers do not source the environment file as shell code. Use literal
`KEY=value` lines without quotes or `export`. Do not print the file or put it
in version control. The ignored repository-root `deploy.env` is retained as a
compatibility fallback; durable external storage is recommended, especially
for disposable worktrees.

For new labs, create the private file at `$HOME/ArcJumpstart/<root>.env`
in a visible folder, not a hidden folder, and pass that path through `ENV_FILE`.
`-ResourceGroupRoot` suggests `rg-arc-jumpstart-v2` by default; users can choose
another root. It sets the filename and records `RESOURCE_GROUP_ROOT`.
The shared runtime derives `AZURE_RESOURCE_GROUP=<root>-infra` and
`ARC_RESOURCE_GROUP=<root>-arc`. These suffixes are fixed; conflicting explicit
group names are rejected. Legacy files without `RESOURCE_GROUP_ROOT` retain
their explicit group names and defaults.
The root must be 1-84 characters, valid in Azure resource-group names and as a
cross-platform filename; the suffix must fit Azure's 90-character limit.
An explicit `ENV_FILE` overrides the generated filename. Clear it before
initializing another lab with a generated filename:

```powershell
$env:ENV_FILE = $null
./scripts/init-config.ps1 -ResourceGroupRoot rg-arc-jumpstart-v3
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/rg-arc-jumpstart-v3.env'
```

Existing overrides and the legacy fallback remain supported; do not silently move or
overwrite an existing file. The agent's final handoff must explicitly include
the actual full path and platform-specific instructions to find and view it,
including a Windows File Explorer path for WSL users. See
[Find your lab configuration and passwords](../README.md#find-your-lab-configuration-and-passwords).

Before any resource creation, `deploy.ps1 all` checks both target groups with
`az group exists` in the configured subscription. If either exists, or a lookup
fails, it stops without deploying. Choose another root for a new lab or use
stage-specific recovery for an existing one. Independent recovery commands
remain available.

`AUTO_SHUTDOWN_ENABLED` has no implicit default. For every new lab, ask the
operator whether to enable it and record `true` or `false`. When enabled,
`AUTO_SHUTDOWN_TIME` is a 24-hour `HHmm` value and
`AUTO_SHUTDOWN_TIME_ZONE` is a Windows time-zone ID. The example suggests
`2200` and `Central Standard Time`, but both are operator decisions. Change the
policy later with `./scripts/deploy.ps1 auto-shutdown`; do not rerun stage `10`.

`deploy.ps1 all` stages the Arc desktop launchers after stage `60` by default.
Set `PREPARE_ARC_LAUNCHERS=false` to opt out. Staging does not install or
connect Arc; it only places the clickable helper and approved non-secret Azure
target identifiers on the guest desktops. Root-based configurations derive
`ARC_RESOURCE_GROUP=<root>-arc`. For legacy files that leave it blank, the
legacy fallback remains `<AZURE_RESOURCE_GROUP>-arc`. `ARC_LOCATION` defaults to
`AZURE_LOCATION` and can be overridden.

`all` also runs the independent host-only `ssms` step after stage `60`, before
Arc launchers. It stages a Microsoft-signed bootstrapper on the host Public
Desktop and installs minimal SSMS 22 for all host users, without a host restart.
Set `INSTALL_HOST_SSMS=false` to omit it from new builds. The explicit
`./scripts/deploy.ps1 ssms` command recovers this step on an existing host
without touching numbered stages or the guests. `all` reports an SSMS failure
after the core stages instead of hiding it, but still attempts Arc launcher
staging. Use `./scripts/lab.ps1 stage-log ssms` after the command becomes
terminal. See [host-only SSMS](../docs/02-deploy.md#host-only-ssms-22).

## Licensed SQL media

Before starting a lab, explicitly ask whether to use the default Enterprise
Developer download or the user's own authorized, pre-keyed SQL Server 2025
Standard and Enterprise ISOs. Record that decision, explain the licensed-media
pause, and guide the user's chosen upload route when storage is ready.
Set `SQL_EDITION_MODE=licensed` for the latter. Separate product-key input is
not implemented: media must already contain its key in `DefaultSetup.ini`.
Keys are never read out, added to the environment file, or passed as `/PID`.
The installed edition is verified using SQL `EditionID` and SSAS setup metadata,
not the ISO filename or `EngineEdition` alone. Developer and Evaluation are
not accepted as licensed Standard/Enterprise.

Stage `00` creates a StorageV2 LRS account, private Blob endpoint, private DNS
zone and VNet link. Public-network, anonymous Blob and shared-key access are
disabled. The account/container live in `<root>-media` by default, or the
explicit `SQL_MEDIA_RESOURCE_GROUP`; the endpoint/DNS resources live in the
disposable infrastructure group. Stage `10` enables a host managed identity
with container-scoped Blob Data Reader; the signed-in operator receives
container-scoped Blob Data Contributor. These resources are also present in
Developer mode, but Developer does not use or wait for uploaded media.
Private Endpoint/DNS and stored media have ongoing costs even when the host
is deallocated; an empty storage account is not a zero-cost private network.
`all` refuses an already-existing derived media group too. To reuse retained
media, approve that scope and set both `SQL_MEDIA_RESOURCE_GROUP` and
`SQL_MEDIA_ACCOUNT_NAME` explicitly; otherwise choose a new root rather than
adopting an existing account implicitly. The named account and `sql-media`
container must already exist. In this reference-only path the foundation does
not redeploy the account, container, network policies or uploader roles.
Only the new lab's private endpoint/DNS and the new host's container-scoped
Blob Data Reader assignment are added. Uploaded files and the existing lab
remain intact.

With an explicitly named existing account, `all` checks the existing manifest
and media from the new host after stage `10`, then continues automatically
through guest/SQL/domain/AG preparation. No upload pause or repeat upload is
required for valid media. Missing, invalid or inaccessible media stops the build
at that check; use the documented media diagnostic/retry boundary rather than
restarting `all`.

For new media storage in licensed mode, `deploy.ps1 all` completes `00`/`10`, applies the approved
shutdown policy and stages `Upload licensed SQL media.cmd` on the host Public
Desktop. It exits **2** with `NEEDS_LICENSED_MEDIA`, not a successful ready-lab
result. Bastion remains independent; a user cannot open the host until access
has separately become available. Download the authorized ISOs onto the host
from the user's licensed source, then open the launcher. It requests elevation,
selects both ISOs, validates Microsoft's setup signature, hashes the bytes,
authenticates the user with AzCopy and uploads to private Blob storage. The
AzCopy download must itself have a valid Microsoft signature. No anonymous or
public-access fallback is used if policy blocks it. User-owned media selection,
Azure authentication and license entitlement remain prerequisites, not
unattended identity impersonation.

**Obtaining and uploading licensed ISOs is a user-owned input, not unfinished
infrastructure automation.** The user may use the host desktop helper or
upload directly into the configured private container. At the checkpoint, the
agent must give the actual host, storage account, media resource group and
`https://<account>.blob.core.windows.net/sql-media` URL from foundation outputs,
ask which route the user prefers, and explain its steps. Do not block
creation of that host on transferring existing workstation copies, or build a
VPN/Bastion upgrade solely for this purpose. The default Basic Bastion browser
session is not an upload tunnel. If the user instead arranges an alternative
private transfer, it must not make the Blob endpoint public. Local workstation
files are not automatically transferred by this repository.

For direct uploads, put exactly one Standard and one Enterprise ISO in the
**root** of `sql-media`, not a virtual folder. Keep the original Microsoft
`enu_sql_server_2025_standard_edition_x64_dvd_<id>.iso` /
`enu_sql_server_2025_enterprise_edition_x64_dvd_<id>.iso` names, or name them
`SQL2025-Standard.iso` and `SQL2025-Enterprise.iso`. Hash-named files produced
by the desktop uploader are also supported. The agent should verify the
user-reported upload by running the saved continuation, not ask the user to
write a manifest or upload the same valid ISOs again.

After both media uploads finish, use the same `ENV_FILE`:

```powershell
./scripts/deploy.ps1 continue
```

`continue` first reads the upload manifest using host managed identity. If it
receives **404 BlobNotFound**, it lists the container root, requires exactly
one supported ISO per edition, downloads them on the host with ETag
preconditions, verifies their Microsoft setup signatures, SQL Server 2025
version and embedded-key presence, and computes SHA-256/length. It then
creates `manifest.json` without overwriting an existing/concurrent manifest.
Original blobs are unchanged; `SourceBlobName` records their original names
while guest payloads retain hash-based filenames. Missing or ambiguous files,
403/network failures, invalid media and changed uploads fail explicitly before
SQL installation. Downloads are retained under the restricted host
`C:\ArcJumpstart\SqlMedia\root-uploads-<run>` directory for diagnosis.

Only manifest publication uses a short-lived storage token from the current
Azure CLI operator, who must have Blob Data Contributor on this container.
The token travels through owner-only temporary ARM parameter files and secure
Bicep/Run Command parameters, never command-line arguments or logs.
The host managed identity stays Blob Data Reader; no new permissions, public
network access or shared keys are introduced. A normal existing manifest is
preserved and is not regenerated from a new root listing.

After the media check, `continue` runs
`20`/`30` in parallel followed by `40`/`45`/`50`/`60` and the normal independent
host setup. The normal upload checkpoint requires successful stage `10` and no later
canonical stages. A failed or partial later stage is not a new upload checkpoint.
An `os-only` trial is the other supported checkpoint: all three stages
`20`/`30`/`40` must have succeeded with no later canonical stage submitted;
`continue` then starts at `45`, never recreating prepared guests.
Lookup failures stop rather than being interpreted as absence. For a later
failure use the documented scoped stage recovery; never restart `all` or use
`continue` to repair a promoted domain.

Stage `45` maps Standard to `JS-SQL-01`, `JS-RETAIL-01` and `JS-INSIGHT-01`,
and Enterprise to both AG replicas. Each worker receives only its assigned
ISO and a persistent edition profile used again after reboot/domain setup.
The private manifest supplies the uploader- or host-recorded length/SHA-256; this is
an integrity baseline, **not an independently published Microsoft checksum**
or proof of license entitlement. Both downloaded bytes and Microsoft Setup
signatures are checked. Installed editions are independently verified.
The cache is bound to the approved account/manifest and rejects source changes,
unbound artifacts, partial downloads and automatic engine replacement.
Content-addressed blobs are retained; rerunning the upload launcher publishes
a new manifest without replacing existing ISO blobs. A changed manifest is not
silently adopted by an already-bound host cache.

No live acceptance has yet proved the private endpoint/RBAC propagation,
licensed SQL/SSAS installation or complete new-media lab build. Record failures
and fix the checked-in implementation before claiming clone-to-ready automation.

## Preparing a fresh installation-media trial

With an initialized external `ENV_FILE` and the approved target groups absent:

```powershell
./scripts/configure-installation-media.ps1 -SqlEditionMode licensed
./scripts/validate.ps1
./scripts/preflight.ps1 infra
./scripts/deploy.ps1 os-only
```

Run each command only after its predecessor succeeds. Configuration preparation
preserves the approved target names and existing host/DSRM/SQL credentials.
It creates an owner-only backup beside `ENV_FILE`, generates an operator SSH
key there when needed, and sets `NESTED_WINDOWS_PASSWORD=JS123!!` for the new
Windows guests. The host, DSRM and SQL service credentials stay unchanged and
must remain strong. It refuses to modify credentials for an existing lab.
Key generation requires the workstation's OpenSSH `ssh-keygen` executable.
The private key stays on the workstation; only its public key enters deployment.

The official Windows source and verification policy are in `deploy.env.example`.
With `WINDOWS_ISO_SHA256=auto`, the Azure host follows only approved Microsoft
HTTPS redirects, downloads the ISO there, verifies Microsoft's Setup signature
and records the downloaded SHA-256 in a protected source receipt. Cached bytes
must match that receipt. This policy is permitted only for the exact official
Windows Server 2025 Evaluation link (or the retained Server 2022 link when
explicitly selected); custom sources require an approved
64-character checksum. No workstation ISO download is required.
A recorded fingerprint is not an independently published Microsoft checksum.
The host additionally checks WIM
edition/build/language and boot configuration before publishing a prepared disk.
Windows first boot, OOBE, generalization, unique identity and activated
Evaluation licensing are separate stage-40 gates.

`os-only` is an infrastructure/OS trial, not a workshop-ready lab or a complete
SQL build. It still creates billable resources and must use the approved cost
envelope. A successful result explicitly prints `OS_IMAGE_TEST_READY` only after
stage `40`; licensed media acquisition can happen on the host while the trial
runs. Keep execution asynchronous/visible and use the normal one-shot status
commands, not polling or manual VM repairs.

## Live progress from the host

Stage scripts retain their detailed transcripts under `C:\ArcJumpstart\Logs`.
They emit timestamped messages at meaningful boundaries such as image download,
guest OOBE, SQL worker state, domain promotion, native cluster validation,
automatic seeding and listener verification. No storage account or external log
service is required for this workshop.

An attached agent should normally inspect a running build with:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/rg-arc-jumpstart-v2.env'
./scripts/lab.ps1 build-status
```

It discovers all concurrently active canonical stages, including overlapping
stages `20` and `30`. If no stage is active, it reports the most recently
started numbered stage (`10`-`60`); the independent `ssms` step is available
through `stage-progress ssms`. It lists names and reads each discovered numbered
stage's instance view separately (at most seven read-only `show` calls), since
Azure's list response may omit instance views even with expansion. Missing or
invalid instance-view state is reported as an error, not as an inactive stage.
Azure's valid `Unknown` execution state remains nonterminal and is displayed
explicitly rather than implying the stage completed.
Use `stage-progress 40` when the desired stage is already known.
Repeat either command only when a progress update is useful; do not create a
tight polling loop. These commands read existing Managed Run Command instance
views, so they return promptly instead of queueing an Action Run Command behind
the active stage. `Elapsed` is calculated from Azure's start time. A recent or
repeated wait message proves observation, not necessarily forward progress.
Azure retains only a bounded latest-output window in instance view. The output
can only describe observable state:
for example, it can say Sysprep is still running or the guest has not completed
OOBE, but cannot invent an internal Windows substep.

Use `stage-log` for the longer 200-line host-transcript tail after a stage is
terminal and the VM agent is free. It launches a read-only Action Run Command,
so it is intentionally not the live-progress mechanism. Both views suppress
transcript startup headers and redact current configured secrets before
display. `stage-log` supplies its full script through a restricted local
temporary file (`--scripts @file.ps1`) and deletes it after invocation, including
on CLI failure. They do not rewrite the raw host transcript, which remains
sensitive.

All three operational wrappers support an alternative environment file:

```powershell
$env:ENV_FILE = 'C:\path\to\approved\lab.env'
./scripts/preflight.ps1 infra &&
./scripts/deploy.ps1 all
./scripts/lab.ps1 status
```

Replace that path with the approved file. Use a consistent configuration for
deployment, status and recovery; a status command against a different resource
group does not describe the build being monitored.

## Completion and recovery

`deploy.ps1` enforces stage predecessors. Stage `10` includes a host restart and
agent wait. `all` and `20-30` submit the image Run Command before configuring
the independent internal network, then join the fresh image execution before
proceeding. Individual `30` and stage `45` still wait for their new asynchronous
Run Command and require exit `0`; do not return core-stage success when only
submission succeeded. If the wrapper stops while images are outstanding, Azure
may continue downloading; inspect the command before retrying.

Use the stage number that failed, not a second `all` invocation, to resume.
For example:

```powershell
./scripts/lab.ps1 stage-log 50
# Resolve the first failure using saved source and the domain runbook.
./scripts/deploy.ps1 50 &&
./scripts/deploy.ps1 60
```

Do not start another installation or configuration operation while earlier work
is active or its completion is unknown. Do not use stage `40` to repair a
promoted DC. Detailed retry boundaries are in the
[AG lessons](../docs/02-sql-ag-lessons.md#recovery-workflow-for-the-next-operator)
and [cleanup guide](../docs/06-troubleshooting-cleanup.md).

## Installation-media images

`IMAGE_MODE=installation-media` replaces both Jumpstart VHDX downloads with
official ISO downloads and local disk preparation. It is the new-lab default
and remains experimental until a clean Azure build passes every readiness gate.
The host uses the standard Azure Marketplace Windows Server 2025 Datacenter
Gen2 (`2025-datacenter-g2`) image, not a Hotpatch SKU, preserving manual patching
and controlled restarts; no custom Azure host image is required.
`WINDOWS_SERVER_VERSION=2025` selects both host and Windows guest versions.
Existing files without that key retain Server 2022, and absent `IMAGE_MODE`
retains legacy `jumpstart` behavior. Do not change versions or image modes
while recovering an existing lab.
Image preparation needs no anonymous/public Blob storage or image uploads;
private SQL-media storage is provisioned independently.
Keep the selected mode and credentials unchanged for the lifetime of a lab.

`INCLUDE_LINUX=false` selects a Windows-only lab across preflight, stage `30`,
and stage `40`. It skips Linux downloads, host SSH-key preparation, Ubuntu
installation, and `JS-UBUNTU-01`; the default remains `true`. All Windows
guests retain their normal setup, activation, identity, and networking gates.
New templates also set `INCLUDE_APPLIANCE_VM=true`: stage `40` adds
`JS-MIGRATE-01` with 8 vCPUs, 16 GiB RAM and an 80-GiB disk on the internal
switch with DHCP. It remains an unused workgroup guest: no SQL, domain join,
Arc launcher, appliance installation or project registration. Set the flag
to `false` to omit it; existing files without the flag do not gain that VM.
This yields eight guests with Linux, or seven Windows guests without Linux.
Microsoft supports installing the Hyper-V appliance on Windows Server 2025
with these resources; use the [official installer procedure](https://learn.microsoft.com/en-us/azure/migrate/deploy-appliance-script)
later, separately from infrastructure preparation.
After a terminal OS-trial failure at the Ubuntu template, the explicitly
approved `./scripts/disable-linux.ps1` recovery stops and unregisters only
`TEMPLATE-Ubuntu-22.04`, leaves its disks and installer artifacts in place,
and saves `INCLUDE_LINUX=false` in the existing environment with a protected
backup. It refuses an active stage `40`, a completed Ubuntu base, or an existing
`JS-UBUNTU-01`. It preserves the host, verified ISOs, and Windows parents.
No export, disk deletion, or archival is needed to continue Windows provisioning.
Resume with `./scripts/deploy.ps1 40`, not `all` or `os-only`.

Use the official `WINDOWS_ISO_URL` and `WINDOWS_ISO_SHA256=auto` defaults for
Azure-host publisher verification, or provide an approved checksum for a custom
Windows Server 2025 Evaluation URL. Register and review the evaluation terms first.
The image must be English, x64, build 26100 (20348 only for selected Server 2022),
Datacenter Evaluation with Desktop
Experience. Set `UBUNTU_ISO_URL` and `UBUNTU_ISO_SHA256` to the Ubuntu 22.04.5
live-server defaults in `deploy.env.example`, and set `LINUX_SSH_PUBLIC_KEY` to
one OpenSSH public key. Do not copy a private key into configuration.
All new Windows guests use `NESTED_WINDOWS_PASSWORD=JS123!!`, a public
lab-only password, never for the outer host, DSRM, or SQL service account.

Stage `30` downloads ISOs on the Azure host using BITS. It verifies the official
Windows publisher/source and records its fingerprint, or checks an explicitly
supplied checksum. Ubuntu always uses its pinned SHA-256. Windows
DISM applies the selected image to a new GPT/UEFI VHDX. For Server 2025,
BCDBoot runs from the installed host's `Windows\System32` with `/offline`,
using the applied image as its source and only its EFI partition as the
destination. This avoids loading offline-image DLLs into a host process.
Offline servicing also prevents the host's BootEX selection from requiring
files absent from the Evaluation ISO; it requires a patched Server 2025 host
with BCDBoot build 26100.8037 or later. The legacy Server 2022 path keeps
its image-matched executable. Neither path changes firmware or code-integrity
policy. The builder creates both EFI destination directories before invoking
BCDBoot, captures native warnings without interrupting Windows PowerShell, and
requires the final native exit code plus the BCD store, Microsoft boot manager
and fallback UEFI loader before publishing readiness. Server 2025 receipts use
`windows-2025-eval-media-v2`; older receipts are not silently reused.
A protected unattended answer file sets Administrator's
password. This prepares a disk, not a fully booted or activated guest.
Ubuntu's ISO is copied to a local FAT32/UEFI installer VHDX with NoCloud
autoinstall configuration. The seed is written explicitly as BOM-free UTF-8;
Windows PowerShell 5.1's default UTF-8 BOM prevents cloud-init from recognizing
the `#cloud-config` header. Installer receipts use `ubuntu-installer-media-v2`
so an older seed is not silently reused. The installer targets the largest disk in an isolated
temporary VM containing only an 80-GiB blank target and an 8-GiB installer child.
No existing guest disk is attached to that VM.

Stage `30` still overlaps stage `20`. After both finish, stage `40` starts the
Ubuntu installer while Windows first boot and Sysprep run. It waits for the
installer's normal shutdown, detaches the installer, boots the installed OS,
and verifies Ubuntu 22.04, an installation receipt, SSH key access, completed
cloud-init and passwordless administrative access before sealing the Linux disk.
Windows still must complete native OOBE, generalization, activation, distinct
SIDs, and final naming. Evaluation activation requires `LicenseStatus=1`,
`TIMEBASED_EVAL`, and positive remaining evaluation time. No KMS key, edition
conversion or rearm is used. SQL edition selection is independent of OS media.

Additional host dependencies are Windows DISM/Storage/Hyper-V cmdlets, BITS,
BCDBoot, and OpenSSH Client (installed as a Windows capability if absent; a
required restart stops the stage). Outbound access is needed to the approved
Microsoft media/activation endpoints, `releases.ubuntu.com`, and Ubuntu package
repositories for unattended installation and OpenSSH Server. Do not bypass
organizational download restrictions. Workstation preflight checks ISO/SQL URL
reachability, not every host/guest endpoint, actual ISO checksums or activation.

The host-only cache is `F:\ArcJumpstart\Images\InstallationMedia`, restricted
to SYSTEM and Administrators. It contains ISOs, read-only prepared disks,
versioned `.ready` receipts, installer VM artifacts, and `Keys\ubuntu-ed25519`
(the host's private verification key). The Windows source disk contains the
unattended configuration and must be treated as secret-bearing. Never upload
or share these files or raw setup logs. Ubuntu login is `jumpstart` with the
operator's SSH key, not the old image password. Ubuntu receives DHCP; discover
its address from the host DHCP leases/VM network information rather than assume
the old `.101` address. Arc onboarding remains user-authenticated and unchanged.

Only completed, matching caches are reused. The image-build lock prevents
concurrent stage-30/stage-40 writers. Missing/mismatched receipts, changed ISO
checksums/keys, existing template VMs and partially built disks stop rather
than trigger deletion or reinstall. If stage `30` fails, use `stage-log 30`
after it is terminal. If stage `40` fails, use `stage-log 40` and inspect the
template console and native installer logs. A Windows failure can leave the
Ubuntu installer running: let it become terminal before any recovery.
Never restart an installer to obtain status or rerun `all` on an existing lab.

For a terminal Windows disk-preparation failure, `./scripts/inspect-image-media.ps1`
reports partition layout and boot-file presence without reading the answer file
or changing the image. It takes the same build lock, refuses an already attached
image, mounts it read-only without drive letters, then unmounts only its own mount.
It is a failure diagnostic, not a progress observer or a boot repair.
The explicit `-InitializeBoot` recovery switch instead mounts the unpublished
disk writable and runs verbose BCDBoot against only its Windows and EFI
partitions. It refuses published disks or hosts with any existing guest.
It never formats/deletes a partition, changes host firmware, or publishes a
ready receipt. Use only after a terminal pre-guest boot-file failure.
After saving a source fix, `-PreserveUnpublishedWindows` explicitly moves only
an unattached, unpublished, independent Windows base disk to a unique diagnostic
filename. It refuses any existing guest or ready receipt, holds the build lock,
and deletes nothing. Then rerun `deploy.ps1 30` followed by `deploy.ps1 40` to
exercise the saved automation afresh, reusing verified ISO media. This is not
recovery for an existing guest lab; never use it to replace a working parent.

After a terminal Ubuntu installer failure, use
`./scripts/inspect-ubuntu-build.ps1 -OutputPath <absolute PNG path>` to capture
its current console through Hyper-V's thumbnail API. It does not send guest
input, start/stop the VM, or mount an installation disk. It holds the build lock
while capturing and transfers one fingerprint-verified snapshot in bounded
chunks to accommodate Azure Run Command's output limit. Do not use it as a
progress polling loop or restart the installer merely to inspect it.

For incomplete preparation, preserve evidence and prefer a separately approved
fresh lab. An in-place retry requires an explicit scoped recovery decision:
first prove the operation is terminal and that the specific incomplete disk has
no VM, checkpoint or detached-disk dependents; then remove only the approved
failed template and its exact incomplete disks/receipts. Never remove the
Windows/Ubuntu parents of working guests or alter a ready marker to claim success.
Retry the failed canonical stage and required successors, not the full pipeline.
There is no automatic partial-installer restart or evaluation-expiration reset.

The first acceptance run must exercise `30`, `40`, parallel SQL stage `45`,
domain stage `50`, AG stage `60`, and launcher staging using only these newly
built disks. A locally passing regression suite is not proof of this run.

## Regression coverage

`validate.ps1` compiles Bicep and runs the PowerShell runtime, host-SSMS, stage-view,
lab-runtime, repository-documentation, Arc-launcher, media-checker and guest-stage regressions.
Stage `45` verifies its SQL media in the guest installation workflow.
`test-image-media.ps1` covers media settings, checksums/cache rejection,
Windows image selection and boot preparation, unattended configuration, Ubuntu
installed-OS verification/failure, and the composed embedded-script syntax.
`test-stage40.ps1` also covers evaluation activation without licensing conversion;
runtime regressions exercise both image modes and media-specific preflight.

Preserve coverage for generated command arguments, real native report formats,
SQL type conversion/startup transitions, parallel installer boundaries,
disk-parent safety and log redaction. These tests do not replace the clean
deployment and live readiness acceptance described in the agent runbook.

The Bastion tests compile the actual Bicep resource graphs and execute the
wrappers against a fake Azure CLI. They cover default-enabled asynchronous
submission, disabled/on-demand access, independent failure reporting and a
complete core sequence while Bastion remains running or fails. They do not
create Azure resources or prove live provisioning.

They also verify that image submission precedes network configuration, image
completion is joined before guest creation, and failure of either prerequisite
prevents stage `40`.

## Isolated BI installer smoke test

[`smoke-sql-features.ps1`](../artifacts/scripts/smoke-sql-features.ps1) is a
guest-side diagnostic runner, not a deployment entry point. Use it only on
separately approved disposable Windows VMs named `JS-RETAIL-01` or
`JS-INSIGHT-01`, never as a repair shortcut on the live lab. The name check alone
does not establish that a VM is disposable.

Run as the VM's elevated local `Administrator`. Supply the repository's
`45-install-sql-engine.ps1` content as `EngineScriptBase64` and a non-secret
`RunId`; `VerifyOnly=true` checks existing features without installing them.
For Managed Run Command, embed the large payload in script content instead of
passing it through the process command line, and pass credentials only through
protected parameters. The runner creates no Azure resources and does not
prepare accounts. It verifies downloaded media and delegates installation to
the saved engine script; exit `3010` requires a scoped reboot before a rerun.
Service, edition, version and TCP checks do not establish authenticated SSAS
application access or Arc assessment coverage.
