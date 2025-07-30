# Azure Container Instance NGroups with Load Balancer - Terraform Configuration

This Terraform configuration converts the ARM template for Azure Container Instance NGroups with Load Balancer integration to Terraform format. This is an advanced setup that includes comprehensive networking infrastructure, load balancing, NAT gateway, and DDoS protection.

## Architecture Overview

This configuration deploys a complete infrastructure stack:

1. **Virtual Network** with dedicated subnet and Container Instance delegation
2. **Network Security Group** with security rules for HTTP traffic (ports 80-331)
3. **DDoS Protection Plan** for enhanced security
4. **NAT Gateway** for outbound internet connectivity
5. **Public IP addresses** for inbound and outbound traffic
6. **Standard Load Balancer** with health probes and load balancing rules
7. **Container Group Profile** with private networking
8. **NGroups** with Load Balancer integration for elastic scaling

## Prerequisites

- Terraform >= 0.14
- Azure CLI installed and authenticated
- An existing Azure Resource Group
- Sufficient Azure permissions to create networking, load balancing, and container resources

## Resources Created

### Networking Infrastructure
- **Virtual Network** (`azurerm_virtual_network`) with DDoS protection
- **Subnet** with Container Instance delegation (`azurerm_subnet`)
- **Network Security Group** with HTTP security rules (`azurerm_network_security_group`)
- **DDoS Protection Plan** (`azurerm_network_ddos_protection_plan`)

### Public IP and NAT
- **Inbound Public IP** for Load Balancer (`azurerm_public_ip`)
- **Outbound Public IP** for NAT Gateway (`azurerm_public_ip`)
- **NAT Gateway** for outbound connectivity (`azurerm_nat_gateway`)

### Load Balancing
- **Standard Load Balancer** (`azurerm_lb`)
- **Backend Address Pool** (`azurerm_lb_backend_address_pool`)
- **Health Probe** (`azurerm_lb_probe`)
- **Load Balancing Rule** (`azurerm_lb_rule`)
- **Inbound NAT Rule** for port range 81-331 (`azurerm_lb_nat_rule`)

### Container Instance Resources
- **Container Group Profile** (via ARM template deployment)
- **NGroups** with Load Balancer integration (via ARM template deployment)

## Usage

### 1. Setup Variables

Copy the example variables file:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your specific values:
```hcl
resource_group_name = "your-resource-group-name"
desired_count      = 50  # Adjust based on your needs
domain_name_label  = "your-unique-domain-label"
```

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Plan the Deployment

```bash
terraform plan
```

### 4. Apply the Configuration

```bash
terraform apply
```

## Configuration Details

### Network Configuration

- **VNet Address Space**: `172.19.0.0/16` (default)
- **Subnet Address Space**: `172.19.1.0/24` (default)
- **Container Instance Delegation**: Enabled on subnet
- **NAT Gateway**: Provides outbound internet access
- **DDoS Protection**: Standard protection enabled

### Security Configuration

The Network Security Group includes:
- **AllowHTTPInbound**: Allows internet traffic on ports 80-331
- **Priority**: 100
- **Protocol**: All protocols (*)

### Load Balancer Configuration

- **SKU**: Standard Load Balancer
- **Frontend**: Public IP with configurable domain name
- **Backend Pool**: Integrated with NGroups container instances
- **Health Probe**: TCP probe on port 80
- **Load Balancing Rule**: HTTP traffic (port 80)
- **NAT Rule**: Port range 81-331 for direct access

### Container Configuration

- **Desired Count**: 100 instances (default, configurable)
- **Maintain Desired Count**: Enabled
- **Container Image**: ACI Hello World (configurable)
- **Networking**: Private IP addresses within VNet
- **Auto-scaling**: Managed by NGroups
- **Load Balancer Integration**: Automatic backend pool membership

## Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `resource_group_name` | Resource Group name | - | ✅ |
| `api_version` | Container Instance API version | `2024-09-01-preview` | ❌ |
| `desired_count` | Desired container count | `100` | ❌ |
| `vnet_address_prefix` | VNet address space | `172.19.0.0/16` | ❌ |
| `subnet_address_prefix` | Subnet CIDR | `172.19.1.0/24` | ❌ |
| `domain_name_label` | Public IP domain label | `ngroupsdemo` | ❌ |
| `container_image` | Container image | ACI Hello World | ❌ |
| `maintain_desired_count` | Maintain desired count | `true` | ❌ |

See `variables.tf` for complete variable list.

## Outputs

Key outputs include:
- Virtual Network and subnet IDs
- Load Balancer ID and frontend IP
- Public IP addresses and FQDN
- Backend address pool and health probe IDs
- NAT Gateway and DDoS protection plan IDs
- Container Group Profile and NGroups deployment IDs

## Important Notes

### Preview Features
- **Container Group Profiles** and **NGroups** are preview features
- These resources use ARM template deployments within Terraform
- Future versions may support native Terraform resources

### Dependencies
- The configuration properly handles complex resource dependencies
- Load Balancer is created before NGroups deployment
- NAT Gateway and DDoS protection are configured before VNet

### Scaling and Performance
- NGroups automatically manages container instance scaling
- Load Balancer distributes traffic across container instances
- Health probes ensure only healthy instances receive traffic
- NAT Gateway provides dedicated outbound connectivity

### Security Considerations
- DDoS protection provides enhanced security
- Network Security Group controls inbound traffic
- Private networking within VNet for container instances
- Outbound traffic routed through NAT Gateway

## Troubleshooting

### Common Issues

1. **Domain Name Label Conflicts**: Ensure unique domain name labels
2. **Address Space Conflicts**: Verify subnet CIDRs don't overlap
3. **Load Balancer Startup**: May take 10-15 minutes to fully provision
4. **Container Health**: Check that containers respond to TCP health probes on port 80

### Monitoring

Monitor the deployment through:
- Azure Portal for resource status
- Load Balancer metrics for traffic distribution
- Container Instance logs for application health
- NAT Gateway metrics for outbound connectivity

## Cost Considerations

This configuration includes several billable resources:
- **Standard Load Balancer**: Hourly charges + data processing
- **NAT Gateway**: Hourly charges + data processing
- **DDoS Protection Plan**: Monthly subscription fee
- **Public IP addresses**: Hourly charges for static IPs
- **Container Instances**: Per-second billing based on resources

## Clean Up

To destroy all resources:
```bash
terraform destroy
```

**Note**: This will delete all networking infrastructure and container resources.

## Migration Path

When native Terraform support becomes available for Container Group Profiles and NGroups:
1. Replace ARM template deployments with native resources
2. Update variable references
3. Test the migration in a development environment

## Performance and Scaling

### Load Balancer Features
- **Session Persistence**: Configurable via load balancing rules
- **Health Monitoring**: TCP health probes with configurable thresholds
- **Traffic Distribution**: Default round-robin distribution
- **Connection Draining**: Graceful handling of unhealthy instances

### NGroups Auto-scaling
- **Desired Count Management**: Automatically maintains specified instance count
- **Zone Distribution**: Optional availability zone distribution
- **Container Lifecycle**: Automatic container restart and replacement

## Support

This configuration is based on the ARM template `ACI-NGroups-LoadBalancer.yaml` and maintains feature parity while providing Terraform workflow benefits.
