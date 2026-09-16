# Script entry points

Run these Bash/Python entry points from the repository root on macOS, Linux or
WSL. They drive the Bicep stages and host-side Windows automation. Do not run
the Hyper-V/AD PowerShell artifacts directly on the workstation.

See the [agent bootstrap runbook](../docs/00-agent-bootstrap.md) for the mission,
inputs and required ready-environment outcome.

## Command reference

| Command | Purpose and boundary |
|---|---|
| `./scripts/validate.sh` | Bicep compilation, Bash syntax, Python regression tests and available ShellCheck/PowerShell checks. Does not deploy Azure resources. Full coverage requires those optional tools to be present; report skipped checks honestly. |
| `./scripts/preflight.sh infra` | Checks the configured Azure target, required infrastructure registrations, host SKU availability and download reachability; prints cost considerations. Does not provision the lab or automatically register providers. |
| `./scripts/preflight.sh full` | Also checks registrations for the later Arc/assessment/migration exercises. Does not perform those exercises. |
| `./scripts/deploy.sh all` | Runs the complete saved infrastructure sequence through stage `60`. Intended for a new lab, not blanket repair of an existing domain. |
| `./scripts/deploy.sh 60` | Runs one supported stage. Other numbers are `00`, `10`, `20`, `30`, `40`, `45` and `50`. Use for scoped recovery and then continue with successors. |
| `./scripts/lab.sh status` | Reports outer host power state only; not whole-lab readiness. |
| `./scripts/lab.sh stage-log 60` | Displays the latest stage transcript through `show-stage-log.py`, suppressing startup headers and redacting configured sensitive values. Raw host files remain sensitive. |
| `./scripts/lab.sh stop` / `start` | Deallocates or starts the outer Azure host. Deallocation does not stop storage/Bastion charges; keep the host allocated during replication/migration. |
| `./scripts/lab.sh retire-source JS-SQL-01` | Stops and marks a migrated source retired. Also supports `JS-UBUNTU-01`. Use only as part of an authorized cutover. |
| `./scripts/lab.sh delete-infra YOUR_RESOURCE_GROUP` | Deletes the configured infrastructure RG only when the argument matches it. Requires explicit deletion approval and the wider cleanup sequence first. |
| `python3 scripts/check-sql-media.py --help` | Optional local media diagnostic; stage `45` already performs its own media checks. |

## Normal automated setup

With a populated private `deploy.env` and an authenticated Azure CLI user:

```bash
./scripts/validate.sh &&
./scripts/preflight.sh infra &&
./scripts/deploy.sh all
```

Azure CLI and Python 3 are required. The wrapper currently rejects service
principal authentication. Authentication, permissions and the cost envelope
must be supplied/approved before provisioning.

The wrappers do not source `deploy.env` as shell code. Use literal `KEY=value`
lines without quotes or `export`. Do not print the file or put it in version
control.

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
agent wait. Stages `30` and `45` wait for the new asynchronous Run Command
execution and require exit `0`; do not return success to the learner when only
submission succeeded.

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

`validate.sh` invokes `test-check-sql-media.py`, `test-stage-log.py`, and, when
PowerShell is available, `test-stage40.ps1`, `test-stage45.ps1`,
`test-stage50.ps1` and `test-stage60.ps1`.

Preserve coverage for generated command arguments, real native report formats,
SQL type conversion/startup transitions, parallel installer boundaries,
disk-parent safety and log redaction. These tests do not replace the clean
deployment and live readiness acceptance described in the agent runbook.
