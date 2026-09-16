# Assess the Arc-enabled environment with Azure Migrate

This lab uses Azure Migrate's Arc-based discovery preview. It does not deploy an Azure Migrate appliance. The nested guests qualify because they are Hyper-V VMs and are already represented by Arc-enabled server resources.

## Create an Arc-based Azure Migrate project

1. Open **Azure Arc > Migration > Savings and Readiness (Preview)**.
2. Select **Create a migration project**.
3. Select the subscription or subscriptions that contain the Arc resources.
4. Choose the project resource group, project region, and the Azure migration **Target region**.
5. Create the project and allow up to one hour for initial provisioning and discovery.
6. Complete the initial manual synchronization.

Arc-based discovery currently works only with new projects. The initial sync takes a snapshot of CPU, memory, disk, network, operating system, hypervisor, and Arc-enabled SQL metadata.

The operator creating the project needs **Azure Migrate Owner** or **Owner** on the project resource group and **Migrate Arc Discovery Reader - Preview** on each in-scope subscription. For automatic synchronization, grant that preview reader role to the Azure Migrate project's managed identity too.

## Confirm discovery

Verify that the project contains:

- Four Windows server machines.
- One Linux server machine.
- The standalone SQL instance.
- Both SQL availability-group replicas and their databases.

Azure Migrate automatically creates default assessments and business cases. Review both default strategies:

- Modernize preference.
- Minimize migration time.

Compare how the standalone SQL server and the AOAG nodes affect readiness, target recommendations, and cost.

## Enable performance-based sizing

Configuration-only sizing works immediately, but a useful assessment should include observed utilization:

1. Confirm you have **Hybrid Server Resource Administrator** on the Arc-enabled servers.
2. Install `AzureMigrateCollectorForWindows` or `AzureMigrateCollectorForLinux` from the portal, Azure CLI, or Azure Policy. Configure its `migrateProjects` setting with the Azure Migrate project resource ID and location shown in the project's data-collection instructions.
3. Verify outbound access to `https://*.migration.windowsazure.com`.
4. Wait for the extension provisioning status to reach **Succeeded**, then allow 15–30 minutes for the first data to appear.
5. Generate load on `JumpstartDB` and the Linux VM.
6. Collect at least 24 hours of data; longer windows produce better recommendations.
7. Recalculate the default assessments and business cases.

The collector extension is not the Azure Migrate appliance. It adds CPU, memory, disk IOPS/throughput, and network history to the existing Arc-based inventory.

## Configure automatic synchronization

For automatic Arc inventory sync:

1. Enable the Azure Migrate project's managed identity.
2. Assign it **Migrate Arc Discovery Reader - Preview** on each in-scope subscription.
3. Enable automatic sync in the Arc-based discovery settings.

Use manual sync while learning the workflow, then enable automatic sync and verify that a tag or newly onboarded machine appears after synchronization.

## Record the assessment

Capture:

- Machines that are ready, ready with conditions, or not ready.
- Recommended Azure VM sizes and monthly cost.
- SQL IaaS versus SQL PaaS recommendations.
- Dependencies or application context that Arc-based discovery cannot currently provide.
- Your proposed migration waves and the reason for their order.

Arc-based discovery currently does not provide software inventory, dependency analysis, web-app discovery, or PostgreSQL/MySQL discovery. Treat those as explicit assessment gaps rather than assuming the data is complete.
