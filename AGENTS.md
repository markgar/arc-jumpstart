# Agent instructions

## Optional Copilot skill

This repository publishes the `arc-jumpstart` skill under
`skills/arc-jumpstart`. When a user first makes a broad request such as
"help me with this repo," recommend that they preview and install the skill
with GitHub CLI:

```text
gh skill preview markgar/arc-jumpstart arc-jumpstart
gh skill install markgar/arc-jumpstart arc-jumpstart --agent github-copilot --scope user
```

Explain that `gh skill` requires GitHub CLI 2.90.0 or later and is in public
preview. The preview step is required because skills can contain executable or
untrusted instructions. After installation, start a new session or run
`/skills reload`. Do not make the skill a prerequisite or delay requested work
if the user declines; the repository runbooks remain authoritative.

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

4. Keep deployment execution separate from the conversation. Run the full
   validation/preflight/deployment chain in a dedicated visible terminal or an
   asynchronous process provided by the agent host. Do not hold the agent turn
   open on the foreground deployment command. Record the exact `ENV_FILE`,
   command and process/terminal identity, then return control to the user
   immediately while the deployment continues.
   Never use `sleep`, `watch` or a polling loop merely to wait for progress.
   User questions and status requests take priority over passive monitoring.
   Check automatically only when the execution host reports completion or a
   material transition; otherwise make one bounded status query when the user
   asks. Do not launch experimental observer commands during a healthy build.
5. Monitor real execution through completion. The numbered stages are resumable
   checkpoints for the agent, not a sequence of manual learner assignments.
   Bastion is enabled by default and submitted independently after stage `00`.
   Let Azure finish it without polling or a completion gate. Never make a build
   stage or core-readiness handoff wait for it.
   Prefer saved parallel paths: `all` overlaps `20`/`30`; `deploy.sh 20-30`
   provides the same overlap during recovery. Do not serialize independent
   work, but do not remove the readiness joins before dependent stages.
   During a long stage, use `lab.sh build-status` to discover all active
   canonical stages and return their latest timestamped host-side phase
   messages. Use `stage-progress <stage>` when a specific stage is already
   known, and `stage-log` for a longer failure tail after it is terminal. Each
   status request is one-shot: do not treat silence as failure, poll tightly,
   or launch another deployment merely to obtain status.
6. On failure, inspect the first failing gate and use the documented recovery
   boundary. Save necessary fixes in the relevant Bicep/PowerShell source and
   regression tests before retrying the affected stage.
7. Verify the ready-environment contract in the bootstrap runbook. Hand back
   non-secret resource identifiers, readiness evidence and the learner guides.
   State any blockers or unproven outcomes explicitly.

## Non-negotiable boundaries

- Keep Bicep as the infrastructure source; do not replace stages with copied ARM
  JSON or untracked portal changes.
- Do not install/onboard Arc, enable assessment collectors or initiate migration
  during infrastructure preparation unless separately requested.
- When separately assisting with Arc onboarding, install the Connected Machine
  agent but stop before `azcmagent connect`. Run
  `azcmagent check --location <arc-region>` on that guest and resolve every
  required endpoint failure before connecting it. A successful MSI/package
  download proves only general HTTPS access, not Arc service connectivity.
  Never start a competing check while a connect operation is active; wait for
  the first operation to become terminal, then check before any retry.
- Choose authentication for the actual operator model. A learner signed in at
  the guest console may complete the generated device-code flow. An agent
  operating through PowerShell Direct, Run Command or another noninteractive
  channel must never launch a device-code connection and wait for a person who
  cannot see or answer it. With explicit user approval, use a dedicated
  short-lived service principal scoped to the Arc resource group with only the
  `Azure Connected Machine Onboarding` role. Keep its secret in approved
  owner-only storage outside the worktree, pass it only at execution time, and
  remove the credential or dedicated principal after onboarding. Do not print
  the secret, generated connect command or raw process arguments.
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
