# Lessons from the first clean-room attempt

## Evidence and limits

A fresh agent used baseline `7323b9d` and repository instructions on
2026-09-16, without the original debugging conversation. Source validation
passed, including Bicep compilation, ShellCheck and the PowerShell stage
regressions. Infrastructure preflight passed for the selected target; the
public Windows, Ubuntu and SQL media endpoints were reachable.

The user stopped the attempt after foundation completion and submission of
stage `10`. The host initialization Run Command was still running at the stop
handoff. No stages `20`-`60` had been submitted. There was no diagnosed guest
failure, but also no proof of completed host initialization, fresh parallel SQL
installation or end-to-end readiness. This attempt is not a successful clean
rebuild.

## Bastion was the first avoidable wait

The VNet was ready at about 13:26:35 UTC. Stage `00` did not finish until
13:37:10 UTC because its nested deployment also contained Bastion. The original
`deploy.sh all` waited for that entire deployment before starting the host:
roughly ten and a half minutes after the network was ready.

The prior documentation said stage `10` could use the ready VNet directly.
That was true for an individually invoked stage, but did not describe the
synchronous `all` path. Documentation must describe the actual orchestration,
not just the resource dependencies.

The saved correction is:

- Stage `00` creates the core network and reserves `AzureBastionSubnet`.
- [Independent Bastion Bicep](../infra/stages/bastion/main.bicep) creates only
  Bastion and its public IP, using the existing subnet.
- [`deploy.sh`](../scripts/deploy.sh) keeps Bastion enabled by default but
  submits it with `--no-wait` after the foundation succeeds. It immediately
  continues the numbered build without a Bastion completion gate.
- Azure finishes Bastion independently; there is no build-side monitoring or
  completion join. Failed access does not trigger a lab rebuild.

[`test-bastion.py`](../scripts/test-bastion.py) checks compiled resource graphs
and runs the wrapper against a fake Azure CLI, including a complete core
sequence while Bastion is running or failed. Live verification of this new
parallel submission path is still outstanding; the stopped attempt used the
old synchronous baseline.

## Region availability and quota are separate checks

The default `Standard_E16s_v5` size had subscription **Location** restrictions in
East US 2, East US and Central US during this attempt. West US 2 had only
**Zone** restrictions, so a non-zonal deployment was allowed there. Do not
interpret a zone restriction as a blanket regional prohibition, or assume a
default SKU is available to every subscription.

The chosen West US 2 target had sufficient regional and ESv5-family vCPU quota
for the 16-vCPU host. The agent checked quota manually: `preflight.sh` checks
SKU availability, but does not yet enforce available regional and family quota.
For a new allocation, verify both quotas can accommodate the requested vCPUs;
for reuse or resizing, account for the existing allocation instead of counting
it twice. SKU eligibility and quota do not guarantee physical capacity.

The approved planning estimate for that attempt was approximately $51/day,
with a $60 first-day planning envelope. These were user-approved estimates,
not current universal pricing or an automatically enforced Azure spending cap.
Stopping a terminal does not stop billing for resources it already created.

Archiving the stopped session subsequently removed its worktree, including its
ignored environment file, while Azure resources could still exist. For
disposable agent sessions, keep the approved private `ENV_FILE` in durable,
owner-only storage outside the worktree. Do not assume an ignored file will be
preserved by session archival, and do not recover convenience by committing
credentials. A new session must distinguish missing local configuration from a
missing Azure lab before creating resources or changing credentials.

## Stopping an agent does not stop Azure

The original deployment terminal and read-only watcher were interrupted, and
process inspection confirmed that no local `deploy.sh` remained. No cloud
operation was cancelled and no resource was stopped, deallocated or deleted.
Stage `10` had already been submitted automatically after stage `00` finished,
so Azure could continue it after the local agent stopped.

The stage `10` host restart and VM-agent readiness wait happen in the local
wrapper after the cloud deployment returns. At the stop handoff those steps
were not verified. An `exitCode` of `0` alongside a **Running** Run Command is
not a completion receipt. The next operator must inspect the live deployment
and Run Command, avoid competing executions, and follow the documented
[interrupted-stage recovery](00-agent-bootstrap.md#resume-an-interrupted-or-failed-build)
before advancing.

## Agent workflow and remaining improvements

Collect the Azure target, cost approval and secure configuration once. After
approval, use documented defaults and continue autonomously; do not turn
routine infrastructure choices into repeated learner questions. Ask again only
for a real permission/configuration blocker, a material cost change or a
destructive action outside the approved scope.

The independent agent made no code changes before stopping. Besides the
Bastion correction above, it recommended:

- Adding regional and VM-family quota checks to preflight, so this does not
  require a separate manual lookup.
- Saving an end-to-end machine-readable readiness receipt covering all stages,
  the final guest/SQL/cluster checks and separate access status. Existing guest
  operation evidence and transcripts are not a complete lab-level receipt.

These remain recommendations, not implemented capabilities or reasons to
claim the stopped run succeeded. Keep private environment files out of Git,
restrict their permissions, and never publish raw credential-bearing
transcripts as readiness evidence.
