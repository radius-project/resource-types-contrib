# Contributing Tests for Stable Resource Types

Resource Types at the Stable maturity level are required to integrate with Radius CI/CD testing. The test files are discussed below and are only relevant if you are adding test coverage for stable Resource Types. The workflow will run on your PR to validate that the Resource Type definition and Recipes are able to be created with Radius and deployed. 

### `.github/workflows` and `.github/scripts`

This folder contains the automated testing workflows and scripts. The workflows validate Resource Type definitions, test Recipe deployments, and ensure compatibility with Radius. Scripts provide utility functions for manifest generation, resource verification, and test execution.

### `.github/build` 

The `build` folder includes logic used to define the make targets. The `help.mk` file provides help documentation for available targets, while `validation.mk` contains all the core testing logic including Radius installation, Resource Type creation, Recipe publishing, and test execution workflows. The `tf-module-server` folder contains a container that is used to host a local module server for Terraform Recipes to referenced during testing.

### Makefile

The Makefile provides standardized commands for testing Resource Types locally and in CI/CD. It includes targets for installing dependencies, creating resources, publishing Recipes, running tests, and cleaning up Environments. These targets can be run locally to help with manual testing.

## Add test coverage for stable Resource Types
These are the steps to follow to ensure that a stable Resource Type is fully integrated with Radius testing in the CI/CD pipelines. 

### Pre-requisites

1. [**Resource Type Definition**](../contributing/contributing-resource-types-tests.md#resource-type-definition): Defines the structure and properties of your Resource Type
2. [**Recipes**](../contributing/contributing-resource-types-tests.md#recipes-for-the-resource-type): Terraform or Bicep templates for deploying the Resource Type on different platforms

### Add an app.bicep

### Add an app.bicep

1. Create a new `test` folder in your Resource Type root folder. For example, for a Secrets Resource Type, the directory structure would be `/Security/secrets/test`.

2. Create a application definition Bicep file called `app.bicep` in the test folder. Add an Application resource and a resource for your new Resource Type. Make sure to include the proper extensions for `radius` and your Resource Type. The naming of extension should be the same as your Resource Type. For example, the extension name for the `Radius.Security/secrets` Resource Type should be `secrets`. An `environment` parameter is also needed and will be set by the workflow during automated testing. 

Using the Secrets example, the full application definition should look similar to:

```
extension radius
extension secrets

param environment string

resource testapp 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  properties: {
    environment: environment
  }
}

resource secret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'secret'
  properties: {
    environment: environment
    application: app.id
    data: {
      apikey: {
        value: 'abc123xyz'
      }
    }
  }
}
```

3. In `validate-common.sh`, update `setup_config()` to contain your new Resource Type. For example, if you were to add a `Radius.Compute/containers` Resource Type, the updated `setup_config()` should look like:  
```
setup_config() {
  resource_folders=("Security" "Compute")
  declare -g -A folder_to_namespace=(
    ["Security"]="Radius.Security"
    ["Compute"]="Radius.Compute"
  )
}
```