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

##@ Testing

RESOURCE_TYPE_ROOT ?=$(shell pwd)

.PHONY: list-resource-type-folders
list-resource-type-folders: ## List resource type folders under the specified root
	@./.github/scripts/list-resource-type-folders.sh "$(RESOURCE_TYPE_ROOT)"

.PHONY: build-resource-type
build-resource-type: ## Validate a resource type by running the 'rad resource-type create' command (requires TYPE_FOLDER parameter)
ifndef TYPE_FOLDER
	$(error TYPE_FOLDER parameter is required. Usage: make build-resource-type TYPE_FOLDER=<resource-type-folder>)
endif
	@./.github/scripts/build-resource-type.sh "$(TYPE_FOLDER)"
