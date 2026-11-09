# Lessons from the first clean-room attempt

This record documents build evidence and safe recovery boundaries.
For a new build or recovery, use the PowerShell commands in the
[bootstrap runbook](00-agent-bootstrap.md).

## Evidence and limits

The opt-in `installation-media` path added on 2026-11-04 prepares fresh Windows
Evaluation and Ubuntu disks from official ISOs. No live Azure acceptance run
has yet been recorded for it. Earlier results below used the Jumpstart VHDX
images and do not establish that their preinstalled configuration is unnecessary.
The next run must prove native Windows setup/generalization/evaluation
activation, Ubuntu unattended install/SSH/cloud-init, fresh parallel SQL/SSAS
installation, domain readiness, cluster validation, AG/listener readiness and
launcher staging without copying state from the old images. Failures must
become saved provisioning fixes or bounded recovery, not manual image repair.

A fresh agent used baseline `7323b9d` and repository instructions on
2026-09-16, without the original debugging conversation. Source validation
passed, including Bicep compilation and the PowerShell stage
regressions. Infrastructure preflight passed for the selected target; the
public Windows, Ubuntu and SQL media endpoints were reachable.

The user stopped the attempt after foundation completion and submission of
stage `10`. The host initialization Run Command was still running at the stop
handoff. No stages `20`-`60` had been submitted. There was no diagnosed guest
failure, but also no proof of completed host initialization, fresh parallel SQL
installation or end-to-end readiness. This attempt is not a successful clean
rebuild.

## First Server 2025 attempt: Hotpatch image mismatch

On 2026-11-06 the separate v4 foundation succeeded while referencing an
explicitly approved existing SQL-media account without redeploying its
settings or uploads. The user deferred Ubuntu, so this run selects only the
seven Windows guests, including the unused appliance VM.

Host creation then failed with `InvalidParameter`: the Server 2025 Azure
Edition image required `PatchMode=AutomaticByPlatform`, conflicting with the
saved manual patch policy. No host VM was created. The durable correction
selects ordinary Server 2025 Datacenter Gen2 (`2025-datacenter-g2`), preserving
manual patching, controlled restarts and the legacy Server 2022 image mapping.
See the [bounded stage-10 recovery](06-troubleshooting-cleanup.md#server-2025-host-image-rejected-for-patch-mode).
This first failed attempt is not evidence of a complete Server 2025 build.

## Server 2025 image boot preparation: offline DLL blocked

The same v4 run subsequently completed host initialization, shared SQL-media
access and stage `20`. Stage `30` verified the Microsoft Evaluation ISO and
applied Windows successfully, but its image-local BCDBoot exited
`-1058471934` (`0xC0E90002`, system-integrity policy violation). Host Code
Integrity event `3077` identified the offline image's `bcrypt.dll` as the
blocked module loaded by the image-local BCDBoot. Read-only inspection found
the expected GPT, FAT32 EFI and NTFS Windows partitions, the BCD template and
boot-manager source, but no EFI BCD store. This was not a download failure or
evidence that the disk needed repartitioning.

The saved correction uses the installed Server 2025 host's signed BCDBoot
with its documented `/offline` option, targeting only the new image's Windows
and EFI volumes. Offline servicing uses the source image's ordinary boot
files without adopting the host's BootEX selection. No code-integrity policy,
Secure Boot setting or licensing gate is changed. The Server 2022 legacy
path remains image-matched.

For this pre-guest failure, once stage `30` is terminal, preserve the
unpublished disk with `scripts/inspect-image-media.ps1
-PreserveUnpublishedWindows`, then retry only `scripts/deploy.ps1 30`.
The helper takes the image-build lock and refuses attached disks, published
receipts, existing guests and differencing disks. It moves the failed disk
to a uniquely named backup rather than deleting it; the verified ISO is reused.
Do not run `all`, rebuild the host or initialize an existing guest's disk.
The correction still needs a successful live stage `30` and all later
readiness gates before this run can establish a working Server 2025 lab.

The first retry passed the earlier code-integrity block, but Windows
PowerShell treated native BCDBoot stderr as a terminating error before the
tool's final status could be collected. A guarded pre-guest diagnostic allowed
BCDBoot to finish: it returned success and created BCD despite warnings about
copying the Microsoft boot manager to a nonexistent destination path.
Consequently, a zero exit and BCD alone are not sufficient evidence.

The saved builder now creates both EFI output directories first, captures
native stderr without prematurely stopping the process, and requires BCD,
`EFI\Microsoft\Boot\bootmgfw.efi` and `EFI\Boot\bootx64.efi` before publishing
readiness. Launch errors and nonzero native exits still fail explicitly.
A guarded live boot-initialization diagnostic with those directory and file
checks passed on the unpublished disk; it created no readiness receipt.
The Server 2025 receipt version is now `windows-2025-eval-media-v2`.
This diagnostic is not proof of a fresh stage `30` or a booted guest; preserve
the unpublished image and rerun the saved stage before continuing.

## Server 2025 first boot: activation already in progress

The next v4 run passed stage `30`, template OOBE and verified Sysprep, and
created the seven Windows guests. Stage `40` verified activation on the first
five guests, then stopped on `JS-INSIGHT-01` with `/ato` exit `-1073422296`
and `0xC004E028`. Microsoft documents this code as another activation request
already being processed, not a bad key or an expired evaluation.

The saved Evaluation path now handles only that exact native exit and error
code by observing the installed licensing product for at most 300 seconds.
It starts no second `/ato`, reboot, key change or rearm, and still requires
exactly one `TIMEBASED_EVAL` product with `LicenseStatus=1` and positive
remaining evaluation time. All other errors remain fatal. A timeout preserves
the guest for diagnosis.

After the failed command is terminal, retry only stage `40`, retaining its
published generalized parent and existing guests. Already licensed guests
skip activation. Continue with `45`, `50` and `60` only after all stage-40
gates succeed; do not replay `all` or rebuild the image for this error.
See [Microsoft's activation-error reference](https://support.microsoft.com/en-us/windows/activation/get-help-with-windows-activation-errors).

## Bastion was the first avoidable wait

The VNet was ready at about 13:26:35 UTC. Stage `00` did not finish until
13:37:10 UTC because its nested deployment also contained Bastion. The
deployment wrapper at that time waited for the entire deployment before
starting the host: roughly ten and a half minutes after the network was ready.

The prior documentation said stage `10` could use the ready VNet directly.
That was true for an individually invoked stage, but did not describe the
synchronous `all` path. Documentation must describe the actual orchestration,
not just the resource dependencies.

The saved correction is:

- Stage `00` creates the core network and reserves `AzureBastionSubnet`.
- [Independent Bastion Bicep](../infra/stages/bastion/main.bicep) creates only
  Bastion and its public IP, using the existing subnet.
- The deployment wrapper keeps Bastion enabled by default but
  submits it with `--no-wait` after the foundation succeeds. It immediately
  continues the numbered build without a Bastion completion gate.
- Azure finishes Bastion independently; there is no build-side monitoring or
  completion join. Failed access does not trigger a lab rebuild.

The PowerShell wrapper has mock coverage for independent Bastion submission in
[`test-powershell-runtime.ps1`](../scripts/test-powershell-runtime.ps1).
A later live build also used the independent submission path without making
Bastion a core-stage gate.

## Region availability and quota are separate checks

The default `Standard_E16s_v5` size had subscription **Location** restrictions in
East US 2, East US and Central US during this attempt. West US 2 had only
**Zone** restrictions, so a non-zonal deployment was allowed there. Do not
interpret a zone restriction as a blanket regional prohibition, or assume a
default SKU is available to every subscription.

The chosen West US 2 target had sufficient regional and ESv5-family vCPU quota
for the 16-vCPU host. The agent checked quota manually: the preflight checks
SKU availability, but does not yet enforce available regional and family quota.
For a new allocation, verify both quotas can accommodate the requested vCPUs;
for reuse or resizing, account for the existing allocation instead of counting
it twice. SKU eligibility and quota do not guarantee physical capacity.

The approved planning estimate for that attempt was approximately $51/day,
with a $60 first-day planning envelope. These were user-approved estimates,
not current universal pricing or an automatically enforced Azure spending cap.
Stopping a terminal does not stop billing for resources it already created.

Archiving the stopped session subsequently removed its worktree, including its
ignored environment file, while Azure resources could still exist. For
disposable agent sessions, keep the approved private `ENV_FILE` in durable,
owner-only storage outside the worktree. Do not assume an ignored file will be
preserved by session archival, and do not recover convenience by committing
credentials. A new session must distinguish missing local configuration from a
missing Azure lab before creating resources or changing credentials.

## Stopping an agent does not stop Azure

The original deployment terminal and read-only watcher were interrupted, and
process inspection confirmed that no local deployment process remained. No cloud
operation was cancelled and no resource was stopped, deallocated or deleted.
Stage `10` had already been submitted automatically after stage `00` finished,
so Azure could continue it after the local agent stopped.

The stage `10` host restart and VM-agent readiness wait happen in the local
wrapper after the cloud deployment returns. At the stop handoff those steps
were not verified. An `exitCode` of `0` alongside a **Running** Run Command is
not a completion receipt. The next operator must inspect the live deployment
and Run Command, avoid competing executions, and follow the documented
[interrupted-stage recovery](00-agent-bootstrap.md#resume-an-interrupted-or-failed-build)
before advancing.

## Agent workflow and remaining improvements

Collect the Azure target, cost approval and secure configuration once. After
approval, use documented defaults and continue autonomously; do not turn
routine infrastructure choices into repeated learner questions. Ask again only
for a real permission/configuration blocker, a material cost change or a
destructive action outside the approved scope.

The independent agent made no code changes before stopping. Besides the
Bastion correction above, it recommended:

- Adding regional and VM-family quota checks to preflight, so this does not
  require a separate manual lookup.
- Saving an end-to-end machine-readable readiness receipt covering all stages,
  the final guest/SQL/cluster checks and separate access status. Existing guest
  operation evidence and transcripts are not a complete lab-level receipt.

These remain recommendations, not implemented capabilities or reasons to
claim the stopped run succeeded. Keep private environment files out of Git,
restrict their permissions, and never publish raw credential-bearing
transcripts as readiness evidence.

## Fresh-agent recovery and completed stages `10`-`60`

A new agent exercised baseline `ca0e89d9b9e59241952bf7a1724f9ae882d263d5`
on 2026-09-16 using the repository runbooks. This was recovery of the existing
test allocation, not authorization for another lab or a clean-from-zero replay.
The approved target was `rg-arc-cleanroom-20260916`, host `jscr0916-host`, in
`westus2`. The separate working lab was not read or changed.

Initial read-only inspection found foundation and the original stage `10`
execution terminal and successful, with no stages `20`-`60` submitted. The
archived session's ignored configuration was gone, so the local wrapper restart
gate could not immediately be replayed. After the user explicitly authorized
recovery, the agent:

- Generated replacement host, DSRM and SQL-service secrets without displaying
  them, retained the documented nested-image credential, and created an
  owner-only durable environment file outside the disposable worktree.
- Used Azure's supported VM user update to reset only the existing test host's
  `jumpstart` local administrator. It did not extract secrets from transcripts,
  use another lab's configuration, change public access or rebuild resources.
- Ran source validation and infrastructure preflight successfully.
- Replayed the supported stage `10` wrapper to complete its restart/VM-agent
  gate, then used `20-30`, followed by `40`, `45`, `50` and `60`. No duplicate
  pipeline or competing Managed Run Command was launched.

### Execution evidence

Every new Managed Run Command was terminal with exit code `0`:

| Command | UTC start | UTC end |
|---|---|---|
| `stage10-init-host` | `14:20:20` | `14:20:32` |
| `stage30-images` | `14:21:54` | `14:23:28` |
| `stage20-host-network` | `14:22:38` | `14:22:53` |
| `stage40-nested-vms` | `14:24:41` | `14:36:04` |
| `stage45-sql-install` | `14:37:38` | `14:52:59` |
| `stage50-domain` | `14:54:18` | `15:09:30` |
| `stage60-sql-ag` | `15:11:09` | `15:19:08` |

The overlap is visible in the stage `30` and `20` timestamps. All numbered ARM
deployments through `60` also reported `Succeeded`.

### Ready-environment evidence

| Area | Observed result |
|---|---|
| Guests | All five intended VMs were running. Each Windows guest completed native setup and reported successful Server Standard KMS activation. An independent host check found Ubuntu heartbeat `OK`, address `192.168.128.101` and TCP `22` reachable. |
| SQL installation | The three parallel workers passed live verification for SQL Server 2025 Enterprise Developer, integrated sysadmin access, bundled `sqlcmd` 17 and native SQL WMI. |
| Domain | `jumpstart.lab` promotion succeeded. ADWS, AD-integrated DNS and LDAP locator discovery passed; all four Windows computer objects were enabled, and each SQL member passed DC discovery. |
| Cluster and quorum | Native cluster verification and the quorum operation completed with independently recorded local-process exit `0` evidence. Stage `60` requires both intended nodes and the configured witness online before succeeding. |
| AG and database | `JS-AG-01` reported `JS-SQL-AG-01` primary and `JS-SQL-AG-02` secondary, both healthy. The saved gate required `JumpstartDB` to become synchronized and healthy on the local secondary before continuing and rejects suspended/offline AG resources. |
| Listener | `ArcJumpstart-VerifyListener` completed with verified local-process exit `0` from `JS-SQL-01`. This gate checks `JS-AG-LSTN.jumpstart.lab`, expected IP `192.168.128.21`, TCP `1433` and an integrated-authentication query against `JumpstartDB`. |
| Standalone sample | Stage `60` created or retained and verified `JumpstartStandaloneDB` online before listener verification. |
| Learning boundary | No `Microsoft.HybridCompute`, `Microsoft.AzureArcData`, `Microsoft.OffAzure` or `Microsoft.Migrate` resources existed in the test resource group. Arc onboarding, collectors and migration were not performed. |

This is strong evidence for the current stages `10`-`60`, including a fresh
generalized Windows parent, untouched guests and the first fresh parallel SQL
installation run. It is still not a complete clean-from-zero proof: stage `00`
and the first host submission came from the stopped earlier attempt, including
its legacy inline Bastion. The newer independent asynchronous Bastion path was
not exercised or monitored in this recovery.

### Implemented documentation corrections

- The [bootstrap runbook](00-agent-bootstrap.md#inputs-to-obtain-once) now
  describes safe missing-configuration inspection and the authorization boundary
  for credential recovery.
- The [AG build sequence](02-sql-ag-lessons.md#the-intended-build-sequence) no
  longer says to run every stage serially, which contradicted `all` and the
  supported `20-30` recovery overlap.

### Operator experience and recommendation status

1. **Preserve configuration continuity — implemented.** The bootstrap,
   prerequisites, README, and script reference now require a durable owner-only
   `ENV_FILE` outside disposable worktrees and explain its credential mapping.
2. **Document the authorized host-credential recovery that was required.** Add
   a bounded procedure to `docs/06-troubleshooting-cleanup.md` for an existing
   host whose local administrator secret is lost. It must require the exact
   target and reset approval, preserve the username and other resources, and
   finish with the supported stage `10` replay. The successful manual reset in
   this attempt should not remain knowledge available only in this report.
3. **Persist a stage `10` wrapper completion receipt.** ARM and script success
   did not prove that the interrupted wrapper performed its restart and agent
   wait. A durable wrapper-level receipt would make that distinction
   machine-readable.
4. **Keep progress visibility bounded and redacted — implemented.** On this baseline,
   `stage-log` safely returned a transcript tail but could itself take about a
   minute because its new Action Run Command queued behind the active stage.
   Stage `40` also displayed transient credential errors before successful
   first-boot completion, which looked alarming without phase context. Main
   commits `558d458` and `95ae18c` added timestamped phase messages. The
   `lab.ps1 stage-progress` command now reads the active Managed Run Command's existing
   instance view instead of entering the busy VM channel. A subsequent fresh
   build returned stage `10` disk/feature phases and live stage `30` file,
   percentage and throughput immediately. Continue exercising it through the
   guest, SQL, domain and AG stages; use `stage-log` only for the longer
   terminal-stage transcript view.

No infrastructure source repair was needed during stages `10`-`60`. The
remaining acceptance gap is one fresh approved invocation beginning at stage
`00` on the corrected baseline, including asynchronous Bastion submission and
the completed core pipeline. Resources remain allocated and billable until the
user chooses to stop or remove them.
