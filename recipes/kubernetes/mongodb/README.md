# MongoDB Kubernetes Recipe (Terraform)

This recipe provisions a MongoDB instance on Kubernetes using Terraform.

## Inputs

- `name` (string, required): MongoDB instance name
- `version` (string, default: 6.0): MongoDB version
- `replicas` (int, default: 1): Number of replicas
- `storage_size` (string, default: 10Gi): PVC size
- `storage_class` (string, default: standard): Storage class
- `username` (string, default: admin): Admin username
- `password` (string, required): Admin password
- `persistence` (bool, default: true): Enable persistence
- `backup_enabled` (bool, default: false): Enable backups
- `backup_schedule` (string): Cron schedule for backups
- `resources` (object): CPU/memory requests/limits

## Outputs

- `mongodb_service_name`: Kubernetes service name
- `mongodb_credentials_secret`: Secret containing credentials

## Manual Testing

1. Apply Terraform:
   ```bash
   terraform init
   terraform apply -var="name=mydb" -var="password=MySecretPass123"
   ```

2. Connect to MongoDB:
   ```bash
   kubectl run mongo-client --rm -it --image=mongo -- \
        mongo "mongodb://$(kubectl get svc mydb-svc -o jsonpath='{.spec.clusterIP}'):27017" \
        -u admin -p MySecretPass123
   ```

3. Verify database operations.
