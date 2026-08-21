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
| `tls` | string (`required`, `optional`) | Optional | The requested transport policy for connections to the database server. Defaults to `required`. The Azure Recipe enforces it on the server, which then rejects connections that do not use TLS; set `optional` to have the server also accept connections that do not use TLS. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Read only | The port number used to connect to the database. Set from the Recipe module's output. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mySqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/aks-recipepack.bicep`](../../recipe-packs/azure/aks-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/db-for-my-sql/flexible-server` |
| Kubernetes | [`recipe-packs/kubernetes/default-recipepack.bicep`](../../recipe-packs/kubernetes/default-recipepack.bicep) | `ghcr.io/radius-project/kube-recipes/mysqldatabases` |

This repository also contains an AWS Terraform Recipe under [`recipes/aws/terraform`](recipes/aws/terraform), which is not yet part of a Recipe Pack.

Only the Azure Recipe enforces the `tls` property, which it maps onto the flexible server's `require_secure_transport` parameter. The Kubernetes and AWS Recipes do not enforce it today, so on those platforms the value states the requested transport policy rather than observed server behavior.

## Using the resource type

Add a `mySqlDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_MYSQLDB_HOST`, `CONNECTION_MYSQLDB_PORT`, `CONNECTION_MYSQLDB_DATABASE`, and `CONNECTION_MYSQLDB_TLS`). Because `tls` defaults to `required`, configure your MySQL client for TLS — for example, by passing `ssl: { minVersion: 'TLSv1.2' }` to the Node.js `mysql2` driver. See [`test/app.bicep`](test/app.bicep) for a complete example.
