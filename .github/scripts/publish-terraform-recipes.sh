#!/bin/bash
set -e

# Script: Publish Terraform recipes to module server
# This script finds, publishes Terraform recipes, and sets up the module server

source .github/scripts/validate-common.sh
setup_config

echo "Finding and publishing Terraform recipes..."
readarray -t terraform_recipes < <(find_and_validate_recipes "*/recipes/kubernetes/terraform/main.tf" "Terraform")

# Set up the module server
read -r tf_namespace tf_deployment tf_configmap <<< "$(setup_terraform_module_server)"

# Create a temporary directory structure for publishing
temp_recipes_dir=$(mktemp -d)
echo "Using temporary directory: $temp_recipes_dir"

# Copy each Terraform recipe to the temp directory with proper naming
for recipe_file in "${terraform_recipes[@]}"; do
  read -r root_folder resource_type platform_service file_name <<< "$(extract_recipe_info "$recipe_file")"
  recipe_dir=$(dirname "$recipe_file")
  recipe_name="$resource_type-$platform_service"
  
  echo "Copying recipe from $recipe_dir to $temp_recipes_dir/$recipe_name"
  cp -r "$recipe_dir" "$temp_recipes_dir/$recipe_name"
done

# Publish all recipes to the module server
publish_terraform_recipes "$temp_recipes_dir" "$tf_namespace" "$tf_configmap"
wait_for_terraform_server "$tf_namespace" "$tf_deployment"

# Clean up temp directory
rm -rf "$temp_recipes_dir"

echo "✅ All Terraform recipes published and server ready"