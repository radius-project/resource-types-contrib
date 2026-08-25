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
| Azure | [`recipe-packs/azure/bicep-recipepack.bicep`](../../recipe-packs/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.32.1` |

## Using the resource type

Add an `objectStorage` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `storage` injects ordinary `CONNECTION_STORAGE_ENDPOINT`, `CONNECTION_STORAGE_ACCOUNTNAME`, and `CONNECTION_STORAGE_CONTAINERNAME` values plus secret-backed `CONNECTION_STORAGE_CONNECTIONSTRING` and `CONNECTION_STORAGE_ACCOUNTKEY`. No second managed-Secret connection is needed on compatible Kubernetes versions. For custom or backward-compatible Kubernetes configuration, `store.properties.secrets.name` remains available as the `secretName` for an explicitly authored `secretKeyRef`. See [`test/app.bicep`](test/app.bicep) for the gradual-adoption example.
