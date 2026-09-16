# Automated domain controller: stage 50

Stage `50` creates the lab's private Active Directory Domain Services (AD DS)
forest, prepares DNS, creates a SQL service account, and joins the three SQL
guests. This is supporting infrastructure for the SQL availability-group lab,
not Azure Arc onboarding.

This guide describes the implementation and how to inspect it. A documented
recovery path is not evidence that a particular deployment succeeded: use the
execution result and guest checks below before proceeding.

## Scope and topology

| Component | Default | Responsibility |
|---|---|---|
| Domain controller | `JS-DC-01`, `192.168.128.10` | AD DS, DNS, SYSVOL and NETLOGON |
| Forest and domain | `jumpstart.lab` | One forest, one domain, one DC |
| NetBIOS domain | `JUMPSTART` | Qualifies Windows domain accounts |
| Standalone SQL | `JS-SQL-01`, `192.168.128.11` | Domain member, default SQL instance |
| AG SQL members | `JS-SQL-AG-01` / `JS-SQL-AG-02`, `.12` / `.13` | Domain members; AG configuration comes in stage `60` |
| Internal gateway | `192.168.128.1` | NAT on the Hyper-V host |
| DHCP | Hyper-V host, scope `192.168.128.0` | Stage `50` changes scope DNS options to the DC |
| External DNS forwarder | `1.1.1.1` | Resolves names outside the private AD namespace |

The nested subnet is `192.168.128.0/24`. The Windows guests use fixed addresses.
Neither the Azure Hyper-V host nor the Ubuntu guest is domain-joined by this
stage. Azure deployment uses your signed-in Entra identity; that identity is
separate from this private Windows domain.

The single DC and all guests share one physical Azure host. This is a disposable
training topology, not a production identity service or a resilient deployment.
Stage `60` also uses the DC for its lab file-share witness; stage `50` does not
create that witness, the cluster, or the availability group.

## Source of truth and inputs

| File | Purpose |
|---|---|
| [`scripts/deploy.sh`](../scripts/deploy.sh) | Prerequisite checks, Bicep deployment and execution monitoring |
| [`infra/stages/50-domain/main.bicep`](../infra/stages/50-domain/main.bicep) | Defaults, secure inputs, embedded script and 90-minute command timeout |
| [`artifacts/scripts/50-configure-domain.ps1`](../artifacts/scripts/50-configure-domain.ps1) | Host orchestration and guest configuration |
| [`scripts/test-stage50.ps1`](../scripts/test-stage50.ps1) | Local regression checks for bootstrap ordering, DNS recovery and credentials |

The domain names, addresses, DNS forwarder and `svc-sql` account name are Bicep
parameters with defaults. They are **not** environment variables exposed by
`deploy.env.example`. Changing the lab network or domain requires coordinated
changes across the relevant stages, not simply adding a variable to `deploy.env`.

Configure the following existing inputs in your ignored `deploy.env`:

| Input | Meaning |
|---|---|
| `NESTED_WINDOWS_PASSWORD` | Existing nested Windows Administrator password; also used for the promoted domain Administrator |
| `SAFE_MODE_PASSWORD` | Directory Services Restore Mode (DSRM) password set when creating the forest; not a normal sign-in password |
| `SQL_SERVICE_ACCOUNT_PASSWORD` | Password used when creating the domain `svc-sql` account |

Bicep passes passwords as secure parameters and protected Run Command parameters.
They are still sensitive credentials handled by the deployment process. Never
commit `deploy.env`, paste passwords into diagnostics, or include them in agent
prompts. Keep DSRM credentials securely available for recovery.

Raw Windows PowerShell transcripts can still record those arguments in their
automatic process-command-line header. Protected Azure parameters do not make
host log files safe to publish. Use the redacting transcript viewer, review
exports, and follow the [log-handling guidance](06-troubleshooting-cleanup.md#read-stage-logs).

## Before running

Stages `00` through `40` must have prepared the host, network and generalized
guests. Stage `40` requires completed Windows first-boot/OOBE before renaming or
rebooting clones and checks unique Windows machine SIDs. Those are separate
checks: AD DS and SQL can function while the setup wizard is still incomplete,
but the Cluster Service can pause waiting for OOBE. Never substitute successful
domain discovery for Windows Setup completion. Stage `45` must have
finished installing and verifying SQL on all three SQL guests. The stage `50`
wrapper requires both the stage `45` deployment and its script execution to have
succeeded.

The Windows answer file must also answer the product-key page. The source
image was observed waiting there despite working AD services; the missing
input did not mean the domain was corrupt. See
[Windows setup recovery](06-troubleshooting-cleanup.md#common-failures).
Setup completion and Windows activation are separate requirements. Do not
rebuild a healthy domain simply to dismiss an unfinished Windows Setup page,
and do not rerun the workgroup-oriented stage `40` against a promoted DC.

From the repository root, with the intended Azure account/subscription selected:

```bash
./scripts/deploy.sh 50
```

Run only one stage at a time. Do not start another stage `50` execution while an
earlier invocation is active, even if the terminal was closed. The 90-minute
Azure timeout is a ceiling, not an expected duration or a reason to wait blindly.

## What the automation does, in order

1. **Finds a usable DC credential.** After checking the VM heartbeat, it tries
   `JUMPSTART\Administrator`, with one `JS-DC-01\Administrator` fallback for a
   fresh workgroup guest. An existing DC in a different domain is rejected.
   Definite authentication failures do not enter the remoting retry loop.
2. **Prepares roles and DNS before promotion.** It installs AD DS and DNS with
   management tools, sets DNS and AD Web Services (ADWS) startup to Automatic,
   starts DNS, and sets the DC's DNS client to its own fixed address. External
   DNS is configured as a forwarder, not as an alternate client resolver.
   A role-installation restart is performed if required.
3. **Creates the forest only when needed.** A guest that is not already a DC is
   promoted with `Install-ADDSForest -InstallDns`. The script explicitly sets
   domain and forest modes to `WinThreshold`, supplies the DSRM password,
   suppresses the cmdlet's immediate reboot, then restarts the VM itself.
4. **Verifies AD locally before requiring DNS discovery.** After promotion it
   uses the qualified domain Administrator, starts ADWS, and queries
   `Get-ADDomain -Server localhost`. Both the domain and forest must match the
   intended lab before DNS-zone changes are allowed.
5. **Verifies or creates secure AD DNS zones.** The domain zone uses Domain
   replication scope; `_msdcs.jumpstart.lab` uses Forest scope. Missing zones
   are created. Existing zones must be primary, AD-integrated and secure-update
   only; conflicting zones are not silently replaced.
6. **Checks SYSVOL and registers genuine DC records.** SYSVOL and NETLOGON
   shares must exist. The script clears the DNS client cache and, only when
   this DC's LDAP SRV record is missing, restarts Netlogon to initiate fresh
   registration. It runs `Register-DnsClient` and `nltest /dsregdns`, then
   requires an actual LDAP SRV response naming this DC on port `389` and a
   DNS-discovered AD domain query. A zero exit from `nltest` alone is not enough.
7. **Creates the SQL account and updates DHCP.** It creates an enabled
   `svc-sql` user if absent, with password expiration disabled for the lab.
   The host DHCP scope is updated to advertise the DC's DNS address and domain
   suffix, and the host DHCP service is restarted.
8. **Joins SQL guests one at a time.** Using each guest's qualified local
   Administrator, it sets its fixed address, waits up to 30 seconds for its
   address state to become `Preferred`, and sets the DC DNS resolver.
   Microsoft documents that a new address cannot be used until duplicate-address
   detection finishes. A `Tentative` address is allowed to settle; conflicting
   or otherwise unusable addresses fail rather than disabling that protection.
   Before a new
   join, it clears the guest's DNS client cache and requires a successful
   `nltest /dsgetdc:jumpstart.lab /force` using the configured domain name.
   Failed discovery stops before `Add-Computer`; it is not hidden by repeated
   join attempts. The stage joins the domain if needed and restarts newly
   joined guests.
9. **Prepares SQL access.** It waits for a working integrated-authentication
   SQL query, creates the domain administrators' Windows login if absent and
   grants SQL `sysadmin`. It checks SQL's local server-name registration and
   corrects it, restarting SQL if a correction was necessary. Finally it
   lists the lab's AD computer objects.

PowerShell Direct (`Invoke-Command -VMName`) runs guest commands through Hyper-V
without depending on working guest DNS or network remoting. It still requires
valid guest credentials. This is why an authentication error is not treated as
another DNS startup delay.

## Inspect execution without changing anything

On the machine where you run Azure CLI, substitute your resource group and host:

```bash
RESOURCE_GROUP='your-resource-group'
HOST_NAME='jsarc-host'
az vm run-command show \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$HOST_NAME" \
  --name stage50-domain \
  --expand instanceView \
  --query 'instanceView.{state:executionState,exitCode:exitCode,start:startTime,end:endTime,output:output,error:error}' \
  --output json
```

Require `Succeeded` and exit code `0` for the **current** execution. Azure
provisioning success is not guest-script success. While an update is being
accepted, the instance view can still show the previous invocation: compare
timestamps and the run ID in the transcript filename with your new deployment.
Output can also be truncated or delayed.

For live detail, open elevated Windows PowerShell on the Hyper-V host:

```powershell
$log = Get-ChildItem 'C:\ArcJumpstart\Logs\50-configure-domain-*.log' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) { throw 'No stage 50 transcript exists on this host yet.' }
$log | Select-Object FullName, LastWriteTime
Get-Content -LiteralPath $log.FullName -Tail 60 -Wait
```

Use Ctrl+C to stop following the file; it does not cancel the deployment.
Preserve the transcript and relevant event timestamps before retrying.

## Verify the domain and members

The following are read-only checks, not alternative installation scripts.
Run them in elevated Windows PowerShell **on the Hyper-V host**, after stage
`50` has finished. Change the names/addresses if you changed Bicep defaults.

```powershell
$domainCredential = Get-Credential 'JUMPSTART\Administrator'
Invoke-Command -VMName JS-DC-01 -Credential $domainCredential -ScriptBlock {
    Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, DomainRole
    Get-Service ADWS, DNS, NTDS, Netlogon, DFSR, Kdc
    Get-ADDomain -Server localhost | Select-Object DNSRoot, Forest, NetBIOSName
    Get-DnsClientServerAddress -AddressFamily IPv4
    Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated, DynamicUpdate
    Get-SmbShare | Where-Object Name -in 'SYSVOL', 'NETLOGON'
    Resolve-DnsName '_ldap._tcp.dc._msdcs.jumpstart.lab' -Type SRV -Server 192.168.128.10
    Get-ADUser svc-sql -Properties Enabled, PasswordNeverExpires |
        Select-Object SamAccountName, Enabled, PasswordNeverExpires
    Get-ADComputer -Filter 'Name -like "JS-*"' |
        Select-Object Name, DNSHostName, Enabled
}
```

Expect the DC in `jumpstart.lab` with a DC domain role (`4` or `5`), running
services, both secure AD-integrated zones, both shares, and an LDAP SRV answer
for `JS-DC-01.jumpstart.lab` on port `389`. The DC's active interface must use
`192.168.128.10` for DNS. Expect the enabled `svc-sql` account and all three SQL
computer objects.

AD computer objects alone do not prove that the guests joined successfully.
Check the guests themselves, their secure channels, and their SQL engines:

```powershell
foreach ($vm in 'JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02') {
    $localCredential = Get-Credential "$vm\Administrator"
    Invoke-Command -VMName $vm -Credential $localCredential -ScriptBlock {
        Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain
        Get-DnsClientServerAddress -AddressFamily IPv4
        Test-ComputerSecureChannel -Verbose
        & sqlcmd.exe -S localhost -E -b -C -Q "SELECT @@SERVERNAME AS ServerName, IS_SRVROLEMEMBER(N'sysadmin', N'JUMPSTART\Domain Admins') AS DomainAdminsSysadmin;"
        if ($LASTEXITCODE -ne 0) { throw 'SQL verification failed.' }
    }
}
```

Each guest should report `PartOfDomain = True`, domain `jumpstart.lab`, DC DNS,
a `True` secure-channel result, its own SQL server name, and
`DomainAdminsSysadmin = 1`. The SQL query verifies the grant using the local
Administrator; it is not a test of a fresh domain user's SQL connection.
`-C` explicitly trusts the lab's self-signed SQL certificate for the localhost
query; it does not disable encryption.

## Failures, evidence and safe retries

| Symptom | Evidence to collect | Recovery boundary |
|---|---|---|
| Invalid credential after promotion | Qualified username and exact remoting error, never the password | Use the domain-qualified DC account; a promoted DC is not a workgroup server. Do not repeatedly guess credentials. |
| ADWS unavailable | Service startup/state and local `Get-ADDomain` error | An observed source-image state had ADWS disabled despite AD DS being installed. The stage explicitly enables/starts it. |
| Local AD works but domain discovery fails | DNS client address, zones and actual LDAP SRV response | Keep the first/only DC pointed at itself. External DNS belongs in forwarders. |
| SRV absent after zone repair | NETLOGON event 5781 with timestamps, `nltest /dsquerydns`, SYSVOL/NETLOGON shares | The stage can restart Netlogon after prerequisites pass. Request acceptance does not prove registration; require the subsequent DNS check. |
| SYSVOL or NETLOGON share missing | DFS Replication events and service state | Stop and investigate the matching Microsoft guidance. Do not force `SysvolReady`, fabricate records, or apply DFSR recovery procedures without matching evidence. |
| Member join or SQL access fails | Guest DNS, clock, membership, secure channel, SQL error and host transcript | Repair the specific prerequisite, then rerun the stage after the previous execution is terminal. Do not reinstall healthy SQL engines. |

In the investigated deployment, DFSR was running and SYSVOL/NETLOGON were
present: that ruled out a suspected SYSVOL initialization failure. An old
NETLOGON event also preceded the DNS repair. Do not infer a new failure from an
old event or apply the same recovery to every DNS problem.

Reruns retain an existing matching forest, valid zones, an existing service
account and already joined members. They still enforce DNS settings and SQL
permissions and can restart services or guests where necessary. They are not
side-effect-free. Conflicting state can fail and require operator investigation.
The stage is not a domain rename, cross-domain migration, password rotation or
general-purpose AD repair tool. In particular, changing the SQL account password
in `deploy.env` does not rotate an already existing AD account, and changing
`SAFE_MODE_PASSWORD` does not reset DSRM on an existing forest.

### When rebuilding the DC is preferable

This DC is disposable lab infrastructure. Prefer a clean rebuild over extensive
in-place AD repair when evidence identifies damaged or uncertain promotion state
and rebuilding is simpler. First distinguish a DC problem from member-side DNS
or connectivity: replacing a healthy DC will not fix a member's network.
Save the failure evidence and correct the reproducible cause in the repository
before rebuilding; otherwise the replacement can reproduce the same failure.

Rebuilding the DC creates a **new domain identity**, even when its DNS name and
passwords are unchanged. Before removing anything, verify all three SQL guests'
actual membership and whether stage `60` has created cluster/domain dependencies.
If no members have joined and no dependent cluster exists, replace only
`JS-DC-01` and its disposable guest disk using the generalized Windows parent,
then run stage `50` again. Preserve the host, parent images and installed SQL
guests. Do not use whole-resource-group cleanup for a DC-only rebuild.

If members have joined, or SQL logins, service accounts, the cluster or witness
already depend on the old domain, a DC-only replacement is not a drop-in repair.
Plan member rejoins and dependent identity/permission recreation, preserving data
and confirming the reset scope first. Do not assume matching account names
preserve their old SIDs. The repository does not currently provide a dedicated
one-command DC reset workflow; inspect the existing stage `40` provisioning path
and exact VM/disk targets before performing a scoped rebuild.

For an intentional full reset of this disposable lab, follow
[cleanup](06-troubleshooting-cleanup.md) and preserve anything needed first.

## Security and learner boundaries

The domain Administrator and Domain Admins SQL `sysadmin` grants are convenient
lab privileges, not least-privilege production recommendations. The SQL service
account's non-expiring password is also a lab choice. Production requires
appropriate account separation, managed credentials/rotation, redundant domain
services, backup/recovery planning and trusted certificates.

Stage `50` creates the SQL service account but does not switch the AG engines
to it; that occurs in stage `60`. No Azure Arc agent, Azure extension for SQL
Server, assessment or migration is installed or started here. Continue to
stage `60` only after verifying domain readiness, then follow the separate
[learner-operated Arc onboarding guide](03-arc-onboarding.md).

## Microsoft references

- [PowerShell Direct requirements and guest sessions](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct)
- [Install-ADDSForest, DNS installation and restart options](https://learn.microsoft.com/en-us/powershell/module/addsdeployment/install-addsforest?view=windowsserver2022-ps)
- [DNS client recommendations for the first/only domain controller](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/best-practices-for-dns-client-settings)
- [Create AD-integrated primary DNS zones](https://learn.microsoft.com/en-us/powershell/module/dnsserver/add-dnsserverprimaryzone?view=windowsserver2022-ps)
- [Verify domain-controller SRV DNS records](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/verify-srv-dns-records-have-been-created)
- [Domain-join networking errors, NetSetup.log and forced DC discovery](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/domain-join-networking-errors)
- [New-NetIPAddress and duplicate-address detection](https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netipaddress?view=windowsserver2022-ps)
- [Nltest, including DC DNS registration](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc731935(v=ws.11))
