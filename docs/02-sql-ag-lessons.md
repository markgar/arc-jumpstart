# SQL availability group: build sequence and lessons learned

This is the record of what it took to bring the lab through stage `60` on
September 16, 2026. It separates fixes saved in the deployment code from
one-time recovery of the development lab. It is not an instruction to repeat
every repair on a new deployment.

Use this alongside the [deployment guide](02-deploy.md),
[domain-controller runbook](02-domain-controller.md), and
[troubleshooting guide](06-troubleshooting-cleanup.md).

## What actually succeeded

The successful stage `60` run was `20260916091449`. Its Managed Run Command
finished successfully at `09:18:58Z`; the outer Bicep deployment reported
`Succeeded` at `09:19:10Z`. Independent follow-up completed at `09:21:40Z`.

| Component | Observed result |
|---|---|
| Windows guests | All four completed native OOBE and reported Windows `LicenseStatus=1` through Azure KMS. |
| Domain | `jumpstart.lab` remained intact; DNS, domain services, member secure channels and domain-admin SQL access passed follow-up checks. |
| WSFC | `JS-SQLCLU`, with `JS-SQL-AG-01` and `JS-SQL-AG-02` both `Up`. |
| Quorum | The configured `File Share Witness` resource was `Online`. |
| SQL services | Both AG engines ran as `JUMPSTART\svc-sql`, using SQL Server 2025 Enterprise Developer. |
| Availability group | `JS-AG-01`: AG01 was `PRIMARY`, AG02 was `SECONDARY`. |
| AG database | `JumpstartDB` was `SYNCHRONIZED`, `HEALTHY` and not suspended on both replicas. |
| Standalone database | `JumpstartStandaloneDB` was `ONLINE`. |
| Listener | `JS-AG-LSTN.jumpstart.lab` resolved to `192.168.128.21`; TCP `1433` and an integrated-authentication SQL query from the standalone guest succeeded. |

No original DC or SQL VM was rebuilt, and no SQL engine was reinstalled during
this recovery. The temporary Windows proof VMs and their isolated disks were
removed afterward; original source images and live differencing-disk parents
were preserved.

The saved stage `50` and `60` scripts were subsequently compared byte-for-byte
with the script contents of their successful Azure Run Commands. Both matched.
The implementation is therefore in the repository, not only in interactive
diagnostics.

## The intended build sequence

Run one stage at a time; retain the previous stage's successful result before
continuing.

| Stage | Responsibility and required outcome |
|---|---|
| `00`-`30` | Build the Azure host, nested networking and persistent image cache. |
| `40` | Generalize the Windows-only parent, supply the correct unattended setup key, create the guests, finish native OOBE, activate Windows, then rename/restart and verify unique machine SIDs. |
| `45` | Install SQL after cloning. The current code installs across three guests in parallel while allowing only one installer per guest. |
| `50` | Establish AD DS/DNS, create the SQL service account, join the SQL members and grant the intended domain SQL access. |
| `60` | Prepare SQL nodes and the standalone sample database; validate the nodes; create or retain the intended cluster; configure witness/listener permissions and quorum; enable HADR; create or retain the intended AG and sample database; verify the listener. |

Stage `60` checks the real cluster and computer account before configuring
witness permissions. SQL service-account changes use SQL's native WMI provider.
HADR enablement uses the pinned Microsoft `SqlServer` module and the documented
`Enable-SqlAlwaysOn` command. Neither operation is replaced by an arbitrary
Windows service edit or a HADR registry write.

## Lessons now reflected in the code

### Prepare Windows first, then install SQL on each clone

We abandoned cloning the preconfigured SQL image for this lab. Generalizing
Windows is not the same as preparing a SQL installation for duplication.
The saved path creates distinct Windows guests first, then installs SQL Server
2025 Enterprise Developer from verified Microsoft media. Evaluation and Standard
Developer are not substitutes for the chosen edition.

SQL Setup runs synchronously inside a held guest session. Parallelism is
between the three guests, never between installers on one guest. A retry
verifies and retains healthy installations rather than blindly reinstalling
them. The original successful installations were sequential; the later
parallel implementation still needs a fresh end-to-end installation run.

### Windows can be reachable while setup is unfinished

Heartbeat, working PowerShell Direct, unique SIDs, functioning AD and even
running SQL did not establish that Windows Setup had finished. Cluster
diagnostics showed the Cluster Service waiting for OOBE; later RPC errors were
symptoms, not the initial cause.

The consoles showed an unanswered product-key page. Stage `40` now supplies the
edition-matching KMS client key in the `Microsoft-Windows-Shell-Setup`
**specialize** pass, then requires native `OOBEComplete` and
`IMAGE_STATE_COMPLETE` before rename/restart. Stage `60` independently rejects
unfinished setup.

Entering an AVMA key finished the setup page on a disposable proof VM, but
activation failed with `0xC004FD02`. An activated outer Datacenter VM was not
proof that AVMA would work in this Azure topology. The documented Azure KMS
path activated the guest successfully. Public client setup keys select an
activation method; they do not grant Windows licensing rights.

The parent cache now has a configuration revision. Old timestamp-only markers
do not prove that the new answer file was used. A stale marker or mismatched
child parent stops the stage rather than silently rebuilding live guests.
Never alter a parent backing differencing disks or relabel an old marker to
pretend it is current.

### Domain readiness needs actual AD and DNS evidence

The DC needed qualified credentials after promotion, ADWS running, its own DNS
address configured before promotion/discovery, and the expected AD-integrated
zones and locator records. Zone creation alone did not prove Netlogon had
registered the LDAP SRV record.

Stage `50` now verifies these conditions and restarts Netlogon only when the
required record is missing. Members wait for their static IP to become
`Preferred` and force DC discovery before joining. A `New-NetIPAddress` return
does not mean duplicate-address detection has finished.

The full sequence and repair-versus-rebuild boundary are documented in the
[domain-controller runbook](02-domain-controller.md). A missing cluster
computer account is not, by itself, evidence that the domain needs rebuilding.

### Starting work is not evidence that it completed

An earlier scheduled-task implementation saw a queued task and an old success
result as completion. No cluster or fresh validation report actually existed.
This later appeared as a failure to resolve the cluster computer account for
witness permissions.

Cluster operations now run in a credentialed local PowerShell process inside
a held PowerShell Direct session. Each attempt records its identity, scripts,
stdout/stderr, result and exit observation. Process identity and completion
must agree. This also supplies the local execution context needed by cluster
commands without enabling CredSSP.

Do not replace active work, delete its marker, or interpret an operation's
timeout budget as permission to kill cluster configuration.

### Generated commands must be exercised, not merely parsed

Continuation backticks inside an expandable here-string were consumed by the
outer string. The generated `New-Cluster` command consequently lost its
mandatory arguments.

Generated `New-Cluster`, `Add-ClusterNode` and `Set-ClusterQuorum` calls now
keep their arguments on one line. Regression tests execute generated calls
against mandatory-parameter mocks; parsing valid PowerShell alone would not
catch the original defect.

### Validate the real report and the specific warning

Native `Test-Cluster` output was HTML, not XML. Its returned report path mattered:
supplying an extension in `-ReportName` could produce a doubled `.htm` extension.
Native warning records also differed from simplified fixtures, including the
two periods in `The test reported some warnings..` and multiline summaries.

The saved parser uses the actual report, per-test details, captured warning
records and selected scope. Only the established single-network-path warning
is allowed. A category summary or successful subcheck cannot override a
failed or warning-bearing test that needs investigation.

The lab selects Inventory, Network and System Configuration, not shared-storage
tests. Both replicas still share one outer Azure host: this is not evidence of
production fault isolation.

### Update inventory and pending reboots are separate questions

Offline Windows Update inventory initially failed with `0x80248014`, even
though the update service was registered. Matching `Get-HotFix` lists did not
prove the failed inventory worked.

For that exact error, the code performs one online metadata search for
`IsInstalled=1`, then requires a successful offline search. It does not install
updates, reset the data store or change update sources/policies.

Later, both inventories succeeded and native validation reported matching
updates, but it recommended rebooting AG02. Common WUA/CBS flags subsequently
read false even though the node's boot time had not changed. A COM-only
preflight was considered and removed because it missed this observed case.

The native report was preserved, the lack of active cluster/installer work was
established, and AG02 received one planned reboot before cluster creation.
SQL and the secure channel were checked afterward. The next native validation
passed. This was an operator recovery action, not a new blanket reboot policy.
Use the maintenance/failover procedure if a cluster already hosts workloads.

### SQL readiness requires correct types and a bounded startup wait

The original readiness query attempted an implicit `sql_variant` conversion.
`SERVERPROPERTY` results must be explicitly converted before concatenation.
The corrected query is:

```sql
SET NOCOUNT ON;
SELECT CONCAT(
    CONVERT(int, SERVERPROPERTY('IsHadrEnabled')),
    ',',
    CONVERT(int, SERVERPROPERTY('HadrManagerStatus'))
);
```

Only **`1,1`** is ready. SQL error 257, authentication/certificate failures,
malformed results and unknown values must not be treated as ordinary startup
delays.

The new SQL process on AG02 briefly returned `1,2` about two seconds into
startup. Its error log showed initialization in progress; the same process
later returned `1,1` without another restart or repair. `Wait-LabSqlHadrReady`
now logs and waits through this observed transition within its deadline.
Persistent `1,2` still fails with the last result and ERRORLOG guidance. No
automatic restart loop or success fallback was added.

### Verify resources and connections, not display labels alone

On this Windows Server 2022 build, `Get-ClusterQuorum` displayed
`QuorumType=Majority` and `QuorumResource=File Share Witness`. Rejecting that
solely because it was not an older `NodeAndFileShareMajority` display value
would have been a false failure.

Verify the configured witness resource is online, both intended nodes are up,
and the database replicas are healthy and synchronized. Listener verification
must include DNS, TCP and an actual SQL query from another guest, not just the
existence of a listener object. See the [verification commands](02-deploy.md#verify-the-availability-group).

### Protected Azure parameters do not make raw host logs safe

Windows PowerShell transcript startup headers included the process command
line, including credential arguments. The `stage-log` viewer now suppresses
startup headers before selecting the tail, redacts configured sensitive values
from both output streams and preserves the command's exit status.

This is display protection, not sanitization of stored transcripts. Do not
publish raw host logs. Review exports and rotate credentials if unredacted
material has been shared. Do not put passwords, registration keys or SAS tokens
in this document, tests, issues or screenshots.

## Permanent fixes versus development-only recovery

| Action | How it should be used now |
|---|---|
| Supply the Windows key and complete/activate first boot | Automated in stage `40`; genuine setup readiness is also enforced in stage `60`. |
| Enter a key through the original guests' setup consoles | One-time recovery of the old lab, not a step required by the new template. |
| Correct ADWS, DNS, Netlogon and member discovery | Implemented in stage `50`, with its prerequisites and retry boundaries documented. |
| Run cluster commands locally with trustworthy completion evidence | Implemented in stage `60`; do not revive the old scheduled-task completion shortcut. |
| Repair the specific missing update inventory metadata | Narrowly implemented in stage `60`; unrelated update errors still stop. |
| Reboot AG02 following the native report | Incident-specific planned recovery. Do not hardcode an unconditional AG02 reboot or delete reboot flags. |
| Wait for typed SQL readiness, including observed startup transitions | Implemented in stage `60`; success still requires `1,1`. |
| Rebuild the DC, SQL engines or working cluster | Not needed for this recovery. Preserve healthy state on retries. |
| Remove disposable proof VMs and isolated disks | Completed after proof; never delete the original shared parents as cleanup. |

## Where the implementation and regression coverage live

| Area | Files |
|---|---|
| Windows setup, activation, cache and disk safety | [`40-create-nested-vms.ps1`](../artifacts/scripts/40-create-nested-vms.ps1), [`test-stage40.ps1`](../scripts/test-stage40.ps1) |
| Clean SQL installation and per-guest parallelism | [`45-install-sql.ps1`](../artifacts/scripts/45-install-sql.ps1), [`45-install-sql-engine.ps1`](../artifacts/scripts/45-install-sql-engine.ps1), [`test-stage45.ps1`](../scripts/test-stage45.ps1) |
| Domain bootstrap and discovery | [`50-configure-domain.ps1`](../artifacts/scripts/50-configure-domain.ps1), [`test-stage50.ps1`](../scripts/test-stage50.ps1) |
| Local operation evidence, validation parsing, cluster/CNO checks, SQL/HADR and listener | [`60-configure-sql-ag.ps1`](../artifacts/scripts/60-configure-sql-ag.ps1), [`test-stage60.ps1`](../scripts/test-stage60.ps1) |
| Safe transcript display | [`lab.sh`](../scripts/lab.sh), [`show-stage-log.py`](../scripts/show-stage-log.py), [`test-stage-log.py`](../scripts/test-stage-log.py) |
| Repository validation entry point | [`validate.sh`](../scripts/validate.sh) |

The regressions include the exact native warning format, generated cluster
arguments, semantic SQL errors, `1,2` to `1,1` progression, persistent-state
timeouts and credential/header redaction. These tests protect known lessons;
they do not replace the live per-stage gates.

## Recovery workflow for the next operator

1. Confirm the failed Azure command is terminal; distinguish deployment state
   from script execution and real guest readiness.
2. Read `./scripts/lab.sh stage-log 60`. Preserve the relevant validation report
   and `C:\ArcJumpstart\Operations\<operation>\<attempt>` evidence securely.
3. Identify the first failing gate. Check actual console/setup, AD/DNS, update
   report, process receipt or SQL ERRORLOG evidence appropriate to that gate.
4. Correct the specific cause in code or follow the documented operator action.
   Do not clear safety markers, drop conflicting databases or rebuild healthy
   infrastructure to bypass the failure.
5. After active work has ended and the prerequisite is healthy, rerun
   `./scripts/deploy.sh 60`. Keep a healthy existing cluster and AG.
6. Verify the database and listener outcomes, not only a zero exit code.

Stage `40` is not a repair command for a promoted DC. For an existing domain,
use the [domain recovery boundaries](02-domain-controller.md#failures-evidence-and-safe-retries)
and the [Windows setup guidance](06-troubleshooting-cleanup.md#common-failures).

## What this does not prove yet

The current lab completed stages through `60`. A separate fresh generalized
Windows Server 2022 Standard parent and untouched clone also completed OOBE
and KMS activation without keyboard input, rename or a forced first-boot restart.

A complete clean replay of all updated stages, including fresh parallel SQL
installations, has not been performed. The documented Datacenter key mapping
was not the live image used in that proof. Arc onboarding, assessment, migration
compatibility and cutover remain separate learner exercises, not completed
outcomes or additional automation hidden in stage `60`.

## Microsoft references

- [OOBEComplete API](https://learn.microsoft.com/en-us/windows/win32/api/oobenotification/nf-oobenotification-oobecomplete)
- [Unattended Shell-Setup ProductKey](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-productkey)
- [Azure AVMA errors and KMS activation](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-vm-activation-error-0xc004fd01-0xc004fd02)
- [KMS client keys and licensing caveats](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys)
- [Create a failover cluster](https://learn.microsoft.com/en-us/windows-server/failover-clustering/create-failover-cluster)
- [New-Cluster remoting restriction](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/new-cluster?view=windowsserver2022-ps)
- [Windows Update installed-update search](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search)
- [Windows Update RebootRequired property](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-isysteminformation-get_rebootrequired)
- [Enable-SqlAlwaysOn](https://learn.microsoft.com/en-us/powershell/module/sqlserver/enable-sqlalwayson)
- [SERVERPROPERTY](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17)
- [sql_variant conversion rules](https://learn.microsoft.com/en-us/sql/t-sql/data-types/sql-variant-transact-sql?view=sql-server-ver17#converting-sql_variant-data)
