---
name: arc-jumpstart
description: Build, monitor, recover, and hand off the Azure Arc Jumpstart environment in this repository. Use when a user wants to create or operate the lab, reports a failed stage or Bastion/RDP trouble (including "my Bastion is not working well now"), or needs guidance for Arc setup, assessment, inventory modeling, or a simple SQL Managed Instance migration.
license: MIT
---

# Arc Jumpstart operator

Use the repository runbooks as the source of truth. This skill guides the
workflow; it does not replace the repository's Bicep and PowerShell
implementation.

## Start safely

1. Read `AGENTS.md`, `docs/00-agent-bootstrap.md`, `infra/README.md`, and
   `scripts/README.md`.
2. Determine whether the request is for a new deployment, recovery of an
   existing lab, lifecycle management, Arc handoff, or workshop activity.
3. Use PowerShell 7 and Azure CLI from the same host OS on Windows, macOS or
   Linux. WSL2 is not required for the PowerShell entry points.
4. Confirm the approved Azure subscription, dedicated resource group, region,
   cost scope, and auto-shutdown decision before provisioning.
5. Use a private `ENV_FILE` outside the repository. For new labs, use
   `init-config.ps1` to create `$HOME/ArcJumpstart/lab.env` in a visible,
   owner-only folder. Preserve an existing lab's exact path; never silently
   move it. Never print, commit, overwrite, or infer credentials.

If required information is missing, ask only for that information. Apply the
documented defaults for routine choices.

## New deployment

From the repository root, use the same private `ENV_FILE` for every command:

```powershell
./scripts/validate.ps1
./scripts/preflight.ps1 infra
./scripts/deploy.ps1 all
```

Do not start the next command if the prior one failed. Set `$env:ENV_FILE` to
the absolute private path in the deployment terminal before running them.
Run the deployment in a dedicated visible terminal or asynchronous process so
the conversation remains responsive. Record the exact command, `ENV_FILE`
path, and process identity. Do not poll continuously or launch a second
deployment because the first is quiet.

Use one-shot progress checks only when useful:

```powershell
./scripts/lab.ps1 build-status
```

## Recovery

- Inspect the first failing gate.
- Use `stage-progress` for an active stage and `stage-log` after it is terminal.
- Follow the recovery boundary in `docs/02-sql-ag-lessons.md` and
  `docs/06-troubleshooting-cleanup.md`.
- Resume only the affected stage and required successors.
- Never rerun `deploy.ps1 all` against an already promoted domain.
- Preserve working guests, disks, databases, identities, and active operations
  unless the user explicitly approves a scoped rebuild or deletion.

### Bastion disconnects after Windows first login

If the Hyper-V host's Bastion RDP session drops or becomes unstable, ask:
"At first login, did Windows ask 'Do you want to allow your PC to be
discoverable by other PCs and devices on this network?' What did you select:
Yes, No, or nothing?" In one observed session, selecting **Yes** was followed
by an immediate disconnect and a successful reconnection; this does not prove
the prompt caused other Bastion failures. **Yes** chooses a discoverable
**Private** network; **No** chooses the less-discoverable **Public** profile.
The profile affects Windows Firewall rules and may affect RDP (TCP 3389).

1. If Bastion provisioning itself failed, use
   [Bastion troubleshooting](../../docs/06-troubleshooting-cleanup.md#bastion-is-slow-or-failed);
   do not change the host profile. If RDP reconnected, avoid changing a
   working host merely because the prompt appeared.
2. For continued RDP trouble after the prompt, inspect the host's current
   network profile and the effective Windows Firewall RDP rules for that
   profile, then check the VM NIC/subnet NSG's TCP 3389 access from
   `AzureBastionSubnet`. Do not infer the current profile from the answer
   alone or treat the prompt as a confirmed root cause.
3. Before a user-approved profile change, ensure alternate Azure Run Command
   access and that RDP is allowed for the intended profile; changing the
   active host interface can drop Bastion again. If **Yes** changed the host
   to Private and returning to Public is appropriate, follow the targeted
   [host profile recovery steps](../../docs/06-troubleshooting-cleanup.md#bastion-is-slow-or-failed)
   and verify reconnection. Never blanket-disable Windows Firewall or change
   Azure networking to compensate for an unverified profile issue.

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
TextEdit**. On native Windows, provide the full File Explorer path and **Open
With Notepad**; on WSL, provide both the WSL path and Windows path using the
actual distro/user. On Linux, provide file
manager/text editor instructions. Identify any remote execution host and its
approved access method. Never display the contents; warn that the file contains
passwords and must not be shared or committed. Follow the detailed handoff
contract in `docs/00-agent-bootstrap.md`; a terminal log or documentation link
alone does not satisfy it.
