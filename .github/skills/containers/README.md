# Compute/containers Integration Test Skill

End-to-end integration test for `Radius.Compute/containers` using the `azure-aci-containers.bicep` recipe.

## What it tests

1. **Deployment** — Deploys `Compute/containers/test/app.bicep` via `rad deploy`
2. **Radius resources** — Verifies container, persistentVolume, and secrets resources are created with `provisioningState: Succeeded`
3. **Connections** — Validates `data` (persistentVolume) and `secrets` connections are wired correctly
4. **Azure infrastructure** — Checks NGroups, Container Group Profile, VNet, Load Balancer, NSG, and NAT Gateway exist in the expected Azure region
5. **Container instances** — Confirms the NGroups resource is provisioned and running
6. **Load Balancer connectivity** — Attempts HTTP requests to the container through the public IP

## Prerequisites

- Radius CLI installed and workspace configured
- Azure CLI authenticated
- Resource types registered:
  - `Radius.Compute/containers`
  - `Radius.Compute/persistentVolumes`
  - `Radius.Security/secrets`
- Recipes registered for all three resource types
- Azure resource group configured in the Radius environment

## Usage

```bash
# Default (uses environment 'default', location 'eastus2euap')
./.github/skills/containers/integration-test.sh

# Custom environment and location
./.github/skills/containers/integration-test.sh \
  /planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/default \
  westeurope

# Override resource group detection
RESOURCE_GROUP=my-rg ./.github/skills/containers/integration-test.sh
```

## Cleanup

On success or failure, the script logs the cleanup command. To manually clean up:

```bash
rad app delete containers-testapp --yes
rad resource delete Radius.Compute/containers myapp --group default --yes
rad resource delete Radius.Compute/persistentVolumes mypersistentvolume --group default --yes
```

## Exit codes

- `0` — All tests passed
- `1` — One or more tests failed or deployment error
