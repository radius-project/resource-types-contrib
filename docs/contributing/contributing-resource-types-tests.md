# Contributing Tests for Stable Resource Types

Stable resource types are required to integrate with Radius CI/CD testing. The test files are discussed below and are only relevant if you are adding test coverage for stable resource types. The workflow will run on your PR to validate that the resource type schema and recipes are able to be created with Radius and deployed. 

### `.github/workflows` and `.github/scripts`

This folder contains the automated testing workflows and scripts. The workflows validate resource type schemas, test recipe deployments, and ensure compatibility with Radius. Scripts provide utility functions for manifest generation, resource verification, and test execution.

### Makefile

The Makefile provides standardized commands for testing resource types locally and in CI/CD. It includes targets for installing dependencies, creating resources, publishing recipes, running tests, and cleaning up test environments. These targets can be run locally to help with manual testing. 

### `bicepconfig.json`

This file configures the Bicep compiler to recognize custom Radius resource types. It specifies extension aliases and registry locations, enabling Bicep files to import and use the contributed resource types during development and testing.

## Add test coverage for stable resource types

These are the steps to follow to ensure that a stable resource type is fully integrated with Radius testing in the CI/CD pipelines. 

### Pre-requsiites

1. [**Resource Type Definition**](../contributing/contributing-resource-types-tests.md#resource-type-definition): Defines the structure and properties of your Resource Type
2. [**Recipes**](../contributing/contributing-resource-types-tests.md#recipes-for-the-resource-type): Terraform or Bicep templates for deploying the Resource on different platforms

### Add an app.bicep

1. Create a new `test` folder in your resource type root folder. For example, for a secrets resource type, the directory structure would be `/Security/secrets/test`.

2. Add an application template named `app.bicep` in the test folder. Define an application resource in this template. Make sure to include the proper extensions for `radius` and your resource type. The naming of extension should be the same as your resource type (for example, for a `Radius.Security/secrets` resource type, the extension name should be `secrets`). An environment parameter is also needed and will be set by the workflow during automated testing. 

```
extension radius
extension secrets

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  location: 'global'
  properties: {
    environment: environment
    extensions: [
      {
        kind: 'kubernetesNamespace'
        namespace: 'testapp'
      }
    ]
  }
}
```

3. Add your new resource type to the bicep template with any input values needed by your recipe. The final `app.bicep` template should looks as follows: 
```
extension radius
extension secrets

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  location: 'global'
  properties: {
    environment: environment
    extensions: [
      {
        kind: 'kubernetesNamespace'
        namespace: 'testapp'
      }
    ]
  }
}

resource secret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'app-secrets-${uniqueString(deployment().name)}'
  properties: {
    environment: environment
    application: app.id
    data: {
      username: {
        value: 'admin'
      }
      password: {
        value: 'c2VjcmV0cGFzc3dvcmQ='
        encoding: 'base64'
      }
      apikey: {
        value: 'abc123xyz'
      }
    }
  }
}
```