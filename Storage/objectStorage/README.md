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

## Naming constraints

`containerName` is used verbatim as a cloud resource name, so from API version
`2026-09-01-preview` it carries format constraints. Radius validates it when the resource is
submitted, which means a bad value is rejected before a Recipe runs and before a billable storage
account exists. API version `2025-08-01-preview` is unconstrained and unchanged.

| Property | Accepted format |
| --- | --- |
| `containerName` | 3-63 characters of lowercase letters, digits and single hyphens. Must start and end with a letter or a digit, and may not contain two hyphens in a row. |

This is the portable subset shared by Azure blob containers and S3 buckets. S3 imposes rules that
cannot be expressed here and are not checked: bucket names may not look like an IP address, may
not use certain reserved prefixes and suffixes, and must be globally unique. A name that satisfies
the format above may therefore still be rejected by S3.

The Azure system containers `$root` and `$logs` need no separate note; `$` is not an accepted
character, so they are already excluded.

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Storage/objectStorage` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/bicep-recipepack.bicep`](../../recipe-packs/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.32.1` |

## Using the resource type

Add an `objectStorage` resource to your application and connect a container to it. Radius injects the store's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_STORAGE_ENDPOINT`, `CONNECTION_STORAGE_ACCOUNTNAME`, and `CONNECTION_STORAGE_CONTAINERNAME`). The `connectionString` and `accountKey` secrets are not injected — bind them from the managed `Radius.Security/secrets` resource with a container `secretKeyRef` using `store.properties.secrets.name`. See [`test/app.bicep`](test/app.bicep) for a complete example.
