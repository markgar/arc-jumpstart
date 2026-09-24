# Complete user-authenticated Azure Arc setup

The agent prepares the machines, domain, SQL instances, sample databases,
availability group, Arc resource group, licensing tag, and desktop launchers.
It cannot connect the guests because no Arc credentials are stored in the
repository. The user completes this prerequisite interactively with their own
Azure identity. Service-principal and unattended onboarding are out of scope.

Before Arc setup, run the broader provider check:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
./scripts/preflight.ps1 full
```

## Verify the prepared Arc target

The agent should already have:

- A resource group dedicated to Arc-enabled resources.
- An Azure region supported by Azure Arc-enabled servers.
- The `ArcSQLServerExtensionDeployment=LicenseOnly` tag.
- A **Connect to Azure Arc.cmd** launcher on each Windows guest's public desktop.

If those items are missing, rerun the launcher stage before asking the user to
connect a guest:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
./scripts/deploy.ps1 arc-launchers
```

The lab installs SQL Server 2025 Enterprise Developer. Arc inventory reports
the edition as `Developer`; `LicenseOnly` is the appropriate Arc SQL license
type and uses the $0 meter.

## Authentication boundary

Use the device-code flow only when the user is signed in to the guest and can
immediately read the code, open the Microsoft sign-in page, and authenticate
with their own Azure identity.

Do not use this path for an agent operating through PowerShell Direct, Azure VM
Run Command, or another noninteractive channel. A device-code command can wait
indefinitely when nobody can see and answer its prompt. If one was launched
accidentally, terminate only that waiting `azcmagent connect` process, preserve
its non-secret result, confirm whether an Arc machine resource was created, and
run the required network check before choosing a supported retry.

Use one SQL guest as the pilot. Require `azcmagent show` to report `Connected`
and confirm the expected Azure Arc machine resource before onboarding the
remaining guests.

### Evidence and safe logs

The launcher retains timestamped per-machine evidence under
`C:\ArcJumpstart\Logs` using names such as:

```text
Arc-Onboard-JS-SQL-01-<UTC timestamp>.log
Arc-Check-JS-SQL-01-<UTC timestamp>.log
Arc-Connect-JS-SQL-01-<UTC timestamp>.log
```

Record observable results rather than credentials or generated commands:

- Guest name, Connected Machine agent version and `himds` service state.
- The `azcmagent check` summary and whether every required endpoint passed.
- Final `azcmagent show` connection state and the matching Azure Arc machine
  resource state.
- Extension provisioning state after connection.

Do not place a generated authentication script, device code, access token or
full `azcmagent connect` arguments in these logs.
PowerShell transcript startup headers and remote-process arguments can contain
sensitive values even when the command output appears harmless. Do not enable
transcription around the connect command. When reporting progress, return only
a bounded redacted tail and the structured state above; never publish a raw
host transcript.

See the [`azcmagent connect` reference](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-connect)
before execution because authentication and agent requirements can change.

## Required pre-connect network check

The staged launcher installs the Connected Machine agent, runs the required
check, and starts device-code connection only after the check succeeds. If the
user follows a manual portal-generated script instead, stop before
`azcmagent connect` and run this on each guest, substituting the Arc resource
region selected in the portal:

```powershell
azcmagent check --location westus2
```

On Linux, run the same check with `sudo`:

```text
sudo azcmagent check --location westus2
```

The check validates DNS and TLS connectivity to the Azure Arc service
endpoints and identifies blocked URLs. Resolve required endpoint failures
before running the generated `azcmagent connect` command. Successfully
downloading the Windows MSI or Linux package proves access to that download
source only; it does not prove connectivity to all services required for Arc
registration.

If a connect command is already running or waiting for authentication, do not
start a competing guest operation. Let it return or time out, record its actual
result, run the network check, and retry only after resolving any failure. Do
not treat an installer exit code or a created Azure resource as proof that the
guest is connected.

## Onboard Windows guests

Repeat the process for:

- `JS-DC-01`
- `JS-SQL-01`
- `JS-SQL-AG-01`
- `JS-SQL-AG-02`

> [!NOTE]
> Onboard `JS-DC-01` to Arc for inventory and assessment so the environment
> represents the whole server estate. Installing the Connected Machine agent
> does not change its domain-controller role. Treat it as a higher-sensitivity
> server: add only extensions required for assessment, verify their support
> and permissions before deployment, and do not use this DC as the lab's
> migration target. If an organization would exclude domain controllers from
> Arc by policy, leaving it out does not block onboarding or assessing the
> remaining guests; record that scope decision in the assessment.

Fresh builds place **Connect to Azure Arc.cmd** on each Windows guest's public
desktop. From the Hyper-V host:

1. Open Hyper-V Manager.
2. Connect to one nested VM.
3. Sign in as a local or domain administrator.
4. Double-click **Connect to Azure Arc.cmd** and approve elevation.
5. Confirm its required endpoint check succeeds.
6. Complete the displayed device-code flow on your own computer.
7. Wait for the launcher and `azcmagent show` to report `Connected`.
8. Confirm that the machine appears in **Azure Arc > Machines** before continuing.

Useful local checks:

```powershell
azcmagent show
azcmagent check
Get-Service himds
```

Browser-based Bastion clipboard does not reliably pass through the Hyper-V
VMConnect boundary. The launcher avoids pasting a generated script and records
network-check and final status evidence without recording the short-lived
device code.

If the launcher is missing, stage it through the supported workstation entry
point:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
./scripts/deploy.ps1 arc-launchers
```

Set `ARC_RESOURCE_GROUP` and `ARC_LOCATION` in the private environment file
to override the defaults. When omitted, they derive as
`<AZURE_RESOURCE_GROUP>-arc` and `AZURE_LOCATION`. The command creates or
retains that dedicated resource group, applies
`ArcSQLServerExtensionDeployment=LicenseOnly`, and stages the launchers. It
does not connect any guest or begin device-code authentication.

`deploy.ps1 all` runs this staging step by default after stage `60`. Set
`PREPARE_ARC_LAUNCHERS=false` before deployment to omit it. Staging is inert:
it does not install the agent, start authentication, or connect a machine.

> [!IMPORTANT]
> The nested guests run on a Hyper-V host that is itself an Azure VM. This is an evaluation-only topology. Before onboarding the full set, onboard one disposable guest and confirm it is accepted as a Hyper-V VM rather than detected as an Azure VM. Check whether Azure IMDS (`169.254.169.254`) or an Azure VM Guest Agent is reachable inside the guest. If Arc rejects the guest as Azure-hosted, follow Microsoft's [evaluation procedure for Arc on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine), record the reversible changes, and retest before continuing.

## Onboard Ubuntu

Connect to `JS-UBUNTU-01` from the Hyper-V console and sign in as `jumpstart`. The external VHDX retains its original Linux hostname, so rename it before onboarding:

```text
sudo hostnamectl set-hostname JS-UBUNTU-01
sudo reboot
```

After the reboot, use the Linux script to install the Connected Machine agent,
stop before its connect command, and run the required
`sudo azcmagent check --location <arc-region>` gate. Resolve any required
endpoint failure before running the generated connect command with `sudo`.

```text
sudo azcmagent show
sudo azcmagent check
systemctl status himdsd
```

## Enable Arc-enabled SQL Server

When an Arc-enabled Windows server contains SQL Server, Azure normally deploys `WindowsAgent.SqlServer` automatically unless auto-deployment was disabled. After each SQL host is connected:

1. Open the Arc-enabled server in the portal.
2. Verify `WindowsAgent.SqlServer` reaches **Succeeded**; install it manually only if it is absent.
3. Confirm the license type is `LicenseOnly` and the detected edition is Developer.
4. Allow outbound HTTPS to `telemetry.<region>.arcdataservices.com`.
5. Confirm that the SQL Server instances and databases appear under **Azure Arc > SQL Server instances**.

When all machine and SQL resources are visible, continue to
[assessment and modeling](04-assessment.md). That guide decides whether an
assessment must be run; Arc setup itself does not start one.

## Verify agent versions

Arc-based Azure Migrate discovery requires Connected Machine agent version 1.46 or later. Check each machine:

```powershell
azcmagent version
```

```text
azcmagent version
```

Upgrade any older agent before starting the assessment.
