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
| `connectionString` | string | Read only | The storage account connection string. Set from the Recipe module's `primaryConnectionString` output. |
| `accountName` | string | Read only | The Azure Storage account name. Set from the Recipe module's `name` output. |
| `accountKey` | string | Read only | The Azure Storage account access key. Set from the Recipe module's `primaryAccessKey` output. |

The schema is platform-neutral: the same developer-facing properties can be backed by Azure Blob Storage, AWS S3, or a Kubernetes object-store recipe by changing only the platform recipe's module source, parameters, and outputs.

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipepack/`](../../recipepack). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Storage/objectStorage` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipepack/azure/bicep-recipepack.bicep`](../../recipepack/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.32.1` |

## Using the resource type

Add an `objectStorage` resource to your application and connect a container to it. Radius injects the store's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_STORAGE_ENDPOINT`, `CONNECTION_STORAGE_ACCOUNTNAME`, and `CONNECTION_STORAGE_CONTAINERNAME`). See [`test/app.bicep`](test/app.bicep) for a complete example.
