# Migrate one database to Azure SQL Managed Instance

This is the final workshop activity. Migrate only
`JumpstartStandaloneDB` from `JS-SQL-01` to a small Azure SQL Managed Instance.
The domain controller, Linux guest, availability group, and Hyper-V virtual
machines are not migration targets in this exercise.

Use native backup and restore. Microsoft describes this as the easiest SQL
Managed Instance migration option when a database can tolerate the downtime
needed to take and restore a full backup. Managed Instance Link, Log Replay
Service, Azure Database Migration Service, and multi-database or AG migrations
are deliberately out of scope.

## Confirm the assessment and cost decision

Before provisioning:

1. Complete [assessment and inventory modeling](04-assessment.md).
2. Confirm the assessment recommends Azure SQL Managed Instance for
   `JumpstartStandaloneDB`, or document why the exercise intentionally differs.
3. Confirm the source database is online and not encrypted with TDE.
4. Review current SQL Managed Instance pricing and regional availability.
5. Obtain explicit approval for the managed instance, storage account, expected
   run time, and cleanup plan.

SQL Managed Instance is billable while provisioned and can take significant
time to create or delete. Use the smallest General Purpose configuration
currently offered in the approved region and subscription. Do not claim a
fixed SKU or price in this repository.

## Create the migration target

Create a dedicated workshop resource group containing:

- One General Purpose SQL managed instance.
- The smallest available compute and storage suitable for the sample database.
- A SQL Server 2025-compatible update policy.
- A dedicated compliant subnet in the outer Azure virtual network.
- One storage account and private container for the temporary backup.

Before creation, confirm that the selected update policy can restore a backup
from the lab's SQL Server 2025 instance. Stop rather than paying for an
incompatible target.

Keep the public endpoint disabled. The outer Hyper-V host can reach a managed
instance placed in the same Azure virtual network; the nested
`192.168.128.0/24` network is not an Azure subnet and must not be delegated to
SQL Managed Instance.

Use SQL authentication for this disposable exercise only if Microsoft Entra
administration is not already configured. Store the administrator credential
in approved owner-only storage outside the repository. Never put it in
`deploy.env`, source control, chat, or command output.

Wait for the managed instance to report **Ready** before continuing.

## Back up the source database to Azure Blob Storage

Create a short-lived container SAS with the permissions required to create,
write, read, and list the backup blob. Set its expiry shortly after the
workshop. Do not record the SAS in transcripts or repository files. In SSMS,
connect to `192.168.128.11` as `JUMPSTART\Administrator`, create a SQL credential
whose name is the container URL, and use the SAS token as its secret.

Back up only the standalone sample database:

```sql
CREATE CREDENTIAL
    [https://<storage-account>.blob.core.windows.net/<container>]
WITH
    IDENTITY = 'SHARED ACCESS SIGNATURE',
    SECRET = '<container-sas-without-leading-question-mark>';
GO

BACKUP DATABASE [JumpstartStandaloneDB]
TO URL = N'https://<storage-account>.blob.core.windows.net/<container>/JumpstartStandaloneDB.bak'
WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 10;
GO

RESTORE VERIFYONLY
FROM URL = N'https://<storage-account>.blob.core.windows.net/<container>/JumpstartStandaloneDB.bak'
WITH CHECKSUM;
GO
```

Confirm the blob exists and has a nonzero length before treating the backup as
complete. The source database remains online; choose a quiet point so the full
backup represents the intended workshop state.

## Restore to SQL Managed Instance

Connect to the managed instance with SSMS. Create the corresponding container
credential, then restore the backup:

```sql
CREATE CREDENTIAL
    [https://<storage-account>.blob.core.windows.net/<container>]
WITH
    IDENTITY = 'SHARED ACCESS SIGNATURE',
    SECRET = '<container-sas-without-leading-question-mark>';
GO

RESTORE DATABASE [JumpstartStandaloneDB]
FROM URL = N'https://<storage-account>.blob.core.windows.net/<container>/JumpstartStandaloneDB.bak';
GO
```

Monitor `sys.dm_operation_status` or the Azure portal until the restore is
terminal. Do not submit a competing restore because the first command returned
before the asynchronous operation completed.

## Validate the migrated database

On the managed instance:

```sql
USE [JumpstartStandaloneDB];
GO

SELECT
    DB_NAME() AS DatabaseName,
    COUNT_BIG(*) AS ObjectCount
FROM sys.objects;
GO

SELECT
    name,
    state_desc,
    compatibility_level
FROM sys.databases
WHERE name = N'JumpstartStandaloneDB';
GO
```

Also compare a small set of known table row counts and application queries
between source and target. Record:

- Source and target identifiers.
- Assessment recommendation and selected managed-instance configuration.
- Backup and restore start/end times.
- Validation queries and results.
- Any compatibility warnings or deliberate deviations.

This exercise proves migration of one database. It does not prove application
cutover, login/job migration, performance equivalence, high availability, or a
production rollback plan.

## Clean up

After evidence is captured:

1. Drop the source and target SQL credentials that held the SAS.
2. Delete the temporary SAS or revoke its stored access policy.
3. Delete the backup blob and storage account if they are no longer required.
4. With explicit approval, delete the SQL managed instance and its dedicated
   workshop resource group.
5. Wait for deletion to complete before assuming charges and subnet occupancy
   have ended.

Do not delete the Arc Jumpstart infrastructure resource group until the entire
workshop is complete.

## Microsoft references

- [SQL Server to Azure SQL Managed Instance migration overview](https://learn.microsoft.com/data-migration/sql-server/managed-instance/overview)
- [Native restore from URL](https://learn.microsoft.com/azure/azure-sql/managed-instance/restore-sample-database-quickstart)
- [Create Azure SQL Managed Instance](https://learn.microsoft.com/azure/azure-sql/managed-instance/instance-create-quickstart)
- [SQL Managed Instance network requirements](https://learn.microsoft.com/azure/azure-sql/managed-instance/vnet-existing-add-subnet)
