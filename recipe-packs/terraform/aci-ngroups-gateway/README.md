# Azure Container Instance NGroups with Application Gateway - Terraform Configuration

This Terraform configuration converts the ARM template for Azure Container Instance NGroups with Application Gateway to Terraform format. This is a comprehensive setup that includes networking infrastructure, security groups, and application gateway integration.

## Architecture Overview

This configuration deploys:

1. **Virtual Network** with two subnets:
   - ACI Subnet (for container instances)
   - Application Gateway Subnet
2. **Network Security Group** with rules for Application Gateway and HTTP traffic
3. **Public IP** for the Application Gateway
4. **Application Gateway** with health probes and routing rules
5. **Container Group Profile** with private networking
6. **NGroups** with Application Gateway integration for elastic scaling

## Prerequisites

- Terraform >= 0.14
- Azure CLI installed and authenticated
- An existing Azure Resource Group
- Sufficient Azure permissions to create networking and container resources

## Resources Created

### Networking
- **Virtual Network** (`azurerm_virtual_network`)
- **ACI Subnet** with Container Instance delegation (`azurerm_subnet`)
- **Application Gateway Subnet** (`azurerm_subnet`)
- **Network Security Group** with security rules (`azurerm_network_security_group`)
- **Public IP** for Application Gateway (`azurerm_public_ip`)

### Application Gateway
- **Application Gateway** with Standard_v2 SKU (`azurerm_application_gateway`)
- Backend address pool for container instances
- HTTP listener on port 80
- Health probe configuration
- Request routing rules

### Container Instance Resources
- **Container Group Profile** (via ARM template deployment)
- **NGroups** with Application Gateway integration (via ARM template deployment)

## Usage

### 1. Setup Variables

Copy the example variables file:
```bash
cp ngroups-gateway.tfvars.example ngroups-gateway.tfvars
```

Edit `ngroups-gateway.tfvars` with your specific values:
```hcl
resource_group_name = "your-resource-group-name"
desired_count      = 50  # Adjust based on your needs
```

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Plan the Deployment

```bash
terraform plan -var-file="ngroups-gateway.tfvars"
```

### 4. Apply the Configuration

```bash
terraform apply -var-file="ngroups-gateway.tfvars"
```

## Configuration Details

### Network Configuration

- **VNet Address Space**: `172.16.0.0/23` (default)
- **ACI Subnet**: `172.16.0.0/25` (default)
- **App Gateway Subnet**: `172.16.1.0/25` (default)

### Security Rules

The Network Security Group includes:
- Application Gateway V2 probe traffic (ports 65200-65535)
- HTTP traffic on port 80
- Public IP specific access
- Virtual Network internal traffic

### Application Gateway

- **SKU**: Standard_v2 with autoscaling (0-3 instances)
- **Frontend**: Public IP configuration
- **Backend**: Integrated with NGroups container instances
- **Health Probe**: HTTP probe on path "/"

### Container Configuration

- **Desired Count**: 100 instances (default, configurable)
- **Maintain Desired Count**: Enabled
- **Container Image**: ACI Hello World (configurable)
- **Networking**: Private IP addresses within VNet
- **Auto-scaling**: Managed by NGroups

## Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `resource_group_name` | Resource Group name | - | ✅ |
| `api_version` | Container Instance API version | `2024-09-01-preview` | ❌ |
| `desired_count` | Desired container count | `100` | ❌ |
| `vnet_address_prefix` | VNet address space | `172.16.0.0/23` | ❌ |
| `aci_subnet_address_prefix` | ACI subnet CIDR | `172.16.0.0/25` | ❌ |
| `app_gateway_subnet_address_prefix` | App Gateway subnet CIDR | `172.16.1.0/25` | ❌ |
| `container_image` | Container image | ACI Hello World | ❌ |
| `maintain_desired_count` | Maintain desired count | `true` | ❌ |

See `ngroups-gateway-variables.tf` for complete variable list.

## Outputs

Key outputs include:
- Virtual Network and subnet IDs
- Application Gateway ID and public IP
- Backend address pool ID
- Container Group Profile and NGroups deployment IDs
- Network Security Group ID

## Important Notes

### Preview Features
- **Container Group Profiles** and **NGroups** are preview features
- These resources use ARM template deployments within Terraform
- Future versions may support native Terraform resources

### Dependencies
- The configuration properly handles resource dependencies
- Application Gateway is created before NGroups deployment
- Subnets are associated with NSG after creation

### Scaling
- NGroups automatically manages container instance scaling
- Application Gateway distributes traffic across container instances
- Health probes ensure only healthy instances receive traffic

## Troubleshooting

### Common Issues

1. **Subnet Address Conflicts**: Ensure subnet CIDRs don't overlap
2. **Application Gateway Startup**: May take 10-15 minutes to fully provision
3. **Container Health**: Check that containers respond to health probes

### Monitoring

Monitor the deployment through:
- Azure Portal for resource status
- Application Gateway metrics for traffic distribution
- Container Instance logs for application health

## Clean Up

To destroy all resources:
```bash
terraform destroy -var-file="ngroups-gateway.tfvars"
```

**Note**: This will delete all networking infrastructure and container resources.

## Migration Path

When native Terraform support becomes available for Container Group Profiles and NGroups:
1. Replace ARM template deployments with native resources
2. Update variable references
3. Test the migration in a development environment

## Support

This configuration is based on the ARM template `ACI-NGroups-Gateway.yaml` and maintains feature parity while providing Terraform workflow benefits.
