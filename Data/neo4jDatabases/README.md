# Radius.Data/neo4jDatabases

## Overview

The `Radius.Data/neo4jDatabases` Resource Type represents a Neo4j graph database. It is intended for application-centric usage and can also be provisioned as a shared resource in a Radius Environment.

## Recipes

| Platform   | IaC       | Recipe Name                         | Stage |
|------------|-----------|--------------------------------------|-------|
| Kubernetes | Bicep     | `kubernetes-neo4j.bicep`             | Alpha |

## Recipe Input Properties

This Resource Type is in Alpha and does not expose developer-set input properties for the Recipe at this time. In future iterations, additional properties (for example, size and Neo4j-specific configuration) may be introduced.

## Recipe Output Properties

Recipes must populate the following read-only properties on the resource:

- `host` (string): DNS hostname clients use to connect.
- `port` (integer): Bolt port (typically `7687`).
- `username` (string): Username for client connections.
- `password` (string): Password for client connections.

## Notes

- The reference Kubernetes recipe is designed for development and evaluation. For production use, consider adding persistence (PVC), authentication, and backup/restore to your own recipe variant.
