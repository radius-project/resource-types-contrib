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

Because `tls` defaults to `required`, configure your PostgreSQL client for TLS. The Kubernetes Recipes enforce the requested policy through ordered `pg_hba.conf` rules for IPv4 and IPv6. `required` (including an omitted `tls`) rejects plaintext TCP connections; `optional` enables TLS but permits both TLS and plaintext. Explicit `disabled` turns PostgreSQL SSL off and accepts only password-authenticated plaintext, without certificates. All modes retain SCRAM TCP authentication. Unix-socket access remains available for the image entrypoint's local database initialization and Bicep `initSql`.

The Azure context Recipe rejects `disabled`, even with an operator transport override. For `required` and `optional`, a platform engineer can still pin the Azure server's transport policy to `ON` or `OFF`; the connection variable reports the application's request. The checked-in Azure pack still uses the previous direct AVM mapping until the guarded wrapper is published and verified. **Do not release the expanded schema or activate `disabled` on Azure before that guard is active.** See [PostgreSQL transport policy](../../recipe-packs/azure-aks/README.md#postgresql-transport-policy) for precedence, public-network restrictions, and publication gates.

For an explicitly disposable Kubernetes database on a trusted/private network, set `tls: 'disabled'` and configure the client with `PGSSLMODE=disable`. No TLS Secret or CA is needed. This sends credentials and data without transport encryption; the documentation does not enforce network isolation. `optional` is not a certificate-free alternative. Neither mode is a fallback for broken or missing certificates in a TLS-enabled deployment.

```bicep
resource disposableDatabase 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'disposable-database'
  properties: {
    environment: environment
    username: 'radadmin'
    password: databasePassword // Supply through a secure parameter.
    tls: 'disabled'
  }
}
```

Use `optional` only when the server is not publicly reachable. Non-TLS connections can expose administrator credentials and query traffic in transit. Private reachability does not encrypt traffic, so TLS remains preferred; keep it required with the Azure pack as written.

## Kubernetes certificates and recipe parameters

### TLS migration and release requirements

Adopting these Recipes requires a new operator-owned TLS Secret for **both
TLS-enabled policies**, `required` and `optional`. Explicit Kubernetes `disabled`
needs no certificate. Existing TLS-enabled deployments without that Secret cannot start the
new Pods. Bicep resource submission can complete while the database is
unavailable; always require a successful rollout and TCP query.

Merging to `main` refreshes the floating `edge` Bicep artifact. Consumers of that
tag must prepare certificates, client trust, and backups before redeployment, or
pin an immutable pre-change artifact while migrating. A merge does not alter an
already-running server or an immutable Recipe reference.

Before rolling out floating artifacts, update affected tutorials, samples, and
demo clients to provision certificates and configure CA trust and hostname
verification, and verify their complete deployment and connection flow. These
downstream updates must precede the contrib merge that refreshes `edge`.

For breaking Recipe upgrades, maintainers must publish a migration notice that
reaches `edge` users, coordinate the `Radius.Data` namespace release and its
breaking-change versioning, and coordinate the resulting
`bot/update-resource-types` PR in `radius-project/radius`. For newly created CLI
default packs, edge builds select `:edge`; released builds select their
`Radius.Data`-pinned namespace commit tag. Normal Environment creation and
deployment defaulting use the CLI's get-or-create path, which reuses existing
default packs unchanged. Upgrading the CLI alone does not change an existing pack's source tags;
explicit custom packs retain their configured sources. See the
[CLI default-pack creation and tag selection](https://github.com/radius-project/radius/blob/ffd051cd6d81307f544a2a0c421a8c67e45a1dfd/pkg/cli/recipepack/recipepack.go#L129-L243).
In contrast, `rad init --preview` [when creating an Environment](https://github.com/radius-project/radius/blob/ffd051cd6d81307f544a2a0c421a8c67e45a1dfd/pkg/cli/cmd/radinit/preview/init.go#L232-L237)
[replaces the shared default pack](https://github.com/radius-project/radius/blob/ffd051cd6d81307f544a2a0c421a8c67e45a1dfd/pkg/cli/cmd/radinit/preview/environment.go#L115-L125)
according to that CLI's channel and namespace pins, affecting every consumer's
subsequent deployments. Reusing an existing Environment in init does not take
that creation path. Inspect the stored pack sources after init or an explicit
pack deployment rather than infer them from the current CLI version.
Deploying the checked-in `recipe-packs/kubernetes/default.bicep` directly retains
its authored PostgreSQL source,
`ghcr.io/radius-project/kube-recipes/postgresqldatabases:latest`. Pinning that pack
template does not freeze its floating Recipe tag. Its unrelated stable Recipe
references must not be changed as part of this migration.

An operator must provision a Kubernetes TLS Secret in the database's namespace **before deployment** for `required` and `optional`. By default the Recipes use `<resource-name>-tls` (for example, `postgresql-tls`). They do not generate certificates or fall back to plaintext when a Secret is absent or invalid. `disabled` does not read or mount this Secret, run the certificate initialization container, or apply certificate-only PostgreSQL settings or rollout metadata.

| Recipe parameter | Default | Purpose |
| --- | --- | --- |
| `postgresqlTlsSecretName` | Empty; resolves to `<resource-name>-tls` | Name of an existing operator-managed Secret in the database namespace. An explicit name is shared by all databases using these parameters in that namespace. Omission or an empty string selects a separate name per resource. |
| `postgresqlTlsCertificateRevision` | `1` | Nonempty operator revision. Changing it triggers a pod rollout for every database redeployed with these parameters, not just one database. |

Both certificate parameters are ignored in `disabled` mode, including an empty revision. Certificate-only changes do not change its Pod template. They resume taking effect when TLS is enabled again.

Set these as `parameters` on the PostgreSQL entry in your Recipe Pack. Pack parameters apply to every database consuming that entry; Environment overrides still apply to every consuming database in that Environment, not to a single resource. A revision change can therefore roll out multiple ephemeral databases as they are redeployed. Inventory and back up all affected databases first.

The Secret must contain a PEM `tls.crt` (leaf certificate followed by intermediates, if needed) and an **unencrypted** matching PEM `tls.key`. Use a server-auth certificate from a CA trusted by your clients. Its DNS SAN must cover the returned `host`, `<resource-name>.<namespace>.svc.cluster.local`; a shared Secret's certificate must cover every consuming database hostname. Include additional DNS names if clients use them. Each namespace needs its own Secret even when the configured name is the same. For clusters with a different DNS suffix, customize the existing host-output convention as well as the certificate.

```bash
# server-chain.pem and server.key are issued/managed by the operator's CA.
kubectl create secret tls postgresql-tls --namespace <database-namespace> \
  --cert=server-chain.pem --key=server.key
```

The operator owns issuance, expiry monitoring, renewal, access control, and deletion of this Secret. It is **not** in the PostgreSQL Recipe's cleanup list; a Secret created outside Radius survives deletion of the Radius application. Do not store private keys in ConfigMaps, ordinary application properties, recipe parameters, source control, or logs. The Recipes mount the Secret read-only to a root init container, copy it to a memory-backed volume, set the private key to `0600` owned by `postgres`, and mount that volume read-only in the server. Only public transport rules go into the Recipe-owned ConfigMap. Credentials retain their existing Secret-backed inputs; neither credentials nor TLS material are returned in `result.values` or `result.secrets`.

Operators can also provision the certificate through [`Radius.Security/secrets`](../../Security/secrets/README.md). Its Kubernetes Bicep Recipe maps `kind: 'certificate-pem'` and `tls.crt`/`tls.key` data to a `kubernetes.io/tls` Secret named after the Radius resource in the runtime namespace. For example, in a separate operator-managed deployment targeting the database namespace:

```bicep
extension radius

param environment string

@secure()
param certificatePem string

@secure()
param privateKeyPem string

resource certificate 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'postgresql-tls'
  properties: {
    environment: environment
    kind: 'certificate-pem'
    data: {
      'tls.crt': { value: certificatePem }
      'tls.key': { value: privateKeyPem }
    }
  }
}
```

Supply these secure parameters through a protected deployment mechanism, not literal values in source or command-line arguments. The Secret schema marks the data values sensitive. Complete this deployment before deploying PostgreSQL and select its Kubernetes name with `postgresqlTlsSecretName` (or use the matching default). If both resources are in one template, add `dependsOn: [certificate]` to the PostgreSQL resource; the name parameter alone does not establish ordering. This retains operator-managed issuance; it does not generate certificates. Unlike an externally created Secret, the Bicep Secret Recipe registers the Secret for Radius cleanup: keep its owning resource alive while databases consume it. Prefer separate operator-owned infrastructure when the certificate must outlive an application. PostgreSQL currently takes a Kubernetes name, not a Radius Secret ID, and creates no implicit dependency or lifecycle link to that resource. A first-class TLS Secret reference would require a separate resource-schema and Recipe contract change.

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

**These Recipes do not provision durable data volumes. Recreating a pod can destroy the database.** Take a logical backup with `pg_dump`, and use `pg_dumpall` for roles and other cluster globals where needed. Verify restoration before upgrading a Recipe, changing policy, rotating certificates, or restarting pods in production. Arrange durable storage in a customized Recipe before relying on this deployment for persistent data; this fix does not redesign storage.

The server uses a startup copy of the certificate, so updating the Secret alone does not rotate the active certificate. Replace its data without recording private keys in a last-applied annotation (use your secret manager or `kubectl create secret tls ... --dry-run=client -o json | kubectl replace -f -` for an existing Secret). For a single database, after backup and restore verification, prefer `kubectl rollout restart deployment/<resource-name> --namespace <database-namespace>` over changing a shared revision. For a coordinated rollout, change `postgresqlTlsCertificateRevision` in the Recipe Pack or Environment override, deploy that configuration, then redeploy each affected application; every consuming database redeployed with that revision will restart and may lose its data. Wait for each rollout and repeat `verify-full`. If the Secret is shared, all consumers need a planned restart to load its replacement. When rotating the CA, distribute a trust bundle containing both CAs before rolling out the new server certificate.

Changing `tls` changes the selected HBA file and pod template. A single Recipe-owned ConfigMap contains all three policies, so transitions neither depend on ConfigMap-update propagation nor leave behind policy-specific ConfigMaps. Moving to `disabled` removes TLS initialization, volumes, mounts, settings, and revision metadata; moving back requires the external certificate again. Always inspect the applied workload and its TCP behavior: source-level omission is not proof that a deployment engine removed old fields. Terraform uses `Recreate`. Bicep uses `RollingUpdate` with `maxSurge: 0` and `maxUnavailable: 1`: it avoids a surge replica and permits downtime for the single database replica. This retains the existing strategy type because Radius's Bicep Kubernetes apply cannot clear defaulted `rollingUpdate` fields when switching an existing Deployment to `Recreate`, even with an explicit null. Kubernetes can retain terminating Pods during their grace period; zero surge is not a guarantee that every old process has exited before the replacement starts.

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

The suite starts with `disabled` and no TLS Secret, checks authenticated plaintext and rejection of wrong passwords and TLS-forcing clients, then provisions an operator-managed TLS Secret from its short-lived test CA for the secure modes. It probes omitted, explicit `required`, and `optional`, repeated deployments, transitions in both directions, applied TLS field removal/restoration, external Secret identity/data preservation, and certificate rotation. It checks `pg_stat_ssl` over TCP with bounded connection/query timeouts, verifies `verify-full`, matches plaintext failures to the HBA transport rejection rather than unrelated errors, checks the schema default and `CONNECTION_POSTGRESQL_TLS`, preserves the output contract, and checks Bicep initialization SQL and private-key permissions. Test keys stay in a protected temporary directory and a Kubernetes Secret and are removed on exit. Do not run these destructive rollout tests against an existing database. Record Radius CLI/runtime versions, schema version, recipe artifact digest, Kubernetes/node versions, and the resolved `postgres:16-alpine` image digest when reproducing a failure.

The first Bicep deployment delays initialization long enough for a separate observer to require an actual socket-ready, TCP-unavailable, Pod-NotReady window. It then requires the initialization-complete marker and final TCP readiness. Missing the window fails the test rather than counting as proof. Run `bash Data/postgreSqlDatabases/test/assert-readiness-test.sh` for the observer's positive and negative regression cases. Terraform's identical TCP probe is checked by its mock-provider tests and live rollouts; its Recipe does not support `initSql`.

The template's `applicationName` parameter matches the CLI application and cleanup target. Cleanup explicitly deletes the contributed resources and their `Radius.Core/applications` resource, then removes any legacy `Applications.Core/applications` created by the CLI. `rad app delete` alone targets the legacy type and is insufficient. The fallback sweep supports both `radapp.io/application` and `app` labels with the generated application name, and deletes the named probe/certificate fixtures; it never sweeps the entire namespace. Fixture deletion waits up to 60 seconds so the next run does not race a terminating probe Pod. Run `bash Data/postgreSqlDatabases/test/test-tls-runner.sh` for cluster-free regression checks of parameter flags, application ownership, and cleanup on success and failure. CI runs these checks before deployment tests.

## Migrating Kubernetes consumers

The Kubernetes Recipes no longer return the user-supplied `password` or derived `connectionString` through `result.secrets`. Existing consumers of those managed secret keys must explicitly provide the password to the consuming Container. Author a `Radius.Security/secrets` resource with the same password passed to the database, then either connect the Container directly to that Secret for generated `CONNECTION_<CONNECTION-NAME>_<KEY>` variables or bind the key to the required variable with `valueFrom.secretKeyRef`, as shown in [`test/app.bicep`](test/app.bicep). This change does not silently create a replacement `connectionString`; applications that require one must compose it from the database connection values and the referenced password.
