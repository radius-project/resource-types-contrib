# Radius Resource Types and Recipes Contributions

## Overview

This repository contains the Resource Type definitions and Recipes for deploying those Resource Types via [Radius](https://radapp.io/). It includes:

- **Resource Type Defintions**: Schema definitions for Resource Types available for developers to use while defining their application
- **Recipes**: Platform-specific Infrastructure as Code used to deploy the associated Resource Type
- **Recipe Packs**: Bundled collections of Recipes organized compute platform or deployment scenario (coming soon)

## What are Resource Types?

Resource Types are abstractions that define the schema for resources in the Radius. They provide a consistent interface that enables developers to define their application's resources that is separated from the platform engineer's implementation.

## What are Recipes?

Recipes define how the Resource Types are provisioned on different compute platforms and cloud environments. Recipes provide the implementation of the interface defined in the Resource Type definition. To learn more about Recipes, please visit [Recipes overview](https://docs.radapp.io/guides/recipes/overview/) in the Radius documentation.

## What are Recipe Packs?

Recipe Packs are collections of Recipes that are grouped together to provide a complete solution for a specific compute platform or deployment scenario. Recipe Packs enable platform engineers to easily add an entire collection of Recipes to a Radius Environment. The Recipe Packs feature is currently under development.

## Repository Structure

```text
resource-types-contrib/
├── <resource_type_namespace>/          # Namespace excluding Radius; the namespace Radius.Data is in the Data directory
│   └── <resource_type_name>/           # e.g., redisCaches/
│       ├── README.md                   # Documentation for platform engineers
│       ├── <resource_type_name>.yaml/  # e.g., redisCaches.yaml
│       └── recipes/                    # Recipes for this type
│               ├── <platform-service>  # e.g., aws-memorydb/
│               │       ├── bicep
│               │       │       ├── aws-memorydb.bicep
│               │       │       └── aws-memorydb.params
│               │       └── terraform
│               │               ├── main.tf
│               │               └── var.tf
│               ├── <platform-service>  # e.g., azure-cache/
│               │       ├── bicep
│               │       │       ├── azure-cache.bicep
│               │       │       └── azure-cache.params
│               │       └── terraform
│               │               ├── main.tf
│               │               └── var.tf
│               └── <platform-service>  # e.g., kubernetes/
│                       ├── bicep
│                       │       ├── kubernetes-redis.bicep
│                       │       └── kubernetes-redis.params
│                       └── terraform
│                               ├── main.tf
│                               └── var.tf
└── recipe-packs/
    ├── azure-aci/                      # Azure Container Instances Recipes
    ├── kubernetes/                     # Kubernetes platform Recipes
    └── ...
```

## Contributing

Community members can contribute new Resource Types, Recipes, and Recipe Packs to this repository. We welcome contributions in many forms: submitting issues, writing code, participating in discussions, reviewing pull requests. For information on contributing, follow these guides:

- [Contributing Resource Types and Radius Recipes](docs/contributing/contributing-resource-types-recipes.md): This guide provides an overview of how to write a Resource Type and one or more Recipes.
- Contributing Recipe Packs: Coming soon!
- [Submitting Issues](docs/contributing/contributing-issues.md): This guide provides an overview of how to submit issues related to Resource Types or Recipes.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Code of Conduct

Please refer to our [Radius Community Code of Conduct](https://github.com/radius-project/radius/blob/main/CODE_OF_CONDUCT.md)
