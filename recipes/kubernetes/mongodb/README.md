# MongoDB Kubernetes Recipe (Terraform)

This recipe provisions a MongoDB instance on Kubernetes using Terraform. It is implemented as a **Radius.Data/mongoDatabases** resource type and can be used in Bicep or Terraform-based applications.

---

## Overview

The `mongoDatabases` Resource Type provisions a MongoDB database instance on Kubernetes with optional persistence, resource configuration, and admin credentials.  
It supports creating the database service, StatefulSet, PVCs (if persistence is enabled), and secrets for credentials.

---

## Recipes

| Platform    | IaC Language | Recipe Name           | Stage |
|------------|-------------|---------------------|-------|
| Kubernetes | Terraform    | kubernetes-mongodb/main.tf | Alpha |

---

## Recipe Input Properties

| Variable           | Type    | Default      | Description                                  |
|-------------------|--------|-------------|----------------------------------------------|
| `name`             | string | required    | MongoDB instance name                        |
| `version`          | string | 6.0         | MongoDB version                              |
| `replicas`         | int    | 1           | Number of replicas                           |
| `storage_size`     | string | 10Gi        | PVC size                                     |
| `storage_class`    | string | standard    | Kubernetes storage class                     |
| `username`         | string | admin       | Admin username                               |
| `password`         | string | required    | Admin password                               |
| `persistence`      | bool   | true        | Enable persistence (creates PVC)            |
| `backup_enabled`   | bool   | false       | Enable backups                               |
| `backup_schedule`  | string | ""          | Cron schedule for backups                    |
| `resources`        | object | {}          | CPU/memory requests and limits               |

> **Note:** For CI or ephemeral testing, set `persistence=false` to avoid PVC-related delays in Kind clusters.

---

## Recipe Output Properties

| Property                 | Description                                          |
|--------------------------|------------------------------------------------------|
| `values.host`            | MongoDB service host (read-only)                    |
| `values.port`            | MongoDB service port (read-only)                    |
| `values.username`        | Admin username (read-only)                          |
| `secrets.password`       | Admin password (sensitive, read-only)              |
| `resources`              | UCP resource IDs for Service and StatefulSet        |

---

## Recipe Description

This Terraform recipe creates:

1. A Kubernetes **Secret** for MongoDB credentials.
2. An optional **PersistentVolumeClaim** if `persistence=true`.
3. A **ClusterIP Service** for MongoDB.
4. A **StatefulSet** running the specified MongoDB version, replicas, and resources.
5. Optional dynamic volume mounts and PVCs.
6. Outputs exposing connection info and secrets for downstream usage.

---

## Usage Instructions

### Manual Testing

1. Apply Terraform:
   ```bash
   terraform init
   terraform apply \
        -var="name=mydb" \
        -var="password=MySecretPass123" \
        -auto-approve
   ```

2. Check pod status:
   ```bash
   kubectl get pods
   # Ensure test-mongodb-0 is READY=1/1
   ```

3. Connect to MongoDB:
   ```bash
   kubectl run mongo-client --rm -it --image=mongo -- \
        mongo "mongodb://$(kubectl get svc mydb-svc -o jsonpath='{.spec.clusterIP}'):27017" \
        -u admin -p MySecretPass123
   ```

4. Verify database operations.

5. Clean up (optional):
   ```bash
   terraform destroy -var="name=mydb" -var="password=MySecretPass123" -auto-approve
   ```

---

## CI / GitHub Actions Testing

This recipe is automatically tested in GitHub Actions for pull requests and branch pushes.

- A temporary Kind cluster is created.
- Terraform applies the recipe with `persistence=false` for fast ephemeral testing.
- The workflow waits for MongoDB pods to become ready.
- Terraform destroys the resources and deletes the Kind cluster after the test.

Workflow file: `.github/workflows/test-mongodb-recipe.yml`

Example ephemeral test run:
```bash
terraform apply -var="name=test-mongodb" -var="password=MySecretPass123" -var="persistence=false" -auto-approve
kubectl get pods
terraform destroy -var="name=test-mongodb" -var="password=MySecretPass123" -var="persistence=false" -auto-approve
```

> Make sure the MongoDB pod shows `READY=1/1` before connecting.

---

## References

- Radius MongoDB Resource Schema: https://docs.radapp.io/reference/resource-schema/databases/mongodb/
- Example Kubernetes Recipe: https://github.com/radius-project/recipes/blob/main/local-dev/mongodatabases.bicep

