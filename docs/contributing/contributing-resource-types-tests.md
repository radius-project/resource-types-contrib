# Contributing Tests for Stable Resource Types

Stable resource types are required to integrate with Radius CI/CD testing. The test files are discussed below and are only relevant if you are adding test coverage for stable resource types. The workflow will run on your PR to validate that the resource type schema and recipes are able to be created with Radius and deployed. 

### `.github/workflows` and `.github/scripts`

This folder contains the automated testing workflows and scripts. The workflows validate resource type schemas, test recipe deployments, and ensure compatibility with Radius. Scripts provide utility functions for manifest generation, resource verification, and test execution.

### `.github/build` 

The `build` folder includes logic used to define the make targets. The `help.mk` file provides help documentation for available targets, while `validation.mk` contains all the core testing logic including Radius installation, resource type creation, recipe publishing, and test execution workflows. The `tf-module-server` folder contains Kubernetes deployment resources for hosting Terraform modules during testing, providing a local module server that recipes can reference.

### Makefile

The Makefile provides standardized commands for testing resource types locally and in CI/CD. It includes targets for installing dependencies, creating resources, publishing recipes, running tests, and cleaning up test environments. These targets can be run locally to help with manual testing.

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

4. In `validate-common.sh`, update `setup_config()` to contain your new type. For example, if you were to add a `Radius.Compute/containers` resource type, the updated `setup_config()` should look like: 
```
setup_config() {
  resource_folders=("Security" "Compute")
  declare -g -A folder_to_namespace=(
    ["Security"]="Radius.Security"
    ["Compute"]="Radius.Compute"
  )
}
```