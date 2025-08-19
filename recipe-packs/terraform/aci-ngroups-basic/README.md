# Azure Container Instance NGroups Terraform Configuration

This Terraform configuration converts the ARM template for Azure Container Instance NGroups to Terraform format.

## Prerequisites

- Terraform >= 0.14
- Azure CLI installed and authenticated
- An existing Azure Resource Group

## Resources Created

1. **Container Group Profile** - Defines the template for container groups
2. **NGroups** - Manages elastic scaling of container groups

## Usage

1. Copy the example variables file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your specific values:
   ```hcl
   resource_group_name = "your-resource-group-name"
   ```

3. Initialize Terraform:
   ```bash
   terraform init
   ```

4. Plan the deployment:
   ```bash
   terraform plan
   ```

5. Apply the configuration:
   ```bash
   terraform apply
   ```

## Important Notes

- **Preview Features**: Both Container Group Profiles and NGroups are preview features in Azure
- **ARM Template Deployment**: Since these resources are not yet fully supported in the AzureRM provider, this configuration uses `azurerm_resource_group_template_deployment` to deploy ARM templates within Terraform
- **Dependencies**: The NGroups resource depends on the Container Group Profile being created first

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `resource_group_name` | Name of the Azure Resource Group | (required) |
| `location` | Azure region | Resource group location |
| `cg_profile_name` | Container Group Profile name | `cgp_1` |
| `ngroups_name` | NGroups resource name | `ngroup_lin1_basic` |
| `desired_count` | Desired container count | `1` |
| `prefix_cg` | Container group prefix | `cg-lin1-basic-` |
| `container_image` | Container image to deploy | ACI Hello World |
| `container_port` | Container port | `80` |
| `memory_gb` | Memory allocation in GB | `1.0` |
| `cpu_cores` | CPU allocation | `1.0` |
| `tags` | Resource tags | Default tags |

## Outputs

- `resource_group_name` - Name of the resource group
- `resource_group_location` - Location of the resource group
- `subscription_id` - Azure subscription ID
- `container_group_profile_name` - Name of the container group profile
- `ngroups_name` - Name of the NGroups resource
- Deployment IDs for both resources

## Clean Up

To destroy the resources:
```bash
terraform destroy
```
