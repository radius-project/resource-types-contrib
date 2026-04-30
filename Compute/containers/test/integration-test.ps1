# ------------------------------------------------------------
# Integration test for Radius.Compute/containers connections
# Verifies successful connections to persistentVolumes and Key Vault (secrets)
#
# Prerequisites:
# - Radius environment with Azure provider configured
# - Resource types and recipes registered
#
# Usage: .\integration-test.ps1 [-Environment <env-id>]
# ------------------------------------------------------------

param(
    [string]$Environment = "/planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/default"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TestFile = Join-Path $ScriptDir "app.bicep"
$AppName = "integration-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
$Passed = 0
$Failed = 0
$Tests = @()

# --- Helpers ---

function Log-Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Log-Pass($msg) { 
    Write-Host "  ✓ $msg" -ForegroundColor Green
    $script:Passed++
    $script:Tests += "PASS: $msg"
}
function Log-Fail($msg) { 
    Write-Host "  ✗ $msg" -ForegroundColor Red
    $script:Failed++
    $script:Tests += "FAIL: $msg"
}

function Assert-NotEmpty($value, $description) {
    if ($value -and $value -ne "null" -and $value -ne "") {
        Log-Pass $description
    } else {
        Log-Fail "$description (got empty/null value)"
    }
}

function Assert-Equals($actual, $expected, $description) {
    if ($actual -eq $expected) {
        Log-Pass $description
    } else {
        Log-Fail "$description (expected '$expected', got '$actual')"
    }
}

function Assert-Contains($haystack, $needle, $description) {
    if ($haystack -match [regex]::Escape($needle)) {
        Log-Pass $description
    } else {
        Log-Fail "$description (expected to contain '$needle')"
    }
}

# --- Cleanup on exit ---
function Cleanup {
    Log-Info "Cleaning up test application: $AppName"
    rad app delete $AppName --yes 2>$null
}

# --- Test Execution ---

Log-Info "Starting integration test for container connections"
Log-Info "Test file: $TestFile"
Log-Info "Application: $AppName"

# Step 1: Deploy the test application
Log-Info "Step 1: Deploying test application..."
$deployOutput = rad deploy $TestFile --application $AppName -e $Environment 2>&1
if ($LASTEXITCODE -ne 0) {
    Log-Fail "Deployment of test application"
    Write-Host $deployOutput
    Write-Host ""
    Write-Host "================================================"
    Write-Host "INTEGRATION TEST ABORTED - Deployment failed"
    Write-Host "================================================"
    Cleanup
    exit 1
}
Log-Pass "Deployment of test application succeeded"

try {
    # Step 2: Verify container resource status
    Log-Info "Step 2: Verifying container resource..."
    $containerJson = rad resource show "Radius.Compute/containers" "myapp" -a $AppName -o json 2>$null | ConvertFrom-Json

    $containerState = $containerJson.properties.provisioningState
    Assert-Equals $containerState "Succeeded" "Container provisioningState is Succeeded"

    # Verify container has connections defined
    $containerConnections = $containerJson.properties.connections.PSObject.Properties.Name -join ","
    Assert-Contains $containerConnections "data" "Container has 'data' connection (persistentVolume)"
    Assert-Contains $containerConnections "secrets" "Container has 'secrets' connection (Key Vault)"

    # Step 3: Verify persistent volume resource and its computed values
    Log-Info "Step 3: Verifying persistentVolume connection..."
    $pvJson = rad resource show "Radius.Compute/persistentVolumes" "mypersistentvolume" -a $AppName -o json 2>$null | ConvertFrom-Json

    $pvState = $pvJson.properties.provisioningState
    Assert-Equals $pvState "Succeeded" "PersistentVolume provisioningState is Succeeded"

    $pvShareName = $pvJson.properties.status.computedValues.shareName
    Assert-NotEmpty $pvShareName "PersistentVolume has shareName in computedValues"

    $pvStorageAccount = $pvJson.properties.status.computedValues.storageAccountName
    Assert-NotEmpty $pvStorageAccount "PersistentVolume has storageAccountName in computedValues"

    $pvProvider = $pvJson.properties.status.computedValues.provider
    Assert-Equals $pvProvider "azureFile" "PersistentVolume provider is 'azureFile'"

    # Verify storage account key exists in secrets
    $pvKeyValue = $pvJson.properties.status.secrets.storageAccountKey.Value
    if ($pvKeyValue) {
        Log-Pass "PersistentVolume has storageAccountKey secret"
    } else {
        Log-Fail "PersistentVolume has storageAccountKey secret"
    }

    # Verify Azure storage account actually exists (use subscription from Radius env provider)
    Log-Info "  Checking Azure storage account exists..."
    $envJson = rad env show -o json 2>$null | ConvertFrom-Json
    $azureScope = $envJson.properties.providers.azure.scope
    $subscription = ($azureScope -split "/")[2]
    $resourceGroup = ($azureScope -split "/")[4]
    $saState = az storage account show --name $pvStorageAccount --resource-group $resourceGroup --subscription $subscription --query "provisioningState" -o tsv 2>$null
    if ($saState -eq "Succeeded") {
        Log-Pass "Azure Storage Account '$pvStorageAccount' exists and is provisioned"
    } else {
        Log-Fail "Azure Storage Account '$pvStorageAccount' not found or not provisioned"
    }

    # Step 4: Verify secrets resource and Key Vault connection
    Log-Info "Step 4: Verifying secrets (Key Vault) connection..."

    # Get the secrets resource name from the container's connections
    # The app.bicep hardcodes the app name as 'containers-testapp', so query without -a filter
    $secretsList = rad resource list "Radius.Security/secrets" -o json 2>$null | ConvertFrom-Json
    $secretsResource = $secretsList | Where-Object { $_.name -match "app-secrets" } | Sort-Object -Property name -Descending | Select-Object -First 1

    if (-not $secretsResource) {
        Log-Fail "Could not find secrets resource in application"
    } else {
        $secretsName = $secretsResource.name
        $secretsJson = rad resource show "Radius.Security/secrets" $secretsName -o json 2>$null | ConvertFrom-Json

        $secretsState = $secretsJson.properties.provisioningState
        Assert-Equals $secretsState "Succeeded" "Secrets provisioningState is Succeeded"

        # Verify Key Vault URI is in computed values
        $kvUri = $secretsJson.properties.status.computedValues.keyVaultUri
        Assert-NotEmpty $kvUri "Secrets has keyVaultUri in computedValues"

        # Verify UAI client ID is in computed values
        $uaiClientId = $secretsJson.properties.status.computedValues.userAssignedIdentityClientId
        Assert-NotEmpty $uaiClientId "Secrets has userAssignedIdentityClientId in computedValues"

        # Verify UAI resource ID is in computed values
        $uaiId = $secretsJson.properties.status.computedValues.userAssignedIdentityId
        Assert-NotEmpty $uaiId "Secrets has userAssignedIdentityId in computedValues"

        # Verify Key Vault exists in Azure
        if ($kvUri -and $kvUri -ne "null") {
            $kvName = ($kvUri -replace "https://", "" -replace "\.vault\.azure\.net/?", "")
            Log-Info "  Checking Azure Key Vault '$kvName' exists..."
            $kvState = az keyvault show --name $kvName --subscription $subscription --query "properties.provisioningState" -o tsv 2>$null
            if ($kvState -eq "Succeeded") {
                Log-Pass "Azure Key Vault '$kvName' exists and is provisioned"
            } else {
                Log-Fail "Azure Key Vault '$kvName' not found or not provisioned"
            }
        }
    }

    # Step 5: Verify the container's recipe output resources are tracked
    Log-Info "Step 5: Verifying container recipe output resources..."
    $outputResources = $containerJson.properties.status.outputResources
    $outputCount = if ($outputResources) { $outputResources.Count } else { 0 }

    if ($outputCount -gt 0) {
        Log-Pass "Container has $outputCount output resources tracked"
    } else {
        Log-Fail "Container has no output resources tracked"
    }

} finally {
    # --- Cleanup ---
    Cleanup
}

# --- Summary ---
Write-Host ""
Write-Host "================================================"
Write-Host "INTEGRATION TEST SUMMARY"
Write-Host "================================================"
Write-Host "Passed: $Passed"
Write-Host "Failed: $Failed"
Write-Host ""
foreach ($test in $Tests) {
    Write-Host "  $test"
}
Write-Host ""

if ($Failed -gt 0) {
    Write-Host "RESULT: FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "RESULT: PASSED" -ForegroundColor Green
    exit 0
}
