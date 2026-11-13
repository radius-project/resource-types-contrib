# Radius.Storage/objectStorage

## Overview

The **Radius.Storage/objectStorage** resource type represents an object storage container (an S3-style bucket / Azure Blob container / GCS bucket). It allows developers to create and easily connect to object storage as part of their Radius applications. Unlike database types, no secret is required from the developer — Azure Storage generates its own account keys, so the platform's Recipe provisions the account without any injected credentials.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Storage/objectStorage` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `containerName` | string | Optional | The object container (blob container / S3 bucket) name to create inside the storage account. Defaults to `data`. |
| `endpoint` | string | Read only | The object storage endpoint. Set from the Recipe module's `primaryBlobEndpoint` output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.connectionString`, `secrets.accountKey` are the secret keys (delivered via that managed secret, never stored on the resource). |
| `accountName` | string | Read only | The Azure Storage account name. Set from the Recipe module's `name` output. |

The schema is platform-neutral: the same developer-facing properties can be backed by Azure Blob Storage, AWS S3, or a Kubernetes object-store recipe by changing only the platform recipe's module source, parameters, and outputs.

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Storage/objectStorage` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.32.1` |

## Using the resource type

Add an `objectStorage` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `storage` injects ordinary `CONNECTION_STORAGE_ENDPOINT`, `CONNECTION_STORAGE_ACCOUNTNAME`, and `CONNECTION_STORAGE_CONTAINERNAME` values plus secret-backed `CONNECTION_STORAGE_CONNECTIONSTRING` and `CONNECTION_STORAGE_ACCOUNTKEY`. No second managed-Secret connection is needed on compatible Kubernetes versions. For custom or backward-compatible Kubernetes configuration, `store.properties.secrets.name` remains available as the `secretName` for an explicitly authored `secretKeyRef`. See [`test/app.bicep`](test/app.bicep) for the gradual-adoption example.

## Kubernetes development recipes

The [Bicep recipe](recipes/kubernetes/bicep/kubernetes-objectstorage.bicep) and
[Terraform recipe](recipes/kubernetes/terraform/main.tf) run Azurite **3.35.0**
with the Azure Blob API. They do not provide S3 or GCS APIs. Only the Blob service
is started; Queue and Table services are not exposed. Use an Azure Blob SDK or
client which supports an explicit HTTP Blob endpoint and Azurite's supported
[API versions and operations](https://github.com/Azure/Azurite/tree/v3.35.0#support-matrix).
The startup probe uses API version `2021-12-02`. Newer unsupported API versions
fail rather than bypassing Azurite's version check.

Both recipes create the developer's `containerName` (default `data`) through an
authenticated request before the Pod becomes ready. The name must have 3 to 63
lowercase letters, digits, or hyphens; it must start and end with a letter or
digit and must not contain consecutive hyphens. An invalid name or failed
authentication keeps the Pod unready. Existing containers are kept on redeploy.
Changing `containerName` creates a new container but does not delete the old one.

### Platform parameters

| Parameter | Variant | Default | Description |
| --- | --- | --- | --- |
| `objectStorageCredentialsSecretName` | Bicep only | `<resource-name>-blob-credentials` | Name of an existing Secret in the runtime namespace. Its `accountKey` entry holds the base64 encoding of 64 random bytes. |
| `objectStorageStorageSize` | Both | `1Gi` | PVC capacity. The cluster needs a volume provisioner or a matching pre-provisioned volume. |
| `objectStorageStorageClassName` | Both | Empty | Use the cluster default StorageClass. Set a name to use a specific class. |

**Never put an account key in Recipe Pack or developer recipe parameters.**
Radius stores these parameters without encryption or redaction; a Bicep
`@secure()` parameter would not protect their stored values.

Before deploying Bicep, create the named Secret directly in the runtime namespace
through a trusted platform setup process. Generate its key with a cryptographic
random generator, keep it stable across redeployments, and do not use the public
Azurite key. The `accountKey` value is an 88-character base64 string with no
trailing newline. When authoring a Secret manifest, Kubernetes `data.accountKey`
is the base64 encoding of that string (two encoding layers); `stringData.accountKey`
is the string itself. The deployment identity needs permission to read the Secret.
Only the Secret name is passed through recipe parameters. Missing Secrets or
`accountKey` entries fail the deployment; no public-key fallback is used.
The recipe creates a separate managed `accounts` Secret for the Pod and does not
delete or overwrite the operator's source Secret.

Terraform has no credential parameter. It generates 64 random bytes with the
`hashicorp/random` provider and keeps them in the recipe's Terraform state.
Repeated applies preserve the key. State loss or explicit resource replacement
generates a different key; keep state storage encrypted and access restricted.
The Terraform `result` is sensitive, but state still contains the secret values.
Do not pass a generated key back into a Recipe Pack parameter.

Use different source Secrets for stores that need separate access. Reusing the
same key grants access to every Azurite instance that uses it. Both variants
return credentials in the required `result.secrets` contract; do not print or
retain raw recipe deployment outputs. No random Bicep default is used: Radius
does not pass previous resolved defaults to each recipe deployment, so
`newGuid()` would not preserve a key.

The Bicep source Secret is still a **zero-configuration default-pack integration
requirement**: platform setup must create it before the recipe can run.

### Output and storage contract

`result.values` contains `accountName: radiusstorage` and
`endpoint: http://<resource-name>-blob.<namespace>.svc.cluster.local:10000/radiusstorage`.
`result.secrets` contains `accountKey` and
`connectionString: DefaultEndpointsProtocol=http;AccountName=radiusstorage;AccountKey=<key>;BlobEndpoint=<endpoint>;`.
The developer property `containerName` remains on the Radius resource. It is not
part of the account endpoint. Use the returned connection string rather than
`UseDevelopmentStorage=true`, which would select localhost and the public key.

The server loads the same custom key from a Kubernetes Secret. The connection
string includes a path-style Blob endpoint; `--disableProductStyleUrl` prevents
Azurite from treating the Kubernetes DNS name as an account name. The Service
is `ClusterIP` only. It has no public endpoint, TLS, or network policy. HTTP traffic
is not encrypted. Restrict access to trusted development workloads.

A single Deployment uses `Recreate` and a `ReadWriteOnce` PVC mounted at `/data`.
The PVC keeps Blob data and metadata across Pod restarts and recipe updates.
For Bicep key rotation, update the source Secret and redeploy the Radius resource;
the source Secret is read at deployment time, not watched. The recipe then updates
the managed Secret and restarts the Pod. Key changes invalidate previous client
credentials; refresh all consumers. There is no high availability, backup, production durability
guarantee, Azure identity integration, or production performance support.
Use Azure Blob Storage for production workloads.

`result.resources` tracks the managed Secret, PVC, Deployment, and Service for Radius
cleanup. Deleting the Radius resource deletes the claim and can delete all data,
subject to the StorageClass reclaim policy. A `Retain` policy requires manual
volume cleanup. PVC size decreases and StorageClass changes are not supported;
create a new resource and migrate data instead. The external Bicep credentials
Secret is operator-owned and is not included in cleanup IDs.

### Publication and validation

The Bicep source is
`Storage/objectStorage/recipes/kubernetes/bicep/kubernetes-objectstorage.bicep`.
The central publication workflow must register this source before a production
GHCR recipe URI can be used. The Terraform source is the complete directory
`Storage/objectStorage/recipes/kubernetes/terraform`; the local module-server
publisher produces `objectStorage-kubernetes.zip`. These recipes do not themselves
change the default pack or the central publication workflow.

Run local contract checks from the repository root with Radius Bicep, Node.js,
Python 3, Bash, and Terraform 1.7 or later:

```bash
node --test .github/scripts/tests/test-objectstorage.js
bash .github/scripts/tests/test-objectstorage-secret.sh
terraform -chdir=Storage/objectStorage/recipes/kubernetes/terraform init -backend=false -input=false
terraform -chdir=Storage/objectStorage/recipes/kubernetes/terraform validate
terraform -chdir=Storage/objectStorage/recipes/kubernetes/terraform test
```

The Node suite compiles the existing Secret reference and checks Bicep snapshots
and probe parity with Terraform. Snapshots substitute only the external Secret
read; they evaluate base64 decoding and resource properties with a fixture key.
The compiled template checks cover the output contract, but do not prove a live
Kubernetes Secret GET. The shell
suite checks direct Secret setup, name-only app parameters, ownership-safe
cleanup, and failure handling without a cluster. Terraform tests use mocked
Kubernetes objects but the real random provider to check key persistence across
repeated applies. To also
test real container creation, Blob upload/download, invalid credentials, and
data retention after an Azurite restart, install Azurite 3.35.0 in a temporary
directory and set `AZURITE_CLI` to its `node_modules/azurite/dist/src/blob/main.js`.
Then run the same Node command. The service test binds localhost port `10000`;
that port must be free. It removes its temporary data and stops its own process.
Without `AZURITE_CLI`, only this service test is skipped.

For end-to-end Radius validation, use a dedicated test cluster with a default
StorageClass. Publish the Bicep recipe with `rad bicep publish` and publish the
Terraform directory with `make build-terraform-recipe`. Register each variant in
turn in a Recipe Pack without any secret-valued parameters, attach the pack to the
test Environment, then run `make test-recipe` with this variant's `RECIPE_PATH`.
For Bicep, the runner dispatches to `test/test-kubernetes.sh <workspace> <environment>`.
This helper creates a unique resource name and its matching source Secret by
piping a generated manifest directly to `kubectl create -f -`. It passes only
`objectStorageResourceName` to `test/kubernetes/app.bicep`, then deletes the source
Secret only after confirmed creation. Use the default Secret-name parameter for
this test. The helper does not change the Environment namespace or Recipe Pack.
See the [testing guide](../../docs/contributing/testing-resource-types-recipes.md).
The dedicated Kubernetes app checks provisioning. The shared `test/app.bicep`
also checks consumer secret wiring. Neither performs Blob operations; the
localhost Azurite test checks those operations.
