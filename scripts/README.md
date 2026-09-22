# Script entry points

Run these Bash/Python entry points from the repository root on macOS, Linux or
WSL2. They drive the Bicep stages and host-side Windows automation. Do not run
the Hyper-V/AD PowerShell artifacts directly on the workstation.

On Windows, WSL2 is required for `preflight.sh`, `deploy.sh` and `lab.sh`.
Git Bash/MSYS2/Cygwin are source-validation environments only; the operational
wrappers reject them before accessing Azure. Install Azure CLI and Python
inside WSL2 and keep the repository and private environment file in the WSL
filesystem. Do not combine Windows-native tools with WSL commands. See the
[Windows prerequisite procedure](../docs/01-prerequisites.md#windows-required-wsl2-setup).

See the [agent bootstrap runbook](../docs/00-agent-bootstrap.md) for the mission,
inputs and required ready-environment outcome.

## Command reference

| Command | Purpose and boundary |
|---|---|
| `./scripts/validate.sh` | Bicep compilation, Bash syntax, Python regression tests and available ShellCheck/PowerShell checks. Does not deploy Azure resources. It may run from Git Bash on native Windows, but that validates source only; full coverage requires the optional tools to be present. |
| `./scripts/preflight.sh infra` | Checks the configured Azure target, required infrastructure registrations, host SKU availability and download reachability; prints cost considerations. Does not provision the lab or automatically register providers. |
| `./scripts/preflight.sh full` | Also checks registrations for the later Arc/assessment/migration exercises. Does not perform those exercises. |
| `./scripts/deploy.sh all` | Runs the complete saved infrastructure sequence through stage `60`. Intended for a new lab, not blanket repair of an existing domain. |
| `./scripts/deploy.sh 60` | Runs one supported stage. Other numbers are `00`, `10`, `20`, `30`, `40`, `45` and `50`. Use for scoped recovery and then continue with successors. |
| `./scripts/deploy.sh 20-30` | Starts image downloads and configures the independent host network while they run, then requires successful download completion. Requires a ready stage `10` host; do not use while either earlier operation is active. |
| `./scripts/deploy.sh bastion` | Submits only the independent Bastion deployment with `--no-wait`, against an existing foundation network. Explicitly requests Bastion even when `DEPLOY_BASTION=false`; requires only the four Azure target settings, not guest credentials. Does not verify readiness. |
| `./scripts/deploy.sh auto-shutdown` | Creates, updates, enables or disables only the outer host's daily Azure auto-shutdown schedule. It never replays host initialization or nested infrastructure stages. |
| `./scripts/deploy.sh arc-launchers` | Creates/tags the dedicated Arc resource group and securely stages **Connect to Azure Arc** on all four Windows guest public desktops. It does not connect any machine; the learner completes device-code authentication interactively. |
| `./scripts/lab.sh status` | Reports outer host power state only; not whole-lab readiness. |
| `./scripts/lab.sh build-status` | Discovers every active canonical stage and displays each existing Managed Run Command instance view. If none is active, displays the most recently started stage. Does not launch a VM command. |
| `./scripts/lab.sh stage-log 60` | Displays the latest stage transcript through `show-stage-log.py`, suppressing startup headers and redacting configured sensitive values. Raw host files remain sensitive. |
| `./scripts/lab.sh stage-progress 40` | Reads the active Managed Run Command's existing instance view and returns state, start/end, elapsed time and latest redacted output. It does not launch another command inside the busy VM. |
| `./scripts/lab.sh stop` / `start` | Deallocates or starts the outer Azure host. Deallocation does not stop storage/Bastion charges; keep the host allocated during replication/migration. |
| `./scripts/lab.sh retire-source JS-SQL-01` | Stops and marks a migrated source retired. Also supports `JS-UBUNTU-01`. Use only as part of an authorized cutover. |
| `./scripts/lab.sh delete-infra YOUR_RESOURCE_GROUP` | Deletes the configured infrastructure RG only when the argument matches it. Requires explicit deletion approval and the wider cleanup sequence first. |
| `python3 scripts/check-sql-media.py --help` | Optional local media diagnostic; stage `45` already performs its own media checks. |

## Normal automated setup

With a populated owner-only environment file outside the repository and an
authenticated Azure CLI user:

```bash
ENV_FILE=/absolute/private/path/lab.env
./scripts/validate.sh &&
ENV_FILE="$ENV_FILE" ./scripts/preflight.sh infra &&
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh all
```

Azure CLI and Python 3 are required. The wrapper currently rejects service
principal authentication. Authentication, permissions and the cost envelope
must be supplied/approved before provisioning.

Bastion is enabled by default. `all` and `00` submit it independently after the
core network deployment completes, then return to the numbered sequence without
waiting for access readiness. Setting `DEPLOY_BASTION=false` omits that request.
Resuming stages `10`-`60` never submits, polls or waits for Bastion. An optional
submission error is printed as a warning without failing the core sequence;
`deploy.sh bastion` used on its own returns a failed submission's nonzero exit
status. After Azure accepts the request, the build does not monitor it.
Azure retains any later provisioning errors in the independent deployment;
they are not reflected in the exit code of a successful submission.

The wrappers do not source the environment file as shell code. Use literal
`KEY=value` lines without quotes or `export`. Do not print the file or put it
in version control. The ignored repository-root `deploy.env` is retained as a
compatibility fallback; durable external storage is recommended, especially
for disposable worktrees.

`AUTO_SHUTDOWN_ENABLED` has no implicit default. For every new lab, ask the
operator whether to enable it and record `true` or `false`. When enabled,
`AUTO_SHUTDOWN_TIME` is a 24-hour `HHmm` value and
`AUTO_SHUTDOWN_TIME_ZONE` is a Windows time-zone ID. The example suggests
`2200` and `Central Standard Time`, but both are operator decisions. Change the
policy later with `./scripts/deploy.sh auto-shutdown`; do not rerun stage `10`.

`deploy.sh all` stages the Arc desktop launchers after stage `60` by default.
Set `PREPARE_ARC_LAUNCHERS=false` to opt out. Staging does not install or
connect Arc; it only places the clickable helper and approved non-secret Azure
target identifiers on the guest desktops. `ARC_RESOURCE_GROUP` defaults to
`<AZURE_RESOURCE_GROUP>-arc`, and `ARC_LOCATION` defaults to
`AZURE_LOCATION`; either can be overridden.

## Live progress from the host

Stage scripts retain their detailed transcripts under `C:\ArcJumpstart\Logs`.
They emit timestamped messages at meaningful boundaries such as image download,
guest OOBE, SQL worker state, domain promotion, native cluster validation,
automatic seeding and listener verification. No storage account or external log
service is required for this workshop.

An attached agent should normally inspect a running build with:

```bash
ENV_FILE=/absolute/private/path/lab.local.env ./scripts/lab.sh build-status
```

It discovers all concurrently active canonical stages, including overlapping
stages `20` and `30`. If no stage is active, it reports the most recently
started one. Use `stage-progress 40` when the desired stage is already known.
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
display. They do not rewrite the raw host transcript, which remains sensitive.

All three operational wrappers support an alternative environment file:

```bash
ENV_FILE=/absolute/private/path/lab.local.env ./scripts/preflight.sh infra &&
ENV_FILE=/absolute/private/path/lab.local.env ./scripts/deploy.sh all
ENV_FILE=/absolute/private/path/lab.local.env ./scripts/lab.sh status
```

Replace that path with the approved file. Use a consistent configuration for
deployment, status and recovery; a status command against a different resource
group does not describe the build being monitored.

## Completion and recovery

`deploy.sh` enforces stage predecessors. Stage `10` includes a host restart and
agent wait. `all` and `20-30` submit the image Run Command before configuring
the independent internal network, then join the fresh image execution before
proceeding. Individual `30` and stage `45` still wait for their new asynchronous
Run Command and require exit `0`; do not return core-stage success when only
submission succeeded. If the wrapper stops while images are outstanding, Azure
may continue downloading; inspect the command before retrying.

Use the stage number that failed, not a second `all` invocation, to resume.
For example:

```bash
./scripts/lab.sh stage-log 50
# Resolve the first failure using saved source and the domain runbook.
./scripts/deploy.sh 50 &&
./scripts/deploy.sh 60
```

Do not start another installation or configuration operation while earlier work
is active or its completion is unknown. Do not use stage `40` to repair a
promoted DC. Detailed retry boundaries are in the
[AG lessons](../docs/02-sql-ag-lessons.md#recovery-workflow-for-the-next-operator)
and [cleanup guide](../docs/06-troubleshooting-cleanup.md).

## Regression coverage

`validate.sh` invokes `test-check-sql-media.py`, `test-runtime.py`,
`test-skill.py`, `test-stage-log.py`, `test-bastion.py`, and, when
PowerShell is available, `test-stage40.ps1`, `test-stage45.ps1`,
`test-stage50.ps1` and `test-stage60.ps1`.

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
