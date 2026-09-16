# Agent bootstrap: deliver the practice environment

## Objective and boundary

Automate the infrastructure so the learner can start with Arc installation,
not spend the session preparing servers. The agent owns deployment, monitoring,
safe recovery and readiness verification through stage `60`.

| Automated preparation | Learner-led exercises afterward |
|---|---|
| Azure host, networking, disks and images | Arc-enabled server onboarding |
| Nested Windows/Linux guests | Azure extension for SQL Server onboarding |
| Windows setup/activation and domain services | Arc-based Azure Migrate discovery and assessment |
| Three SQL installations, sample data, cluster, AG and listener | Optional replication, test migration and cutover |

The defaults produce five nested VMs: `JS-DC-01`, `JS-SQL-01`,
`JS-SQL-AG-01`, `JS-SQL-AG-02` and `JS-UBUNTU-01`. The domain is
`jumpstart.lab`; the AG is `JS-AG-01`.

## Inputs to obtain once

Read [prerequisites](01-prerequisites.md) and `deploy.env.example`. Obtain:

- The approved subscription, region, dedicated resource group and name prefix.
- Azure CLI user authentication and the permissions/provider registrations
  required by the prerequisites.
- Approved host size and quota/cost envelope, including default-enabled Bastion.
  Keep Bastion enabled unless the user asks to omit it; it is not a build gate.
- Host, nested-image, DSRM and SQL-service credentials through a secure channel.
  The nested-image password must match the chosen source image.
- Any approved image/media overrides; use the documented defaults otherwise.

The wrappers currently require an Azure CLI **user** identity. Do not imply
that service-principal-based unattended authentication has been implemented.
Missing credentials, permissions, quota or approval are real prerequisites,
not reasons to bypass safeguards.

Once those inputs are approved, use documented defaults and proceed without
repeated routine confirmation questions. See the
[first clean-room attempt](02-clean-room-lessons.md) for observed region/quota,
Bastion and interrupted-run lessons, and recommendations not yet implemented.

Create the ignored configuration file only if it does not already exist:

```bash
if [[ ! -f deploy.env ]]; then
  cp deploy.env.example deploy.env
fi
```

Populate it without displaying secret values. It contains literal `KEY=value`
data, not shell code: do not `source` it, add `export`, or surround values with
shell quotes. An alternative private file can be selected with `ENV_FILE`;
use the same file consistently for all wrappers. See the [script reference](../scripts/README.md).

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

## Default: run the saved automation

From the repository root, after configuration and Azure authentication:

```bash
./scripts/validate.sh &&
./scripts/preflight.sh infra &&
./scripts/deploy.sh all
```

The `&&` chain prevents deployment after failed source validation or preflight.
The deployment wrapper does not itself invoke those two entry points.

### Responsive agent execution

An attached agent must run the chain in a dedicated visible terminal or an
asynchronous process supplied by its host environment. The deployment remains
a foreground process in that terminal, but the conversational agent must not
block its own turn waiting for it. Record the exact `ENV_FILE`, command and
terminal/process identity, then return control to the user immediately.

Do not use `sleep`, `watch`, repeated terminal reads or a polling loop to occupy
the conversation while Azure works. Do not launch an observer Run Command or
another deployment to make a healthy operation more visible. Answer user
questions promptly. On a status request, perform one bounded query and return
the result:

```bash
ENV_FILE=/absolute/private/path/lab.local.env ./scripts/lab.sh build-status
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
between stages. Stage `30` downloads approximately 38 GiB of images; stage `45`
downloads SQL media once and installs on three guests in parallel. A quiet
terminal is not proof of a hang, and a running VM is not proof that SQL is ready.

Use `./scripts/lab.sh build-status` as the normal one-shot check during long
operations. Use `./scripts/lab.sh stage-progress <stage>` when the relevant
stage is already known. Both read existing Managed Run Command instance views
and return immediately with state, elapsed time and bounded latest timestamped
output. Neither launches another command inside the busy VM, and no storage
account is required.
Report the last observable step and wait reason rather than only saying that a
script is running. Use the longer host-side `stage-log` view after the stage is
terminal. Do not tight-poll or confuse repeated wait messages with proof of
forward progress.

For a stopped build whose host is ready but `20`/`30` have not been submitted,
use `./scripts/deploy.sh 20-30` to retain their overlap rather than running two
serial commands. If either operation is already active, inspect it and use the
appropriate individual recovery boundary; do not launch a competing pair.

Use the [infrastructure map](../infra/README.md) for the stage-to-script mapping
and the [deployment guide](02-deploy.md) for implementation details.

## Resume an interrupted or failed build

1. Establish the last successful stage and whether an Azure command or guest
   operation is still active. Do not start a competing execution.
2. Use `./scripts/lab.sh stage-log 60`, substituting the affected stage number,
   and inspect its execution result and retained guest evidence securely.
3. Correct the first actual failure. Apply the [AG lessons](02-sql-ag-lessons.md)
   and [domain recovery boundaries](02-domain-controller.md#failures-evidence-and-safe-retries),
   not a guessed symptom-based repair.
4. Persist any necessary implementation fix and regression coverage in this
   repository. Document justified operator recovery actions.
5. Rerun the affected stage, then its successors. For example, after a stage
   `50` failure is corrected:

   ```bash
   ./scripts/deploy.sh 50 &&
   ./scripts/deploy.sh 60
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

## Definition of ready

Do not hand off solely because the outer VM exists or an ARM deployment says
`Succeeded`. Verify the following, using the linked runbooks and actual results.

| Area | Required handoff state |
|---|---|
| Deployment | Stages through `60` succeeded; asynchronous script executions are terminal with exit `0`; no unresolved installer or configuration operation remains. |
| Guests | The five intended nested guests exist and are running; Linux boot/access is usable, and the four Windows guests completed native setup and activation. |
| Domain | Expected domain, DNS locator records, SYSVOL/NETLOGON and SQL service account; SQL members have healthy secure channels. |
| SQL | Three SQL Server 2025 Enterprise Developer instances with intended administrative access; both AG engines use the configured domain service identity. |
| Cluster | Both intended nodes `Up`, correct cluster computer account and configured file-share witness online. |
| AG | One primary and one secondary; `JumpstartDB` synchronized, healthy and not suspended on both. |
| Listener | Intended DNS/IP and TCP `1433`, plus an actual integrated-authentication SQL query from the standalone guest to the primary database. |
| Migration sample | `JumpstartStandaloneDB` online on `JS-SQL-01`. |
| Learning boundary | No Arc onboarding, collector installation or migration has been performed by bootstrap. |

Use [domain verification](02-domain-controller.md#verify-the-domain-and-members)
and [AG verification](02-deploy.md#verify-the-availability-group). Note that
`lab.sh status` reports the **outer host's power state**, not this whole contract.

## Handoff and evidence

Provide the configured resource group/host, guest roles, successful stage/run
identifiers, actual readiness results and any limitations. Do not include
credentials or raw transcript headers.

The normal diagnostic locations are:

- Host transcripts: `C:\ArcJumpstart\Logs`.
- Cluster reports: `C:\ArcJumpstart\Logs\ClusterValidation` on AG01.
- Local operation receipts: `C:\ArcJumpstart\Operations\<operation>\<attempt>`
  on the relevant guest.

Raw artifacts remain sensitive. Use the redacting viewer, review exports and
record reusable lessons in the repo rather than requiring a future agent to
find this session's private files.

Stop at the ready-environment boundary. The next guides are
[Arc onboarding](03-arc-onboarding.md), [assessment](04-assessment.md) and
[optional migration](05-migration.md). Follow them with the learner when asked,
not automatically as part of provisioning.

## Acceptance of the automation itself

The existing development lab and a separate fresh Windows-template proof
succeeded. That is not a complete clean replay of the updated pipeline.

The outstanding repeatability gate is a fresh, approved deployment using only
this repo and supplied configuration, including fresh parallel SQL installs.
If it requires a new repair, capture that repair in code and documentation
before claiming reproducibility. Do not substitute more manual instructions
for automation of routine provisioning.
