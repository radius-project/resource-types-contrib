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

##@ Environment Setup

# Environment Setup:
#   make install-radius		     # Install Radius CLI
#   make create-cluster		     # Create a local k3d Kubernetes cluster for testing
#   make delete-cluster		     # Delete the local k3d Kubernetes cluster

RAD_VERSION ?=

.PHONY: install-radius-cli
install-radius-cli: ## Install the Radius CLI. Optionally specify a version number, e.g., "make install-radius RAD_VERSION=0.48.0" or "make install-radius RAD_VERSION=edge"
	@echo -e "$(ARROW) Installing Radius..."
	wget -q "https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh" -O - | /bin/bash $(if $(RAD_VERSION),-s $(RAD_VERSION))

.PHONY: create-radius-cluster
create-radius-cluster: ## Create a local k3d Kubernetes cluster with a default Radius workspace/group/environment.
	@echo -e "$(ARROW) Creating local k3d cluster and installing Radius..."
	@.github/scripts/create-cluster.sh
	@.github/scripts/verify-ucp-readiness.sh
	@echo -e "$(ARROW) Creating workspace and environment..."
	@.github/scripts/create-workspace.sh

.PHONY: clean
clean: ## Delete the local k3d cluster, Radius config, Bicep extensions (*.tgz), and bicepconfig.json files
	@echo -e "$(ARROW) Deleting Radius config file at ~/.rad/config.yaml..."
	@rm -f ~/.rad/config.yaml
	@echo -e "$(ARROW) Deleting Bicep extension files (*.tgz)..."
	@find . -name "*.tgz" -type f -delete
	@echo -e "$(ARROW) Deleting bicepconfig.json files..."
	@find . -name "bicepconfig.json" -type f -delete
	@echo -e "$(ARROW) Deleting k3d cluster..."
	@k3d cluster delete
