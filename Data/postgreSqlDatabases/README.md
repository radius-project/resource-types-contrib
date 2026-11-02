# Radius.Data/postgreSqlDatabases

## Overview

The **Radius.Data/postgreSqlDatabases** resource type represents a PostgreSQL database. It allows developers to create and easily connect to a PostgreSQL database as part of their Radius applications. The developer provides the administrator `username` and `password` directly on the resource; the `password` property is marked `x-radius-sensitive`, so Radius encrypts it at rest, redacts it on reads, and injects it decrypted only into the platform's Recipe.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/postgreSqlDatabases` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `username` | string | Required | The administrator username for the PostgreSQL database. Passed to the Recipe as `{{context.resource.properties.username}}`. |
| `password` | string (`x-radius-sensitive`) | Required | The administrator password. Encrypted at rest, redacted on reads, and injected decrypted into the Recipe as `{{context.resource.properties.password}}`. |
| `database` | string | Optional | The name of the database. Defaults to `postgres_db`. |
| `size` | string (`S`, `M`, `L`) | Optional | The size of the PostgreSQL database. Defaults to `S`. The Recipe maps the size onto a concrete cloud SKU/tier. |
| `initSql` | string | Optional | Optional SQL script executed on first initialization to create tables, indexes, and seed data. |
| `tls` | string (`required`, `optional`) | Optional | The requested transport policy for connections to the database server. Defaults to `required`. Use `optional`, which permits non-TLS connections, only when the server is not publicly reachable. See below for platform behavior and operator overrides. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `5432`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/postgreSqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `avm/res/db-for-postgre-sql/flexible-server` |
| Kubernetes | [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep) | `ghcr.io/radius-project/kube-recipes/postgresqldatabases` |

## Using the resource type

Add a `postgreSqlDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_POSTGRESQL_HOST`, `CONNECTION_POSTGRESQL_PORT`, `CONNECTION_POSTGRESQL_DATABASE`, and `CONNECTION_POSTGRESQL_TLS`). See [`test/app.bicep`](test/app.bicep) for a complete example.

Because `tls` defaults to `required`, configure your PostgreSQL client for TLS — for example, by passing `ssl: { rejectUnauthorized: true }` to the Node.js `pg` driver. `tls` states the policy the application requests, and each Recipe honors it where the platform allows: the Azure Recipe enforces it on the flexible server, while the Kubernetes Recipe runs a PostgreSQL container that serves plaintext. Setting `required` does not enable TLS in that Kubernetes Recipe. A platform engineer can also pin the Azure server's transport policy to `ON` or `OFF`; the connection variable still reports the application's request. See [PostgreSQL transport policy](../../recipe-packs/azure-aks/README.md#postgresql-transport-policy) for precedence and public-network restrictions.

Use `optional` only when the server is not publicly reachable. Non-TLS connections can expose administrator credentials and query traffic in transit. Private reachability does not encrypt traffic, so TLS remains preferred; keep it required with the Azure pack as written.

## Migrating Kubernetes consumers

The Kubernetes Recipes no longer return the user-supplied `password` or derived `connectionString` through `result.secrets`. Existing consumers of those managed secret keys must explicitly provide the password to the consuming Container. Author a `Radius.Security/secrets` resource with the same password passed to the database, then either connect the Container directly to that Secret for generated `CONNECTION_<CONNECTION-NAME>_<KEY>` variables or bind the key to the required variable with `valueFrom.secretKeyRef`, as shown in [`test/app.bicep`](test/app.bicep). This change does not silently create a replacement `connectionString`; applications that require one must compose it from the database connection values and the referenced password.

## Test size and Azure capacity recovery

The test app accepts `postgresSize` (`S`, `M`, or `L`) and defaults to `S`.
Kubernetes tests keep that default. Azure pack-entry tests use only `S`
(`Standard_B1ms`, Burstable) and `M` (`Standard_D2ds_v5`, GeneralPurpose).
`L` is not a recovery option because it maps to the same Azure SKU as `M`.
The Resource Type schema and production pack defaults do not change.

The all-entry runner reads `RTC_AZURE_SELECTION_FILE` when it is set. Only a
valid version 1 result with `status: selected` permits PostgreSQL deployment.
The result must match the existing resource group's region and the approved
size, SKU, and tier. A missing, invalid, exhausted, or failed result fails the
PostgreSQL entry; later entries still run. Without a result file, the runner
makes one bounded probe of the first configured size in the existing group's
region (`S` by default).

Before any initial or recovery probe creates a server, it makes a bounded
`az postgres flexible-server list-skus` call. The catalog must support
PostgreSQL 16, the selected tier and SKU, and 32 GiB of storage. A verified
unsupported tuple returns exit 4 with `outcome: unsupported` and an
`UnsupportedVersion`, `UnsupportedTier`, `UnsupportedSku`, or
`UnsupportedStorage` code. A restricted region, including `OfferRestricted`
enabled, is a policy error (`RegionRestricted`), not capacity exhaustion.
Malformed catalogs and failed reads stop allocation. Catalog reads share the
create deadline.
Probe commands and region reads run in a separate process group. Their
watchdog kills that group on timeout, cancellation, or command exit so a
wrapper's child cannot keep output handles open or outlive cleanup.

The probe uses a 128-bit random server name and checks that the name is absent
before creation. It sets an ownership tag at creation and verifies that tag
before deletion, including after a failed or timed-out create. Azure reads are
bounded: absence checks use the create budget; ownership checks and deletion
use the cleanup reserve. Unknown ownership or unconfirmed cleanup stops the
probe without another allocation.

A timed-out create can finish after the client exits. An immediate
`ResourceNotFound` response does not rule out later creation. On create
timeout or interruption during creation, the probe prints the exact server
name, resource group, and expected `rtc-probe-owner` tag. It also logs this
non-secret recovery target before creation, in case the process is killed
before cleanup can run. Mixed or uncoded failure records cannot authorize
another allocation or confirm absence during cleanup.
Use `az postgres flexible-server show --resource-group
<group> --name <server> --output json` with the original subscription to check
the target again. Delete it only after its `tags["rtc-probe-owner"]` value
matches the printed tag. If ownership cannot be verified, do not delete it.

For a direct Azure entry test, set `RTC_TEST_PLATFORM=azure`,
`AZURE_RESOURCE_GROUP`, and `RTC_POSTGRES_TEST_SIZE=S` or `M`. The runner passes
the size to the test app. Each deployment has a 15-minute limit, reduced to
the remaining time when `deadlineEpochSeconds` is present in the selection
result. Direct runs can set `RTC_POSTGRES_TEST_DEADLINE_EPOCH` to the same
absolute Unix deadline. Without a deadline, the entry has a 30-minute budget.
`RTC_POSTGRES_TEST_SIZES` limits allowed allocations (default `S,M`).
The selected size must be in that list. A single-size list disables size
recovery; an empty or invalid list fails before deployment.
Direct entry calls first probe the requested size in the actual resource
group's region, even if `AZURE_LOCATION` is unset or points elsewhere.
The all-entry runner passes its verified size and region to avoid a duplicate
initial probe. The entry runner checks that this region still matches the
existing resource group before it accepts the verification.

All PostgreSQL deployment, assertion, lock and resource inventory commands
use a process-group watchdog with the remaining work budget. Cleanup uses
one separate reserve across lock removal, application deletion, Kubernetes
cleanup, and the final Azure inventory check.
`RTC_POSTGRES_CLEANUP_RESERVE_SECONDS` sets this reserve (default and maximum
900 seconds). A cleanup timeout blocks further probes and deployment.
These limits do not change unrelated entry tests.

If a deployment reports a structured `SkuNotAvailable` or `ServerIsBusy`
error for an Azure PostgreSQL server, the runner deletes the failed app and
checks that no new Azure resource IDs remain in the group. Only after these
checks pass can it probe the other allowed size once in the existing group's
region. The probe uses the remaining shared deadline and must confirm its
own cleanup before a retry with that size and a distinct app name.
An unsupported, failed, or uncertain probe stops recovery.
The region does not change. Mixed or unknown errors, timeouts,
assertion failures, and incomplete cleanup stop recovery. Cleanup has a
separate time allowance and never deletes untracked Azure resources.
