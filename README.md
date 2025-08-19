# Radius Resource Types and Recipes Contributions

This repository contains the core Radius Resource Types and Recipes for Radius Environments, enabling platform engineers to extend Radius capabilities to their internal developer platforms

## Overview

Radius is a cloud-native application platform that enables developers and the platform engineers that support them to collaborate on delivering and managing cloud-native applications that follow organizational best practices for cost, operations and security, by default. Radius is designed to be extensible across different compute platforms and providers. This repository serves as the central hub for contributions of:

- **Resource Types**: Schema definitions of the Radius core and community-contributed resources
- **Recipes**: Platform-specific deployment templates using Bicep or Terraform
- **Recipe Packs**: Bundled collections of Recipes by compute platform or deployment scenario (coming soon)

## What are Resource Types?

Resource Types are simple abstractions that define the schema for resources in the Radius ecosystem. They provide a consistent interface that enables developers to define, manage and deploy resources in their applications.

## What are Recipes?

Recipes define how the Resource types are provisioned on different compute platforms and cloud environments. Platform engineers or infrastructure operators define Recipes to provision the infrastructure in a secured way following the organization's best practices. To learn more about Recipes, please visit [Recipes overview](https://docs.radapp.io/guides/recipes/overview/) in the Radius documentation.

## What are Recipe Packs?

Recipe Packs are collections of Recipes that are grouped together to provide a complete solution for a specific compute platform or deployment scenario. They allow platform engineers to easily deploy and manage resources across different environments using pre-defined configurations. The Recipe Packs feature is currently under development.

## Repository Structure

```
resource-types-contrib/
├── <category of the resource type>/    #e.g., data/
│   ├── <name of the resource type>/   # e.g., redis/
│   │   ├── README.MD       # Resource type documentation
│   │   ├── `<resourcetype>.yaml`/  # e.g., redis.yaml
│   │   ├── recipes/     # Recipes for this type
│   │   │       ├── <provider1> # e.g., azure-redis/
│   │   │       │       ├── bicep
│   │   │       │       │       ├── azure-rediscache.bicep
│   │   │       │       │       └── azure-rediscache.params
│   │   │       │       └── terraform
│   │   │       │               ├── main.tf
│   │   │       │               └── var.tf
│   │   │       ├── <provider2> # e.g., aws-memorydb/
│   │   │       │       ├── bicep
│   │   │       │       │       ├── aws-memorydb.bicep
│   │   │       │       │       └── aws-memorydb.params
│   │   │       │       └── terraform
│   │   │       │               ├── main.tf
│   │   │       │               └── var.tf
│   │   │       └── <provider3> # e.g., kubernetes/
│   │               ├── bicep
│   │               │       ├── kubernetes-redis.bicep
│   │               │       └── kubernetes-redis.params
│   │               └── terraform
│   │                       ├── main.tf
│   │                       └── var.tf
├── recipe-packs/
│   ├── azure-aci/         # Azure Container Instances Recipes
│   ├── kubernetes/        # Kubernetes platform Recipes
│   └── ...
```

## Contributing

Community members can contribute new Resource Types, Recipes and Recipe packs to this repository. Follow the [Contribution.md](CONTRIBUTING.MD) guidelines for more information.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Code of Conduct

Please refer to our [Radius Community Code of Conduct](https://github.com/radius-project/radius/blob/main/CODE_OF_CONDUCT.md)
