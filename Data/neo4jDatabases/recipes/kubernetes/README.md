# Kubernetes Recipe - Neo4j (Alpha)

This Alpha recipe deploys Neo4j to Kubernetes as an `apps/StatefulSet` with a `ReadWriteOnce` PersistentVolumeClaim and a `ClusterIP` Service exposing the Bolt port (7687). It is suitable for local development and evaluation.

Authentication is enabled via parameters. The recipe accepts a username and password and returns these in the outputs so that the corresponding resource properties can be populated in Radius.

Outputs:

- `values.host`: Internal DNS name of the Service
- `values.port`: Bolt port (7687)
- `values.username`: Username provided to the recipe
- `values.database`: Database name used by the deployment
- `secrets.password`: Password provided to the recipe

## Usage

This recipe is intended to be registered to a Radius Environment and mapped to `Radius.Data/neo4jDatabases@2025-09-11-preview`.

When a developer defines a `neo4jDatabases` resource, Radius will invoke this recipe and populate the resource outputs.

### Parameters

- `database` (string, default: resource name): Database name to configure.
- `user` (string, default: `neo4j`): Username to provision.
- `password` (secure string, default: `uniqueString(context.resource.id)`): Password to provision.
- `tag` (string, default: `community`): Tag for the `neo4j` container image.

### Notes

- This reference recipe enables persistence via a 10Gi PVC and uses a single replica StatefulSet.
- For production use, consider customizing storage class, resource requests/limits, authentication hardening, backup/restore, and service exposure.
