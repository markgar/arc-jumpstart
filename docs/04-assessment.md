# Assess and export the Arc-enabled environment

This is the first workshop activity. Start only after the user has completed
[interactive Arc setup](03-arc-onboarding.md) and the machines, SQL instances,
databases, and availability group are visible in Azure. The lab uses Azure
Migrate's Arc-based discovery preview and does not deploy an Azure Migrate
appliance.

## Reuse or create an assessment

First check each Arc-enabled SQL instance's **Migration assessment** page and
the intended Azure Migrate project:

1. If a successful assessment and synchronized project already cover the
   current machines and databases, record their timestamps and reuse them.
2. If the assessment is missing, failed, or predates material lab changes,
   select **Run assessment** and wait for a successful completion timestamp.
3. Do not start a second assessment while the first is still running.

If no Arc-based Azure Migrate project exists:

1. Open **Azure Arc > Migration > Savings and Readiness (Preview)**.
2. Select **Create a migration project**.
3. Select the subscription containing the Arc resources.
4. Choose the project resource group, project region, and Azure migration
   **Target region**.
5. Create the project and allow up to one hour for initial provisioning and
   discovery.
6. Complete the initial manual synchronization.

The operator needs **Azure Migrate Owner** or **Owner** on the project resource
group and **Migrate Arc Discovery Reader - Preview** on the in-scope
subscription. Arc-based discovery currently works only with new projects.

## Confirm the assessment

Verify that the project contains:

- Four Windows server machines.
- One Linux server machine.
- The standalone SQL instance.
- Both SQL availability-group replicas and their databases.

Azure Migrate automatically creates default assessments and business cases. Review both default strategies:

- Modernize preference.
- Minimize migration time.

Compare how the standalone SQL server and the AOAG nodes affect readiness, target recommendations, and cost.

Record the assessment timestamp and confirm that `JumpstartStandaloneDB` has an
Azure SQL Managed Instance recommendation before using it for the migration
activity. Do not treat an old or incomplete assessment as modeling evidence.

## Enable performance-based sizing

Configuration-only sizing works immediately, but a useful assessment should include observed utilization:

1. Confirm you have **Hybrid Server Resource Administrator** on the Arc-enabled servers.
2. Install `AzureMigrateCollectorForWindows` or `AzureMigrateCollectorForLinux` from the portal, Azure CLI, or Azure Policy. Configure its `migrateProjects` setting with the Azure Migrate project resource ID and location shown in the project's data-collection instructions.
3. Verify outbound access to `https://*.migration.windowsazure.com`.
4. Wait for the extension provisioning status to reach **Succeeded**, then allow 15–30 minutes for the first data to appear.
5. If the exercise includes performance sizing, generate representative load on
   `JumpstartDB` and the Linux VM. Idle utilization is valid for demonstrating
   oversubscription, but it is not representative production sizing data.
6. Collect at least 24 hours of data; longer windows produce better recommendations.
7. Recalculate the default assessments and business cases.

The collector extension is not the Azure Migrate appliance. It adds CPU, memory, disk IOPS/throughput, and network history to the existing Arc-based inventory.

## Configure automatic synchronization

For automatic Arc inventory sync:

1. Enable the Azure Migrate project's managed identity.
2. Assign it **Migrate Arc Discovery Reader - Preview** on each in-scope subscription.
3. Enable automatic sync in the Arc-based discovery settings.

Use manual sync while learning the workflow, then enable automatic sync and verify that a tag or newly onboarded machine appears after synchronization.

## Export Resource Graph modeling input

The versioned query at
[`queries/arc-sql-modeling-inventory.kql`](../queries/arc-sql-modeling-inventory.kql)
returns Arc machines, Arc-enabled SQL instances, databases, availability groups,
SQL extensions, and licensing resources. Its join keys preserve these
relationships:

- Arc machine to SQL instance.
- SQL instance to database and availability group.
- Arc machine to SQL extension.

Run the supported export after the assessment and Arc inventory are current:

```powershell
$env:ENV_FILE = Join-Path $HOME 'ArcJumpstart/lab.env'
./scripts/lab.ps1 inventory
```

The command limits the query to the configured subscription and Arc resource
group, then writes a timestamped directory under `out/arc-modeling/` containing:

- `inventory.raw.json`: the complete Azure Resource Graph response.
- `inventory.csv`: one modeling row per resource, including raw `Properties`.

The export does not invent missing values or flatten undocumented property
shapes. Use `RecordType`, `JoinKey`, and `ParentJoinKey` to correlate records,
then inspect the current properties for server sizing, SQL configuration,
database details, assessment findings, and AG replica role. Count workload
capacity from the active/primary replica; retain passive/secondary resources in
the model without counting the same protected workload twice.

## Record the modeling decision

Capture:

- Machines that are ready, ready with conditions, or not ready.
- Recommended Azure VM sizes and monthly cost.
- SQL IaaS versus SQL PaaS recommendations.
- Dependencies or application context that Arc-based discovery cannot currently provide.
- Your proposed migration waves and the reason for their order.
- The Resource Graph export directory and the query revision used.
- Which AG replica was treated as active and how passive capacity was modeled.
- Why `JumpstartStandaloneDB` is the low-complexity migration candidate.

Arc-based discovery currently does not provide software inventory, dependency analysis, web-app discovery, or PostgreSQL/MySQL discovery. Treat those as explicit assessment gaps rather than assuming the data is complete.
