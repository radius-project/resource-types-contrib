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

Because `tls` defaults to `required`, configure your PostgreSQL client for TLS. Both Kubernetes Recipes enable PostgreSQL SSL for every policy and enforce the requested policy through ordered `pg_hba.conf` rules for IPv4 and IPv6. `required` (including an omitted `tls`) rejects plaintext TCP connections; `optional` permits both TLS and plaintext. Both paths require SCRAM password authentication. Unix-socket access remains available for the image entrypoint's local database initialization and Bicep `initSql`.

The Azure Recipe also enforces the requested policy, but a platform engineer can pin the Azure server's transport policy to `ON` or `OFF`; the connection variable still reports the application's request. See [PostgreSQL transport policy](../../recipe-packs/azure-aks/README.md#postgresql-transport-policy) for unchanged precedence and public-network restrictions.

Use `optional` only when the server is not publicly reachable. Non-TLS connections can expose administrator credentials and query traffic in transit. Private reachability does not encrypt traffic, so TLS remains preferred; keep it required with the Azure pack as written.

## Kubernetes certificates and recipe parameters

### TLS migration and release requirements

Adopting these Recipes requires a new operator-owned TLS Secret for **both**
transport policies. Existing deployments without that Secret cannot start the
new Pods. Bicep resource submission can complete while the database is
unavailable; always require a successful rollout and TCP query.

Merging to `main` refreshes the floating `edge` Bicep artifact. Consumers of that
tag must prepare certificates, client trust, and backups before redeployment, or
pin an immutable pre-change artifact while migrating. A merge does not alter an
already-running server or an immutable Recipe reference.

For breaking Recipe upgrades, maintainers must publish a migration notice that
reaches `edge` users, coordinate the `Radius.Data` namespace release and its
breaking-change versioning, and coordinate the resulting
`bot/update-resource-types` PR in `radius-project/radius`. Released Radius
versions pin a namespace release's commit; they do not automatically adopt every
new `edge` artifact. The checked-in Kubernetes default pack currently has no
PostgreSQL entry. Its unrelated stable Recipe references must not be changed as
part of this migration.

An operator must provision a Kubernetes TLS Secret in the database's namespace **before deployment**, for both policies. By default the Recipes use `<resource-name>-tls` (for example, `postgresql-tls`). They do not generate certificates or fall back to plaintext when a Secret is absent or invalid.

| Recipe parameter | Default | Purpose |
| --- | --- | --- |
| `postgresqlTlsSecretName` | Empty; resolves to `<resource-name>-tls` | Name of an existing operator-owned Secret in the database namespace. Both Recipes accept omission or an empty string to select this default. |
| `postgresqlTlsCertificateRevision` | `1` | Nonempty operator revision. Change it after replacing the certificate to trigger a pod rollout on redeployment. |

Set these as `parameters` on the PostgreSQL entry in your Recipe Pack. The Secret must contain a PEM `tls.crt` (leaf certificate followed by intermediates, if needed) and an **unencrypted** matching PEM `tls.key`. Use a server-auth certificate from a CA trusted by your clients. Its DNS SAN must cover the returned `host`, `<resource-name>.<namespace>.svc.cluster.local`; include additional DNS names if clients use them. For clusters with a different DNS suffix, customize the existing host-output convention as well as the certificate.

```bash
# server-chain.pem and server.key are issued/managed by the operator's CA.
kubectl create secret tls postgresql-tls --namespace <database-namespace> \
  --cert=server-chain.pem --key=server.key
```

The operator owns issuance, expiry monitoring, renewal, access control, and deletion of this Secret. It is **not** in the Recipe's cleanup list, so deleting the Radius application does not delete it. Do not store private keys in ConfigMaps, application properties, recipe parameters, source control, or logs. The Recipes mount the Secret read-only to a root init container, copy it to a memory-backed volume, set the private key to `0600` owned by `postgres`, and mount that volume read-only in the server. Only public transport rules go into the Recipe-owned ConfigMap. Credentials retain their existing Secret-backed inputs; neither credentials nor TLS material are returned in `result.values` or `result.secrets`.

Missing Secrets or keys block pod initialization (inspect Kubernetes events); empty files cause an explicit init-container error. PostgreSQL refuses to start with malformed or mismatched TLS material (inspect the server's startup error). Terraform waits for the Deployment rollout; Bicep's resource submission alone is not a health check, so operators must wait for `kubectl rollout status deployment/<resource-name> --timeout=180s` and run a TCP query before declaring deployment usable. There is no plaintext-only fallback.

### Encryption versus verified server identity

`CONNECTION_POSTGRESQL_TLS` reports the transport policy, not a CA bundle or proof of identity. `sslmode=require` encrypts a connection but does not by itself provide hostname verification. Distribute the issuing CA's public certificate to clients separately, and use `sslmode=verify-full`:

```bash
PGSSLMODE=verify-full PGSSLROOTCERT=/path/to/ca.pem \
  psql --host=postgresql.<database-namespace>.svc.cluster.local \
  --port=5432 --username=<username> --dbname=appdb \
  --command='SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();'
```

Supply passwords through your client's secret mechanism (for example a protected `.pgpass`), not command-line arguments. The query must return `t`. Node.js `pg` clients should provide the trusted CA and keep certificate verification enabled, for example `ssl: { ca: caPem, rejectUnauthorized: true }`. Do not disable certificate verification to accommodate an untrusted certificate. A self-signed certificate is suitable only for isolated development unless clients explicitly trust it and verify its DNS SAN.

### Rotation, policy changes, and data protection

**These Recipes do not provision durable data volumes. Recreating a pod can destroy the database.** Back up and verify restoration before upgrading a Recipe, changing policy, rotating certificates, or restarting pods. Arrange durable storage in a customized Recipe before relying on this deployment for persistent data; this fix does not redesign storage.

The server uses a startup copy of the certificate, so updating the Secret alone does not rotate the active certificate. Replace its data without recording private keys in a last-applied annotation (use your secret manager or `kubectl create secret tls ... --dry-run=client -o json | kubectl replace -f -` for an existing Secret). Then change `postgresqlTlsCertificateRevision` in the Recipe Pack and redeploy the pack and application, or explicitly run `kubectl rollout restart deployment/<resource-name>`. Wait for the rollout and repeat `verify-full`. When rotating the CA, distribute a trust bundle containing both CAs before rolling out the new server certificate.

Changing `tls` changes the selected HBA file and pod template. A single Recipe-owned ConfigMap contains both policies, so transitions neither depend on ConfigMap-update propagation nor leave behind policy-specific ConfigMaps. Terraform uses `Recreate`. Bicep uses `RollingUpdate` with `maxSurge: 0` and `maxUnavailable: 1`: it avoids a surge replica and permits downtime for the single database replica. This retains the existing strategy type because Radius's Bicep Kubernetes apply cannot clear defaulted `rollingUpdate` fields when switching an existing Deployment to `Recreate`, even with an explicit null. Kubernetes can retain terminating Pods during their grace period; zero surge is not a guarantee that every old process has exited before the replacement starts.

Adopting the new Recipe changes the pod template and triggers a rollout. Live transition tests cover fresh ephemeral databases after those rollouts, not policy changes with retained PGDATA. A repeat deployment with unchanged inputs does not intentionally restart the database. Bicep's `initSql` behavior is preserved; Terraform still does not implement that property.

### Publishing and upgrading

A source merge does not update deployed servers. Publish new artifacts and use an explicit version in your Recipe Pack, then redeploy. For example:

```bash
# Bicep: use Radius's bundled compiler through publishing.
rad bicep publish \
  --file Data/postgreSqlDatabases/recipes/kubernetes/bicep/kubernetes-postgresql.bicep \
  --target br:<registry>/postgre-sql:<new-version>

# Terraform: package the module for your module host; the local test publisher is:
make build-terraform-recipe RECIPE_PATH=Data/postgreSqlDatabases/recipes/kubernetes/terraform

# Update the PostgreSQL Recipe Pack entry's source/parameters first.
rad deploy <your-recipe-pack.bicep> --environment <environment>
rad deploy <your-app.bicep> --environment <environment>
kubectl rollout status deployment/<resource-name> --namespace <database-namespace> --timeout=180s
```

Existing plaintext-only Kubernetes clients will stop working under the default `required` policy. Provision the Secret, distribute CA trust, and migrate clients to TLS before redeploying. An explicit `optional` is a compatibility escape hatch only on isolated, non-public networks, not a substitute for migration.

## Kubernetes deployment tests

After publishing/registering the selected Recipe in an isolated test Environment, run `.github/scripts/test-recipe.sh Data/postgreSqlDatabases/recipes/kubernetes/bicep` or the corresponding `terraform` path. The normal CI recipe matrix runs this suite for both implementations and waits for explicit probe results.

The suite creates a short-lived test CA and an operator-owned TLS Secret, then probes omitted, explicit `required`, and `optional`, repeat deployments, both policy transitions, and certificate rotation. It checks `pg_stat_ssl` over TCP with bounded connection/query timeouts, verifies `verify-full`, matches plaintext failures to the HBA transport rejection rather than unrelated errors, checks the schema default and `CONNECTION_POSTGRESQL_TLS`, preserves the output contract, and checks Bicep initialization SQL and private-key permissions. Test keys stay in a protected temporary directory and a Kubernetes Secret and are removed on exit. Do not run these destructive rollout tests against an existing database. Record Radius CLI/runtime versions, schema version, recipe artifact digest, Kubernetes/node versions, and the resolved `postgres:16-alpine` image digest when reproducing a failure.

The first Bicep deployment delays initialization long enough for a separate observer to require an actual socket-ready, TCP-unavailable, Pod-NotReady window. It then requires the initialization-complete marker and final TCP readiness. Missing the window fails the test rather than counting as proof. Run `bash Data/postgreSqlDatabases/test/assert-readiness-test.sh` for the observer's positive and negative regression cases. Terraform's identical TCP probe is checked by its mock-provider tests and live rollouts; its Recipe does not support `initSql`.

The template's `applicationName` parameter matches the CLI application and cleanup target. Cleanup explicitly deletes the contributed resources and their `Radius.Core/applications` resource, then removes any legacy `Applications.Core/applications` created by the CLI. `rad app delete` alone targets the legacy type and is insufficient. The fallback sweep supports both `radapp.io/application` and `app` labels with the generated application name, and deletes the named probe/certificate fixtures; it never sweeps the entire namespace. Fixture deletion waits up to 60 seconds so the next run does not race a terminating probe Pod. Run `bash Data/postgreSqlDatabases/test/test-tls-runner.sh` for cluster-free regression checks of parameter flags, application ownership, and cleanup on success and failure. CI runs these checks before deployment tests.

## Migrating Kubernetes consumers

The Kubernetes Recipes no longer return the user-supplied `password` or derived `connectionString` through `result.secrets`. Existing consumers of those managed secret keys must explicitly provide the password to the consuming Container. Author a `Radius.Security/secrets` resource with the same password passed to the database, then either connect the Container directly to that Secret for generated `CONNECTION_<CONNECTION-NAME>_<KEY>` variables or bind the key to the required variable with `valueFrom.secretKeyRef`, as shown in [`test/app.bicep`](test/app.bicep). This change does not silently create a replacement `connectionString`; applications that require one must compose it from the database connection values and the referenced password.
