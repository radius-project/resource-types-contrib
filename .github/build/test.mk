# ------------------------------------------------------------
# Copyright 2025 The Radius Authors.
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

##@ Testing

RESOURCE_TYPE_ROOT ?=$(shell pwd)
ENVIRONMENT ?= default
RECIPE_TYPE ?= all

.PHONY: build
build: ## Build all resource types and recipes
	@./.github/scripts/build-all.sh "$(RESOURCE_TYPE_ROOT)"

.PHONY: build-resource-type
build-resource-type: ## Validate a resource type by running the 'rad resource-type create' and 'bicep publish-extension' commands (requires TYPE_FOLDER parameter)
ifndef TYPE_FOLDER
	$(error TYPE_FOLDER parameter is required. Usage: make build-resource-type TYPE_FOLDER=<resource-type-folder>)
endif
	@./.github/scripts/build-resource-type.sh "$(TYPE_FOLDER)"
	./.github/scripts/update-bicepconfig.sh

.PHONY: build-bicep-recipe
build-bicep-recipe: ## Build a Bicep recipe at the specified path (requires RECIPE_PATH parameter)
ifndef RECIPE_PATH
	$(error RECIPE_PATH parameter is required. Usage: make build-bicep-recipe RECIPE_PATH=<path-to-bicep-recipe>)
endif
	@echo -e "$(ARROW) Building Bicep recipe at $(RECIPE_PATH)..."
	@./.github/scripts/build-bicep-recipe.sh "$(RECIPE_PATH)"

.PHONY: build-terraform-recipe
build-terraform-recipe: ## Build a Terraform recipe at the specified path (requires RECIPE_PATH parameter)
ifndef RECIPE_PATH
	$(error RECIPE_PATH parameter is required. Usage: make build-terraform-recipe RECIPE_PATH=<path-to-terraform-recipe-directory>)
endif
	@./.github/scripts/build-terraform-recipe.sh "$(RECIPE_PATH)"

.PHONY: register-recipe
register-recipe: ## Register a single recipe (requires RECIPE_PATH parameter)
ifndef RECIPE_PATH
	$(error RECIPE_PATH parameter is required. Usage: make register-recipe RECIPE_PATH=<path-to-recipe-directory>)
endif
	@./.github/scripts/register-recipe.sh "$(RECIPE_PATH)"

.PHONY: register
register: ## Register built recipes (set ENVIRONMENT and/or RECIPE_TYPE to override defaults)
	@./.github/scripts/register-all-recipes.sh "$(RESOURCE_TYPE_ROOT)" "$(ENVIRONMENT)" "$(RECIPE_TYPE)"

.PHONY: test-recipe
test-recipe: ## Test a single recipe (assumes already registered, requires RECIPE_PATH parameter)
ifndef RECIPE_PATH
	$(error RECIPE_PATH parameter is required. Usage: make test-recipe RECIPE_PATH=<path-to-recipe-directory>)
endif
	@./.github/scripts/test-recipe.sh "$(RECIPE_PATH)"

.PHONY: test
test: ## Run recipe tests (assumes already registered)
	@./.github/scripts/test-all-recipes.sh "$(RESOURCE_TYPE_ROOT)" "$(ENVIRONMENT)" "$(RECIPE_TYPE)"

.PHONY: list-resource-types
list-resource-types: ## List resource type folders under the specified root
	@./.github/scripts/list-resource-type-folders.sh "$(RESOURCE_TYPE_ROOT)"

.PHONY: list-recipes
list-recipes: ## List all recipe folders (Bicep and Terraform) under the specified root
	@./.github/scripts/list-recipe-folders.sh "$(RESOURCE_TYPE_ROOT)"
