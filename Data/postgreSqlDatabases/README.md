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

Because `tls` defaults to `required`, configure your PostgreSQL client for TLS and trust the server's certificate authority (CA). Both Kubernetes Recipes enable TLS for every policy and reject plaintext TCP connections when `tls` is omitted or `required`. With `optional`, both TLS and password-authenticated plaintext connections work. A platform engineer can still pin the Azure server's transport policy to `ON` or `OFF`; the connection variable reports the application's request. See [PostgreSQL transport policy](../../recipe-packs/azure-aks/README.md#postgresql-transport-policy) for Azure precedence and public-network restrictions.

Use `optional` only when the server is not publicly reachable. Non-TLS connections can expose administrator credentials and query traffic in transit. Private reachability does not encrypt traffic, so TLS remains preferred; keep it required with the Azure pack as written.

## Kubernetes TLS

Before deploying either Kubernetes Recipe, the operator must create a TLS Secret named `<resource-name>-tls` in the Radius Environment's Kubernetes namespace. This prerequisite applies even to `tls: 'optional'`: optional permits plaintext but does not disable TLS. The Recipes do not generate certificates or manage this Secret's lifecycle.

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

Keep `ca.key` offline and protect/delete local private-key files appropriately. The CA private key is never uploaded to Kubernetes. The server Secret is mounted read-only; each server startup copies its key into a memory-backed volume owned by `postgres` with mode `0600`. Certificate errors stop the server rather than falling back to plaintext. Missing material identifies the expected Secret in the container logs.

Verify readiness after deployment rather than relying solely on `rad deploy`: the current Bicep Recipe runtime can report success before the PostgreSQL Pod is ready, including when certificates prevent startup.

```bash
kubectl rollout status deployment/"$database" --namespace "$namespace" --timeout=180s
```

### Client trust

Encryption alone does not establish server identity. `sslmode=require` requests TLS; use `sslmode=verify-full` with the trusted root CA to validate both the certificate chain and hostname. From a client that can resolve and reach the Service:

```bash
psql "host=$database.$namespace.svc.cluster.local port=5432 dbname=appdb user=radadmin sslmode=verify-full sslrootcert=/path/to/ca.crt"
```

Supply the password through a password prompt or protected credential mechanism, not a logged connection string. `CONNECTION_POSTGRESQL_TLS` describes transport policy; it neither configures a client nor distributes a CA. For Node.js `pg`, use verified TLS with the public CA, or supported `PGSSLMODE=verify-full` and `NODE_EXTRA_CA_CERTS` settings in the client process. Do not disable certificate verification.

### Updates and data protection

**Back up and plan to restore data before upgrading, changing policy, or restarting the Deployment.** These Recipes do not provision durable database volumes; a replacement Pod starts with an empty database. Bicep's `initSql` runs again on an empty database and is not a substitute for a backup.

Changing `tls` changes the Pod template and triggers a rollout. The dedicated authentication file is configured on every startup, not just initial database creation. Wait for rollout completion before relying on the new policy; old Pods can temporarily serve the previous policy.

The operator is responsible for certificate expiration and rotation. Update the same Secret and explicitly restart the Deployment to load the new certificate/key; there is no automatic reload:

```bash
kubectl create secret tls "$database-tls" --namespace "$namespace" \
  --cert=server.crt --key=server.key --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/"$database" --namespace "$namespace"
kubectl rollout status deployment/"$database" --namespace "$namespace"
```

Distribute a new CA to clients before rotating to a different issuer, and restart clients that load CA certificates only at startup. Deleting the Radius application does not delete the operator's TLS Secret or client CA. Remove these explicitly only when no consumers need them.

Existing plaintext clients must adopt TLS before deploying these updated Recipes with required/default policy. A source merge alone changes no running server: publish the Bicep artifact with `rad bicep publish` or package/publish the Terraform module, update the Environment's Recipe Pack to the new artifact/version, then redeploy the application. Publish the corresponding compatible sample configuration and migration instructions before rolling out the new artifacts to tutorial users.

## Migrating Kubernetes consumers

The Kubernetes Recipes no longer return the user-supplied `password` or derived `connectionString` through `result.secrets`. Existing consumers of those managed secret keys must explicitly provide the password to the consuming Container. Author a `Radius.Security/secrets` resource with the same password passed to the database, then either connect the Container directly to that Secret for generated `CONNECTION_<CONNECTION-NAME>_<KEY>` variables or bind the key to the required variable with `valueFrom.secretKeyRef`, as shown in [`test/app.bicep`](test/app.bicep). This change does not silently create a replacement `connectionString`; applications that require one must compose it from the database connection values and the referenced password.
