# ------------------------------------------------------------
# Copyright 2023 The Radius Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#    
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ------------------------------------------------------------

TERRAFORM_MODULE_SERVER_NAMESPACE=radius-test-tf-module-server
TERRAFORM_MODULE_SERVER_DEPLOYMENT_NAME=tf-module-server
TERRAFORM_MODULE_CONFIGMAP_NAME=tf-module-server-content

##@ Recipes

.PHONY: publish-test-terraform-recipes
publish-test-terraform-recipes: ## Publishes terraform recipes to the current Kubernetes cluster
	@echo -e "$(ARROW) Creating Kubernetes namespace $(TERRAFORM_MODULE_SERVER_NAMESPACE)..."
	kubectl create namespace $(TERRAFORM_MODULE_SERVER_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

	@echo -e "$(ARROW) Finding and publishing Terraform recipes..."
	@source .github/scripts/validate-common.sh && setup_config && \
	readarray -t terraform_recipes < <(find_and_validate_recipes "*/recipes/kubernetes/terraform/main.tf" "Terraform") && \
	temp_recipes_dir=$$(mktemp -d) && \
	echo "Using temporary directory: $$temp_recipes_dir" && \
	for recipe_file in "$${terraform_recipes[@]}"; do \
		read -r root_folder resource_type platform_service file_name <<< "$$(extract_recipe_info "$$recipe_file")" && \
		recipe_dir=$$(dirname "$$recipe_file") && \
		recipe_name="$$resource_type-$$platform_service" && \
		echo "Copying recipe from $$recipe_dir to $$temp_recipes_dir/$$recipe_name" && \
		cp -r "$$recipe_dir" "$$temp_recipes_dir/$$recipe_name"; \
	done && \
	./.github/scripts/publish-test-terraform-recipes.py \
		"$$temp_recipes_dir" \
		$(TERRAFORM_MODULE_SERVER_NAMESPACE) \
		$(TERRAFORM_MODULE_CONFIGMAP_NAME) && \
	rm -rf "$$temp_recipes_dir"
	
	@echo -e "$(ARROW) Deploying web server..."
	kubectl apply -f ./build/tf-module-server/resources.yaml -n $(TERRAFORM_MODULE_SERVER_NAMESPACE)

	@echo -e "$(ARROW) Waiting for web server to be ready..."
	kubectl rollout status deployment.apps/tf-module-server -n $(TERRAFORM_MODULE_SERVER_NAMESPACE) --timeout=600s

	@echo -e "$(ARROW) Web server ready. Recipes published to http://$(TERRAFORM_MODULE_SERVER_DEPLOYMENT_NAME).$(TERRAFORM_MODULE_SERVER_NAMESPACE).svc.cluster.local/<recipe_name>.zip"
	@echo -e "$(ARROW) To test use:"
	@echo -e "$(ARROW)     kubectl port-forward svc/$(TERRAFORM_MODULE_SERVER_DEPLOYMENT_NAME) 8999:80 -n $(TERRAFORM_MODULE_SERVER_NAMESPACE)"
	@echo -e "$(ARROW)     curl http://localhost:8999/<recipe-name>.zip --output <recipe-name>.zip"

##@ Workflow Commands

.PHONY: install-radius
install-radius: ## Set up k3d cluster, install tools, and install Radius
	@echo -e "$(ARROW) Installing Radius..."
	./.github/scripts/install-radius.sh $(VERSION)

.PHONY: verify-manifests
verify-manifests: ## Verify that manifests are registered in the UCP pod
	@echo -e "$(ARROW) Verifying manifests registration..."
	./.github/scripts/verify-manifests.sh

.PHONY: create-workspace
create-workspace: ## Create Radius workspace and environment
	@echo -e "$(ARROW) Creating workspace and environment..."
	./.github/scripts/create-workspace.sh

.PHONY: create-resource-types
create-resource-types: ## Create resource types from YAML files
	@echo -e "$(ARROW) Creating resource types..."
	@source .github/scripts/validate-common.sh && setup_config && create_resource_types

.PHONY: verify-resource-types
verify-resource-types: ## Verify that expected resource types are present
	@echo -e "$(ARROW) Verifying resource types..."
	@source .github/scripts/validate-common.sh && setup_config && verify_resource_types

.PHONY: publish-bicep-extensions
publish-bicep-extensions: ## Publish Bicep extensions for all YAML files
	@echo -e "$(ARROW) Publishing Bicep extensions..."
	@source .github/scripts/validate-common.sh && setup_config && publish_bicep_extensions

.PHONY: update-bicepconfig
update-bicepconfig: ## Update bicepconfig.json with published extensions
	@echo -e "$(ARROW) Updating bicepconfig.json..."
	./.github/scripts/update-bicepconfig.sh

.PHONY: publish-bicep-recipes
publish-bicep-recipes: ## Publish all Bicep recipes to registry
	@echo -e "$(ARROW) Publishing Bicep recipes..."
	@source .github/scripts/validate-common.sh && setup_config && publish_bicep_recipes

.PHONY: test-bicep-recipes
test-bicep-recipes: ## Register and test Bicep recipes
	@echo -e "$(ARROW) Testing Bicep recipes..."
	@source .github/scripts/validate-common.sh && setup_config && \
	readarray -t bicep_recipes < <(find_and_validate_recipes "*/recipes/kubernetes/bicep/*.bicep" "Kubernetes Bicep") && \
	test_recipes "bicep" "$${bicep_recipes[@]}" && \
	echo "✅ All Kubernetes Bicep recipes tested successfully" && \
	rad recipe list --environment default


.PHONY: test-terraform-recipes
test-terraform-recipes: ## Register and test Terraform recipes
	@echo -e "$(ARROW) Testing Terraform recipes..."
	@source .github/scripts/validate-common.sh && setup_config && \
	readarray -t terraform_recipes < <(find_and_validate_recipes "*/recipes/kubernetes/terraform/main.tf" "Terraform") && \
	test_recipes "terraform" "$${terraform_recipes[@]}" && \
	echo "✅ All Terraform recipes tested successfully" && \
	rad recipe list --environment default