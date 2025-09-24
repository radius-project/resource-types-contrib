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

##@ Environment Setup Commands

# Environment Setup:
#   make install-radius		     # Install Radius CLI
#   make create-cluster		     # Create a local k3d Kubernetes cluster for testing
#   make delete-cluster		     # Delete the local k3d Kubernetes cluster

.PHONY: install-radius
install-radius: ## Install the Radius CLI. Optionally specify a version number using the RAD_VERSION argument, e.g., "make install-radius RAD_VERSION=0.48.0". Set RAD_VERSION=edge for the edge version.
	@echo -e "$(ARROW) Installing Radius..."
	@RAD_VERSION="$(RAD_VERSION)"; \
	if [ -n "$$RAD_VERSION" ]; then \
		wget -q "https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh" -O - | /bin/bash -s "$$RAD_VERSION"; \
	else \
		wget -q "https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh" -O - | /bin/bash; \
	fi

.PHONY: create-cluster
create-cluster: ## Create a local k3d Kubernetes cluster for testing using the default cluster name.
	@.github/scripts/create-cluster.sh

.PHONY: delete-cluster
delete-cluster: ## Delete the local default k3d cluster.
	@echo -e "$(ARROW) Deleting k3d cluster..."
	k3d cluster delete