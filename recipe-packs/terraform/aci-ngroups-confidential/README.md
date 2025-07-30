# Azure Container Instance NGroups with Confidential Computing - Terraform Configuration

This Terraform configuration converts the ARM template for Azure Container Instance NGroups with Confidential Computing capabilities to Terraform format. This demonstrates the use of confidential computing features with elastic container scaling.

## Architecture Overview

This configuration deploys:

1. **Container Group Profile** with Confidential Computing SKU
2. **NGroups** for elastic scaling of confidential container instances
3. **Confidential Compute Environment** with CCE (Confidential Computing Enclave) policy support

## Prerequisites

- Terraform >= 0.14
- Azure CLI installed and authenticated
- An existing Azure Resource Group
- Azure subscription with access to Confidential Computing features
- Sufficient Azure permissions to create Container Instance resources

## Resources Created

### Confidential Computing Resources
- **Container Group Profile** (`azurerm_resource_group_template_deployment`) with Confidential SKU
- **NGroups** (`azurerm_resource_group_template_deployment`) for elastic scaling
- **CCE Policy** configuration for confidential computing

## Usage

### 1. Setup Variables

Copy the example variables file:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your specific values:
```hcl
resource_group_name = "your-resource-group-name"
desired_count      = 1  # Start with 1 for confidential computing
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

### Confidential Computing Features

- **SKU**: Confidential (specialized for secure enclaves)
- **CCE Policy**: Configurable Confidential Computing Enclave policy
- **Secure Execution**: Containers run in hardware-protected environments
- **Memory Encryption**: Runtime memory encryption
- **Attestation**: Support for remote attestation of the secure environment

### Container Configuration

- **Desired Count**: 1 instance (default, suitable for confidential workloads)
- **Container Image**: ACI Hello World (configurable)
- **Networking**: Public IP addresses (configurable to Private)
- **Auto-scaling**: Managed by NGroups
- **Resource Allocation**: 1 CPU, 1GB RAM (optimized for confidential computing)

### Security Features

- **Hardware-level Security**: Intel SGX or AMD SEV-based protection
- **Encrypted Memory**: Runtime memory encryption
- **Secure Boot**: Verified boot process
- **Isolation**: Strong isolation between containers and host

## Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `resource_group_name` | Resource Group name | - | ✅ |
| `api_version` | Container Instance API version | `2024-09-01-preview` | ❌ |
| `container_group_profile_name` | Profile name | `cgp_1` | ❌ |
| `ngroups_name` | NGroups name | `ngroup_confidential_basic` | ❌ |
| `desired_count` | Desired container count | `1` | ❌ |
| `prefix_cg` | Container naming prefix | `cg-confidential-` | ❌ |
| `container_image` | Container image | ACI Hello World | ❌ |
| `tags` | Resource tags | `{}` | ❌ |

See `variables.tf` for complete variable list.

## Outputs

Key outputs include:
- Container Group Profile ID
- NGroups ID
- Resource Group name
- ARM deployment names

## Important Notes

### Preview Features
- **Confidential Computing** is a preview feature
- **Container Group Profiles** and **NGroups** are preview features
- These resources use ARM template deployments within Terraform
- Future versions may support native Terraform resources

### Confidential Computing Considerations
- Limited to specific Azure regions with confidential computing support
- Requires specialized VM SKUs (DCsv2, DCsv3, etc.)
- May have different pricing compared to standard container instances
- Performance characteristics may differ from standard containers

### Dependencies
- Confidential computing hardware availability in target region
- Proper Azure subscription permissions for confidential computing
- Compatible container images (some images may need modification)

### Security and Compliance
- Ideal for processing sensitive data
- Supports regulatory compliance requirements
- Provides hardware-level data protection
- Enables secure multi-party computation scenarios

## Troubleshooting

### Common Issues

1. **Region Availability**: Ensure confidential computing is available in your region
2. **Subscription Limits**: Check quota limits for confidential computing resources
3. **Container Compatibility**: Verify container images work with confidential computing
4. **CCE Policy**: Ensure CCE policy is properly configured if using custom policies

### Monitoring

Monitor the deployment through:
- Azure Portal for resource status
- Container Instance logs for application health
- Azure Monitor for confidential computing metrics
- Attestation logs for security verification

## Cost Considerations

Confidential computing resources typically have:
- **Premium Pricing**: Higher cost than standard container instances
- **Specialized Hardware**: Limited availability may affect pricing
- **Per-second Billing**: Based on confidential computing resources
- **Regional Variations**: Pricing may vary by region

## Clean Up

To destroy all resources:
```bash
terraform destroy
```

**Note**: This will delete all confidential computing resources.

## Security Best Practices

### CCE Policy Management
- Use specific CCE policies for production workloads
- Regularly update and validate policies
- Implement proper key management for encrypted data

### Container Security
- Use verified and signed container images
- Implement proper access controls
- Monitor for security events and attestation failures

### Network Security
- Consider using Private IP addresses for production
- Implement proper network segmentation
- Use Azure Private Link where applicable

## Migration Path

When native Terraform support becomes available:
1. Replace ARM template deployments with native resources
2. Update variable references
3. Test the migration in a development environment
4. Validate confidential computing functionality

## Performance Considerations

### Confidential Computing Performance
- **Startup Time**: May be longer than standard containers
- **Memory Overhead**: Additional memory used for security features
- **CPU Performance**: Slight overhead for encryption/decryption
- **Network Latency**: Potential impact from security processing

### Scaling Behavior
- **Conservative Scaling**: Start with lower desired counts
- **Monitoring**: Close monitoring of performance metrics
- **Resource Allocation**: Adequate CPU/memory for security overhead

## Use Cases

### Ideal Scenarios
- **Sensitive Data Processing**: Financial, healthcare, personal data
- **Regulatory Compliance**: GDPR, HIPAA, SOX requirements
- **Multi-party Computation**: Secure collaboration between organizations
- **Edge Computing**: Secure processing at edge locations

### Example Applications
- **Data Analytics**: Secure analysis of sensitive datasets
- **AI/ML Workloads**: Confidential machine learning training
- **Database Processing**: Secure database operations
- **API Services**: Secure API endpoints for sensitive operations

## Support

This configuration is based on the ARM template `ACI-NGroups-Confidential.yaml` and provides confidential computing capabilities while maintaining Terraform workflow benefits.
