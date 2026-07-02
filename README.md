# Radius Resource Types and Recipes Contributions

## Overview

This repository contains the Resource Type definitions and Recipes for deploying those Resource Types via [Radius](https://radapp.io/). It includes:

- **Resource Type Definitions**: Schema definitions for Resource Types available for developers to use while defining their application
- **Recipes**: Platform-specific Infrastructure as Code (Bicep or Terraform) used to deploy the associated Resource Type
- **Recipe Packs**: Bundled collections of Recipes, grouped by compute platform, that provide the recipe definitions for every Resource Type in the repository

## What are Resource Types?

Resource Types are abstractions that define the schema for resources in the Radius. They provide a consistent interface that enables developers to define their application's resources that is separated from the platform engineer's implementation.

## What are Recipes?

Recipes define how the Resource Types are provisioned on different compute platforms and cloud environments. A Recipe provides the implementation of the interface defined in the Resource Type definition. Today Radius supports Bicep and Terraform Recipe drivers, so a Recipe can be a Bicep template or a Terraform configuration. It can also point to well-maintained community modules like the [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) or the [AWS Terraform modules](https://registry.terraform.io/namespaces/terraform-aws-modules). To learn more about Recipes, please visit [Recipes overview](https://docs.radapp.io/guides/recipes/overview/) in the Radius documentation.

## What are Recipe Packs?

Recipe Packs are collections of Recipes grouped together to provide a complete solution for a specific compute platform. Platform engineers add an entire collection of Recipes to a Radius Environment by referencing a single Recipe Pack, rather than registering Recipes one Resource Type at a time.

## Repository Structure

```text
resource-types-contrib/
├── <resource_type_namespace>/          # Namespace excluding Radius; the namespace Radius.Data is in the Data directory
│   └── <resource_type_name>/           # e.g., redisCaches/
│       ├── README.md                   # Documentation for platform engineers
│       ├── <resource_type_name>.yaml   # e.g., redisCaches.yaml
│       └── test/
│               └── app.bicep           # Developer-facing test application
└── recipepack/                         # Recipe packs cover recipe definitions for all types in the repo
    ├── azure/                           # Azure recipe packs (recipes for all types + environment)
    │       ├── README.md                    # Documentation for the Azure recipe packs
    │       ├── bicep-recipepack.bicep       # Recipe pack wiring Bicep recipes
    │       └── terraform-recipepack.bicep   # Recipe pack wiring Terraform recipes
    ├── aws/                             # AWS recipe packs
    │       ├── README.md
    │       └── terraform-recipepack.bicep   # AWS recipes use Terraform modules
    ├── kubernetes/                      # Kubernetes recipe packs
    │       ├── README.md
    │       ├── bicep-recipepack.bicep
    │       └── terraform-recipepack.bicep
    └── default-kubernetes/              # Default recipe pack 
            ├── README.md
            ├── bicep-recipepack.bicep
            └── terraform-recipepack.bicep
```

## Discovering and using Resource Types and Recipe Packs

Developers can discover the Resource Types in this repository and use them in a Radius application, and platform engineers can use the Recipe Packs to configure how those types are provisioned in an Environment. For a step-by-step guide on discovering, registering, and using Resource Types and Recipe Packs, see [Discovering and Using Resource Types and Recipe Packs](docs/using-resource-types.md).

Every Resource Type in this repository can be registered via `rad resource-type create`. A subset is also registered as defaults in Radius, so they are available out of the box without any user action. The default resource types are paired with the default Recipe Pack under `recipepack/default-kubernetes/`, a zero-config, in-cluster Kubernetes pack that ships out of the box, so they can be deployed without any cloud provider configuration. The list of default resource types is managed in the [Radius repository](https://github.com/radius-project/radius) via [`deploy/manifest/defaults.yaml`](https://github.com/radius-project/radius/blob/main/deploy/manifest/defaults.yaml).

## Contributing

Community members can contribute new Resource Types, Recipes, and Recipe Packs to this repository. We welcome contributions in many forms: submitting issues, writing code, participating in discussions, reviewing pull requests. For information on contributing, follow these guides:

- [Contributing Resource Types and Radius Recipes](docs/contributing/contributing-resource-types-recipes.md): This guide provides an overview of how to write a Resource Type and its Recipes in a Recipe Pack.
- [Submitting Issues](docs/contributing/contributing-issues.md): This guide provides an overview of how to submit issues related to Resource Types or Recipes.

**Thanks to everyone who has contributed!**

<a href="https://github.com/radius-project/resource-types-contrib/graphs/contributors">
  <img src="https://contributors-img.web.app/image?repo=radius-project/resource-types-contrib" />
</a>

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Code of Conduct

Please refer to our [Radius Community Code of Conduct](https://github.com/radius-project/radius/blob/main/CODE_OF_CONDUCT.md)
