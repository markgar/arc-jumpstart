# Agent bootstrap: deliver the practice environment

## Objective and boundary

Automate the infrastructure so the user reaches the required interactive
Arc handoff: installing and connecting Arc with their own Azure identity. The agent
owns deployment, monitoring, safe recovery, readiness verification through
stage `60`, and staging the Arc launchers.
The optional licensed SQL path also pauses for user-owned media acquisition
and upload after the host is ready. This is an intentional input boundary,
not a requirement to automate workstation-to-private-network file transfer.

| Agent-prepared prerequisite | User/workshop action afterward |
|---|---|
| Azure host, networking, disks and images | Open the staged launcher and authenticate Arc |
| Nested guests, Windows setup and domain services | Perform or reuse an assessment |
| Four Database Engine and two SSAS installations, sample data, cluster, AG and listener | Export Resource Graph modeling data |
| Arc resource group, SQL licensing tag and desktop launchers | Migrate `JumpstartStandaloneDB` to SQL Managed Instance |

The defaults produce eight nested VMs: `JS-DC-01`, `JS-SQL-01`,
`JS-SQL-AG-01`, `JS-SQL-AG-02`, `JS-RETAIL-01`, `JS-INSIGHT-01`,
`JS-UBUNTU-01` and the unused `JS-MIGRATE-01`. All Windows guests and the
Marketplace host use Server 2025; no custom host image is required. The domain is
`jumpstart.lab`; the AG is `JS-AG-01`.

## Inputs to obtain once

Read [prerequisites](01-prerequisites.md) and `deploy.env.example`. Obtain:

- The approved subscription, region, dedicated resource group and name prefix.
- Azure CLI user authentication and the permissions/provider registrations
  required by the prerequisites.
- Approved host size and quota/cost envelope, including default-enabled Bastion.
  Keep Bastion enabled unless the user asks to omit it; it is not a build gate.
- Host, DSRM and SQL-service credentials through a secure channel.
  New Windows guests always use the public lab-only password `JS123!!`.
- One shared SQL `sa` password for the four Database Engines:
  `init-config.ps1` generates `SQL_SA_PASSWORD` once per new private configuration.
  Keep that 52-character value; do not generate a different password per guest
  or reuse another lab credential. Installation enables mixed mode and retains
  Windows administrator access. SSAS has no `sa` login.
- Any approved image/media overrides; use the documented defaults otherwise.
- Before deploying, explicitly ask whether to use default SQL Developer or
  the user's own licensed SQL Server 2025 Standard and Enterprise ISOs.
  Record that choice in `SQL_EDITION_MODE`. The licensed option requires approved pre-keyed ISOs and the
  [private media checkpoint](../scripts/README.md#licensed-sql-media), not a
  manual SQL installation or a public storage exception.

### Licensed-media conversation and handoff

If the user already uploaded authorized media for a previous lab, ask whether
to reuse that account instead of uploading again. Record its approved resource
group and account in `SQL_MEDIA_RESOURCE_GROUP` and `SQL_MEDIA_ACCOUNT_NAME`.
The existing account/container/settings are only referenced; the new lab gets
its own private endpoint and host read role. Valid existing media is checked
after stage `10`, then `all` continues automatically without an upload pause.
Never infer permission to share another lab's storage from its existence.

If the user chooses their own ISOs, explain before deployment that the build
will pause after the host and private storage are ready unless they approved
reuse of existing media. For a new upload, offer both supported
routes: select the ISOs with `Upload licensed SQL media.cmd` on the outer host,
or upload both directly into the root of its configured `sql-media` container
using approved private connectivity. Do not imply that a desktop uploader is
the only supported route.

At the pause, report the actual host, storage account, media resource group,
container name and Blob URL from the deployed foundation outputs. Ask which
upload route the user prefers and guide that route. Direct uploads must have
their original Microsoft `enu_sql_server_2025_<edition>_edition_x64_dvd_<id>.iso`
names or `SQL2025-Standard.iso` / `SQL2025-Enterprise.iso`, one per edition,
not inside a virtual folder. Never request media keys or file contents in chat,
make storage public, or require new workstation networking.

When the user says both uploads are finished, the agent runs `deploy.ps1 continue`
asynchronously with the same private `ENV_FILE`. It first reads any existing
manifest. Only a confirmed `BlobNotFound` starts root discovery, signature and
pre-keyed-media validation, SHA-256 calculation, and create-only manifest
publication. This uses the current Azure CLI operator's storage token through
protected parameters; the host managed identity retains read-only access.
The user does not write the manifest manually. If an ISO is missing, ambiguous,
or invalid, explain the exact correction and retain completed infrastructure.
After it is corrected, retry the same media checkpoint, not `all`.

For the default `IMAGE_MODE=installation-media`, the Windows password `JS123!!`
is set during initial setup, not inherited from a VHDX. Obtain approved Windows
Server 2025 Evaluation and Ubuntu
ISO sources and the operator's Linux SSH public key; never collect a
private key. The official Windows default is downloaded and publisher-verified
on the Azure host, with a recorded/rechecked fingerprint; custom Windows media
and Ubuntu require approved checksums. The configuration helper creates a local
operator key when needed. The same normal deployment chain builds the disks without
Jumpstart images or user-hosted Blob storage. This experimental path still
requires a full clean-build proof; see
[image preparation and recovery](../scripts/README.md#installation-media-images).

The wrappers currently require an Azure CLI **user** identity. Do not imply
that service-principal-based unattended authentication has been implemented.
Missing credentials, permissions, quota or approval are real prerequisites,
not reasons to bypass safeguards.

Before collecting deployment inputs, establish the execution runtime. The
cross-platform path uses PowerShell 7 and Azure CLI in the same host OS
(Windows, macOS or Linux); WSL2 is not required. Run the
PowerShell entry points from this repository checkout on the same host OS
as Azure CLI. See [workstation prerequisites](01-prerequisites.md#workstation).

Once those inputs are approved, use documented defaults and proceed without
repeated routine confirmation questions. See the
[clean-room lessons](02-clean-room-lessons.md) for observed region/quota,
Bastion and interrupted-run evidence, and current recommendation status.

## Default decisions and required questions

Apply these defaults for a requested new lab. Users may override any
non-safety setting:

| Decision | Default |
|---|---|
| Azure identity | Current authenticated Azure CLI user |
| Region | `westus2` |
| Resource-group root | `rg-arc-jumpstart-v2` |
| Infrastructure resource group | `rg-arc-jumpstart-v2-infra` |
| Arc resource group | `rg-arc-jumpstart-v2-arc` |
| Name prefix | `jsarc` |
| Host size | `Standard_E16s_v7` |
| Host OS | Standard Azure Marketplace Server 2025 Datacenter Gen2 (`2025-datacenter-g2`), non-Hotpatch with manual patching; no custom image |
| Nested Windows OS | Server 2025 Datacenter Evaluation, build 26100, prepared from ISO |
| Reserved appliance guest | `INCLUDE_APPLIANCE_VM=true`: unused `JS-MIGRATE-01`, 8 vCPUs, 16 GiB RAM, 80-GiB disk; no appliance install/registration, domain join, SQL or Arc |
| Host data disk | 1 TiB Premium SSD |
| Browser access | Bastion enabled and submitted independently |
| Images and SQL media | URLs and file names in `deploy.env.example` |
| SQL edition | Ask before provisioning: default Developer, or the user's pre-keyed Standard and Enterprise ISOs |
| Configuration | Durable owner-only file outside the repository |
| Host, DSRM and SQL service passwords | Generate unique strong values directly in the approved private file when the user has not supplied them |
| SQL `sa` password | Keep the single generated `SQL_SA_PASSWORD` in the private file and use it for all four Database Engines; never print it or rotate it on retry |
| Nested Windows password | Always `JS123!!` for new guests; public lab-only credential, never for host/DSRM/SQL service |
| Auto-shutdown | Ask whether to enable it, and if enabled ask for the daily time and time zone; never infer consent from repository defaults |
| Arc desktop launchers | Stage on the six Windows workload guests, not the reserved appliance VM; they remain inert until the user authenticates. Allow `PREPARE_ARC_LAUNCHERS=false` as an override |
| Execution | Validation, infrastructure preflight and `deploy.ps1 all` in a separate terminal or asynchronous process |
| User boundary | Stop after staging launchers; do not connect Arc, run assessment or migrate data |

The agent still requires explicit approval for the Azure subscription and
dedicated resource group, the billable footprint and applicable licensing
scope. Auto-shutdown is also an explicit setup choice because it can interrupt
active learner, replication or migration work. If the target resource group or matching lab resources already exist,
stop and establish new deployment versus recovery; never reuse or replace them
implicitly. Ask again when a region/SKU fallback changes residency or cost, or
when recovery requires deletion, rebuild, credential reset or another
destructive action.

Do not ask the user to choose routine implementation details already represented
by these defaults. Discover Azure CLI state, SKU availability, source
reachability and existing-resource state directly. A failed preflight is a
reason to present the specific blocked decision, not to restart the entire
questionnaire.

Keep the configuration in approved durable, owner-only storage outside the
repository. For new labs on Windows, macOS, Linux, and WSL2, use the visible
`$HOME/ArcJumpstart/<root>.env` location, named after the approved root.
New labs use `<root>-infra` and `<root>-arc` resource groups.
Do not create configuration in hidden
folders. Preserve an existing lab's exact `ENV_FILE`; do not silently move or
overwrite it. A user-approved alternative for a new lab must also be visible.

```powershell
$env:ENV_FILE = $null # Clear a previous lab's override before creating a new file.
./scripts/init-config.ps1 -ResourceGroupRoot rg-arc-jumpstart-v2
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/rg-arc-jumpstart-v2.env'
```

Suggest `rg-arc-jumpstart-v2`, but let the user choose the approved root.
Initialization records `RESOURCE_GROUP_ROOT`; the runtime derives
`AZURE_RESOURCE_GROUP=<root>-infra` and `ARC_RESOURCE_GROUP=<root>-arc`.
The suffixes are fixed for root-based configurations.
An explicit `ENV_FILE` overrides the generated path; existing files,
including `lab.env`, are never renamed or overwritten.
Files without `RESOURCE_GROUP_ROOT` retain their existing explicit targets.
Before creating any resources, `deploy.ps1 all` checks both target groups in
the configured subscription. An existing group or failed lookup blocks a fresh
deployment; use the documented stage-specific recovery path instead.

Populate it without displaying secret values. It contains literal `KEY=value`
data, not shell code: do not `source` it, add `export`, or surround values with
shell quotes. Set `ENV_FILE` to the chosen absolute path and use the same file
consistently for all wrappers. The legacy ignored repository-root `deploy.env`
remains a fallback, but it is not recommended for disposable worktrees. See the
[script reference](../scripts/README.md).

For disposable worktree sessions, keep that private `ENV_FILE` in approved
durable storage outside the worktree with owner-only permissions. Session
archival can remove ignored workspace files without stopping the Azure lab.
Preserve secure configuration access for the next operator; never commit
credentials to avoid this problem.

If an existing lab's configuration was lost, first inspect Azure deployment and
Managed Run Command states using the explicitly approved subscription, resource
group and host. These read-only queries do not require the lab passwords. Ask
for the approved durable file path without asking the user to paste secrets in
chat. Do not copy another lab's configuration, retrieve passwords from raw
transcripts, or generate a replacement host password and replay stage `10` as
though it were the original. A lost host credential requires a separately
authorized credential-recovery/reset procedure. Until configuration is restored,
leave submitted operations and resources intact; the lab remains billable.

For a second deployment, use a separately approved target and configuration.
Do not silently reset or overwrite the existing practice lab.
If the previous lab was fully deleted and the operator approves rebuilding the
same target, its existing private `ENV_FILE` and credentials may be reused
without running `init-config.ps1` again. Verify the target resource groups are
absent before starting a fresh `all`. This is different from a concurrent
second lab, which needs a distinct approved resource group and private file.
Neither case permits replaying `all` to repair a still-promoted domain.

## Default: run the saved automation

From the repository root, after configuration and Azure authentication:

```powershell
./scripts/validate.ps1
./scripts/preflight.ps1 infra
./scripts/deploy.ps1 all
```

Only start the next command after the prior one succeeds; do not run deployment
after failed source validation or preflight.
The deployment wrapper does not itself invoke those two entry points.

With `SQL_EDITION_MODE=licensed`, exit `2` after stage `10` is the explicit
user-media handoff, not completion or a provisioning failure. Use the staged
host upload launcher, then `deploy.ps1 continue`. This continuation preserves
the `20`/`30` overlap and never replays `00`/`10`. Do not use it again after
any later stage was submitted; inspect and recover the actual failed stage.
For an explicitly requested new-OS trial, replace `all` with `os-only` in the
same validated/preflighted chain. It uses the same fresh-target safety checks,
stages the SQL upload helper after `10`, and continues through `40` without
requiring SQL media. It creates no SQL installation, domain or Arc connection.
After a successful OS trial and licensed-media upload, `continue` resumes at
`45` without repeating OS preparation; failed/partial trials require scoped
recovery instead.
The default Developer path has no media-upload pause. In licensed mode the user
obtains the ISOs from their authorized source on the prepared host, then uses
the upload helper. Do not block infrastructure creation on transferring local
workstation copies or add a VPN/Bastion upgrade for that purpose. Basic Bastion
is not a file-transfer tunnel; any alternative private transfer is separately
user-arranged and must not require public Blob access.

### Responsive agent execution

An attached agent must run the chain in a dedicated visible terminal or an
asynchronous process supplied by its host environment. The deployment remains
a foreground process in that terminal, but the conversational agent must not
block its own turn waiting for it. Record the exact `ENV_FILE`, command and
terminal/process identity, then return control to the user immediately.

Use the PowerShell entry points for deployment, status and recovery.

Do not use `sleep`, `watch`, repeated terminal reads or a polling loop to occupy
the conversation while Azure works. Do not launch an observer Run Command or
another deployment to make a healthy operation more visible. Answer user
questions promptly. On a status request, perform one bounded query and return
the result:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/rg-arc-jumpstart-v2.env'
./scripts/lab.ps1 build-status
```

`build-status` discovers every concurrently active canonical stage, so the
caller does not need to know that stages `20` and `30` are overlapping. If
nothing is active, it reports the most recently started stage. During stage
`00`, preflight or a local wrapper-only boundary such as the stage `10` restart,
there may be no active Managed Run Command; report that limitation rather than
starting a diagnostic operation.

Automatic checks are appropriate when the execution host reports command
completion or another material transition. Otherwise wait for a user status
request without holding an agent turn open merely for time to pass.

`all` follows the dependency graph: `00` -> `10` -> overlapping `20`/`30` ->
`40` -> `45` -> `50` -> `60`. It uses Bicep, embeds the saved PowerShell
artifacts, handles the stage `10` host restart, and requires successful image
and network completion before `40`. Do not replace this with a private
sequence of portal edits or one-off scripts.

Bastion is a separate Azure deployment, submitted with `--no-wait` after the
foundation network succeeds. It runs alongside stages `10`-`60`; none of those
stages, nor core-lab completion, waits for its provisioning or success.
The reserved `AzureBastionSubnet` has no Bastion service charge by itself.
Submission errors are reported without stopping the core build. After a
successful submission, let Azure finish it: no monitoring, polling or completion
join is needed. An accepted request is not a claim that browser access is
already available. If access ever needs repair, use the independent deployment
instead of replaying infrastructure stages.

Monitor execution rather than asking the learner to perform routine setup
between stages. In legacy `jumpstart` mode, stage `30` downloads approximately
38 GiB of images. In `installation-media` mode it downloads ISOs and prepares
local disks, and stage `40` also installs Ubuntu. Stage `45`
downloads SQL media once and installs assigned SQL/SSAS features on five guests in parallel. A quiet
terminal is not proof of a hang, and a running VM is not proof that SQL is ready.

Use `./scripts/lab.ps1 build-status` as the normal one-shot check during long
operations. Use `./scripts/lab.ps1 stage-progress <stage>` when the relevant
stage is already known. Both read existing Managed Run Command instance views
and return immediately with state, elapsed time and bounded latest timestamped
output. Neither launches another command inside the busy VM, and no storage
account is required.
Report the last observable step and wait reason rather than only saying that a
script is running. Use the longer host-side `stage-log` view after the stage is
terminal. Do not tight-poll or confuse repeated wait messages with proof of
forward progress.

For a stopped build whose host is ready but `20`/`30` have not been submitted,
use `./scripts/deploy.ps1 20-30` to retain their overlap rather than running two
serial commands. If either operation is already active, inspect it and use the
appropriate individual recovery boundary; do not launch a competing pair.

Use the [infrastructure map](../infra/README.md) for the stage-to-script mapping
and the [deployment guide](02-deploy.md) for implementation details.

## Resume an interrupted or failed build

1. Establish the last successful stage and whether an Azure command or guest
   operation is still active. Do not start a competing execution.
2. Use `./scripts/lab.ps1 stage-log 60`, substituting the affected stage number,
   and inspect its execution result and retained guest evidence securely.
3. Correct the first actual failure. Apply the [AG lessons](02-sql-ag-lessons.md)
   and [domain recovery boundaries](02-domain-controller.md#failures-evidence-and-safe-retries),
   not a guessed symptom-based repair.
4. Persist any necessary implementation fix and regression coverage in this
   repository. Document justified operator recovery actions.
5. Rerun the affected stage, then its successors. For example, after a stage
   `50` failure is corrected:

   ```powershell
   ./scripts/deploy.ps1 50 &&
   ./scripts/deploy.ps1 60
   ```

Do not restart `all` merely to resume stage `50` or `60`: that would also revisit
the workgroup-oriented stage `40`. Do not relabel old generalized-parent
markers, mutate shared parent disks, drop conflicting databases or delete
active-operation evidence.

Stopping the local terminal does not cancel an Azure deployment or Managed Run
Command that was already submitted. Inspect their real states before resuming.
In particular, stage `10` performs its host restart and VM-agent wait in the
local wrapper **after** the cloud deployment returns. If that wrapper was
interrupted, ARM success alone does not prove those steps happened. Wait for the
previous cloud deployment and Run Command to become terminal, then rerun the
supported stage `10` wrapper to finish its restart/readiness gate before `20`.
Do not create a competing stage `10` execution while the old one is running.

Readiness failures should be resolved by the agent within the user's approved
scope. Ask for a decision when credentials/permissions are unavailable or a
repair requires a new cost, destructive reset or material design change.
Routine infrastructure setup is not a learner exercise.

## Measured build duration

Tell the learner: **"Building the environment could take 2 hours."** This estimate
is for the seven-server topology on `Standard_E16s_v7`. Actual time varies with
downloads and any required recovery; two hours is not a guaranteed upper limit.
It is based on one observed build, not a clean-run benchmark.

The September 29, 2026 run started validation at **17:12:43 UTC** and the final
Arc-launcher deployment returned successfully at approximately **19:04:36 UTC**:
**1 hour 51 minutes 53 seconds**, including investigation and scoped retries.
Post-deployment handoff checks are additional. The successful Managed Run Command
execution intervals below exclude ARM submission, wrapper waits and host restart
time; do not add them together to estimate end-to-end duration.

| Operation | Successful execution (UTC) | Duration |
|---|---|---|
| Host initialization (`10`) | 17:19:03-17:21:34 | 2m 31s |
| Networking (`20`) | 17:25:42-17:26:11 | 29s |
| Images (`30`, overlapping `20`) | 17:24:20-17:25:49 | 1m 29s |
| Seven nested guests (`40`) | 17:27:15-17:39:01 | 11m 46s |
| SQL/SSAS recovery (`45`) | 18:10:06-18:16:35 | 6m 29s |
| Domain configuration (`50`) | 18:17:47-18:37:36 | 19m 49s |
| Cluster/AG recovery (`60`) | 18:54:19-18:57:31 | 3m 12s |
| Host SSMS | 18:58:20-19:03:04 | 4m 44s |
| Arc desktop launchers | 19:04:03-19:04:09 | 6s |

The first SQL attempt was submitted at 17:39:39 UTC and failed at 18:03:03 UTC.
Its successful retry retained already installed instances; **6m 29s is not a
fresh five-guest SQL installation estimate**. The first cluster attempt also
failed, at 18:43:48 UTC, on stale OLE DB installed-update metadata. A bounded
metadata refresh preceded the successful retry. See the
[recovery evidence](02-sql-ag-lessons.md). Neither recovery weakened native
readiness or cluster-validation gates.

For subsequent measurements, record the local workflow start/end and each
canonical Run Command's `instanceView.startTime`, `endTime`, `executionState`
and `exitCode` before a retry replaces that attempt. Record failures and
investigation gaps separately. ARM acceptance or deployment timestamps alone
do not measure asynchronous guest execution. A fresh complete run without
these interventions is still required to claim clean end-to-end repeatability.

## Definition of ready

Do not hand off solely because the outer VM exists or an ARM deployment says
`Succeeded`. Verify the following, using the linked runbooks and actual results.

| Area | Required handoff state |
|---|---|
| Deployment | Stages through `60` succeeded; asynchronous script executions are terminal with exit `0`; no unresolved installer or configuration operation remains. |
| Guests | All selected guests exist and are running: eight by default, seven with Linux excluded. Every Windows guest, including the reserved appliance VM, completed native setup, activation, unique-SID and Enhanced Session Mode gates. Verify Linux boot/access only when selected. |
| Reserved appliance VM | When selected, `JS-MIGRATE-01` has 8 vCPUs, 16 GiB RAM, 80-GiB disk and internal-network DHCP access; it remains a workgroup VM without SQL, appliance installation/registration or Arc launchers. |
| Domain | Expected domain, DNS locator records, SYSVOL/NETLOGON and SQL service account; SQL members have healthy secure channels. |
| SQL | Four SQL Server 2025 Database Engine instances of the selected editions, in mixed mode with enabled `sa` and the shared private `SQL_SA_PASSWORD`. Each passes an encrypted TCP `sa` sysadmin query and retains Windows administrative access; both AG engines use the configured domain service identity. `JS-SQL-01` stays engine-only. |
| SSAS | `JS-RETAIL-01` and `JS-INSIGHT-01` run SSAS 2025 Tabular with TCP 2383 reachable from the host; no BI models are deployed. `JS-INSIGHT-01` has no relational engine services, registry instances or orphaned instance files. SSAS application authentication and assessment visibility are separate checks, not implied by a listening port. |
| Cluster | Both intended nodes `Up`, correct cluster computer account and configured file-share witness online. |
| AG | One primary and one secondary; `JumpstartDB` synchronized, healthy and not suspended on both. |
| Listener | Intended DNS/IP and TCP `1433`, plus an actual integrated-authentication SQL query from the standalone guest to the primary database. |
| Relational samples | `JumpstartStandaloneDB` online on `JS-SQL-01`; `JumpstartRetailDB` on `JS-RETAIL-01`. The migration exercise still uses `JS-SQL-01`. |
| Arc handoff | Dedicated Arc resource group and licensing tag exist; **Connect to Azure Arc.cmd** is staged on the six Windows workload guests, excluding the reserved appliance VM. |
| Configuration handoff | The actual full `ENV_FILE` path, execution host, and platform-specific find/view instructions have been explicitly presented to the user without exposing file contents. |
| User boundary | Arc launchers are staged, but no Arc connection, assessment, collector installation or migration has been performed. |

Use [domain verification](02-domain-controller.md#verify-the-domain-and-members)
and [AG verification](02-deploy.md#verify-the-availability-group). Note that
`lab.ps1 status` reports the **outer host's power state**, not this whole contract.

## Handoff and evidence

Provide the configured resource group/host, guest roles, successful stage/run
identifiers, actual readiness results and any limitations. Do not include
credentials or raw transcript headers.

The final user-facing response must include a prominent **Your lab configuration
and passwords** section. This is required even if the location was already
mentioned during setup or printed in a terminal:

- State that the private `lab.env` file contains the lab configuration and
  passwords, and must not be shared or committed.
- Give the actual full absolute path of the file used for this lab, with the
  username expanded. Do not provide only `ENV_FILE`, `$HOME`, `~`, a sample
  path, or a link to documentation. Verify that this file still exists without
  displaying its contents.
- On macOS, give the actual containing folder path for **Finder > Go > Go to
  Folder**, then instruct the user to right-click the file and choose
  **Open With > TextEdit** to view it.
- On native Windows, give the actual full Windows File Explorer path and the
  containing folder to paste into its address bar, and instruct the user to
  open the file with Notepad. The file is under the Windows account's
  `ArcJumpstart` directory unless the user approved another location.
- On Windows/WSL2, give both the absolute WSL path and the full Windows File
  Explorer path. Obtain the actual distribution name from `WSL_DISTRO_NAME`
  in the deployment's WSL environment; do not assume Ubuntu. For a WSL-native
  absolute path, the Windows path is `\\wsl.localhost\<distro>` followed by
  that path with backslashes. Provide the actual containing folder path to paste
  into File Explorer's address bar, and instruct the user to open the file with
  Notepad to view it. Make edits inside WSL and retain mode `600`.
- On Linux, give the containing folder path to open in the file manager and
  instruct the user to view the file with a text editor.
- If the execution host is remote, name it and provide the approved way to
  access the file there. Do not imply a remote path is on the user's laptop.
  If the path or access method cannot be verified, state that handoff blocker
  rather than inventing a location.

Use the real path even for a pre-existing lab in a legacy location. A path
change requires the user's approval; do not create a second configuration just
to match the new convention. The
[user-facing location guide](../README.md#find-your-lab-configuration-and-passwords)
contains platform examples.

The normal diagnostic locations are:

- Host transcripts: `C:\ArcJumpstart\Logs`.
- Cluster reports: `C:\ArcJumpstart\Logs\ClusterValidation` on AG01.
- Local operation receipts: `C:\ArcJumpstart\Operations\<operation>\<attempt>`
  on the relevant guest.

Raw artifacts remain sensitive. Use the redacting viewer, review exports and
record reusable lessons in the repo rather than requiring a future agent to
find this session's private files.

Stop at the ready-environment boundary. The user completes
[interactive Arc setup](03-arc-onboarding.md) with their own identity. The
workshop then follows [assessment and modeling](04-assessment.md) and
[single-database migration](05-migration.md). Do not perform those steps
automatically as part of provisioning.

## Acceptance of the automation itself

The existing development lab and a separate fresh Windows-template proof
succeeded. That is not a complete clean replay of the updated pipeline.

The outstanding repeatability gate is a fresh, approved deployment using only
this repo and supplied configuration, including fresh parallel SQL installs.
If it requires a new repair, capture that repair in code and documentation
before claiming reproducibility. Do not substitute more manual instructions
for automation of routine provisioning.
