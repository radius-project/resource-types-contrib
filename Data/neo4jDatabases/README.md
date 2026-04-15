# Radius.Data/neo4jDatabases

## Overview

The `Radius.Data/neo4jDatabases` Resource Type represents a Neo4j graph database. It is intended for application-centric usage and can also be provisioned as a shared resource in a Radius Environment.

Developer documentation is embedded in the resource type definition YAML file, and it is accessible via the `rad resource-type show Radius.Data/neo4jDatabases` command.

## Recipes

| Platform   | IaC       | Recipe Name                         | Stage |
|------------|-----------|--------------------------------------|-------|
| Kubernetes | Bicep     | `kubernetes-neo4j.bicep`             | Alpha |

## Recipe Input Properties

Properties for the **Radius.Data/neo4jDatabases** resource type are provided via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.secretName` (string, required): Name of the secret containing the database credentials. The secret must have `USERNAME` and `PASSWORD` keys.

## Recipe Output Properties

The **Radius.Data/neo4jDatabases** resource type expects the following output properties to be set in the Results object in the Recipe:

- `values.host` (string): Internal DNS name of the Service.
- `values.port` (integer): Bolt port (typically `7687`).
- `values.database` (string): The name of the database.

## Notes

- The reference Kubernetes recipe is designed for development and evaluation. For production use, consider adding resource limits, authentication hardening, and backup/restore to your own recipe variant.
- Credentials are managed via a `Radius.Security/secrets` resource and passed to the recipe via the `secretName` property. See the `test/app.bicep` for an example.
