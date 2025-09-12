#!/bin/bash
set -e

# Script: Register and test Bicep recipes
# This script finds, registers, and tests Bicep recipes

source .github/scripts/validate-common.sh
setup_config

echo "Finding and testing Bicep recipes..."
readarray -t bicep_recipes < <(find_and_validate_recipes "*/recipes/kubernetes/bicep/*.bicep" "Kubernetes Bicep")

# Test Bicep recipes
test_recipes "bicep" "${bicep_recipes[@]}"

echo ""
echo "✅ All Kubernetes Bicep recipes tested successfully"

echo "Listing all registered recipes..."
rad recipe list --environment default