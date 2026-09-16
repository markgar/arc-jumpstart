# Test and perform a Hyper-V migration

Arc-based discovery removes the appliance from the assessment path. Hyper-V replication uses a different component: the Azure Site Recovery provider and Recovery Services agent installed directly on the Hyper-V host. An Azure Migrate appliance is not required for Hyper-V migration.

Start with `JS-UBUNTU-01` or `JS-SQL-01`. Do not make the two-node availability group your first migration target.

## Freeze the assessment and prepare the guest for Azure

Before enabling replication:

1. Export or record the final Arc-based assessment and business case. Disable automatic synchronization if the results must remain stable.
2. Inventory and remove all Arc extensions from the selected source, including `AzureMigrateCollectorForWindows`/`AzureMigrateCollectorForLinux` and `WindowsAgent.SqlServer` when present.
3. Run `azcmagent disconnect`, uninstall the Connected Machine agent, and verify that its Arc-enabled server resource is deleted.
4. Install, repair, or re-enable the appropriate Azure VM Guest Agent so the migrated Azure VM can be managed after cutover.
5. Review the current [Arc-to-Azure migration procedure](https://learn.microsoft.com/azure/azure-arc/servers/scenario-migrate-to-azure) and [Hyper-V migration support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v-migration).

Removing the Connected Machine agent alone does not remove Arc extensions. Do not test-migrate a disk that still contains the source machine's Arc identity.

### Reverse the Arc-on-Azure evaluation workaround

If you used Microsoft's evaluation-only workaround, reverse every change before migration so the resulting Azure VM has normal IMDS and guest-agent behavior.

On Windows, run as Administrator:

```powershell
Remove-NetFirewallRule -Name BlockAzureIMDS -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable(
    'MSFT_ARC_TEST',
    $null,
    [EnvironmentVariableTarget]::Machine
)
Set-Service WindowsAzureGuestAgent -StartupType Automatic
Start-Service WindowsAzureGuestAgent
```

On Ubuntu, remove the exact firewall mechanism you used, clear the systemd override, and restore the Azure Linux Agent:

```bash
# UFW:
sudo ufw delete deny out from any to 169.254.169.254

# Or firewalld:
sudo firewall-cmd --permanent --direct --remove-rule ipv4 filter OUTPUT 1 \
  -p tcp -d 169.254.169.254 -j REJECT
sudo firewall-cmd --reload

# Or a nonpersistent iptables rule:
sudo iptables -D OUTPUT -d 169.254.169.254 -j REJECT

sudo systemctl unset-environment MSFT_ARC_TEST
unset MSFT_ARC_TEST
sudo systemctl enable walinuxagent
sudo systemctl start walinuxagent
```

Also remove `MSFT_ARC_TEST` from any profile, `/etc/environment`, or systemd unit override where you made it persistent. If you also blocked Azure Local IMDS at `169.254.169.253`, remove that matching rule. Reboot and verify the guest agent is running and `http://169.254.169.254/metadata/instance` is reachable with the `Metadata: true` header before enabling replication.

## Create migration resources and register the host

In the same Azure Migrate project:

1. Open **Execute > Migration > Start execution**.
2. Choose migration of a server/VM to an Azure VM.
3. Select **From replication provider (Hyper-V)**.
4. Choose and confirm the target region. Treat this as immutable for the exercise.
5. Select **Create resources** and wait for the migration resources to finish provisioning.
6. Download the Hyper-V replication provider and project registration key. The key is valid for five days.
7. Copy both files to the outer `${NAME_PREFIX}-host` VM.
8. Install the provider and Recovery Services agent on the host.
9. Register the host with the Azure Migrate project and select **Finalize registration**.
10. Allow up to 15 minutes for provider-discovered guests to appear.

The Arc discovery inventory and the replication-provider inventory are different views. Reusing the same project does not turn Arc-discovered records into replication objects. Stop until the selected guest appears under the Hyper-V provider inventory.

The host needs outbound HTTPS access to the endpoints in the current support matrix, including:

- `login.microsoftonline.com`
- `backup.windowsazure.com`
- `*.hypervrecoverymanager.windowsazure.com`
- `*.blob.core.windows.net`
- `dc.services.visualstudio.com`
- `time.windows.com`

Before enabling replication, confirm Secure Boot is disabled on the selected nested VM. Stage `40` does this by default because Secure Boot guests are not supported by the Hyper-V migration path.

This lab uses differencing disks. The support matrix documents VHD/VHDX but does not explicitly guarantee pre-existing differencing chains. First enable replication for one disposable guest as a stop/go test. If the provider rejects the chain, shut down the guest, flatten/merge it into a standalone dynamic VHDX, attach that disk, and retry before continuing.

## Replicate one guest

1. Select `JS-UBUNTU-01` or `JS-SQL-01` from the provider-discovered workloads.
2. Choose the target subscription, resource group, normal Azure VNet/subnet, cache storage, availability options, VM size, security settings, and disk type.
3. Start replication.
4. Wait for initial replication and delta synchronization to become healthy.

Do not place the migrated VM on the nested `192.168.128.0/24` network. Keep the outer Hyper-V host allocated throughout initial replication, test migration, final synchronization, and cleanup.

Compare the migration target size with the Arc-based assessment recommendation. Document any deliberate difference.

## Test migration

1. Choose an isolated test VNet that cannot conflict with production addresses.
2. Run **Test migrate**.
3. Connect to the test VM and verify boot, network, application/service state, and data.
4. For `JS-SQL-01`, verify the instance and `JumpstartStandaloneDB`.
5. Clean up the test migration from the portal when validation is complete.

## Cut over

For a final migration exercise:

1. Schedule a change window.
2. Stop application writes and confirm the latest replication cycle is healthy.
3. Select **Migrate** and set **Shut down virtual machines and perform a planned migration with no data loss** to **Yes**.
4. Start migration and wait for the Azure VM to be created.
5. Validate boot, networking, guest-agent health, application/service state, and data.
6. Select **Complete migration** to stop replication and clean up migration state.
7. Mark a retained source as retired so host restarts and stage reruns cannot start it:

   ```bash
   ./scripts/lab.sh retire-source JS-SQL-01
   # or: ./scripts/lab.sh retire-source JS-UBUNTU-01
   ```

8. Delete or retain the retired source guest according to the exercise plan. Do not rerun provisioning against a cut-over source unless it is intentionally restored to service.

## Availability-group migration

Treat the AOAG as a later exercise. Typical strategies include:

- Build new Azure replicas and extend or replace the AG.
- Migrate replicas in separate waves while preserving quorum.
- Move to SQL Server on Azure VMs with an Azure Load Balancer or distributed network name.
- Modernize to Azure SQL Managed Instance when the assessment supports it.

A simple simultaneous lift-and-shift of both cluster nodes is not a safe production migration plan.
