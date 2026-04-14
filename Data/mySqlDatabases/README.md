# Radius.Data/mySqlDatabases

## Overview

The **Radius.Data/mySqlDatabases** resource type represents a MySQL database. It allows developers to create and easily connect to a MySQL database as part of their Radius applications.

Developer documentation is embedded in the resource type definition YAML file, and it is accessible via the `rad resource-type show Radius.Data/mySqlDatabases` command.

## Recipes

A list of available Recipes for this resource type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Recipe parameters | Pre-requisites |
|---|---|---|---|---|
| Kubernetes | Bicep | kubernetes-mysql.bicep | Alpha | |
| AWS | Terraform | main.tf | Alpha | VPC ID, Subnet IDs|

## Recipe Input Properties

Properties for the **Radius.Data/mySqlDatabases** resource type are provided via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.database`(string, optional): The name of the database. Defaults to `mysql_db` if not provided.
- `context.properties.secretName`(string, required): Name of the secret containing the database credentials.
- `context.properties.version`(string, optional): The major MySQL server version in the X.Y format. Defaults to the version `8.4` if not provided.

## Recipe Output Properties

The **Radius.Data/mySqlDatabases** resource type expects the following output properties to be set in the Results object in the Recipe:

- `context.properties.host` (string): The hostname used to connect to the database.
- `context.properties.port` (integer): The port number used to connect to the database.
- `context.properties.database` (string): The name of the database.
