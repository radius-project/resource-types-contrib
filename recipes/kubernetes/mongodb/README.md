# MongoDB Kubernetes Recipe (Terraform)

This recipe provisions a MongoDB instance on Kubernetes using Terraform.

---

## Inputs

| Variable           | Type   | Default      | Description                        |
|-------------------|--------|-------------|------------------------------------|
| `name`             | string | required    | MongoDB instance name              |
| `version`          | string | 6.0         | MongoDB version                    |
| `replicas`         | int    | 1           | Number of replicas                 |
| `storage_size`     | string | 10Gi        | PVC size                           |
| `storage_class`    | string | standard    | Kubernetes storage class           |
| `username`         | string | admin       | Admin username                     |
| `password`         | string | required    | Admin password                     |
| `persistence`      | bool   | true        | Enable persistence                 |
| `backup_enabled`   | bool   | false       | Enable backups                     |
| `backup_schedule`  | string | ""         | Cron schedule for backups          |
| `resources`        | object | {}          | CPU/memory requests and limits     |

> **Note:** For CI or ephemeral testing, `persistence` should be set to `false` to avoid PVC-related delays in Kind clusters.

---

## Outputs

- `mongodb_service_name`: Kubernetes service name
- `mongodb_credentials_secret`: Secret containing credentials

---

## Manual Testing

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

