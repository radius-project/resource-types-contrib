# Radius.Data/mySqlDatabases

## Overview

The **Radius.Data/mySqlDatabases** resource type represents a MySQL database. It allows developers to create and easily connect to a MySQL database as part of their Radius applications. The developer provides the administrator `username` and `password` directly on the resource; the `password` property is marked `x-radius-sensitive`, so Radius encrypts it at rest, redacts it on reads, and injects it decrypted only into the platform's Recipe.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/mySqlDatabases` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `username` | string | Required | The administrator username for the MySQL database. Passed to the Recipe as `{{context.resource.properties.username}}`. |
| `password` | string (`x-radius-sensitive`) | Required | The administrator password. Encrypted at rest, redacted on reads, and injected decrypted into the Recipe as `{{context.resource.properties.password}}`. |
| `database` | string | Optional | The name of the database. Defaults to `mysql_db`. |
| `version` | string (`5.7`, `8.0`, `8.4`) | Optional | The major MySQL server version. Defaults to `8.4`. |
| `tls` | string (`required`, `optional`) | Optional | The transport policy enforced for TCP connections by the Kubernetes, AWS RDS, and Azure Recipes. Defaults to `required`, which rejects plaintext. `optional` permits plaintext without disabling TLS; use it only when the server is not publicly reachable. Certificate trust is configured separately. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `3306`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mySqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/aks-recipepack.bicep`](../../recipe-packs/azure/aks-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/db-for-my-sql/flexible-server` |
| Kubernetes | [`recipe-packs/kubernetes/default-recipepack.bicep`](../../recipe-packs/kubernetes/default-recipepack.bicep) | `ghcr.io/radius-project/kube-recipes/mysqldatabases` |

An [AWS RDS Terraform Recipe](recipes/aws/terraform/main.tf) is also available for registration in an AWS-enabled Environment; this repository does not supply an AWS Recipe Pack.

## Using the resource type

Add a `mySqlDatabases` resource to your application and connect a container to
it. Unless `disableDefaultEnvVars` is enabled on the connection, Radius injects
the database's connection properties into the container as environment
variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>`. For example, a
connection named `mysqldb` produces `CONNECTION_MYSQLDB_HOST`,
`CONNECTION_MYSQLDB_PORT`, `CONNECTION_MYSQLDB_DATABASE`, and
`CONNECTION_MYSQLDB_TLS`. Because `tls` defaults to `required`, configure your
MySQL client for TLS and configure its trust in the server certificate.

### Transport enforcement and certificate trust

All three Recipes set MySQL's `require_secure_transport` setting. Omitting
`tls` or setting it to `required` enables enforcement; `optional` disables
enforcement, not TLS support. The Kubernetes Recipe passes a server startup
argument while preserving the image entrypoint. The AWS Recipe sets the RDS
DB parameter group value with an immediate apply method and preserves the
existing character-set parameters. Local Unix sockets count as secure
transport in MySQL; this policy rejects unencrypted **TCP** connections, not
local socket connections.

The Kubernetes Recipe uses the official MySQL image's automatically generated
certificates. Clients do not normally trust their CA, and the generated
server certificate does not match the Kubernetes Service hostname for
`VERIFY_IDENTITY`. For an isolated development/test environment,
`mysql --ssl-mode=REQUIRED --protocol=TCP ...` requires encryption but **does
not authenticate the server's identity**. It is not a substitute for verified
TLS on an untrusted network. Trusting the generated CA alone does not fix the
hostname mismatch.

For authenticated TLS on Kubernetes, use a customized Recipe with a server
certificate valid for the Service hostname and configure clients to trust
its issuing CA. Certificate management is not included in this Recipe.
Generated certificates are tied to the data directory; the current Recipe
does not provide durable storage, so do not rely on their persistence across
pod replacements.

For AWS RDS and Azure, follow the provider's
[RDS certificate guidance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
or [Azure certificate guidance](https://learn.microsoft.com/azure/mysql/flexible-server/security-tls).
Configure the appropriate trusted CA and verify the endpoint hostname
(for example, `--ssl-mode=VERIFY_IDENTITY --ssl-ca=...` in the MySQL CLI).
With `mysql2`, supply the trusted CA in the `ssl` options and retain
certificate verification; setting a minimum TLS version alone does not
establish trust in Kubernetes-generated certificates.

Use `optional` only when the server is not publicly reachable. Non-TLS
connections can expose administrator credentials and query traffic in transit.
Private reachability does not encrypt traffic, so TLS remains preferred.
Keep it required with the Azure pack as written; see
[MySQL transport policy](../../recipe-packs/azure/README.md#mysql-transport-policy)
for public-network restrictions.

### Upgrading existing deployments

Older Kubernetes and AWS Recipes ignored `tls`. With the fixed Recipes,
applications that omit it now reject plaintext TCP clients. Configure clients
for TLS before upgrading; use `optional` only as an explicit choice for a
server that is not publicly reachable.

Updating Kubernetes server arguments triggers a pod rollout. This Recipe has
no explicit persistent data volume: protect existing data before redeploying
and use a customized persistent-storage Recipe for databases that must
survive pod replacement. Reverting the argument does not restore lost data.
RDS applies the transport parameter dynamically without a reboot; verify new
connections after an update.

Deploy a published Bicep recipe artifact or Terraform module containing this
fix, update its Environment registration as needed, and redeploy affected
resources. A source merge alone does not change deployed servers.
Kubernetes `:edge` follows main; `:latest` and version tags change with stable
releases. Older pinned artifacts retain the previous behavior.

This enforcement change covers MySQL only. PostgreSQL on Kubernetes still
needs separate TLS enforcement work, as tracked in [#310](https://github.com/radius-project/resource-types-contrib/issues/310).

### Checking transport enforcement

The MySQL test application exercises omitted, required, and optional policies
through the Kubernetes recipe test runner. It checks successful encrypted
TCP queries, the effective server setting, and plaintext rejection or
acceptance as appropriate. The separate supported-image matrix checks the
same behavior on MySQL 5.7, 8.0, and 8.4 on amd64.

Run `make test-mysql-tls` for the test-runner regression checks and
`bash Data/mySqlDatabases/test/test-image-matrix.sh` for the Docker matrix
from the repository root. Run the normal recipe deployment tests in an
isolated Radius test environment; the runner cleans up its test namespace.

For cloud-free AWS checks, use Terraform 1.11.4 in
`Data/mySqlDatabases/recipes/aws/terraform`:

```bash
terraform init -backend=false -input=false
terraform fmt -check -recursive
terraform validate
set -o pipefail
terraform test -json -verbose | python3 tests/assert-tls-plan.py
```

These mocked plans check the actual RDS parameter group and instance
attachment, including a missing or null `tls` value. They do not prove live
AWS enforcement. In an authorized AWS test environment, verify the effective
parameter and TLS/plaintext TCP behavior after initial deployment and a
policy update.

### Using developer-owned credentials

The Kubernetes Recipe no longer includes its unused developer-provided
`password` and derived `connectionString` entries in `result.secrets`. These
entries were not declared by the resource schema, so applications could not
consume them as managed outputs. Applications that need the password must
author the value in a `Radius.Security/secrets` resource.

With a Kubernetes Container Recipe that supports direct Secret connections,
connect the container to that authored Secret to receive secret-backed
`CONNECTION_<CONNECTION-NAME>_<KEY>` environment variables. For gradual
adoption or environments using an earlier Container Recipe, bind the authored
Secret explicitly with `env.valueFrom.secretKeyRef`, as shown in
[`test/app.bicep`](test/app.bicep). In either case, pass the same
developer-owned password to the database resource and the authored Secret; do
not depend on the MySQL Recipe to copy it into a new managed Secret.
