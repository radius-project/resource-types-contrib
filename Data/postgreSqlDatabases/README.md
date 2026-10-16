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
| `tls` | string (`required`, `optional`, `disabled`) | Optional | Defaults to `required` (TLS only). Kubernetes `optional` supports TLS and plaintext; `disabled` is an explicit plaintext-only opt-out without certificates. Azure rejects `disabled`. See the certificate and migration requirements below. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `5432`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/postgreSqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | [TLS-validating wrapper](recipes/azure/bicep/azure-postgresql.bicep) around the pinned Azure Verified Module |
| Kubernetes | [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep) | `ghcr.io/radius-project/kube-recipes/postgresqldatabases` |

## Using the resource type

Add a `postgreSqlDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_POSTGRESQL_HOST`, `CONNECTION_POSTGRESQL_PORT`, `CONNECTION_POSTGRESQL_DATABASE`, and `CONNECTION_POSTGRESQL_TLS`). See [`test/app.bicep`](test/app.bicep) for a complete example.

Because `tls` defaults to `required`, configure your PostgreSQL client for TLS and trusted server identity. Both Kubernetes recipes enable SSL for `required` and `optional`, and enforce the policy through ordered `pg_hba.conf` rules at every container startup. TCP connections, including IPv4/IPv6 loopback, retain SCRAM password authentication; local Unix-socket trust is preserved for entrypoint initialization.

The Azure wrapper rejects `disabled` before invoking the existing AVM. For `required` and `optional`, a platform engineer can still pin Azure's transport policy to `ON` or `OFF`; the connection variable reports the application's request. See [PostgreSQL transport policy](../../recipe-packs/azure-aks/README.md#postgresql-transport-policy) for precedence and public-network restrictions.

Use `optional` only when the server is not publicly reachable. Non-TLS connections can expose administrator credentials and query traffic in transit. Private reachability does not encrypt traffic, so TLS remains preferred; keep it required with the Azure pack as written.

## Kubernetes TLS prerequisites

| Policy | TLS TCP | Plaintext TCP | Operator certificate |
| --- | --- | --- | --- |
| Omitted / `required` | Accepted | Rejected | Required |
| `optional` | Accepted | Accepted | Required |
| `disabled` | Rejected (`ssl=off`) | Accepted | Not used |

Before deploying either TLS-enabled mode, create a `kubernetes.io/tls` Secret in the database's **actual runtime namespace**, `context.runtime.kubernetes.namespace`. This can differ from the Environment namespace. The default Secret name is `<resource-name>-tls`.

```bash
kubectl create secret tls postgresql-tls -n <runtime-namespace> \
  --cert=server-chain.pem --key=server-key.pem
```

Use a CA-issued server certificate with a DNS SAN matching the returned host, `<resource-name>.<runtime-namespace>.svc.cluster.local`. `tls.crt` contains the PEM leaf certificate followed by intermediates; `tls.key` contains its matching unencrypted PEM private key. The operator owns issuance, renewal, trust distribution, and eventual Secret deletion. These recipes do not generate production certificates.

Both recipes accept `postgresqlTlsSecretName` (default `<resource-name>-tls`) and `postgresqlTlsCertificateRevision` (default empty). Configure these in Recipe Pack or Environment recipe parameters. A shared Secret must cover every intended server hostname. An environment-level revision affects each TLS-enabled database when its application is subsequently redeployed; it does not immediately restart every database.

Only the two certificate keys are mounted, root-readable and read-only (`0400`). Startup copies them into a memory-backed pod volume, gives them to the image's `postgres` user, and restricts the private key to `0600` before the standard entrypoint drops privileges. Keys are not placed in ConfigMaps, connection properties, recipe results, or Terraform data sources. The external Secret is not included in Radius cleanup. Restrict Kubernetes Secret access and enable encryption at rest.

`disabled` neither mounts nor reads certificate material and ignores certificate revision changes. It is never a fallback for certificate problems. Use it only as an intentional, private-network/development opt-out; it exposes database traffic to interception.

### Client trust and verified identity

Encryption alone does not authenticate the server. `sslmode=require` is not a substitute for hostname verification. Distribute the issuing CA to clients through a trusted channel, never the private key, and use the returned DNS hostname:

```bash
# Supply PGPASSWORD through the client's secret mechanism, not command history.
PGSSLROOTCERT=/trusted/postgresql-ca.pem PGSSLMODE=verify-full \
  psql "host=postgresql.<runtime-namespace>.svc.cluster.local port=5432 dbname=appdb user=radadmin"
```

For Node.js `pg`, use the same hostname and `ssl: { ca: fs.readFileSync('/trusted/postgresql-ca.pem'), rejectUnauthorized: true }`. Do not disable certificate verification to accommodate a private CA.

### Rollout, rotation, and failure handling

**Back up and verify restore before any rollout.** These recipes have no explicit durable database volume. Replacing a pod may discard its data and rerun Bicep `initSql`. This change does not add persistence or Terraform `initSql` support.

Policy changes update the pod template. Certificate updates alone do not update the running server's private copy. After protecting data, replace the Secret and either change the revision parameter and redeploy the intended applications, or restart only the database:

```bash
kubectl rollout restart deployment/<resource-name> -n <runtime-namespace>
kubectl rollout status deployment/<resource-name> -n <runtime-namespace> --timeout=180s
```

Every startup recopies certificate material and regenerates HBA rules, including container restarts where the memory-backed volume already exists. When changing CAs, distribute the new trust before the rollout. Reapplying an unchanged deployment does not generate or renew certificates.

Missing Secrets/keys cause mount errors; empty or malformed certificates prevent PostgreSQL startup rather than enabling plaintext. The Bicep recipe checks Secret existence before updating a TLS-enabled Deployment. Inspect pod events and PostgreSQL startup errors to correct failures.

**Bicep readiness limitation:** [#131](https://github.com/radius-project/resource-types-contrib/issues/131) means raw `rad deploy` success only confirms manifest application, not a successful rollout. Neither an additional Kubernetes Job nor the experimental Bicep `waitUntil` decorator supplies a reliable gate on the tested runtime. Always wait for the current rollout and run TCP probes. An unsuccessful rolling update may leave the old pod serving the **previous policy**; do not treat the requested policy as active until verification succeeds. Terraform waits for deployment rollout. The test runner checks both implementations explicitly and exits unsuccessfully on rollout/probe failure.

## Adopting the change

Existing applications that omit `tls` now need an operator TLS Secret before adopting the updated Kubernetes recipe. Existing plaintext clients must migrate to TLS, or deliberately select `optional`/`disabled` in a restricted environment. Provision the Secret before transitioning from `disabled` to a TLS-enabled mode.

Publish the changed Bicep artifact with `rad bicep publish` (or `make build-bicep-recipe` for the local registry); package and publish Terraform with `make build-terraform-recipe`. Update the registered recipe/pack source to the new artifact version or digest, configure certificates, then redeploy the application. A source merge alone does not update running servers. Treat mutable `latest` references as an upgrade requiring the same preparation.

The Azure pack's new wrapper is published by the existing Bicep publication workflow to `ghcr.io/radius-project/azure-recipes/postgresqldatabases`. Publish a compatible wrapper tag and ensure anonymous pull access before releasing/adopting the pack. It retains the pack's existing AVM input names, configuration overrides, and `fqdn` mapping. Deploy the new schema and compatible pack/recipe artifacts together: older Azure packs may interpret `disabled` as `ON`, and older Kubernetes recipes remain plaintext. That legacy behavior is not a supported fallback. Rolling back to the old Kubernetes recipe restores its insecure transport behavior.

## Kubernetes transport tests

Build/register the matching recipe in an isolated Environment, then run:

```bash
make test-recipe RECIPE_PATH=Data/postgreSqlDatabases/recipes/kubernetes/bicep
make test-recipe RECIPE_PATH=Data/postgreSqlDatabases/recipes/kubernetes/terraform
```

Both CI entries exercise certificate-free disabled mode, the omitted default, all explicit policies, transitions in both directions, repeat deployment, pod replacement, container restart, and certificate rotation. A short-lived test CA exercises `verify-full`, wrong-CA rejection, and hostname rejection. Probes check the actual backend's `pg_stat_ssl`, exact transport-rejection errors, connection-property projection, existing output contracts, and Bicep initialization SQL. Retries and timeouts are bounded. Fixture Secrets are not allowed to overwrite existing operator Secrets and are cleaned up with the test application.

The Bicep CI job also runs `bash Data/postgreSqlDatabases/test/assert-startup-failures.sh` against the real PostgreSQL image to verify both startup scripts reject missing/malformed certificates, and `bash Data/postgreSqlDatabases/test/assert-azure-tls-guard.sh` against the isolated Radius environment to verify Azure rejects `disabled` with no transport override and with both `ON` and `OFF` overrides. The latter requires no Azure credentials and must fail specifically on the `tlsPolicy` allowed-values constraint, not on provider configuration.

## Migrating Kubernetes consumers

The Kubernetes Recipes no longer return the user-supplied `password` or derived `connectionString` through `result.secrets`. Existing consumers of those managed secret keys must explicitly provide the password to the consuming Container. Author a `Radius.Security/secrets` resource with the same password passed to the database, then either connect the Container directly to that Secret for generated `CONNECTION_<CONNECTION-NAME>_<KEY>` variables or bind the key to the required variable with `valueFrom.secretKeyRef`, as shown in [`test/app.bicep`](test/app.bicep). This change does not silently create a replacement `connectionString`; applications that require one must compose it from the database connection values and the referenced password.
