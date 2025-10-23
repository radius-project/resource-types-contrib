# Radius.Dapr/stateStores

## Overview

The **Radius.Dapr/stateStores** resource type represents a Dapr state store component. This resource type deploys a Dapr component that can be used by containers with the Dapr sidecar extension enabled.

Developer documentation is embedded in the resource type definition YAML file, and it is accessible via the `rad resource-type show Radius.Dapr/stateStores` command.

## Recipes

A list of available Recipes for this resource type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes-dapr-statestore.bicep | Alpha |
| Kubernetes | Terraform | main.tf | Alpha |

## Recipe Input Properties

Properties for the **Radius.Dapr/stateStores** resource type are provided via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.type` (string, optional): The type of state store. Defaults to `state.redis` if not provided. See [Dapr state store components](https://docs.dapr.io/reference/components-reference/supported-state-stores/) for available options.
- `context.properties.version` (string, optional): The version of the state store component. Defaults to `v1` if not provided.
- `context.properties.metadata` (array, optional): Metadata specific to the state store component. Each item contains `name`, `value`, and optionally `secretKeyRef`. See [Dapr state store components](https://docs.dapr.io/reference/components-reference/supported-state-stores/) for details.

## Recipe Output Properties

The **Radius.Dapr/stateStores** resource type expects the following output properties to be set in the Results object in the Recipe:

- `context.properties.type` (string): The type of the deployed state store component.
- `context.properties.componentName` (string): The name of the Dapr component that can be used to reference the state store.
