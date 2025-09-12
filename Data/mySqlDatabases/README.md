# Radius.Data/mySqlDatabases

## Overview

The **Radius.Data/mySqlDatabases** resource type represents a MySQL database. It allows developers to create and easily connect to a MySQL database as part of their Radius applications.

Developer documentation is embedded in the resource type definition YAML file, and it is accessible via the `rad resource-type show Radius.Data/mySqlDatabases` command.

## Recipes

A list of available Recipes for this resource type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes-mySql.bicep | Alpha |

## Recipe Input Properties

Properties for the **Radius.Data/mySqlDatabases** resource type are provided via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.database`(string, optional): The name of the database to create/use.
- `context.properties.user`(string, optional): The username to use to connect to the database.
- `context.properties.tag`(string, optional): The MySQL server version as a container tag.
- `context.properties.memoryRequest`(string, optional): Memory request for the mysql deployment.
- `context.properties.memoryLimit`(string, optional): Memory limit for the mysql deployment.

## Recipe Output Properties

The **Radius.Data/mySqlDatabases** resource type expects the following output properties to be set in the Results object in the Recipe:

- `context.properties.host` (string): The hostname used to connect to the MySQL server.
- `context.properties.port` (integer): The port number used to connect to the MySQL server.
- `context.properties.database` (string): Database name to select on connection.
- `context.properties.user` (string): The username for connecting to the database.
- `context.properties.password` (string): The password for connecting to the database.
- `context.properties.root_password` (string): The password for the MySQL server root user.
