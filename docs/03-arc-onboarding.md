# Manually onboard the guests to Azure Arc

The infrastructure deliberately stops before Arc onboarding. Stages `00` through `60` prepare the machines, domain, SQL instances, sample databases, and availability group, but do not install or connect Azure Arc or the Azure extension for SQL Server. Generate and run the onboarding commands yourself so you experience the identity, scope, agent, networking, and troubleshooting steps used with real servers.

Before starting the Arc and migration exercises, run the broader provider check:

```bash
./scripts/preflight.sh full
```

## Decide the Arc resource scope

Create or choose:

- A resource group dedicated to Arc-enabled resources.
- An Azure region supported by Azure Arc-enabled servers.
- Consistent tags such as `environment=jumpstart`, `site=hyperv-lab`, and `wave=assessment`.

Before onboarding the three SQL machines, set this tag on the Arc resource group:

```text
ArcSQLServerExtensionDeployment=LicenseOnly
```

The lab uses SQL Server Developer edition. `LicenseOnly` is the appropriate Arc SQL license type for Developer/Evaluation/Express editions; Developer edition is reported on a $0 meter.

## Generate a single-server onboarding script

In the Azure portal:

1. Open **Azure Arc**.
2. Select **Machines > Add/Create > Add a machine**.
3. Choose **Add a single server**.
4. Select your subscription, Arc resource group, region, operating system, connectivity method, and tags.
5. Download or copy the generated script.

Use the portal-generated script rather than a script committed to this repository. It contains your selected tenant, subscription, resource group, region, and a short-lived authentication flow.

## Required pre-connect network check

Do not run an entire generated onboarding script without pausing at the
connection boundary. First use its package-install portion to install the
Connected Machine agent, but stop before `azcmagent connect`. Then run this on
each guest, substituting the Arc resource region selected in the portal:

```powershell
azcmagent check --location westus2
```

On Linux, run the same check with `sudo`:

```bash
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
> Onboard `JS-DC-01` to Arc for inventory and assessment so the exercise
> represents the whole server estate. Installing the Connected Machine agent
> does not change its domain-controller role. Treat it as a higher-sensitivity
> server: add only extensions required by the exercise, verify their support
> and permissions before deployment, and do not use this DC as the lab's
> migration target. If an organization would exclude domain controllers from
> Arc by policy, leaving it out does not block onboarding or assessing the
> remaining guests; record that scope decision in the assessment.

From the Hyper-V host:

1. Open Hyper-V Manager.
2. Connect to one nested VM.
3. Sign in as a local or domain administrator.
4. Open Windows PowerShell as Administrator.
5. Install the Connected Machine agent from the generated script, stopping
   before its `azcmagent connect` command.
6. Run `azcmagent check --location <arc-region>` and resolve required failures.
7. Run the generated `azcmagent connect` command.
8. Wait for `azcmagent show` to report `Connected`.
9. Confirm that the machine appears in **Azure Arc > Machines** before continuing.

Useful local checks:

```powershell
azcmagent show
azcmagent check
Get-Service himds
```

> [!IMPORTANT]
> The nested guests run on a Hyper-V host that is itself an Azure VM. This is an evaluation-only topology. Before onboarding the full set, onboard one disposable guest and confirm it is accepted as a Hyper-V VM rather than detected as an Azure VM. Check whether Azure IMDS (`169.254.169.254`) or an Azure VM Guest Agent is reachable inside the guest. If Arc rejects the guest as Azure-hosted, follow Microsoft's [evaluation procedure for Arc on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine), record the reversible changes, and retest before continuing.

## Onboard Ubuntu

Connect to `JS-UBUNTU-01` from the Hyper-V console and sign in as `jumpstart`. The external VHDX retains its original Linux hostname, so rename it before onboarding:

```bash
sudo hostnamectl set-hostname JS-UBUNTU-01
sudo reboot
```

After the reboot, use the Linux script to install the Connected Machine agent,
stop before its connect command, and run the required
`sudo azcmagent check --location <arc-region>` gate. Resolve any required
endpoint failure before running the generated connect command with `sudo`.

```bash
sudo azcmagent show
sudo azcmagent check
systemctl status himdsd
```

## Enable Arc-enabled SQL Server

When an Arc-enabled Windows server contains SQL Server, Azure normally deploys `WindowsAgent.SqlServer` automatically unless auto-deployment was disabled. After each SQL host is connected:

1. Open the Arc-enabled server in the portal.
2. Verify `WindowsAgent.SqlServer` reaches **Succeeded**; install it manually only if it is absent.
3. Confirm the extension version is at least `1.1.2594.118`.
4. Confirm the license type is `LicenseOnly` and the detected edition is Developer.
5. Allow outbound HTTPS to `telemetry.<region>.arcdataservices.com`.
6. Confirm that the SQL Server instances and databases appear under **Azure Arc > SQL Server instances**.

Arc SQL migration assessment normally runs weekly. Open each Arc-enabled SQL instance, select **Migration assessment**, and choose **Run assessment**. Wait for a successful completed-assessment timestamp before synchronizing the Azure Migrate project.

## Verify agent versions

Arc-based Azure Migrate discovery requires Connected Machine agent version 1.46 or later. Check each machine:

```powershell
azcmagent version
```

```bash
azcmagent version
```

Upgrade any older agent before starting the assessment.
