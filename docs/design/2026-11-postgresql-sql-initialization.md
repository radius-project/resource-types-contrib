# Proposal: PostgreSQL SQL initialization

**Status:** Proposal. The Azure Recipe Pack on `main` selects the PostgreSQL AVM directly and does not execute `initSql`. The wrapper described here is implemented in open [#474](https://github.com/radius-project/resource-types-contrib/pull/474), not yet on `main`. Recipe composition is a proposed future Radius feature.

## Underlying issue

**A successfully provisioned database is not necessarily a database the application can use.** Azure can finish creating the PostgreSQL server, database, firewall rules, and server settings without creating any application users, schemas, tables, or seed data. An application might connect successfully, then fail its first query because a required table such as `catalog.products` does not exist.

The Resource Type already exposes `initSql`, so the missing piece is not an input in the YAML schema. The Azure Recipe on `main` accepts a resource containing that input but does not execute it. This creates a gap between the resource's advertised behavior and its platform implementation, as reported in [#369](https://github.com/radius-project/resource-types-contrib/issues/369).

There are two different operations involved:

- **Create infrastructure:** The PostgreSQL AVM calls Azure management APIs to provision the server and database. Its `databases` input creates databases, not their application tables or contents.
- **Initialize database contents:** A client must connect to PostgreSQL and execute SQL. That requires database credentials, network access, a PostgreSQL client, and a place to run it. Adding another schema property or parameter mapping does not perform this operation.

This also changes what deployment success should mean. **When `initSql` is supplied, successful resource deployment should mean that the required SQL completed successfully, not merely that Azure created the database.** Initialization must therefore participate in dependency ordering and failure reporting. A separate, untracked background script could leave Radius reporting success while dependent services fail.

There are consequently **two distinct gaps**:

1. **An implementation gap:** The Azure Recipe needs to honor `initSql`. A wrapper Recipe can fix this today.
2. **A reuse gap:** A Recipe Pack selects one Recipe source for a resource; it cannot currently describe a sequence of separately referenced modules for that same resource. Connecting an unchanged database AVM to a separate initializer therefore requires another template.

Radius already manages resource dependencies, and Bicep already orders resources within a template. Recipe composition would add coordination at the Recipe Pack level; it would not introduce SQL execution by itself.

## Options

**Wrapper Recipe, uses existing Radius features:** Publish a Bicep Recipe that calls the PostgreSQL AVM, then runs SQL through an Azure deployment script, as implemented in open [#474](https://github.com/radius-project/resource-types-contrib/pull/474). It reuses the AVM rather than copying its database implementation.

**Recipe composition, proposed Radius feature:** Let a Recipe Pack define ordered steps for one resource. Radius would call the database module, pass its outputs to an initialization module, and manage the combined result.

| Consideration | Wrapper Recipe | Recipe composition |
| --- | --- | --- |
| **Delivery** | Solves the current issue with existing features. | Requires a new configuration contract and engine support. |
| **Maintenance** | Adds an artifact to publish and version. Similar wrappers can repeat coordination code. | Avoids artifacts used only to join modules, but adds a shared feature for Radius to maintain. |
| **Failure and cleanup** | Bicep controls ordering, but initialization can fail before the Recipe returns cleanup IDs. Failed deployment cleanup needs separate verification. | Radius must save completed-step resources before starting the next step and track resources created by a failed step, even if it returns no outputs. |
| **Custom logic** | Can also perform settings conversion and platform-specific work. | Does not remove that work. Some wrappers may still be necessary. |
| **RRT alignment** | Keeps database-specific behavior in the platform-selected Recipe. | Also fits RRT if Radius manages generic steps, not PostgreSQL-specific commands. |

Both options still need a SQL runner, protected credentials, network access, execution limits, and SQL that is safe to repeat. Neither guarantees exactly-once execution, automatic undo, or an implicit whole-script transaction. These requirements concern reliable initialization, not a database migration system.

## Recommendation

**Use the wrapper to close the implementation gap now.** Keep live execution and cleanup verification in [#472](https://github.com/radius-project/resource-types-contrib/issues/472).

**Evaluate composition separately as a reuse improvement.** It becomes worthwhile when several Resource Types need the same staged workflow. It should not be a prerequisite for making the existing `initSql` property work.

## Failed initialization, cleanup, and retries

**Initialization failure must report deployment failure while preserving the database and committed SQL.** Database deletion must require a separate explicit action; initialization failure alone must not trigger it. The wrapper provides no implicit whole-script transaction or undo.

`cleanupPreference: Always` requests cleanup of the temporary runner container and storage account. It does not delete PostgreSQL or roll back SQL.

Cleanup IDs in the final `result` do not prove Radius recorded resources if failure occurs before outputs reach Radius. Tracking resources for later explicit deletion is separate from runner cleanup and database teardown; verify failed-path tracking and deletion in [#472](https://github.com/radius-project/resource-types-contrib/issues/472).

Retries require SQL that is safe to repeat. The runner stops on the first SQL error; it does not resume at that statement. Do not assume exactly-once execution or that an unchanged deployment will rerun a failed script.

Proposed composition must save completed-step resource IDs before initialization, retain them on failure, and track resources created by failed steps even without outputs.
