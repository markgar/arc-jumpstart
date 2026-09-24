# Deploy and inspect the lab

## Configure

```powershell
./scripts/init-config.ps1
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
# Edit the file privately and replace every CHANGEME.
./scripts/validate.ps1
./scripts/preflight.ps1 infra
```

Keep this file in a visible folder outside the repository. Do not overwrite or
silently move an existing lab's configuration. At completion, the agent must
explicitly present the actual full file path and platform-specific instructions
to find and view it; see
[Find your lab configuration and passwords](../README.md#find-your-lab-configuration-and-passwords).

The wrapper uses your signed-in Entra user to deploy Azure resources. Each PowerShell artifact is embedded in its Bicep-managed Run Command, avoiding a public deployment storage dependency. This is unrelated to the local Active Directory domain created inside the nested lab.

## Automated deployment

Infrastructure preparation belongs to the automation, not to the learner.
For a new lab with validated configuration and an authenticated Azure CLI user:

```powershell
./scripts/validate.ps1
./scripts/preflight.ps1 infra
./scripts/deploy.ps1 all
```

Stop if either prerequisite command fails. PowerShell 7 and Azure CLI work on
Windows, macOS and Linux without WSL.

The [agent bootstrap runbook](00-agent-bootstrap.md) defines the inputs,
monitoring/recovery workflow and required handoff state. Use the individual
stages below for inspection and scoped recovery, not as a requirement for the
learner to construct the environment manually.

## Inspect or resume individual stages

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
./scripts/deploy.ps1 00
./scripts/deploy.ps1 10
./scripts/deploy.ps1 20-30
./scripts/deploy.ps1 40
./scripts/deploy.ps1 45
./scripts/deploy.ps1 50
./scripts/deploy.ps1 60
```

Stage `40` must wait for genuine Windows first-boot/OOBE completion before
renaming or restarting a Windows guest. It checks Microsoft's native
[`OOBEComplete` API](https://learn.microsoft.com/en-us/windows/win32/api/oobenotification/nf-oobenotification-oobecomplete)
and `IMAGE_STATE_COMPLETE`, with a ten-minute wait. A heartbeat, a unique SID,
working PowerShell Direct, or even a working SQL instance does not establish
that Windows Setup finished. If the check stops, inspect the guest console and
`C:\Windows\Panther\UnattendGC`; do not proceed to later stages or manually
force setup-state registry values. Completing the parent image's Sysprep
generalization and completing each clone's first boot are separate requirements.

The answer file supplies the matching Windows Server 2022 KMS client
`ProductKey` in the `Microsoft-Windows-Shell-Setup` **specialize** pass.
Without this input, the source image was observed waiting indefinitely at
"It's time to enter the product key"; hiding other OOBE pages did not answer
that page. Stage `40` also verifies Azure KMS activation after setup completes,
before renaming the guest. Successful key installation alone is not activation.
See [Windows setup and activation prerequisites](01-prerequisites.md#windows-setup-and-activation)
and Microsoft's [ProductKey setting](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-productkey).

Each PowerShell stage runs through Azure VM Run Command. Azure retains recent command output, and the host retains full transcripts under `C:\ArcJumpstart\Logs`. Stages `30` and `45` use asynchronous Run Command for image downloads and SQL installations; the deployment wrapper polls the command until it reaches a terminal state and verifies exit code `0` before returning.

Stage `30` downloads approximately 38 GiB of Windows and Ubuntu images. Source throttling and regional network conditions affect download time. Azure does not send the operator a separate completion notification. Keep the `./scripts/deploy.ps1 30` terminal open and wait for it to return successfully before starting stage `40`.

`all` and `20-30` start those image downloads before configuring the independent
internal network, then join image completion before creating guests. Individual
`20` and `30` remain available for scoped recovery. Failure of either prevents
stage `40`; a failed/interrupted wrapper can leave a cloud image download running,
so inspect it before any retry.

Stage `40` prepares the generalized parent once, then starts every clone before
waiting for individual Windows first-boot completion. Rename reboots overlap as
well; final heartbeat/SID checks and DC configuration still wait for the Windows
guests to be ready. OOBE and activation are never bypassed to gain concurrency.

Stage `00` deploys only the core network, including a reserved
`AzureBastionSubnet`. Bastion is enabled by default but submitted separately as
`arc-jumpstart-bastion` with `--no-wait` immediately afterward. The wrapper then
continues to stage `10`; nothing in stages `10`-`60` or final core readiness
depends on Bastion. Even a rejected Bastion submission is reported separately
and does not stop the core build. Set `DEPLOY_BASTION=false` to omit that request.

Stage `40` prepares and verifies a generalized Windows parent before cloning all
four Windows guests. It validates Sysprep evidence offline, rejects stale parent
markers or conflicting child disks, and checks OOBE, activation, and unique
machine SIDs before continuing. Do not manually alter the parent, readiness
markers, or guest setup state. See the
[SQL AG lessons](02-sql-ag-lessons.md#prepare-windows-first-then-install-sql-on-each-clone)
for implementation history and recovery boundaries.

Stage `45` downloads SQL Server 2025 Enterprise Developer media once to the host's persistent disk and installs the default database-engine instance on each of the three SQL guests. It uses the ODBC driver and `sqlcmd` tooling supplied by SQL Setup rather than installing an older command-line utility separately. Installation uses Windows authentication and grants the guest's local Administrator SQL sysadmin access; no SQL authentication password is configured. Stage `50` later grants the lab domain administrators SQL access, and stage `60` configures the domain service account and availability group through SQL Server's native WMI provider.

After preparing the shared media cache, stage `45` processes the three SQL guests
in parallel, with at most one worker per guest. Each worker holds its own
PowerShell Direct session and waits synchronously for that guest's SQL Setup.
Parallelism is between guests, never between installers on the same guest.
Guest diagnostics remain separate. If one worker fails, the stage still waits
for the other started workers to finish, then reports failure; it does not stop
their installers or allow stage `50` to proceed. Healthy instances are retained
on a retry. Shared host CPU and disk bandwidth mean three simultaneous installs
are not guaranteed to take the same time as a single install.

Running stage `45` accepts Microsoft's installer license terms. Developer edition is for development, testing, and training, not production. The host must be able to reach the Microsoft download endpoints and any redirect destinations. Guest installation runs synchronously as the guest's local Administrator through a held PowerShell Direct session and preserves setup diagnostics; it does not create an installation scheduled task. The stage checks SQL queries and sysadmin access before succeeding; a running Windows guest or SQL service alone is insufficient. A rerun verifies and retains a healthy installation rather than reinstalling it. A conflicting or broken existing instance is reported for investigation, not silently overwritten. Use `./scripts/lab.ps1 stage-log 45` for the host log.

Stage `45` installs `SQLENGINE` only, not `AZUREEXTENSION`. Stages `00` through
`60` prepare the infrastructure and sample workloads; they do not install or
connect Azure Arc or the Azure extension for SQL Server. After the agent stages
the launchers, the user completes [interactive Arc setup](03-arc-onboarding.md)
with their own Azure identity.

### Host-only SSMS 22

On new `deploy.ps1 all` builds, the independent `ssms` step runs **after**
numbered stage `60`. It stages Microsoft's signed SSMS 22 bootstrapper at
`C:\Users\Public\Desktop\vs_SSMS.exe`, then installs the minimal SSMS product
for all host users on the persistent `F:\ArcJumpstart\SSMS22` volume. Setup
executes only the verified copy under protected Program Files, never a
pre-existing executable on the Public Desktop. This
noninteractive install accepts Microsoft's SSMS terms, uses
`--quiet --wait --norestart`, and requires internet access to Microsoft's
installer/package endpoints plus at least 20 GiB free on both C: and F:.
No credentials or user-specific SSMS settings are installed, and the host is
never restarted by this step. An existing verified SSMS 22 is retained.
`INSTALL_HOST_SSMS=false` in the private `ENV_FILE` opts out of the default;
the explicit command below runs regardless of that setting.

The SSMS step is not a predecessor to any guest, Arc, or SQL readiness gate.
If it fails after the core stages, `all` reports an error instead of claiming
complete setup; the numbered stages remain intact. Arc launcher staging is
still attempted independently. The signed bootstrapper stays on Public Desktop
even when installer package retrieval or setup fails. To recover an existing
lab or retry **only** host SSMS (never rerun `all` after domain promotion):

```powershell
./scripts/deploy.ps1 ssms
./scripts/lab.ps1 stage-progress ssms
# After the run command is terminal:
./scripts/lab.ps1 stage-log ssms
```

Wait for an earlier SSMS Run Command or Visual Studio installation to finish
before retrying. A failure due to a partial product installation needs
diagnosis from Visual Studio Installer logs rather than an automatic repair.
Exit `3010` means a host reboot is required before using SSMS; do not reboot
while guests or another operation are active. Arrange a scoped host restart,
then rerun `deploy.ps1 ssms` to verify the installed executable. The bootstrapper
is a web installer, not offline installation media; if package downloads are
blocked, [Microsoft's offline layout procedure](https://learn.microsoft.com/en-us/ssms/install/create-offline)
is a separate operator action.

For stage `50`, read the [automated domain-controller runbook](02-domain-controller.md).
It explains the AD/DNS bootstrap sequence, credentials, service account,
domain joins, live diagnostics, verification criteria and safe retry boundaries.

The bundled SQL 2025 command-line utility uses newer encryption defaults. Stages `45`, `50`, and `60` explicitly trust the lab server's self-signed certificate for their `localhost` SQL probes (`sqlcmd -C`); this does not disable encryption or alter global certificate validation. For production or remote client connections, configure a trusted SQL Server certificate instead.

The stage `45` Azure command has a four-hour limit, and the wrapper waits for its terminal result. Do not launch domain setup while SQL installation is still running. Stage `50` requires both a successful stage `45` deployment and successful script execution.

### Isolate SQL engine installation on one guest

`artifacts/scripts/45-install-sql-engine.ps1` is the engine-only installer also
used by stage `45`. It runs full-media Setup
synchronously without Task Scheduler, tool installation, or automatic reboots.
It must run as the SQL guest's local Administrator, never on the Hyper-V host.
It verifies the ISO checksum and Microsoft Setup signature before installation.

After staging the verified ISO at
`C:\ArcJumpstart\Sql2025\SQLServer2025-x64-ENU-EntDev.iso` inside `JS-SQL-01`,
run this from an elevated PowerShell console on the Hyper-V host. Set `$scriptPath`
to a host-local copy of the repository's engine script:

```powershell
$credential = Get-Credential 'JS-SQL-01\Administrator'
$session = New-PSSession -VMName JS-SQL-01 -Credential $credential
try {
    Invoke-Command -Session $session -FilePath $scriptPath -ErrorAction Stop
}
finally {
    Remove-PSSession $session
}
```

Keep the session open until Setup returns. The script uses
`Start-Process -Wait -PassThru`, preserving console output and a result record in
`C:\ArcJumpstart\Logs\45-sql-engine\<timestamp>`. SQL's native diagnostics remain
under `C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log`.
`RebootRequired` is not a readiness result: reboot only that guest after Setup
finishes, reconnect, and rerun the script to verify the existing installation.
The verification checks Enterprise Developer edition, major version 17,
Windows-only authentication, local Administrator sysadmin access, server name,
and a real SQL query using the built-in .NET client.

This diagnostic deliberately disables Setup-time update discovery to isolate
the pinned media installation; it does not establish that the server is patched.
It neither satisfies the canonical stage `45` gate nor proves that `sqlcmd` and
stage `60` management dependencies are ready. Do not run it concurrently with
stage `45` or another SQL installer. Existing or partial instances are never
automatically repaired, upgraded, or replaced.

### Optional local SQL media check

The SQL downloads page offers a small interactive downloader, not the full installation media. Stage `45` instead downloads the full Enterprise Developer ISO directly from Microsoft and verifies its published length and SHA-256. The source URL, size (`1265688576` bytes), and checksum were obtained from the Enterprise Developer ISO manifest embedded in Microsoft's signed `SQL2025-SSEI-EntDev.exe`. Changing releases requires updating those values together; stage `45` rejects other media, including Evaluation and Standard Developer.

To inspect the media locally without executing the installer, choose a **new**
path outside the repository and run:

```powershell
./scripts/check-sql-media.ps1 `
  -Url 'https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLServer2025-x64-ENU-EntDev.iso' `
  -Output (Join-Path $HOME 'ArcJumpstart/SQLServer2025-x64-ENU-EntDev.iso') `
  -Sha256 'f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851'
```

The PowerShell checker requires HTTPS, verifies the full length, ISO/PE
structure and supplied hash, and never overwrites an existing output. Stage
`45` independently checks the downloaded media before installation, then
verifies SQL edition and login readiness on the guests.

Do not start the next numbered stage until its required predecessor reports success. Bastion is not a predecessor. If a host-script stage fails, run `./scripts/lab.ps1 stage-log <stage>`, correct the cause in the repository, and rerun only that number.

## Independent Bastion access

The default build submits Bastion after the network is ready and lets Azure
finish it. There is no monitoring loop, status gate or completion join, including
at the end of the core build. An accepted request is not a claim that browser
access is already available. Azure retains deployment state/errors if you later
need to troubleshoot access; there is no reason to inspect them during a normal
infrastructure build.

If access was omitted or its independent deployment failed, submit/retry it
without touching the working host or guests:

```powershell
./scripts/deploy.ps1 bastion
```

This explicitly requests Bastion regardless of `DEPLOY_BASTION`, and returns
after Azure accepts the request, not after provisioning finishes. Do not
resubmit while its earlier deployment is active. Failed access must be
investigated separately; it is not a reason to rebuild healthy infrastructure.

## Connect to the host

With Bastion enabled and its separate deployment succeeded:

1. Open the `${NAME_PREFIX}-host` VM in the Azure portal.
2. Select **Connect > Bastion**.
3. Sign in with `HOST_ADMIN_USERNAME` and `HOST_ADMIN_PASSWORD`.
4. Open Hyper-V Manager.

Stage `20` enables the Hyper-V Enhanced Session Mode host policy, and stage
`40` enables the Windows guest Remote Desktop Services prerequisite. VMConnect
can therefore resize supported Windows guest desktops and offer
clipboard/device redirection over the Hyper-V bus without guest network
connectivity. If a console opens in Basic Session Mode, use the Enhanced
Session Mode button on the VMConnect toolbar. The Linux guest continues to use
its normal console.

Expected nested VMs:

| VM | Expected role |
|---|---|
| `JS-DC-01` | Domain controller, DNS, cluster witness and SQL backup share |
| `JS-SQL-01` | Domain-joined standalone SQL Server |
| `JS-SQL-AG-01` | WSFC and AOAG replica |
| `JS-SQL-AG-02` | WSFC and AOAG replica |
| `JS-UBUNTU-01` | Standalone Linux workload |

### Connect to nested SQL from the host

The Hyper-V host is intentionally not joined to `jumpstart.lab`, and it does
not use the lab domain controller for DNS. In SSMS, connect by fixed IP rather
than by guest name:

| SQL guest | Server name in SSMS |
|---|---|
| `JS-SQL-01` | `192.168.128.11` |
| `JS-SQL-AG-01` | `192.168.128.12` |
| `JS-SQL-AG-02` | `192.168.128.13` |
| AG listener | `192.168.128.21` |

Stage `50` enables TCP `1433` on all three SQL guests only from
`192.168.128.0/24` and verifies the port from the host. It grants
`JUMPSTART\Domain Admins` SQL sysadmin. Because the host itself has no domain logon token, launch SSMS with network-only
domain credentials from the host desktop. For the default installation:

```powershell
$ssms = 'F:\ArcJumpstart\SSMS22\Common7\IDE\Ssms.exe'
if (-not (Test-Path -LiteralPath $ssms)) {
  $ssms = Join-Path $env:ProgramFiles 'Microsoft SQL Server Management Studio 22\Common7\IDE\Ssms.exe'
}
if (-not (Test-Path -LiteralPath $ssms)) { throw 'SSMS 22 is not installed on the host.' }
runas.exe /netonly /user:JUMPSTART\Administrator "`"$ssms`""
```

Enter the value of `NESTED_WINDOWS_PASSWORD` when `runas` prompts. In SSMS,
select **Windows Authentication**, enable **Trust server certificate** for
these lab instances, and connect to one of the IP addresses above. Do not put
the password on the command line.

Files downloaded on the host are not automatically visible inside a nested
guest. To restore an AdventureWorks backup, copy it through PowerShell Direct
using the nested guest's local Administrator credential:

```powershell
$credential = Get-Credential 'JS-SQL-01\Administrator'
$session = New-PSSession -VMName JS-SQL-01 -Credential $credential
Invoke-Command -Session $session {
  New-Item C:\ArcJumpstart\Backups -ItemType Directory -Force | Out-Null
}
Copy-Item C:\Path\To\AdventureWorks2025.bak `
  -Destination C:\ArcJumpstart\Backups\AdventureWorks2025.bak `
  -ToSession $session
Remove-PSSession $session
```

Use `NESTED_WINDOWS_PASSWORD` for that local credential. Restore the guest path
from SSMS. A lab deployed before this host-access rule was added can apply it
by rerunning stage `50`, then stage `60` only if its AG configuration still
needs recovery; do not rerun `all`.

## Stage 60 prerequisites and safety checks

Read the [AG build sequence and lessons learned](02-sql-ag-lessons.md) for
implementation details, permanent fixes, recovery boundaries, and evidence.

Complete the [domain-readiness checks](02-domain-controller.md#verify-the-domain-and-members)
before running `./scripts/deploy.ps1 60`. This stage requires working domain-admin
credentials and HTTPS access from the host to `cdn.powershellgallery.com`.

Stage `60` verifies completed Windows setup, SQL and update readiness, native
cluster validation, completion evidence for local cluster operations, quorum,
AG health, synchronized databases, and listener DNS/TCP/SQL access. It rejects
active operations, stale evidence, conflicting AG state, unknown validation
warnings, and incomplete database synchronization. Do not bypass these gates
or delete retained operation evidence to force a retry.

All nested guests share one Azure host, so a healthy cluster demonstrates the
software workflow—not physical fault-domain isolation. A complete clean replay
of the current saved pipeline remains the repeatability acceptance gate.

## Verify the availability group

On `JS-SQL-AG-01`, open an elevated PowerShell window and run:

```powershell
sqlcmd -S localhost -E -b -C -Q @"
SELECT
    ag.name,
    ar.replica_server_name,
    rs.role_desc,
    rs.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states rs ON ar.replica_id = rs.replica_id
WHERE ag.name = N'JS-AG-01';
"@
```

You should see `JS-AG-01`, one primary replica, one secondary replica, and healthy synchronization.

On each AG node, also check the local database state:

```powershell
sqlcmd -S localhost -E -b -C -Q @"
SELECT
    adc.database_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_suspended
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adc
    ON drs.group_id = adc.group_id
    AND drs.group_database_id = adc.group_database_id
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE ag.name = N'JS-AG-01'
    AND adc.database_name = N'JumpstartDB'
    AND drs.is_local = 1;
"@
```

Expect one row per node: `JumpstartDB`, `SYNCHRONIZED`, `HEALTHY`, and
`is_suspended=0`. The standalone guest should have `JumpstartStandaloneDB`
online, and `JS-AG-LSTN.jumpstart.lab` should resolve to `192.168.128.21`.

The Windows servers use fixed nested addresses: the domain controller is `.10`, standalone SQL is `.11`, and the two AG nodes are `.12` and `.13` on `192.168.128.0/24`.
