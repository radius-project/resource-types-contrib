# Contributing Resource Type Definitions and Recipes to Radius

This guide walks you through the process of creating and contributing Radius Resource Type definitions and Recipes to this repository.

## Prerequisites

Before you begin, ensure you have basic understanding of Radius concepts and the IaC languages you plan to use (Bicep or Terraform). 

 - Familiarize yourself with the [Radius](https://docs.radapp.io) 
 - Familiarize yourself with the [Resource Types](https://docs.radapp.io/tutorials/create-resource-type/) tutorial
 - Familiarize yourself with the [Radius Recipes](https://docs.radapp.io/guides/recipes) concept

## Overview

Contributing a Resource Type and Recipe involves the following:

1. [**Resource Type Schema**](#resource-type-schema): Defines the structure and properties of your Resource Type
2. [**Recipes**](#recipes-for-the-resource-type): Terraform or Bicep templates for deploying the Resource on different platforms
3. [**Documentation**](#document-your-resource-type-and-recipes): Providing clear usage examples and instructions
4. [**Testing**](/resource-types-contrib/contributing-docs/testing-resource-types-recipes.md): Ensuring your Resource Type works as expected in a Radius environment
5. [**Submission**](/resource-types-contrib/contributing-docs/submitting-contribution): Creating a pull request with your changes

## Maturity Levels

Radius Resource Types and Recipes are categorized into the three maturity levels detailed below. Contributions of Resource Types and Recipes may begin at the `Alpha` or `Beta` stage and progress through to the `Stable` phase.

_Stage 1 : Alpha_

    Purpose: Enable community members to contribute resource types and Recipes with minimal barriers
    Audience: Developers/Contributors exploring new technologies or learning Radius
    Requirements:
        - Resource type schema Validation: YAML schema passes validation
        - Single Recipe: At least one working recipe for any cloud provider or platform
        - Basic Documentation: README with usage examples
        - Manual Testing: Evidence of local testing by contributor
        - Maintainer Review: Formal review and approval by Radius maintainers

_Stage 2 : Beta_

    Purpose: Ensure contributions meet production-ready standards with comprehensive testing and documentation
    Audience: Contributors seeking to have their resource types included in official Radius releases
    Requirements:
        - Multi-Platform Support: Recipes for all three platforms ( AWS, Azure, Kubernetes)
        - IAC Support: Recipes for both Bicep and Terraform
        - Automated Testing: Functional tests that validate resource type and Recipes
        - Documentation: Detailed README with Recipe coverage, troubleshooting guides, and best practices
        - Ownership: Designated owner for the resource type and Recipe
        - Maintainer Review: Formal review and approval by Radius maintainers

_Stage 3 : Stable_

    Purpose: Establish Resource types and Recipes as officially supported and maintained by the Radius project
    Audience: Enterprise users doing production deployments and seeking stable, well-tested Resource types and Recipes
    Requirements:
        - Functional tests have 100% coverage and results for Resource type schema and Recipe
        - Integration Testing: Full integration with Radius CI/CD pipeline and release process
        - Documentation: Complete user guides, troubleshooting, and best practices
        - Ownership (Resource type and Kubernetes Recipe): Radius maintainers assume ownership of the resource type schema and Kubernetes Recipe
        - Ownership (cloud Recipes): Contributor designates a committed owner for the cloud platform Recipes (e.g. AWS and/or Azure)
        - SLA Commitment: Defined support level and response time commitments from cloud platform Recipe owners
        - Maintainer Review: Formal review and approval by Radius maintainers
    
## Resource Type Schema

### 1. Choose a Resource Type

Identify the resource type you want to contribute. It could be a database, messaging service, or any other resource that fits within the Radius ecosystem. You can pick from the open issues in this repository or propose a new resource type.

### 2. Create a fork and clone this Repository

Create a fork of the `resource-types-contrib` repository on GitHub, then clone your fork to your local machine:

```bash
git clone https://github.com/<your-username>/resource-types-contrib.git
```

### 3. Create a new Resource Type directory

Create a new directory for your resource type under the appropriate category. For eg: if you are contributing a new `redisCache` resource type, the directory structure should look like this:

```
resource-types-contrib/
└── data/
 └── redis/
  ├── redis.yaml
  ├── README.md
  └── recipes/
    ├── aws-memorydb/
    │   ├── bicep/
    │   │   ├── memorydb.bicep
    │   │   └── memorydb.params
    │   └── terraform/
    │       ├── main.tf
    │       └── var.tf
    ├── azure-rediscache/
    │   ├── bicep/
    │   └── terraform/
    └── kubernetes/
      ├── bicep/
      └── terraform/
```

### 4. Define Your Resource Type Schema

For eg: if you are contributing to a `redisCaches` resource type, create a `redis.yaml` file that defines your resource type schema:

```yaml
namespace: Radius.Data
types:
  redisCaches:
    apiVersions:
      '2025-07-24-preview':
        schema: 
          type: object
          properties:
            environment:
              type: string
              description: The Radius environment ID to which the resource belongs to
            application:
              type: string
              description: The Radius application ID to which the resource belongs to
            capacity:
              type: string
              description: The size of the Redis Cache instance. Valid values are S, M, L
            host:
              type: string
              description: The Redis host name.
              readOnly: true
            port:
              type: string
              description: The Redis port
              readOnly: true
            username:
              type: string
              description: The username for the Redis cache.
              readOnly: true
            secrets:
              type: object
              properties:
                connectionString:
                  type: string
                  description: The connection string for the Redis cache
                  readOnly: true
                password:
                  type: string
                  description: The password for the Redis cache.
                  readOnly: true
        required:
            - environment
```

#### Schema Guidelines

The following guidelines should be followed when contributing resource types:

- The `namespace` field follows the format `Radius.<Category>`, where `<Category>` is a high-level grouping (e.g., Data, Dapr, AI). Some examples might be `Radius.Data/*` or `Radius.Security/*`.

- The resource type name follows the camelCase convention and is in plural form, such as `redisCaches`, `sqlDatabases`, or `rabbitMQQueues`.

- Version should be the latest date and follow the format `YYYY-MM-DD-preview`. This is the date on which the contribution is made or when the resource type is tested and validated, e.g. `2025-07-20-preview`. 

- Properties should follow the camel Case convention and include a description for each property. 
    - `readOnly:true` set for property automatically populated by Radius Recipes.
    - `type` could be `integer`, `string` or `object`; Support `array` and `enum` in progress
    - `required` for required properties. `environment` should always be a required property.

- Make sure the schema is simple and intuitive, avoiding unnecessary complexity.

## Recipes for the Resource Type

Radius supports Recipes in both Bicep and Terraform. Create a `recipes` directory under your resource type directory, and add platform-specific subdirectories for each IaC language you want to support.

 - Familiarize yourself with the IaC language of your choice [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview?tabs=bicep) or [Terraform](https://developer.hashicorp.com/terraform)
 - Familiarize yourself with the Radius [Recipe](https://docs.radapp.io/guides/recipes) concept
 - Follow this [how-to guide](https://docs.radapp.io/guides/recipes/howto-author-recipes/) to write your first recipe, register your recipe in the environment

### Example Bicep Recipe for Redis Cache on Kubernetes

```bicep

@description('Information about what resource is calling this Recipe. Generated by Radius. For more information visit https://docs.radapp.dev/operations/custom-recipes/')
param context object

extension kubernetes with {
  kubeConfig: ''
  namespace: context.runtime.kubernetes.namespace
} as kubernetes

resource redis 'apps/Deployment@v1' = {
  metadata: {
    name: 'redis-${uniqueString(context.resource.id)}'
  }
  spec: {
    selector: {
      matchLabels: {
        app: 'redis'
        resource: context.resource.name
      }
    }
    template: {
      metadata: {
        labels: {
          app: 'redis'
          resource: context.resource.name

          // Label pods with the application name so `rad run` can find the logs.
          'radapp.io/application': context.application == null ? '' : context.application.name
        }
      }
      spec: {
        containers: [
          {
            // This container is the running redis instance.
            name: 'redis'
            image: 'redis'
            ports: [
              {
                containerPort: 6379
              }
            ]
          }
          {
            // This container will connect to redis and stream logs to stdout for aid in development.
            name: 'redis-monitor'
            image: 'redis'
            args: [
              'redis-cli'
              '-h'
              'localhost'
              'MONITOR'
            ]
          }
        ]
      }
    }
  }
}

resource svc 'core/Service@v1' = {
  metadata: {
    name: 'redis-${uniqueString(context.resource.id)}'
  }
  spec: {
    type: 'ClusterIP'
    selector: {
      app: 'redis'
      resource: context.resource.name
    }
    ports: [
      {
        port: 6379
      }
    ]
  }
}

output result object = {
  // This workaround is needed because the deployment engine omits Kubernetes resources from its output.
  // This allows Kubernetes resources to be cleaned up when the resource is deleted.
  // Once this gap is addressed, users won't need to do this.
  resources: [
    '/planes/kubernetes/local/namespaces/${svc.metadata.namespace}/providers/core/Service/${svc.metadata.name}'
    '/planes/kubernetes/local/namespaces/${redis.metadata.namespace}/providers/apps/Deployment/${redis.metadata.name}'
  ]
  values: {
    host: '${svc.metadata.name}.${svc.metadata.namespace}.svc.cluster.local'
    port: 6379
  }
}
```

### Example Terraform Recipe

```hcl
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

variable "context" {
  description = "Radius-provided object containing information about the resource calling the Recipe."
  type = any
}

variable "port" {
  description = "The port Redis is offered on. Defaults to 6379."
  type = number
  default = 6379
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name = "redis-${sha512(var.context.resource.id)}"
    namespace = var.context.runtime.kubernetes.namespace
    labels = {
      app = "redis"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "redis"
        resource = var.context.resource.name
      }
    }
    template {
      metadata {
        labels = {
          app = "redis"
          resource = var.context.resource.name
        }
      }
      spec {
        container {
          name  = "redis"
          image = "redis:6"
          port {
            container_port = 6379
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name = "redis-${sha512(var.context.resource.id)}"
    namespace = var.context.runtime.kubernetes.namespace
  }
  spec {
    type = "ClusterIP"
    selector = {
      app = "redis"
      resource = var.context.resource.name
    }
    port {
      port        = var.port
      target_port = "6379"
    }
  }
}

output "result" {
  value = {
    values = {
      host = "${kubernetes_service.metadata.name}.${kubernetes_service.metadata.namespace}.svc.cluster.local"
      port = kubernetes_service.spec.port[0].port
      username = ""
    }
    secrets = {
      password = ""
    }
    // UCP resource IDs
    resources = [
        "/planes/kubernetes/local/namespaces/${kubernetes_service.metadata.namespace}/providers/core/Service/${kubernetes_service.metadata.name}",
        "/planes/kubernetes/local/namespaces/${kubernetes_deployment.metadata.namespace}/providers/apps/Deployment/${kubernetes_deployment.metadata.name}"
    ]
  }
  description = "The result of the Recipe. Must match the target resource's schema."
  sensitive = true
}

```
### Recipe Guidelines

- Recipes should be idempotent, meaning they can be run multiple times without causing issues.
- Handle secure defaults for all parameters, especially those related to secrets.
- Recipes should handle different size/configuration options, allowing users to choose the appropriate configuration for their needs.
- Provide outputs required to connect to the resource provisioned by the Recipe.
- Use core Radius resource types like `containers`, `gateway` and `secrets` where applicable to ensure consistency and reusability.
- Use comments to explain complex logic or important decisions in your Recipe code.

## Document Your Resource Type and Recipes

Create a `README.md` file in your resource type directory. This file should include:

```
## Overview

A brief description of the resource type and its purpose.

## Resource Type Schema Definition

A list of properties and their descriptions, including required properties.

## Recipes

A list of available Recipes for this resource type, including links to the Bicep and Terraform templates.:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|
| AWS | Bicep | aws-memorydb.bicep | Alpha |
| AWS | Terraform | aws-memorydb/main.tf | Alpha |
| Azure | Bicep | azure-rediscache.bicep | Alpha |
| Azure | Terraform | azure-rediscache/main.tf | Alpha |
| Kubernetes | Bicep | kubernetes.bicep | Alpha |
| Kubernetes | Terraform | kubernetes/main.tf | Alpha |

```

Create a `README.md` file in each Recipe directory to provide specific instructions for using that Recipe. Include:

```
## Recipe Description
A brief description of what the Recipe does and how to use it.

## Usage Instructions

```

### Documentation Guidelines

- Include overview of the Resource Type and its purpose
- Provide clear instructions for using the Resource Type and Recipes
- Document any special requirements or limitations
- Provide troubleshooting guidance
- Link to relevant external documentation
