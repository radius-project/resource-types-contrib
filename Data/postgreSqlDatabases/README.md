# Radius.Data/mySqlDatabases

## Overview

The **Radius.Data/postgreSqlDatabases** resource type represents a PostgreSQL database. It allows developers to create and easily connect to a PostgreSQL database as part of their Radius applications.

Developer documentation is embedded in the resource type definition YAML file, and it is accessible via the `rad resource-type show Radius.Data/postgreSqlDatabases` command.

## Recipes

A list of available Recipes for this resource type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes-postgresql.bicep | Alpha |

## Recipe Input Properties

Properties for the **Radius.Data/postgreSqlDatabases** resource type are provided via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.size`(string, optional): The size of the database. Defaults to `S` if not provided.

## Recipe Output Properties

The **Radius.Data/postgreSqlDatabases** resource type expects the following output properties to be set in the Results object in the Recipe:

- `context.properties.host` (string): The hostname used to connect to the database.
- `context.properties.port` (integer): The port number used to connect to the database.
- `context.properties.database` (string): The name of the database.
- `context.properties.username` (string): The username for connecting to the database.
- `context.properties.password` (string): The password for connecting to the database.
