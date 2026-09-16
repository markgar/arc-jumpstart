# Agent instructions

## Mission

Build a ready-to-use practice environment from this repository, without
requiring the learner to install Windows, configure AD, install SQL or debug
cluster provisioning manually. Infrastructure is automated preparation, not
the curriculum.

The learner practices Azure Arc / Arc SQL onboarding, assessment and optionally
migration. Do not perform those exercises as hidden bootstrap steps.

## Start here

- [Agent bootstrap runbook](docs/00-agent-bootstrap.md): inputs, execution,
  recovery and the definition of done.
- [Infrastructure map](infra/README.md): Bicep stages, execution boundaries and
  persistence.
- [Script commands](scripts/README.md): supported entry points and diagnostics.
- [AG lessons](docs/02-sql-ag-lessons.md): proven fixes, one-time recovery actions
  and remaining evidence gaps.

Do not depend on an earlier conversation, session artifact or a hand-repaired
VM. The repository must contain the implementation and instructions needed for
the next build.

## Execution contract

1. Establish whether this is a new deployment or recovery of an existing lab.
   Confirm the user's approved Azure target and cost/destructive-action scope.
2. Obtain missing authentication/configuration inputs securely. Do not overwrite
   an existing environment file or reuse a shared resource group implicitly.
3. For a new lab, run from the repository root:

   ```bash
   ./scripts/validate.sh &&
   ./scripts/preflight.sh infra &&
   ./scripts/deploy.sh all
   ```

4. Monitor real execution through completion. The numbered stages are resumable
   checkpoints for the agent, not a sequence of manual learner assignments.
5. On failure, inspect the first failing gate and use the documented recovery
   boundary. Save necessary fixes in the relevant Bicep/PowerShell source and
   regression tests before retrying the affected stage.
6. Verify the ready-environment contract in the bootstrap runbook. Hand back
   non-secret resource identifiers, readiness evidence and the learner guides.
   State any blockers or unproven outcomes explicitly.

## Non-negotiable boundaries

- Keep Bicep as the infrastructure source; do not replace stages with copied ARM
  JSON or untracked portal changes.
- Do not install/onboard Arc, enable assessment collectors or initiate migration
  during infrastructure preparation unless separately requested.
- Never print or commit `deploy.env`, passwords, SAS tokens or registration keys.
  Use `lab.sh stage-log`; raw Windows transcripts can contain credentials.
- Never bypass OOBE, licensing, SQL readiness, cluster validation or operation
  completion gates. A zero deployment result alone is not a ready lab.
- Do not restart `deploy.sh all` against an already-promoted domain to resume a
  later failure. Stage `40` is not an in-place DC repair tool.
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
