---
name: arc-jumpstart
description: Build, monitor, recover, and hand off the Azure Arc Jumpstart practice environment in this repository. Use when a user asks for help with this repo, wants to create or operate the lab, reports a failed stage, or needs guidance for Arc, assessment, or migration exercises.
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
   existing lab, lifecycle management, or a learner exercise.
3. On Windows, verify that operational commands will run inside WSL2 with
   Linux Azure CLI and Python. Native Windows and Git Bash are source-validation
   environments only.
4. Confirm the approved Azure subscription, dedicated resource group, region,
   cost scope, and auto-shutdown decision before provisioning.
5. Use a private `ENV_FILE` outside the repository. Never print, commit,
   overwrite, or infer credentials.

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

## Learner boundary

Infrastructure preparation stops after stage `60`. Do not silently onboard Arc,
enable assessment collectors, or start migration. For a separately requested
Arc onboarding exercise, follow `docs/03-arc-onboarding.md`, including the
connectivity check and authentication rules in `AGENTS.md`.

## Completion

Verify the ready-environment contract in `docs/00-agent-bootstrap.md`. Report
non-secret resource identifiers, readiness evidence, skipped validation, and
any unproven outcomes. Point the learner to the relevant exercise guide.
