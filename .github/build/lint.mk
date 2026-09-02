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

##@ Linting

.PHONY: install-cspell
install-cspell: ## Install cspell globally via npm (requires Node.js/npm).
	@command -v npm >/dev/null 2>&1 || { echo "npm (Node.js) is required to install cspell. Install Node.js $$(cat .node-version 2>/dev/null || echo 24), then retry."; exit 1; }
	@echo -e "$(ARROW) Installing cspell..."
	@npm install -g cspell

.PHONY: spellcheck
spellcheck: ## Run cspell over Markdown and YAML docs (matches the Spellcheck CI workflow). Installs cspell if missing.
	@command -v cspell >/dev/null 2>&1 || $(MAKE) install-cspell
	@echo -e "$(ARROW) Running spellcheck..."
	@cspell lint --config ./.github/linters/.cspell.yml --no-progress --dot "**/*.{md,yaml,yml}"

.PHONY: validate-icons
validate-icons: ## Validate resource type SVG icons against the rules Radius enforces at registration time.
	@command -v node >/dev/null 2>&1 || { echo "Node.js is required to validate icons. Install Node.js $$(cat .node-version 2>/dev/null || echo 24), then retry."; exit 1; }
	@echo -e "$(ARROW) Validating resource type icons..."
	@node ./.github/scripts/validate-icons.js "$(RESOURCE_TYPE_ROOT)"
