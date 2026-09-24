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
| `./scripts/preflight.ps1 infra` / `full` | Checks Azure registrations, host SKU and media reachability. Does not create resources or register providers. |
| `./scripts/deploy.ps1 all` / `20-30` / `<stage>` | Deploys all stages or a scoped recovery stage with predecessor and Run Command gates. |
| `./scripts/deploy.ps1 bastion` / `auto-shutdown` / `arc-launchers` / `ssms` | Independent access, shutdown, interactive Arc-launcher setup and host-only SSMS 22 installation. |
| `./scripts/lab.ps1 build-status` / `stage-progress 40` / `stage-log 40` | One-shot redacted stage views; live views never start a competing VM command. |
| `./scripts/lab.ps1 status` / `start` / `stop` / `inventory` / `delete-infra <RG>` | Host power, modeling export and explicitly confirmed infrastructure cleanup. |
| `./scripts/check-sql-media.ps1` | Optional local HTTPS media download and length/structure/SHA-256 verification; stage `45` has its own checks. |

From a PowerShell 7 terminal, set `$env:ENV_FILE` to the actual external file
path, sign in with `az login`, then run `validate.ps1`, `preflight.ps1 infra`,
and `deploy.ps1 all` **in order**, stopping on any failure. Keep deployment in a
separate terminal or attached asynchronous process. For a new file, use
`init-config.ps1`, then fill it privately before preflight. Do not paste the
configuration or passwords into chat.

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

## Regression coverage

`validate.ps1` compiles Bicep and runs the PowerShell runtime, host-SSMS, stage-view,
lab-runtime, repository-documentation, Arc-launcher, media-checker and guest-stage regressions.
Stage `45` verifies its SQL media in the guest installation workflow.

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
