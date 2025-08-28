#!/bin/bash

# Common configuration and functions for workflow validation

# Define common configuration
setup_config() {
  resource_folders=("Security")
  declare -g -A folder_to_namespace=(
    ["Security"]="Radius.Security"
  )
}

# Find YAML files in resource folders
find_yaml_files() {
  local yaml_files=()
  for folder in "${resource_folders[@]}"; do
    if [[ -d "./$folder" ]]; then
      echo "Searching in folder: $folder"
      while IFS= read -r -d '' file; do
        yaml_files+=("$file")
      done < <(find "./$folder" -name "*.yaml" -type f -print0)
    else
      echo "Folder $folder does not exist, skipping..."
    fi
  done
  
  if [[ ${#yaml_files[@]} -eq 0 ]]; then
    echo "No YAML files found in any resource type folders"
    exit 0
  fi
  
  printf '%s\n' "${yaml_files[@]}"
}

# Find recipe files with specific pattern
find_recipe_files() {
  local pattern="$1"
  local recipe_files=()
  
  while IFS= read -r -d '' f; do
    recipe_files+=("$f")
  done < <(find . -path "$pattern" -type f -print0)
  
  printf '%s\n' "${recipe_files[@]}"
}

# Extract path components from recipe file
extract_recipe_info() {
  local recipe_file="$1"
  local relpath="${recipe_file#./}"
  IFS='/' read -r root_folder resource_type _recipes_dir platform_service file_name <<< "$relpath"
  
  if [[ -z "$root_folder" || -z "$resource_type" || -z "$platform_service" ]]; then
    echo "❌ Unexpected recipe path structure: $recipe_file" >&2
    exit 1
  fi
  
  echo "$root_folder $resource_type $platform_service $file_name"
}

# Get Radius namespace for folder
get_radius_namespace() {
  local root_folder="$1"
  local radius_namespace="${folder_to_namespace[$root_folder]}"
  
  if [[ -z "$radius_namespace" ]]; then
    echo "❌ Unknown root folder: $root_folder" >&2
    exit 1
  fi
  
  echo "$radius_namespace"
}

# Deploy and cleanup test application
deploy_and_cleanup_test_app() {
  local test_app_path="$1"
  local deployment_name="$2"
  local description="$3"
  
  if [[ -f "$test_app_path" ]]; then
    echo ""
    echo "🚀 Deploying test application $description..."
    
    echo "Deploying $test_app_path as application: $deployment_name"
    if rad deploy "$test_app_path" --application "$deployment_name"; then
      echo "✅ Successfully deployed test application $description"
      
      # Clean up immediately
      echo "Cleaning up deployment: $deployment_name"
      rad app delete "$deployment_name" --yes || echo "⚠️ Failed to clean up deployment: $deployment_name"
      echo "✅ Cleaned up test deployment"
    else
      echo "❌ Failed to deploy test application $description"
      exit 1
    fi
  else
    echo "ℹ️ No test application found at $test_app_path, skipping deployment test..."
  fi
}

# Register and test a recipe type (Bicep or Terraform)
test_recipe_type() {
  local template_kind="$1"
  shift
  local recipes=("$@")
  
  if [[ ${#recipes[@]} -eq 0 ]]; then
    echo "No $template_kind recipes to test"
    return 0
  fi
  
  echo ""
  echo "🔄 Testing $template_kind recipes..."
  
  # Group recipes by platform service
  declare -A platform_recipes
  for recipe_file in "${recipes[@]}"; do
    read -r root_folder resource_type platform_service file_name <<< "$(extract_recipe_info "$recipe_file")"
    
    platform_key="$root_folder/$resource_type/$platform_service"
    if [[ -z "${platform_recipes[$platform_key]}" ]]; then
      platform_recipes[$platform_key]="$recipe_file"
    else
      platform_recipes[$platform_key]="${platform_recipes[$platform_key]} $recipe_file"
    fi
  done

  # Process each platform service
  for platform_key in "${!platform_recipes[@]}"; do
    IFS='/' read -r root_folder resource_type platform_service <<< "$platform_key"
    echo ""
    echo "🔄 Processing $template_kind recipe for: $platform_service ($root_folder/$resource_type)"
    
    # Get the Radius namespace
    radius_namespace=$(get_radius_namespace "$root_folder")

    # Unregister any existing default recipe for this resource type
    echo "Unregistering any existing default recipe for $radius_namespace/$resource_type"
    rad recipe unregister default --environment default --resource-type "$radius_namespace/$resource_type" || echo "No existing default recipe to unregister"

    # Process recipes for this platform service
    for recipe_file in ${platform_recipes[$platform_key]}; do
      if [[ "$template_kind" == "bicep" ]]; then
        recipe_name=$(basename "$recipe_file" .bicep)
        registry_path="localhost:51351/recipes/$resource_type/$platform_service/$recipe_name:latest"
        
        echo "Publishing Bicep recipe '$recipe_name' to registry: $registry_path"
        if rad bicep publish --file "$recipe_file" --target "br:$registry_path" --plain-http; then
          echo "✅ Successfully published Bicep recipe to registry"
        else
          echo "❌ Failed to publish Bicep recipe to registry"
          exit 1
        fi
        
        internal_registry_path="reciperegistry:5000/recipes/$resource_type/$platform_service/$recipe_name:latest"
        echo "Registering Bicep recipe 'default' for resource type '$radius_namespace/$resource_type'"
        if rad recipe register default --environment default --resource-type "$radius_namespace/$resource_type" --template-kind bicep --template-path "$internal_registry_path" --plain-http; then
          echo "✅ Successfully registered Bicep recipe as default"
        else
          echo "❌ Failed to register Bicep recipe as default"
          exit 1
        fi
        
      elif [[ "$template_kind" == "terraform" ]]; then
        # For Terraform, use the directory path
        recipe_dir=$(dirname "$recipe_file")
        echo "Registering Terraform recipe 'default' for resource type '$radius_namespace/$resource_type'"
        if rad recipe register default --environment default --resource-type "$radius_namespace/$resource_type" --template-kind terraform --template-path "$recipe_dir"; then
          echo "✅ Successfully registered Terraform recipe as default"
        else
          echo "❌ Failed to register Terraform recipe as default"
          exit 1
        fi
      fi
    done
    
    # Deploy test application for this resource type
    test_app_path="$root_folder/$resource_type/app.bicep"
    deployment_name="test-${root_folder,,}-${platform_service}-${template_kind}-$(date +%s)"
    
    deploy_and_cleanup_test_app "$test_app_path" "$deployment_name" "for $platform_service ($template_kind recipe)"
    
    echo "✅ Completed testing $template_kind recipe for $platform_service"
  done
}