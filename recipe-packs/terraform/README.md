# Terraform Configurations for Azure Container Instance NGroups

This directory contains Terraform configurations for deploying Azure Container Instance NGroups with different networking setups.

## Directory Structure

```
terraform/
├── README.md                    # This file
├── ngroups-basic/              # Basic NGroups configuration
│   ├── main.tf                 # Basic setup with public networking
│   ├── variables.tf            # Variable definitions
│   ├── outputs.tf              # Output values
│   ├── terraform.tfvars.example # Example variable values
│   └── README.md               # Detailed documentation
└── ngroups-gateway/            # Advanced NGroups with Application Gateway
    ├── main.tf                 # Full networking stack with App Gateway
    ├── variables.tf            # Variable definitions
    ├── outputs.tf              # Output values
    ├── terraform.tfvars.example # Example variable values
    └── README.md               # Detailed documentation
```

## Configurations

### 1. NGroups Basic (`ngroups-basic/`)

**Purpose**: Simple deployment of Container Group Profile and NGroups with public networking.

**Use Cases**:
- Development and testing
- Simple container workloads
- Quick proof-of-concept deployments

**Resources Created**:
- Container Group Profile with public IP
- NGroups with basic elastic scaling

**Based on ARM Template**: `ACI-Ngroups-basic.yaml`

### 2. NGroups Gateway (`ngroups-gateway/`)

**Purpose**: Production-ready deployment with Application Gateway, Virtual Network, and comprehensive networking.

**Use Cases**:
- Production workloads
- Load-balanced container applications
- Secure private networking
- High-availability setups

**Resources Created**:
- Virtual Network with dedicated subnets
- Network Security Group with security rules
- Public IP and Application Gateway
- Container Group Profile with private networking
- NGroups with Application Gateway integration

**Based on ARM Template**: `ACI-NGroups-Gateway.yaml`

## Quick Start

### Basic Configuration

```bash
cd ngroups-basic
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your resource group name
terraform init
terraform plan
terraform apply
```

### Gateway Configuration

```bash
cd ngroups-gateway
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your resource group name and desired settings
terraform init
terraform plan
terraform apply
```

## Prerequisites

- **Terraform** >= 0.14
- **Azure CLI** installed and authenticated
- **Azure Subscription** with appropriate permissions
- **Existing Resource Group** for deployment

## Authentication

Ensure you're authenticated with Azure:

```bash
az login
az account set --subscription "your-subscription-id"
```

## Important Notes

### Preview Features
Both configurations use Azure Container Instance preview features:
- **Container Group Profiles**
- **NGroups**

These are deployed using ARM templates within Terraform until native support is available.

### Resource Dependencies
- Basic: Minimal dependencies, quick deployment
- Gateway: Complex networking dependencies, longer deployment time

### Cost Considerations
- Basic: Lower cost, minimal networking resources
- Gateway: Higher cost due to Application Gateway and networking components

## Migration Between Configurations

You can migrate from basic to gateway configuration:

1. Export container configuration from basic setup
2. Deploy gateway configuration
3. Update DNS/routing to point to new Application Gateway
4. Destroy basic setup

## Support and Troubleshooting

- Check individual README files in each directory for detailed troubleshooting
- Review Azure Portal for resource deployment status
- Use `terraform plan` to preview changes before applying

## Contributing

When adding new configurations:
1. Create a new directory under `terraform/`
2. Include all standard Terraform files (main.tf, variables.tf, outputs.tf)
3. Provide comprehensive README documentation
4. Include example tfvars file
5. Update this main README with the new configuration details
