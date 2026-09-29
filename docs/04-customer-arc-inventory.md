# Customer Arc inventory: one query, one export

Use [arc-sql-modeling-inventory.kql](../queries/arc-sql-modeling-inventory.kql)
in Azure Resource Graph Explorer to collect the Arc-visible server, SQL,
migration-assessment and high-availability inventory in one CSV.

This is a read-only collection workflow. It does not access the virtualization
host, run commands inside servers, connect new machines to Arc, enable
collectors, or start an assessment. No lab credentials, deployment environment
file, host access, or Jumpstart server names are required.

## Instructions to send to the customer

1. Open **Azure Resource Graph Explorer** in the Azure portal using an identity
   with read access to the intended Arc resources.
2. Select the agreed subscriptions/resource groups in **Scope**. Include all
   in-scope Arc servers, SQL resources, replicas and relevant licensing resources,
   even when they live in different groups. Do not select the lab infrastructure
   group instead of its Arc group.
3. Paste the complete linked query and select **Run query**. The
   `// __RESOURCE_GROUP_FILTER__` line is only a comment; no edits are required.
4. Select **Download as CSV**. Keep the original export unchanged; do not copy
   just the visible page or open and re-save it in Excel, which can change
   identifiers or truncate long JSON cells.
5. Confirm the exported record count matches the reported result count. Record
   the selected scope, collection time and query revision alongside the file.
   Send the CSV through the agreed customer-approved secure channel.

Resource Graph only returns resources the caller can read. An empty result does
not prove that the customer has no SQL servers. Resolve incorrect scope,
permissions, incomplete Arc onboarding or inventory upload delays first.

Resource Graph Explorer CSV export has a **55,000-record limit**; the interactive
result page/API default is 1,000. For larger estates, run the **same query** over
disjoint subscription/resource-group scopes and provide all exports. Reconcile
cross-scope relationships after combining them. Do not add `take` or `limit` to
make an incomplete export appear complete. For API automation use pagination.
The repository's `lab.ps1 inventory` command remains a small-lab convenience:
it explicitly fails above 1,000 records rather than silently truncating.

The export contains customer-sensitive infrastructure metadata: names, resource
IDs, addresses/endpoints, tags, extension settings, database names and assessment
findings. Obtain approval for its scope and recipient; do not post it publicly
or commit it to this repository.

## What the query returns

There is one row per Azure resource, not one row per workload. No join or array
expansion drops servers without SQL, drops instances without assessments, or
multiplies database/replica rows. Structured values are JSON strings in CSV.
`Properties` retains the full property bag returned by ARG, including fields
not yet explicitly projected. This is not a guarantee that ARG contains all
guest or telemetry data.

| Data | Columns and interpretation |
|---|---|
| Arc server | `ARC_MACHINE`, `MachineStatus`, `OsName`, `OsVersion`, `LogicalCoreCount`, `MemoryGiB`; retain Linux and BI-only servers even without relational children. |
| SQL instances/components | `SQL_INSTANCE`, `SqlInstanceName`, `SqlServiceType`, `SqlVersion`, `SqlEdition`, `SqlHostCoreCount`. `serviceType`, when exposed, distinguishes Engine, SSAS, SSIS, SSRS and PBIRS. A missing value is unknown, not proof of Engine or absence of BI. |
| Databases | `DATABASE`, `SqlInstanceResourceId`, full `Properties` for the reported size, configuration, status and assessment metadata. Do not guess units for schema-specific size fields. |
| Availability groups | `AVAILABILITY_GROUP`, `AvailabilityGroupInfo`, `AvailabilityGroupReplicas`, `AvailabilityGroupDatabases`. Preserve the full configuration, listener, replica state and member identities. |
| Failover cluster instances | `FailoverCluster` on SQL-instance rows. An FCI is not a separate ARG resource type. Preserve network name, active/passive membership and identifiers wherever reported. |
| Migration assessment | `AssessmentEnabled`, `AssessmentUploadTime`, complete `SqlMiRecommendation`, `SqlDbRecommendation`, `SqlVmRecommendation`, `ServerAssessments`, and `MigrationAssessment`. These include published recommendations/findings, not just an enabled flag. |
| Best practices assessment | `BestPracticesAssessment` is the resource's configuration/metadata, not a substitute for its Log Analytics findings. |
| Extensions | `SQL_EXTENSION` and `ARC_EXTENSION`, `ExtensionType`, `ExtensionVersion`, full `Properties`; include SQL, monitoring and Migrate collectors rather than filtering out non-SQL extensions. |
| Licensing | `SQL_LICENSE` and `ESU_LICENSE` with full `Properties`. These are separate records, not evidence that every SQL instance is licensed or eligible for Azure Hybrid Benefit. |
| Other SQL child types | `OTHER_SQL_CHILD` retains any additional indexed SQL-instance child resource and its `SqlInstanceResourceId`. Review unknown schemas rather than dropping them. |

`Location` is the Azure resource registration location, not the physical
datacenter location. `ExportedAtUtc` is query time, not inventory freshness.
`AssessmentUploadTime` is the published assessment upload timestamp; it is not
the performance observation window or the time the assessment was viewed.
Preserve source timestamps inside `Properties` and record absent timestamps as
unknown. Do not hide old assessments with a recent-date filter.

The SQL core count describes the hosting operating system environment, not
capacity reserved for each instance. Do not sum it across colocated instances.
Configured cores/RAM are not measured utilization or a target-sizing decision.
Blank fields are expected on unrelated row types and remain unknown on relevant
rows when the service has not reported them.

## Build relationships without the host

Normalize resource IDs case-insensitively. Use `JoinKey` as the resource key:

- SQL instance `MachineResourceId` / `ParentJoinKey` -> Arc machine `JoinKey`
  when `containerResourceId` reports that relationship.
- Database or AG `SqlInstanceResourceId` -> SQL instance `JoinKey`.
- Extension `MachineResourceId` / `ParentJoinKey` -> Arc machine `JoinKey`.
- FCI membership -> the members reported by `FailoverCluster`, not a guessed
  one-machine parent. Retain any unresolved membership.

`ParentJoinKey` describes known immediate parent relationships. It does not
claim that an AG's reporting instance is the only replica. Other SQL child
schemas retain an instance link but may need additional parent interpretation.

For AGs, inspect `AvailabilityGroupReplicas.value` and
`AvailabilityGroupDatabases.value`. Preserve `replicaName`, `replicaResourceId`,
`configure` and `state`, plus the listener and distributed-AG flags in
`AvailabilityGroupInfo`. A replica resource ID can refer to an AG (especially
for distributed AGs); do not automatically interpret it as a SQL instance ID.

Match reported identifiers and membership across all observations of an AG.
Record the evidence for the match and retain all original resource IDs. Names
alone are not globally unique. If shared AG/cluster identity or unambiguous
membership is absent, mark the relationship unresolved instead of merging on
an AG name, listener name or similar server names.

AG membership and WSFC membership are different: one cluster can host multiple
AGs, instances and unrelated databases. Arc's AG representation does not
guarantee a complete WSFC topology or quorum/witness inventory. The query never
uses Azure Compute, Hyper-V, VMware, guest SQL queries or host commands to fill
those gaps.

## Model one protected workload, not two target machines

For a two-replica AG protecting the same databases, identify the unique logical
database set before estimating target capacity. Do not charge twice for two
copies of the same protected data. Equally, do not simply discard secondary
servers or halve their combined core count:

- Include readable-secondary/reporting workloads, backup offload and other
  databases/instances or BI services on each server.
- Examine all AGs on each instance: a node may be primary for one and secondary
  for another. Account for failovers during the performance collection window;
  a snapshot primary role is not the whole workload history.
- Review the migration findings, full target recommendations and assessment
  settings (region, lookback, percentile, comfort factor and pricing options).
  Recommendations assessed per source instance are not automatically
  consolidated recommendations for a deduplicated AG.
- Confirm compatibility, memory, storage, IOPS/throughput, latency, business
  isolation and RPO/RTO/DR requirements before selecting a destination.

One Azure SQL Managed Instance **General Purpose** can be a candidate for one
protected workload, with platform-managed HA replacing a customer-managed pair.
It is not one ordinary VM providing equivalent HA. General Purpose, Business
Critical, read-scale and cross-region DR options must be evaluated against the
actual requirements. Neither matching cluster membership nor a `Ready` status
alone proves that one GP managed instance is sufficient.

An FCI is one logical SQL instance across nodes, not an AG with replicated
database copies. Keep FCI and AG semantics separate. Microsoft currently lists
AG-on-FCI and best practices assessment on FCI as unsupported Arc scenarios;
do not interpret missing records/findings as a clean assessment.

## What one ARG export cannot promise

This query returns all matching **ARG-visible** resources and their reported
properties, including the published migration-assessment fields. It does not
create missing assessments, fetch data from inside the servers, or return
telemetry that has not been projected into ARG.

For each migration decision, record whether these evidence requirements were
met. Where not met, request a specifically scoped follow-up instead of asking
every customer to run more queries:

| Evidence gap | Follow-up |
|---|---|
| Missing/stale migration results or incomplete SKU reason/compatibility detail | Review the Arc SQL **Migration > Assessments** report. Preserve completion time, settings, findings, source requirements and performance coverage. The report requires the documented `getTelemetry` permission; do not guess undocumented API request bodies. Running a new assessment is a separate approved action. |
| SQL best practices findings | Obtain the existing report/results from the configured Log Analytics workspace with appropriate read permission. This is distinct from migration readiness; enabling it has licensing, collection and cost implications. |
| Time-series CPU/memory/I/O or representative sizing history | Obtain existing Arc SQL/Migrate monitoring or assessment evidence. ARG inventory is not a time-series store. Idle lab data is not customer sizing evidence. |
| SSAS/SSIS inventory or sizing | Preserve reported `serviceType` and component properties. Component discovery does not imply a relational migration assessment covers that workload. |
| Missing replicas, cluster IDs, topology or application/DR requirements | Resolve visibility/onboarding/freshness first; otherwise retain an explicit gap and request customer confirmation. Never infer a cluster solely from naming. |

## Sources and validation

The query uses fields documented by Microsoft as of 2026-09-29:

- [Migration dashboard and official ARG assessment/server queries](https://learn.microsoft.com/sql/sql-server/azure-arc/migration-inventory).
- [Migration assessment requirements and report contents](https://learn.microsoft.com/sql/sql-server/azure-arc/migration-assessment).
- [SQL instance/component properties](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/sqlserverinstances).
- [AG replica, database and listener properties](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/sqlserverinstances/availabilitygroups).
- [FCI inventory and limitations](https://learn.microsoft.com/sql/sql-server/azure-arc/support-for-fci).
- [Best practices assessment and Log Analytics](https://learn.microsoft.com/sql/sql-server/azure-arc/assess).
- [ARG export limits and paging](https://learn.microsoft.com/azure/governance/resource-graph/concepts/work-with-data).

The seven-server lab has not yet supplied an onboarded Arc dataset for this
query. Live populated-field and end-to-end relationship validation is pending.
It contains an AG but no FCI; FCI behavior requires separate customer-approved
or test evidence. Passing ARG syntax validation does not prove completeness.
