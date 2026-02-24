# Contributing Resource Type Definitions and Recipes to Radius

This guide walks you through the process of creating and contributing Radius Resource Type definitions and Recipes to this repository.

## Prerequisites

Before you begin, ensure you have basic understanding of Radius concepts and the IaC languages you plan to use (Bicep or Terraform). 

 - Familiarize yourself with the [Radius](https://docs.radapp.io) 
 - Familiarize yourself with the [Resource Types](https://docs.radapp.io/tutorials/create-resource-type/) tutorial
 - Familiarize yourself with the [Radius Recipes](https://docs.radapp.io/guides/recipes) concept

## Overview

Contributing a Resource Type and Recipe involves the following:

1. [**Resource Type Definition**](#resource-type-definition): Defines the structure and properties of your Resource Type
2. [**Recipes**](#recipes-for-the-resource-type): Terraform or Bicep templates for deploying the Resource on different platforms
3. [**Documentation**](#document-your-resource-type-and-recipes): Providing clear usage examples and instructions
4. [**Testing**](testing-resource-types-recipes.md): Ensuring your Resource Type works as expected in a Radius Environment
5. [**Submission**](submitting-contribution.md): Creating a pull request with your changes

## Maturity Levels

Radius Resource Types and Recipes are categorized into the three maturity levels detailed below. Contributions of Resource Types and Recipes may begin at the `Alpha` or `Beta` stage and progress through to the `Stable` phase.

_Stage 1: Alpha_

    Purpose: Enable community members to contribute Resource Types and Recipes with minimal barriers
    Audience: Developers/Contributors exploring new technologies or learning Radius
    Requirements:
        - Resource Type schema validation: YAML schema passes validation
        - Single Recipe: At least one working Recipe for any cloud platform
        - Basic documentation: README with usage examples
        - Manual testing: Evidence of local testing by contributor
        - Maintainer review: Formal review and approval by Radius maintainers

_Stage 2: Beta_

    Purpose: Ensure contributions meet production-ready standards with comprehensive testing and documentation
    Audience: Contributors seeking to have their Resource Types included in official Radius releases
    Requirements:
        - Multi-platform support: Recipes for all three platforms (AWS, Azure, and Kubernetes)
        - IAC support: Recipes for both Bicep and Terraform
        - Automated testing: Functional tests that validate the Resource Type and Recipes
        - Documentation: Detailed README written for platform engineers describing Recipe behavior as well as developer documentation in the description fields of the Resource Type definition
        - Ownership: Designated owner for the Resource Type and Recipe
        - Maintainer review: Formal review and approval by Radius maintainers

_Stage 3: Stable_

    Purpose: Establish Resource Types and Recipes as officially supported and maintained by the Radius project
    Audience: Enterprise users doing production deployments and seeking stable, well-tested Resource Types and Recipes
    Requirements:
        - Functional tests have 100% coverage and results for Resource Type definition and Recipes
        - Integration testing: Full integration with Radius CI/CD pipeline and release process
        - Documentation: Well proven platform engineer and developer documentation
        - Ownership (Resource Type and Kubernetes Recipes): Radius maintainers assume ownership of the Resource Type definition and Kubernetes Recipes
        - Ownership (cloud platform Recipes): Contributor designates a committed owner for the cloud platform Recipes (e.g. AWS and Azure)
        - SLA commitment: Defined support level and response time commitments from cloud platform Recipe owners
        - Maintainer review: Formal review and approval by Radius maintainers

## Resource Type Definition

### 1. Choose a Resource Type

Identify the Resource Type you want to contribute. It could be a database, messaging service, or any other resource that fits within the Radius ecosystem. You can pick from the open issues in this repository or propose a new Resource Type.

### 2. Create a fork and clone this Repository

Create a fork of the `resource-types-contrib` repository on GitHub, then clone your fork to your local machine:

```bash
git clone https://github.com/<your-username>/resource-types-contrib.git
```

### 3. Create a new Resource Type directory

Create a new directory for your Resource Type under the appropriate category. For example if you are contributing a new `redisCaches` Resource Type, the directory structure should look like this:

```
resource-types-contrib/
└── Data/
 └── redisCaches/
  ├── redisCaches.yaml
  ├── README.md
  └── recipes/
    ├── aws-memorydb/
    │   ├── bicep/
    │   │   ├── memorydb.bicep
    │   │   └── memorydb.params
    │   └── terraform/
    │       ├── main.tf
    │       └── var.tf
    ├── azure-cache/
    │   ├── bicep/
    │   │   ├── azure-cache.bicep
    │   │   └── azure-cache.params
    │   └── terraform/
    │       ├── main.tf
    │       └── var.tf    
    └── kubernetes/
        ├── bicep/
        │   ├── kubernetes-redis.bicep
        │   └── kubernetes-redis.params
        └── terraform/
            ├── main.tf
            └── var.tf
```

### 4. Define Your Resource Type Definition

For example, if you are contributing to a `redisCaches` Resource Type, create a `redisCaches.yaml` file that defines the `redisCaches` Resource Type. The initial version may look similar to:

```yaml
namespace: Radius.Data
types:
  redisCaches:
    apiVersions:
      '2025-08-01-preview':
        schema: 
          type: object
          properties:
            environment:
              type: string
            application:
              type: string
            capacity:
              type: string
              enum: [S, M, L, XL]
            host:
              type: string
              readOnly: true
            port:
              type: string
              readOnly: true
            username:
              type: string
              readOnly: true
            secrets:
              type: object
              properties:
                password:
                  type: string
                  readOnly: true
        required:
            - environment
            - application
```

#### Schema Guidelines

The following guidelines should be followed when contributing new Resource Types:

- The `namespace` field follows the format `Radius.<Category>`, where `<Category>` is a high-level grouping (e.g., Data, Dapr, AI). Some examples might be `Radius.Data/*` or `Radius.Security/*`.

- The Resource Type name follows the camelCase convention and is in plural form, such as `redisCaches`, `sqlDatabases`, or `rabbitMQQueues`.

- Version should be the latest date and follow the format `YYYY-MM-DD-preview`. This is the date on which the contribution is made or when the Resource Type is tested and validated, e.g. `2025-07-20-preview`. Once the Resource Types has reached the Stable maturity level, the `-preview` suffix is removed.

- The description property must be populated with developer documentation. The top-level descrption and each property's description are output by `rad resource-type show` and will be visible in the Radius Dashboard in the future. See documentation section for more details.

- Each Resource Type will have one or more common properties:
   - `environment` must always be a required property (include in the `required` property).
   - `application` may be a required or property:
     - Required: Use when a resource must always be part of an application. For example, a Container will always be part of an application. 
     - Not required: Do not include in the `required` property for resources that may be deployed to an Environment without an application with the intention of being a shared resource. A blob store, for example, may be shared across multiple containers and applications.
   
- Each additional properties must:
    - Follow the camelCase naming convention.
    - Include a description for each property (see documentation section for more details).
    - Properties that are required must be listed in the `required` block.
    - Properties that are set by the Recipe only after the resource is deployed must be marked as `readOnly: true`.
    - Have a `type`. Valid types are:`integer`, `string`, `object`, `enum`, and `array`.
    
- Resource Types are made for developers and must be application-oriented. Avoid infrastructure-specific or platform-specific properties. Make sure the schema is simple and intuitive, avoiding unnecessary complexity.

## Document Your Resource Type and Recipes

Each Resource Type has two types of documentation written specifically for developers, and separately, for platform engineers.

### Developers
Developer documentation is embedded in the Resource Type definition. Each Resource Type definition must have documentation on how and when to use the resource in the top-level description property. When writing developer documentation, use Markdown. This is especially important for code blocks which must be quoted using triple backquotes. Output from `rad resource-type show` is shown in text only, but the Radius Dashboard formats the Markdown property including the ability to single-click copy code blocks.

Each property must also include:
 - The overall description of the property including example values.
 - Whether the property is required or optional.

When setting the description of properties:
 - Unquoted strings are preferred, avoid special characters such as `:`, `{`, `}`, `[`, `]`, `,`, `&`, `*`, `#`, `?`, `|`, `-`, `<`, `>`, `=`, `!`, `%`, `@`, and `\`.
 - Prefix the description with `(Required)`, `(Optional)`, or `(Read Only)`.
 - If an enum, do not add acceptable values in the description (these are visible in VS Code via Intellisense).
 - There are no defaults for enums. If the Recipes should assume a value, denote that "the value is assumed to be _____".
 - Denote values using `backquotes`. 

For example, the initial `redisCaches` Resource Type from above must be enhanced with developer documentation:

```yaml
namespace: Radius.Data
types:
  redisCaches:
    description: |
      The Radius.Data/redisCaches Resource Type adds a Redis cache to an application. Start by adding a redisCaches resource to your application definition Bicep file:

        resource redis 'Radius.Data/redisCaches@2025-08-01-preview' = {
          name: 'redis'
          properties: {
            application: todolist.id
            environment: environment
            capacity: 'M'
          }
        }

      Then add a connection from a Container resource to the Redis resource.

        resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
          name: 'myContainer'
          properties: { ... }
          connections: {
            redis: {
              source: redis.id
            }
          }
        }
    apiVersions:
      '2025-08-01-preview':
        schema: 
          type: object
          properties:
            environment:
              type: string
              description: (Required) The Radius Environment ID. Typically set by the rad CLI. Typically value should be `environment`.
            application:
              type: string
              description: (Required) The Radius Application ID. `todolist.id` for example.
            capacity:
              type: string
              enum: [S, M, L, XL]
              description: (Optional) The capacity of the Redis cache.
            host:
              type: string
              readOnly: true
              description: (Read Only) The hostname used to connect to the Redis server.
            port:
              type: string
              readOnly: true
              description: (Read Only) The network port used to connect of the Redis server.
            username:
              type: string
              readOnly: true
              description: (Read Only) The username used to connect to Redis server.
            secrets:
              type: object
              properties:
                password:
                  type: string
                  readOnly: true
                  description: (Read Only) The password used to connect to the Redis server.
          required:
            - environment
            - application
```

### Platform Engineers

Documentation for platform engineers must be provided in a `README.md` file in the Resource Type directory. This README should focus on describing the Recipes and the requirements for building a custom Recipe for the Resource Type. This file should include:

```
## Overview

A brief description of the Resource Type and its purpose.

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates.:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| AWS | Bicep | aws-memorydb.bicep | Alpha |
| AWS | Terraform | aws-memorydb/main.tf | Alpha |
| Azure | Bicep | azure-cache.bicep | Alpha |
| Azure | Terraform | azure-cache/main.tf | Alpha |
| Kubernetes | Bicep | kubernetes-redis.bicep | Alpha |
| Kubernetes | Terraform | kubernetes/main.tf | Alpha |

## Recipe Input Properties

A list of properties set by developers and a description of their purpose when authoring a Recipe. 

## Recipe Output Properties

A list of read-only properties which are required to be set by the Recipe.
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

## Recipes for the Resource Type

Radius supports Recipes in both Bicep and Terraform. Create a `recipes` directory under your Resource Type directory, and add platform-specific subdirectories for each IaC language you want to support.

 - Familiarize yourself with the IaC language of your choice [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview?tabs=bicep) or [Terraform](https://developer.hashicorp.com/terraform)
 - Familiarize yourself with the Radius [Recipe](https://docs.radapp.io/guides/recipes) concept
 - Follow this [how-to guide](https://docs.radapp.io/guides/recipes/howto-author-recipes/) to write your first Recipe, register your Recipe in the Environment

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

          // Label pods with the Application name so `rad run` can find the logs.
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
- Use core Radius Resource Types like `containers`, `gateway` and `secrets` where applicable to ensure consistency and reusability.
- Use comments to explain complex logic or important decisions in your Recipe code.

## Testing Your Contribution

After creating your Resource Type and Recipes, test them locally using the provided `make` commands.

### Quick Testing Workflow

1. **Set up your environment** (one-time setup):
   ```bash
   make install-radius-cli
   make create-radius-cluster
   ```

2. **Build your Resource Type**:
   ```bash
   make build-resource-type TYPE_FOLDER=Data/redisCaches
   ```

3. **Build your recipes**:
   ```bash
   # For Bicep recipes
   make build-bicep-recipe RECIPE_PATH=Data/redisCaches/recipes/kubernetes/bicep
   
   # For Terraform recipes
   make build-terraform-recipe RECIPE_PATH=Data/redisCaches/recipes/kubernetes/terraform
   ```

4. **Register your recipes** (required before testing):
  ```bash
  # Register Bicep recipes you've built
  make register RECIPE_TYPE=bicep

  # Register Terraform recipes in a separate environment or after cleanup
  make register RECIPE_TYPE=terraform ENVIRONMENT=my-terraform-env
  ```

  If you rely on a single Radius environment, run the register → test flow for one IaC format, clean up (or switch environments), and only then repeat for the other format so the two template kinds do not overwrite each other's registrations.

5. **Test individual recipes**:
   ```bash
   make test-recipe RECIPE_PATH=Data/redisCaches/recipes/kubernetes/bicep
   ```

6. **Test all recipes** (if you have multiple):
  ```bash
  make test
  ```

  To scope testing to a specific implementation, set `RECIPE_TYPE` to `bicep` or `terraform` (and optionally override the Radius environment with `ENVIRONMENT`):
  ```bash
  make test RECIPE_TYPE=bicep
  make test RECIPE_TYPE=terraform ENVIRONMENT=my-terraform-env
  ```

  Remember that `make test` assumes recipes are already registered. To validate both Bicep and Terraform recipes for the same resource type, run those register/test cycles sequentially or in distinct environments to avoid template registration conflicts.

For detailed testing instructions, see [Testing Resource Types and Recipes](testing-resource-types-recipes.md).

## Integration with CI/CD Testing for Stable Resource Types

For resource types categorized in the "Stable" maturity level, automated test coverage is required in the repository's CI/CD pipeline. The contribution guide with the steps to follow to update the automated tests can be found in [Contributing Tests for Stable Resource Types](contributing-resource-types-tests.md)