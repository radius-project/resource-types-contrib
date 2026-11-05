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
| `extensions` | array of strings | Optional | Extension names. Azure allow-lists them; the application must create each extension in its database. Kubernetes creates them when the database is first initialized. Defaults to `[]`. |
| `serverSettings` | object of strings | Optional | PostgreSQL server parameter names and values. Azure operator settings take precedence. Reserved TLS and port settings cannot be changed through this object. Defaults to `{}`. |
| `initSql` | string (`x-radius-sensitive`) | Optional | SQL for users, schemas, and seed data. Azure runs it after provisioning; it must be safe to repeat. Kubernetes Bicep runs it when the data directory is empty. See [database initialization](#database-initialization). |
| `tls` | string (`required`, `optional`) | Optional | The requested transport policy for connections to the database server. Defaults to `required`. Use `optional`, which permits non-TLS connections, only when the server is not publicly reachable. See below for platform behavior and operator overrides. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `5432`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/postgreSqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | [Authored Recipe](recipes/azure/README.md) using Azure Verified Module `avm/res/db-for-postgre-sql/flexible-server:0.15.2` |
| Kubernetes | [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep) | `ghcr.io/radius-project/kube-recipes/postgresqldatabases` |

## Using the resource type

Add a `postgreSqlDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_POSTGRESQL_HOST`, `CONNECTION_POSTGRESQL_PORT`, `CONNECTION_POSTGRESQL_DATABASE`, and `CONNECTION_POSTGRESQL_TLS`). See [`test/app.bicep`](test/app.bicep) for a complete example.

Because `tls` defaults to `required`, configure your PostgreSQL client for TLS and trust the server's certificate authority (CA). Both Kubernetes Recipes enable TLS for every policy and reject plaintext TCP connections when `tls` is omitted or `required`. With `optional`, both TLS and password-authenticated plaintext connections work. A platform engineer can still pin the Azure server's transport policy to `ON` or `OFF`; the connection variable reports the application's request. See [PostgreSQL transport policy](../../recipe-packs/azure-aks/README.md#postgresql-transport-policy) for Azure precedence and public-network restrictions.

Use `optional` only when the server is not publicly reachable. Non-TLS connections can expose administrator credentials and query traffic in transit. Private reachability does not encrypt traffic, so TLS remains preferred; keep it required with the Azure pack as written.

## Extensions and server settings

Declare the settings that the application needs:

```bicep
extensions: [
  'pg_trgm'
  'btree_gin'
]
serverSettings: {
  log_min_duration_statement: '1000'
}
```

Use extension names supported by the target server. The default
`postgres:16-alpine` image includes `pg_trgm` and `btree_gin`, but not every
extension. For example, `vector` needs an image that includes pgvector.
These Recipes do not install extension packages.

On Azure, `extensions` sets the server's `azure.extensions` allow-list.
The application must then create each extension in its database. An omitted
or empty list leaves an existing allow-list unchanged; it does not remove
extensions. An explicit operator `azure.extensions` value replaces the
application list and can clear it. Generic `serverSettings` entries for
`azure.extensions`, `require_secure_transport`, or `port` are ignored,
without regard to case. Use the dedicated `extensions` and `tls` properties.
Operator settings override matching application names without regard to case.
See the [Azure Recipe](recipes/azure/README.md) for the AVM conversion and
the publication prerequisite for the new Recipe image.

On Kubernetes, both Recipes generate `CREATE EXTENSION IF NOT EXISTS`
statements in `/docker-entrypoint-initdb.d/00-extensions.sql`. PostgreSQL
runs these only when its data directory is empty. The Bicep Recipe keeps
the existing `01-init.sql` file after the extension file. Updating the list
does not create or remove extensions in an existing database. Both Recipes
pass server settings as separate `postgres -c name=value` arguments, not
shell commands. They escape dollar signs in Pod arguments so Kubernetes
preserves literal values such as `$(POSTGRES_DB)` and `$$` before the shell
forwards them to PostgreSQL. Invalid or unavailable settings fail startup. Setting
changes cause a Pod rollout; read the [data protection warning](#updates-and-data-protection)
before making changes.

The Kubernetes Recipes reserve `port`, `ssl`, `ssl_cert_file`,
`ssl_key_file`, and `hba_file`, without regard to case. This preserves
the existing TLS policy and certificate handling. Both platforms keep
the server on port 5432. Other setting names and values are passed
unchanged. Do not place credentials in `serverSettings`.

## Database initialization

Use `initSql` to create the users, schemas, and seed data the application
needs. For example:

```bicep
initSql: '''
  CREATE SCHEMA IF NOT EXISTS app;
  CREATE TABLE IF NOT EXISTS app.products (id integer PRIMARY KEY, name text NOT NULL);
  INSERT INTO app.products (id, name) VALUES (1, 'sample') ON CONFLICT (id) DO NOTHING;
'''
```

On Azure, the Recipe runs nonempty SQL after the server, database, and
server settings are ready. Empty or whitespace-only SQL creates no runner.
SQL changes can run the script again. A later deployment can also run it
again after the deployment-script retention period expires. Use SQL that
is safe to repeat; execution is not guaranteed to occur only once.

A SQL error fails the Recipe. The runner does not wrap the whole script in
a transaction or undo completed statements. It does not print SQL results
or database errors, which can contain credentials. See the
[Azure Recipe](recipes/azure/README.md#sql-initialization) for time limits,
permissions, network requirements, and cleanup behavior.

Radius encrypts `initSql` at rest and redacts it on reads. Use a secure
Bicep parameter if the script contains credentials. This does not change
the existing Kubernetes Bicep ConfigMap storage: that Recipe mounts the
script under `/docker-entrypoint-initdb.d/` and runs it when the data
directory is empty. It does not run changed SQL against an existing volume.
The Kubernetes Terraform Recipe does not implement `initSql`.

### Local settings and initialization checks

Use Node.js, the Radius-bundled Bicep CLI (`~/.rad/bin/bicep`, or set
`BICEP_CLI`), and Terraform 1.7 or later. The first run needs access to the
public AVM and Terraform provider registries.

```bash
make test-postgresql-settings
make test-postgresql-inputs
bash .github/scripts/tests/test-postgresql-transport.sh
```

These commands check compiled output, Azure snapshots, SQL-runner shell
fixtures, Terraform plans with a mock Kubernetes provider, and existing
transport regressions. They do not deploy to Azure or Kubernetes. Deployment-specific checks remain
in [#472](https://github.com/radius-project/resource-types-contrib/issues/472).

## Kubernetes TLS

Both Kubernetes Recipes enable TLS without requiring certificate setup. An init container generates a self-signed development certificate when the optional `<resource-name>-tls` Secret is absent or empty. It uses RSA-2048/SHA-256, expires after 365 days, and includes the Service hostname in its subject alternative names. This encrypts connections but does not establish an identity clients already trust.

For managed certificates and verified identity, create `<resource-name>-tls` in the Radius Environment's Kubernetes namespace before deployment. Supplied material takes precedence in both transport modes. A nonempty Secret must contain a valid matching `tls.crt` and unencrypted `tls.key`; partial, empty-file, malformed, or mismatched material fails initialization instead of falling back. Kubernetes projects absent and empty Secrets identically, so both select generation. The Recipe needs no Kubernetes API access or additional RBAC permissions and never creates or deletes this operator Secret.

Creating or populating the Secret after the Pod starts does not replace its prepared certificate. This also applies when an external certificate manager, such as cert-manager, issues the certificate asynchronously; cert-manager is not a Recipe dependency. Supply valid material before deployment if clients need verified identity immediately. Otherwise, once it is available, follow the [Deployment restart procedure](#updates-and-data-protection), wait for readiness, and verify client trust. An ordinary PostgreSQL container restart does not adopt the new Secret. Read the backup/restore warning before replacing the Pod.

Provide a PEM server certificate chain in `tls.crt` (leaf first, followed by intermediate certificates) and its matching, unencrypted private key in `tls.key`. The certificate's subject alternative names must include the returned Service hostname, `<resource-name>.<namespace>.svc.cluster.local`, plus any other DNS names clients use. Obtain certificates from your organization's CA for production. Distribute the public root CA to clients separately; never mount the server private key into a client.

For example, after obtaining the certificate and key:

```bash
namespace=default # Replace with the namespace shown by rad env show.
database=postgresql
kubectl create secret tls "$database-tls" --namespace "$namespace" \
  --cert=server.crt --key=server.key
```

For an isolated development cluster, the operator can instead issue a short-lived certificate using a test CA:

```bash
umask 077
hostname="$database.$namespace.svc.cluster.local"
openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj /CN=postgresql-test-ca \
  -keyout ca.key -out ca.crt
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$hostname" \
  -keyout server.key -out server.csr
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$hostname" > server.ext
openssl x509 -req -days 7 -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -extfile server.ext -out server.crt
kubectl create secret tls "$database-tls" --namespace "$namespace" \
  --cert=server.crt --key=server.key
```

Keep `ca.key` offline and protect/delete local private-key files appropriately. The CA private key is never uploaded to Kubernetes. The init container reads one revision of the read-only Secret projection and prepares certificate material in a memory-backed volume. PostgreSQL startup gives the key to `postgres` with mode `0600` and configures authentication rules. Invalid supplied material stops initialization; inspect `kubectl logs deployment/<resource-name> -c prepare-tls` for a diagnostic identifying the Secret.

Verify readiness after deployment rather than relying solely on `rad deploy`: the current Bicep Recipe runtime can report success before the PostgreSQL Pod is ready, including when certificates prevent startup.

```bash
kubectl rollout status deployment/"$database" --namespace "$namespace" --timeout=180s
```

### Client trust

Encryption alone does not establish server identity. `sslmode=require` requests TLS; use `sslmode=verify-full` with the trusted root CA to validate both the certificate chain and hostname. From a client that can resolve and reach the Service:

```bash
psql "host=$database.$namespace.svc.cluster.local port=5432 dbname=appdb user=radadmin sslmode=verify-full sslrootcert=/path/to/ca.crt"
```

Supply the password through a password prompt or protected credential mechanism, not a logged connection string. `CONNECTION_POSTGRESQL_TLS` describes transport policy; it neither configures a client nor distributes a CA. For Node.js `pg`, use verified TLS with the public CA, or supported `PGSSLMODE=verify-full` and `NODE_EXTRA_CA_CERTS` settings in the client process. Do not disable certificate verification in production.

An automatically generated self-signed certificate is not trusted by default. Development clients can request encryption without identity verification, or explicitly enroll its public certificate as a trust anchor through a trusted channel. Never distribute the private key. Use an operator-managed certificate and verified identity for production. The generated pair survives ordinary container restarts, but a replacement Pod generates a new identity unless an operator Secret is supplied.

### Updates and data protection

**Back up and plan to restore data before upgrading, changing policy, or restarting the Deployment.** These Recipes do not provision durable database volumes; a replacement Pod starts with an empty database. Bicep's `initSql` runs again on an empty database and is not a substitute for a backup.

Changing `tls` changes the Pod template and triggers a rollout. The dedicated authentication file is configured on every startup, not just initial database creation. Wait for rollout completion before relying on the new policy; a failed rollout can leave an old ready Pod serving the previous policy until the operator repairs the rollout.

The operator is responsible for certificate expiration and rotation. Update the same Secret and explicitly restart the Deployment to rerun certificate preparation; an ordinary PostgreSQL container restart reuses the prepared material and does not reload the Secret. There is no automatic renewal or reload:

```bash
kubectl create secret tls "$database-tls" --namespace "$namespace" \
  --cert=server.crt --key=server.key --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/"$database" --namespace "$namespace"
kubectl rollout status deployment/"$database" --namespace "$namespace"
```

Distribute a new CA to clients before rotating to a different issuer, and restart clients that load CA certificates only at startup. Deleting the Radius application does not delete the operator's TLS Secret or client CA. Remove these explicitly only when no consumers need them.

Existing plaintext clients must adopt TLS before deploying these updated Recipes with required/default policy. A source merge alone changes no running server, but the main-branch publishing workflow updates the floating Bicep `edge` artifact for subsequent deployments. Publish/version the Bicep artifact with `rad bicep publish` or package/publish the Terraform module, update the Environment's Recipe Pack as needed, then redeploy the application. Publish compatible sample configuration and migration instructions before rolling out the new artifacts to tutorial users.

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
makes one bounded `S` probe in the existing group's region.

The probe uses a 128-bit random server name and checks that the name is absent
before creation. It sets an ownership tag at creation and verifies that tag
before deletion, including after a failed or timed-out create. Azure reads are
bounded: absence checks use the create budget; ownership checks and deletion
use the cleanup reserve. Unknown ownership or unconfirmed cleanup stops the
probe without another allocation.

A timed-out create can finish after the client exits. An immediate
`ResourceNotFound` response does not rule out later creation. On create
timeout, the probe prints the exact server name, resource group, and expected
`rtc-probe-owner` tag. Use `az postgres flexible-server show --resource-group
<group> --name <server> --output json` with the original subscription to check
the target again. Delete it only after its `tags["rtc-probe-owner"]` value
matches the printed tag. If ownership cannot be verified, do not delete it.

For a direct Azure entry test, set `RTC_TEST_PLATFORM=azure`,
`AZURE_RESOURCE_GROUP`, and `RTC_POSTGRES_TEST_SIZE=S` or `M`. The runner passes
the size to the test app. Each deployment has a 15-minute limit, reduced to
the remaining time when `deadlineEpochSeconds` is present in the selection
result. Direct runs can set `RTC_POSTGRES_TEST_DEADLINE_EPOCH` to the same
absolute Unix deadline. Without a deadline, the entry has a 30-minute budget.

If a deployment reports a structured `SkuNotAvailable` or `ServerIsBusy`
error for an Azure PostgreSQL server, the runner deletes the failed app and
checks that no new Azure resource IDs remain in the group. Only after these
checks pass can it retry once with the other approved size and a distinct
app name. The region does not change. Mixed or unknown errors, timeouts,
assertion failures, and incomplete cleanup stop recovery. Cleanup has a
separate time allowance and never deletes untracked Azure resources.
