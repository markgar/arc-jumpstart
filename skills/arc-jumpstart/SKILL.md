---
name: arc-jumpstart
description: Build, monitor, recover, and hand off the Azure Arc Jumpstart environment in this repository. Use when a user wants to create or operate the lab, reports a failed stage, or needs guidance for Arc setup, assessment, inventory modeling, or a simple SQL Managed Instance migration.
license: MIT
---

# Arc Jumpstart operator

Use the repository runbooks as the source of truth. This skill guides the
workflow; it does not replace the repository's Bicep, Python, Bash, or
PowerShell implementation.

## Start safely

1. Read `AGENTS.md`, `docs/00-agent-bootstrap.md`, `infra/README.md`, and
   `scripts/README.md`.
2. Determine whether the request is for a new deployment, recovery of an
   existing lab, lifecycle management, Arc handoff, or workshop activity.
3. On Windows, verify that operational commands will run inside WSL2 with
   Linux Azure CLI and Python. Native Windows and Git Bash are source-validation
   environments only.
4. Confirm the approved Azure subscription, dedicated resource group, region,
   cost scope, and auto-shutdown decision before provisioning.
5. Use a private `ENV_FILE` outside the repository. For new labs, use the visible
   `$HOME/ArcJumpstart/lab.env`, not a hidden folder. Preserve an existing lab's
   exact path; never silently move it. Never print, commit, overwrite, or infer
   credentials.

If required information is missing, ask only for that information. Apply the
documented defaults for routine choices.

## New deployment

From the repository root, use the same private `ENV_FILE` for every command:

```bash
./scripts/validate.sh &&
ENV_FILE=/absolute/private/path/lab.env ./scripts/preflight.sh infra &&
ENV_FILE=/absolute/private/path/lab.env ./scripts/deploy.sh all
```

Run the deployment in a dedicated visible terminal or asynchronous process so
the conversation remains responsive. Record the exact command, `ENV_FILE`
path, and process identity. Do not poll continuously or launch a second
deployment because the first is quiet.

Use one-shot progress checks only when useful:

```bash
ENV_FILE=/absolute/private/path/lab.env ./scripts/lab.sh build-status
```

## Recovery

- Inspect the first failing gate.
- Use `stage-progress` for an active stage and `stage-log` after it is terminal.
- Follow the recovery boundary in `docs/02-sql-ag-lessons.md` and
  `docs/06-troubleshooting-cleanup.md`.
- Resume only the affected stage and required successors.
- Never rerun `deploy.sh all` against an already promoted domain.
- Preserve working guests, disks, databases, identities, and active operations
  unless the user explicitly approves a scoped rebuild or deletion.

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
TextEdit**. On Windows, provide both the WSL path and full File Explorer path
using the actual distro/user, and **Open With Notepad**. On Linux, provide file
manager/text editor instructions. Identify any remote execution host and its
approved access method. Never display the contents; warn that the file contains
passwords and must not be shared or committed. Follow the detailed handoff
contract in `docs/00-agent-bootstrap.md`; a terminal log or documentation link
alone does not satisfy it.
