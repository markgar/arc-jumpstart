# Deploy and inspect the lab

## Configure

```bash
ENV_FILE="$HOME/.config/arc-jumpstart/lab.env"
mkdir -p "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  install -m 600 deploy.env.example "$ENV_FILE"
fi
${EDITOR:-vi} "$ENV_FILE"
./scripts/validate.sh
ENV_FILE="$ENV_FILE" ./scripts/preflight.sh infra
```

The wrapper uses your signed-in Entra user to deploy Azure resources. Each PowerShell artifact is embedded in its Bicep-managed Run Command, avoiding a public deployment storage dependency. This is unrelated to the local Active Directory domain created inside the nested lab.

## Automated deployment

Infrastructure preparation belongs to the automation, not to the learner.
For a new lab with validated configuration and an authenticated Azure CLI user:

```bash
./scripts/validate.sh &&
ENV_FILE="$ENV_FILE" ./scripts/preflight.sh infra &&
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh all
```

The [agent bootstrap runbook](00-agent-bootstrap.md) defines the inputs,
monitoring/recovery workflow and required handoff state. Use the individual
stages below for inspection and scoped recovery, not as a requirement for the
learner to construct the environment manually.

## Inspect or resume individual stages

```bash
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh 00
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh 10
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh 20-30
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh 40
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh 45
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh 50
ENV_FILE="$ENV_FILE" ./scripts/deploy.sh 60
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

Stage `30` downloads approximately 38 GiB of Windows and Ubuntu images. Source throttling and regional network conditions affect download time. Azure does not send the operator a separate completion notification. Keep the `./scripts/deploy.sh 30` terminal open and wait for it to return successfully before starting stage `40`.

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

Running stage `45` accepts Microsoft's installer license terms. Developer edition is for development, testing, and training, not production. The host must be able to reach the Microsoft download endpoints and any redirect destinations. Guest installation runs synchronously as the guest's local Administrator through a held PowerShell Direct session and preserves setup diagnostics; it does not create an installation scheduled task. The stage checks SQL queries and sysadmin access before succeeding; a running Windows guest or SQL service alone is insufficient. A rerun verifies and retains a healthy installation rather than reinstalling it. A conflicting or broken existing instance is reported for investigation, not silently overwritten. Use `./scripts/lab.sh stage-log 45` for the host log.

Stage `45` installs `SQLENGINE` only, not `AZUREEXTENSION`. Stages `00` through `60` prepare the infrastructure and sample workloads; they do not install or connect Azure Arc or the Azure extension for SQL Server. The learner performs those actions by following [Arc and Arc SQL onboarding](03-arc-onboarding.md).

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

### Check SQL media locally before deployment

The SQL downloads page offers a small interactive downloader, not the full installation media. Stage `45` instead downloads the full Enterprise Developer ISO directly from Microsoft and verifies its published length and SHA-256. The source URL, size (`1265688576` bytes), and checksum were obtained from the Enterprise Developer ISO manifest embedded in Microsoft's signed `SQL2025-SSEI-EntDev.exe`. Changing releases requires updating those values together; stage `45` rejects other media, including Evaluation and Standard Developer.

This check runs on macOS, Linux, or Windows with Python, without executing the installer. Choose a new output path outside the repository:

```bash
python3 scripts/check-sql-media.py \
  --url 'https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLServer2025-x64-ENU-EntDev.iso' \
  --output /tmp/SQLServer2025-x64-ENU-EntDev.iso \
  --sha256 f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851
```

The command downloads the entire file, rejects incomplete or non-ISO content,
and verifies the checksum before publishing the output file. It does not prove
Windows setup, SQL edition, or login readiness; stage `45` checks those on the
guests.

Do not start the next numbered stage until its required predecessor reports success. Bastion is not a predecessor. If a host-script stage fails, run `./scripts/lab.sh stage-log <stage>`, correct the cause in the repository, and rerun only that number.

## Independent Bastion access

The default build submits Bastion after the network is ready and lets Azure
finish it. There is no monitoring loop, status gate or completion join, including
at the end of the core build. An accepted request is not a claim that browser
access is already available. Azure retains deployment state/errors if you later
need to troubleshoot access; there is no reason to inspect them during a normal
infrastructure build.

If access was omitted or its independent deployment failed, submit/retry it
without touching the working host or guests:

```bash
./scripts/deploy.sh bastion
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
`JUMPSTART\Domain Admins` SQL sysadmin. Because the host itself has no domain
logon token, launch SSMS with network-only domain credentials:

```powershell
$ssms = Get-ChildItem "$env:ProgramFiles\Microsoft SQL Server Management Studio*" `
  -Filter Ssms.exe -Recurse -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty FullName
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

Read the [AG build sequence and lessons learned](02-sql-ag-lessons.md) for the
implementation details, permanent fixes, recovery boundaries, and evidence.

Complete the [domain-readiness checks](02-domain-controller.md#verify-the-domain-and-members)
before running `./scripts/deploy.sh 60`. This stage requires working domain-admin
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
