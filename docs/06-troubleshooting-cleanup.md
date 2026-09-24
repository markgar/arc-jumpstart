# Troubleshooting and cleanup

## Bastion is slow or failed

Bastion is enabled by default but is independent of the lab build. Its
provisioning must not block any numbered stage or core-readiness check.
Let Azure finish the request without monitoring it during the build. If you
later need to troubleshoot access, inspect `arc-jumpstart-bastion` in Azure.
A submission warning or failed access deployment can be repaired independently:
retry only `./scripts/deploy.ps1 bastion` after the previous request is terminal.
Do not recreate healthy infrastructure to repair browser access.

Builds started before this separation still use their submitted stage `00`
template. See [independent Bastion access](02-deploy.md#independent-bastion-access)
for that boundary and the standalone commands.

## Read stage logs

For concise live progress while a stage is running:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
./scripts/lab.ps1 stage-progress 40
```

This reads the already-running Managed Run Command's Azure instance view:
execution state, start/end, elapsed time and bounded latest output. It returns
without launching another VM command, does not require Blob Storage, and does
not start, resume or replace the stage. Missing/repeated output is a reason to
inspect the reported wait—not automatic permission to retry.

Read the latest host transcript for a stage:

```powershell
./scripts/lab.ps1 stage-log 10
./scripts/lab.ps1 stage-log 20
```

The helper retrieves the latest matching transcript from `C:\ArcJumpstart\Logs` through Azure Run Command. Managed Run Command instance view also retains the most recent command status and output.

Treat raw host transcripts as sensitive. Windows PowerShell 5.1 includes the
process command line in its automatic `Host Application` header; protected
Run Command parameters can therefore appear there as plaintext credentials.
The viewer's redaction does not sanitize files already stored on the host.
Do not publish raw transcripts or attach them to issues. Review any exported
diagnostics and rotate credentials if an unredacted log has been shared.

## Common failures

The [AG lessons and recovery record](02-sql-ag-lessons.md) ties these symptoms
to the successful build, the corresponding code/tests and actions that should
not be repeated blindly on a fresh or already-working lab.

**Stage 10 cannot install Hyper-V**

- Confirm the chosen Azure VM size supports nested virtualization.
- Confirm the host is using the explicitly configured Standard security type.
- Wait for the scheduled restart before running stage `20`.

**Stage 30 times out or fails**

- Rerun stage `30`; completed VHDXs are skipped.
- Confirm the public Jumpstart blob URLs still exist.
- Copy the artifacts to an approved private container and set `IMAGE_SOURCE_URL` and, when required, `IMAGE_SOURCE_SAS_TOKEN` in the approved private `ENV_FILE`.

**PowerShell Direct cannot sign in**

- Wait for the guest heartbeat and first-boot specialization.
- Confirm `NESTED_WINDOWS_PASSWORD` matches the image.
- Use Hyper-V console access to inspect OOBE, boot, or credential errors.

**Stage 40 reports duplicate Windows machine SIDs**

- Do not bypass the check for the domain/cluster lab.
- Confirm that the configured source VHDX is a generalized image.
- Point `IMAGE_SOURCE_URL` and the matching image file name in the approved private `ENV_FILE` at an approved generalized replacement.
- Rerun stage `30`, remove the failed nested child VMs/disks from the host, and rerun stage `40`.

**Stage 40 waits for OOBE, or reports a stale generalized parent**

- Inspect the guest console. The original Windows clones were waiting at
  "It's time to enter the product key", even though PowerShell Direct, AD and
  SQL worked. The corrected answer file supplies the edition-matching KMS
  client setup key in the specialize pass. Do not skip the native OOBE check
  or fabricate `IMAGE_STATE_COMPLETE`.
- An old timestamp-only `.ready` marker is not compatible with the updated
  answer file. Preserve the existing parent and its dependent disks. Do not
  relabel the marker, modify the parent in place, or rerun stage `40` against
  an already-promoted DC as a repair procedure.
- Existing guests can complete the supported Windows Setup flow without
  reinstalling AD or SQL. Confirm the edition before supplying its
  [Microsoft-published KMS client key](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys).
  Follow the [documented Azure KMS activation steps](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-vm-activation-error-0xc004fd01-0xc004fd02);
  verify `LicenseStatus=1` separately from setup completion. An AVMA key
  finished the setup page in a disposable proof, but activation failed with
  `0xC004FD02`; that was not a successful activation solution.
- If activation fails, inspect the Windows activation error and DNS/TCP `1688`
  connectivity to `azkms.core.windows.net`. Do not treat a zero script exit
  code or "product key installed" message as proof of activation.
- Before resuming domain/cluster work, verify genuine setup completion on
  every Windows guest and recheck DNS, secure channels and SQL access. A
  successful disposable-VM experiment does not establish the originals' state.
- The original DC and three SQL guests were subsequently recovered in place:
  all four reported native OOBE completion, `IMAGE_STATE_COMPLETE` and
  `LicenseStatus=1`. Independent domain, secure-channel and SQL sysadmin checks
  passed afterward. No domain identity, Windows VM or SQL installation was
  rebuilt. This recovery is distinct from validating a fresh unattended image.
- A child disk using a different parent is retained and reported as a conflict,
  not automatically deleted. Rebuild only after explicitly deciding what data,
  domain identity, Arc connections and migration state must be preserved.

**Stage 45 SQL installation fails**

- Read `./scripts/lab.ps1 stage-log 45` and SQL Setup logs under `C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log` inside the affected guest.
- Confirm Microsoft download endpoints are reachable from the host and `SQL_DOWNLOAD_URL` points to SQL Server 2025 Enterprise Developer media.
- Do not repair a cloned ArcBox SQL image in place: stage `40` must create the SQL guests from the Windows-only parent before stage `45` installs SQL.
- Correct the repository configuration or installer failure, then rerun stage `45`. Existing healthy instances are retained; conflicting or unhealthy instances require investigation.
- Stage `45` must prove local Administrator integrated-auth SQL access before stage `50` can create domain logins.
- Engine-only progress and results are under `C:\ArcJumpstart\Logs\45-sql-engine` in each guest. Compare SQL Setup's `Detail.txt` size and modification time before treating a quiet Azure command as stalled.
- Do not start a second installer while Setup is active. A legacy `ArcJumpstart-InstallSql*` task in `Queued` or `Running` state blocks the new synchronous path; inspect it and confirm no installation is active before explicitly canceling it.
- Stage `60` uses `SqlService.SetServiceAccount` in `root\Microsoft\SqlServer\ComputerManagement17`; this account-change operation does not require a separately installed SMO assembly. Always On enablement separately uses the pinned `SqlServer` module described in the [deployment guide](02-deploy.md#stage-60-prerequisites-and-safety-checks). A missing provider or nonzero method return is an error to investigate, not a reason to change the service account using Windows Services.

**Domain join or cluster creation fails**

See the [stage 50 domain-controller runbook](02-domain-controller.md) for the
complete bootstrap sequence, read-only guest checks, credential handling and
safe retry boundaries.

- If the Cluster Service pauses during creation and its Diagnostic log says it is waiting for OOBE completion, inspect Windows Setup rather than treating later RPC endpoint errors as the root cause. All four original clones were observed with `OOBEInProgress=1`, `IMAGE_STATE_UNDEPLOYABLE`, and an active setup wizard despite working SQL/domain access. Stage `40` now waits for genuine first-boot completion before rename/reboot. Finish the supported setup flow or correct the image/answer file; never set OOBE registry flags to pretend completion.
- If stage `60` cannot translate `JUMPSTART\JS-SQLCLU$` while assigning witness permissions, first establish that cluster creation actually completed and that its cluster name object exists in AD. An absent CNO is not evidence that AD needs rebuilding. During development, Task Scheduler events showed the creation task being queued and then prematurely deleted; no validation report or cluster had been created. A changed task timestamp or an old zero result must not count as completion.
- Preserve the validation reports, guest task output and Task Scheduler Operational events. A `Queued` or `Running` task is not safe to replace blindly. Do not grant witness permissions to another account or fabricate a cluster identity to bypass missing cluster creation.
- The corrected stage uses credentialed local processes instead of scheduling new cluster tasks. Inspect `C:\ArcJumpstart\Operations` on the relevant guest for current-process diagnostics and retained completion evidence. Old scheduler history remains useful when investigating an earlier deployment.
- A `Validate Software Update Levels` warning with `0x80248014` means Windows Update could not find a service in its data store. In the observed image, the default Windows Update service was already registered, but an offline installed-update search failed on both AG nodes. Matching `Get-HotFix` lists and the report's subsequent "All software updates present" text do not prove that failed inventory succeeded. Investigate the update inventory; do not blindly re-register services, delete the update data store, or accept the warning as a single-network-path exception.
- Stage `60` now checks installed-update inventory before cluster validation. For this exact COM error only, it performs one metadata-only online `Search('IsInstalled=1')`, then requires a successful offline search. Healthy caches skip the online step. Network/source errors and partial results fail explicitly; this is not an automatic patch-installation or Windows Update reset procedure.
- A successful inventory and matching updates do not rule out a pending reboot.
  After Windows setup recovery, both nodes returned successful inventories with
  11 installed updates, but native validation reported an update reboot pending
  on `JS-SQL-AG-02`. Complete the affected node's planned reboot and verify
  readiness before rerunning stage `60`; never delete reboot markers or accept
  this as the single-network-path exception. On an existing cluster, use its
  maintenance/failover procedure rather than restarting nodes indiscriminately.
  Microsoft's read-only
  [`ISystemInformation.RebootRequired`](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-isysteminformation-get_rebootrequired)
  reports whether update installation/removal requires a restart.
  In this case that COM flag and the common CBS/Windows Update registry flags
  later read false even though the node had not rebooted since the native
  report. A false flag is therefore not a substitute for successful cluster
  validation; preserve the report and compare boot times before deciding on
  a planned restart.
- Stage `50` configures the first DC's DNS client to use `192.168.128.10` before promotion/discovery, and uses the external resolver only as a DNS forwarder. A public DNS client address cannot discover the private AD domain.
- The source image can retain a disabled ADWS service even when the AD DS role is installed. Stage `50` explicitly sets ADWS to Automatic and starts it after promotion; it queries local ADWS before relying on DNS-based domain discovery.
- DC reruns use a qualified domain Administrator account after promotion, with a single qualified local-account fallback for a fresh workgroup guest. SQL guest operations explicitly use each VM's local Administrator. Invalid credentials fail promptly rather than being retried as transport startup delays.
- A rerun verifies the intended forest before creating any missing secure AD-integrated domain and `_msdcs` zones. Existing conflicting zones fail explicitly. The stage then registers DC records and verifies the LDAP SRV record before joining SQL guests.
- If LDAP SRV records are still missing after repairing DNS, stage `50` first requires genuine SYSVOL/NETLOGON shares, clears the DNS client cache, and restarts Netlogon to initiate registration against the repaired zones. It does not restart Netlogon when the expected LDAP record already exists. `nltest /dsregdns` returning zero only acknowledges the request: actual SRV discovery must still pass. Check timestamps on NETLOGON event 5781 and use `nltest /dsquerydns` to distinguish an old failure from a new one. Never manually fabricate SRV records or force `SysvolReady`.
- Confirm `JS-DC-01` is at `192.168.128.10`.
- Confirm SQL nodes use the domain controller for DNS.
- A newly assigned static address is not necessarily usable when `New-NetIPAddress` returns. Stage `50` waits for the member's address state to become `Preferred` before discovery and joining; `Tentative` can mean duplicate-address detection is still running. It fails on unusable/conflicting addresses rather than disabling DAD. See [Microsoft's New-NetIPAddress documentation](https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netipaddress?view=windowsserver2022-ps).
- Before joining each SQL member, stage `50` clears its DNS client cache and requires `nltest /dsgetdc:<domain> /force` to succeed. A failed lookup stops before the join. Inspect `C:\Windows\debug\NetSetup.log` on that member, not just the DC's own successful DNS query. See Microsoft's [domain-join networking guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/domain-join-networking-errors).
- Confirm the domain controller and both AG nodes have correct clocks.
- For a corrected domain-bootstrap failure, rerun stage `50`. When domain readiness is already healthy, correct the specific cluster prerequisite and rerun stage `60` instead.

**SQL HADR readiness fails**

- `SERVERPROPERTY` returns `sql_variant`. SQL Server does not implicitly convert
  that type to `varchar`; a probe that prints or assigns it as text must use an
  explicit conversion. See Microsoft's
  [sql_variant conversion rules](https://learn.microsoft.com/en-us/sql/t-sql/data-types/sql-variant-transact-sql?view=sql-server-ver17#converting-sql_variant-data).
- During development, the cluster and witness were already online and AG01
  reported `IsHadrEnabled=1` through an explicitly converted query, while the
  original readiness probe failed with error 257. This is a query error, not
  evidence that SQL needs reinstalling or the cluster needs rebuilding.
- Preserve the working cluster and correct the probe before retrying. Repeating
  a deterministic SQL conversion error until a startup timeout does not repair
  it.
- A successful `New-Cluster` process can return before the new cluster control
  plane accepts `Get-Cluster`. Stage `60` waits five minutes with timestamped
  15-second observations and still requires both intended nodes `Up`. If that
  wait expires, preserve the cluster and the `ArcJumpstart-CreateCluster` and
  `ArcJumpstart-VerifyCluster` receipts. Correct the first native error, then
  rerun only stage `60`; do not delete or recreate a cluster whose creation
  receipt completed with exit `0`.
- A successful query can also observe an intermediate startup state. On AG02,
  the new SQL process returned `IsHadrEnabled=1,HadrManagerStatus=2` about two
  seconds after starting, then reached `1,1` without another restart or repair.
  The startup wait must still require `1,1`, but allow that observed transition
  within its deadline. A persistent state `2` fails with the last state and SQL
  ERRORLOG guidance; it is not accepted as readiness or handled by repeatedly
  restarting SQL.
- When inspecting quorum on this Windows Server 2022 build,
  `Get-ClusterQuorum` reports `QuorumType=Majority` with
  `QuorumResource=File Share Witness`. Verify the actual witness resource is
  online rather than rejecting that representation because it differs from an
  older enum/display name.

**Listener creation fails**

- Confirm `JS-AG-LSTN` is a disabled, prestaged AD computer object.
- Confirm the `JS-SQLCLU$` cluster identity has control of that object.
- Confirm `192.168.128.21` is outside the DHCP pool.

## Stop compute

Deallocate the outer host when pausing:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
./scripts/lab.ps1 stop
```

Start it again before continuing:

```powershell
./scripts/lab.ps1 start
```

The nested VMs are configured to start automatically with the host.

## Delete the lab

Cleanup spans multiple resource groups. Perform it in this order:

1. Delete or revoke temporary database-migration SAS credentials.
2. Delete the migration backup blob and temporary storage account when they are
   no longer required.
3. Delete the SQL managed instance and wait for deletion to complete.
4. Delete the Azure Migrate project and assessment resources when they are no
   longer required.
5. Disconnect or delete remaining Arc-enabled server and Arc-enabled SQL resources.
6. Delete the dedicated Arc, Migrate, SQL Managed Instance, and finally
   infrastructure resource groups.

```powershell
$approvedResourceGroup = 'your-approved-infrastructure-resource-group'
./scripts/lab.ps1 delete-infra $approvedResourceGroup
```

Resource-group deletion is intentionally not included in the deployment wrapper.

Finish by using Azure Resource Graph and Cost Management to search for the
project prefix, Arc machine names, Azure Migrate project, SQL managed instance,
temporary migration storage, public IPs, managed disks, and image-source storage
accounts. Provider registration is subscription-wide and does not incur a
resource charge; unregister providers only if that is part of your subscription
governance.
