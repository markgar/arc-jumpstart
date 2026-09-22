# Deploy and inspect the lab

## Configure

```bash
ENV_FILE="$HOME/.config/arc-jumpstart/lab.env" # macOS example; any approved absolute path works
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

Stage `40` prepares a local generalized Windows parent before cloning all four Windows guests. In each temporary template, it removes a removable, unprovisioned Administrator Edge AppX registration when a newer Edge version is provisioned, or when the registration is the known source-image version `120.0.2210.61`. Fresh source images can have that old registration without any provisioned Edge replacement; cleanup does not depend on waiting for an Edge update. It preserves all provisioned versions and other applications, and fails explicitly if an unprovisioned registration remains under another user or cannot be safely removed. This addresses Sysprep error `0x80073cf2` seen in the source images without requiring manual package cleanup.

Sysprep runs through a SYSTEM task using `/generalize /oobe /quit`. The task records the result at `C:\Windows\System32\Sysprep\ArcJumpstart-Result.json` and requests shutdown, including on failure so the host can inspect the disk. Generalization can disconnect PowerShell Direct, so the host does not depend on a live guest session to determine success. After the VM reaches `Off`, the host mounts its disk read-only and checks the recorded process exit code, Windows image state, and `Sysprep_succeeded.tag` before writing the parent's `.ready` marker. A task result of zero or a VM reaching `Off` alone is not proof of generalization. Failures include the guest's Panther error-log tail in the stage transcript; paused or saved VMs fail immediately, and shutdown has a 30-minute timeout. Do not manually shut down, reboot, or resume templates while stage `40` is active.

After a failure, preserve the transcript and guest diagnostics before retrying. Once the previous Azure Run Command has terminated and its cleanup is complete, an incomplete template without a `.ready` marker can be rebuilt from the unchanged downloaded source image only if no dependent lab disks exist. Manual repairs to that temporary template are not required or retained by the retry. Unique Windows SIDs are still checked after the final guests boot; SQL functionality must also be verified before continuing the SQL exercises.

The generalized-parent readiness marker includes a configuration revision.
Older timestamp-only markers do not prove that the answer file includes the
product-key fix. Stage `40` rejects stale markers and conflicting child-disk
parents rather than silently upgrading the cache or deleting existing guests.
Never edit a marker to make an old parent appear current, or alter a parent
backing differencing disks. For an existing lab, finish supported setup inside
the affected guests, or deliberately rebuild in a fresh lab after preserving
needed data. Stage `40` is a bootstrap stage, not an in-place repair tool for an
already-promoted DC: its local-account and machine-SID checks assume workgroup
guests.

The updated path was also exercised independently with the default Windows
Server 2022 Standard source: a new isolated parent passed offline Sysprep
verification, and its new clone completed native OOBE and Azure KMS activation
without keyboard input, renaming or a forced first-boot restart. This is
separate evidence from repairing the original guests in place; it does not
establish that arbitrary replacement images or other editions were live-tested.

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

The command downloads the entire file, rejects incomplete or non-ISO content, and verifies the checksum before publishing the output file. It does not prove Windows setup, SQL edition, or login readiness; stage `45` checks those on the guests. A full local download was verified in about 19 seconds during live development, but this is not a network performance guarantee.

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

Older builds deployed Bastion inside stage `00`. Already-running deployments
retain their submitted template; updating this repo does not remove their old
wait. Do not start a second competing `all` invocation. New submissions use
`arc-jumpstart-bastion`, not the old nested deployment. Older labs created
with Bastion disabled may need a scoped stage `00` network update to reserve
the access subnet before adding Bastion; do not rerun `all` for this.

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
root causes encountered during development, their permanent fixes, one-time
recovery actions and the exact scope of the successful deployment.

Complete the [domain-readiness checks](02-domain-controller.md#verify-the-domain-and-members)
before running `./scripts/deploy.sh 60`. This stage requires working domain-admin
credentials and HTTPS access from the host to `cdn.powershellgallery.com`.

Stage `60` first checks the native `OOBEComplete` state on both AG guests.
An unfinished setup or a failed state query stops immediately, before downloads
or cluster configuration. This guard does not finish OOBE or modify setup flags;
resolve the Windows first-boot issue before retrying.

Cluster operations run in a local Windows PowerShell child process on an AG
guest, launched with the domain credential from a held PowerShell Direct session.
The caller waits for the process and checks fresh completion/exit evidence;
starting a process is not completion. This supplies a local execution context
and credentials for cross-machine operations without enabling CredSSP. See
[New-Cluster's remoting restriction](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/new-cluster?view=windowsserver2022-ps)
and [Start-Process lifetime and wait behavior](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1#notes).
Operations retain scripts, stdout/stderr, result and exit evidence under
`C:\ArcJumpstart\Operations\<operation>\<attempt>\`;
`C:\ArcJumpstart\Operations\active.json` records prior work on the guest.
The operation budgets are evaluated after the synchronous
process finishes, not enforced by killing an in-progress cluster operation.
Inspect retained evidence before retrying; do not delete active markers to
bypass an unresolved operation.

A consistent terminal failure can be retried after its process is inactive and
locks are released; the old attempt's diagnostics remain available. Active,
unknown or inconsistent completion evidence blocks a new attempt.

The stage downloads Microsoft `SqlServer` PowerShell module **22.4.5.1** once
(47,388,419 bytes), verifies its pinned size/SHA512 against the
[published package metadata](https://www.powershellgallery.com/api/v2/Packages(Id='SqlServer',Version='22.4.5.1')),
and copies it into the guests. The host cache is
`F:\ArcJumpstart\SqlServerModule\sqlserver.22.4.5.1.nupkg`; guest extraction is
`C:\ArcJumpstart\Modules\SqlServer\22.4.5.1`. This dependency supplies the documented
`Enable-SqlAlwaysOn` command. SQL service-account changes use native SQL WMI;
Always On enablement does not directly write the HADR registry flag. Instances
are enabled and checked one at a time, including restart/readiness handling.

The SQL readiness probe explicitly converts both `SERVERPROPERTY` results to
integers and requires `IsHadrEnabled=1` and `HadrManagerStatus=1`. Deterministic
SQL errors, such as a type-conversion failure, stop immediately instead of being
repeated until a startup timeout. Valid not-ready states and recognized startup
connection failures use a bounded wait; a running Windows service alone is not
sufficient.

Before validation, both AG guests verify their installed-update inventory with
an offline Windows Update Agent search. Only error `0x80248014` triggers one
online metadata search for already installed updates, followed by a required
successful offline recheck. This initializes missing inventory metadata without
invoking an update downloader or installer, changing update policies or sources,
or deleting the data store. Guests therefore need access to their configured
update source when this initialization is required; an already healthy offline
inventory requires no online search. Other errors and partially successful
results stop the stage. See Microsoft's [update-search API](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search).

Before creating WSFC, stage `60` runs `Test-Cluster` for Inventory, Network and
System Configuration. Shared-storage tests are excluded because the AG uses
independent SQL disks, not shared cluster storage. Reports remain on `JS-SQL-AG-01`
under `C:\ArcJumpstart\Logs\ClusterValidation\Validation-<UTC>.htm`, with
`.warnings.txt` and `.scope.txt` sidecars. Only narrowly recognized warnings about
the lab's single network path/interface pair are accepted. Failed, canceled,
unrun or unrecognized results block creation; do not bypass a report because
the environment is a lab. All nodes share one Azure host, so these checks do
not establish physical fault isolation.

Existing unrelated AG state is not adopted, and a conflicting secondary database
is not automatically dropped. Preserve its data and investigate before retrying.
The final listener check runs from the standalone SQL guest under a local
domain-admin process: it verifies DNS, TCP port `1433`, and an integrated-authentication SQL query
against the intended primary database. This remote lab check also uses `-C` to
trust the lab certificate; production clients need properly trusted certificates.
The development lab completed stage `60` and its listener SQL check. Independent
follow-up confirmed both cluster nodes and the witness online, one primary and
one secondary, `JumpstartDB` synchronized and healthy on both replicas,
`JumpstartStandaloneDB` online, and listener DNS/TCP reachability. The separate
fresh stage `40` image proof also passed. A later clean-room recovery completed
fresh parallel SQL installations and stages through `60`, but reused the earlier
foundation/host allocation. A complete replay beginning with the updated stage
`00` has not yet been performed; retain the per-stage gates on new deployments.

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
