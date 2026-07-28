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

##@ Release

# Per-namespace releases are cut by the release-namespace.yaml workflow and
# per-recipe-pack releases by the release-recipe-pack.yaml workflow. These
# targets mirror the workflow steps for local inspection and dry runs. Git tags
# (Radius.<Category>/vX.Y.Z and recipe-pack/<pack>/vX.Y.Z) are the single source
# of truth for versions.

BUMP ?= minor
OUT_DIR ?= dist

.PHONY: test-release-automation
test-release-automation: ## Run focused tests for namespace sync and release versioning automation
	@./.github/scripts/tests/test-release-automation.sh

.PHONY: list-namespaces
list-namespaces: ## List releasable namespaces (Radius.<Category>)
	@./.github/scripts/release/list-namespaces.sh

.PHONY: list-recipe-packs
list-recipe-packs: ## List releasable recipe packs (recipepack/<pack>)
	@./.github/scripts/release/list-recipe-packs.sh

.PHONY: next-version
next-version: ## Show current/next version for a namespace or recipe pack (requires NAMESPACE or RECIPE_PACK; optional BUMP=patch|minor|major, PRERELEASE_LABEL)
ifeq ($(strip $(NAMESPACE))$(strip $(RECIPE_PACK)),)
	$(error NAMESPACE or RECIPE_PACK parameter is required. Usage: make next-version NAMESPACE=Radius.Data BUMP=minor | make next-version RECIPE_PACK=kubernetes BUMP=minor)
endif
ifneq ($(and $(strip $(NAMESPACE)),$(strip $(RECIPE_PACK))),)
	$(error NAMESPACE and RECIPE_PACK are mutually exclusive. Set exactly one of them)
endif
	@NAMESPACE="$(NAMESPACE)" RECIPE_PACK="$(RECIPE_PACK)" BUMP="$(BUMP)" PRERELEASE_LABEL="$(PRERELEASE_LABEL)" ./.github/scripts/release/next-version.sh

.PHONY: release-bundle
release-bundle: ## Build a namespace manifest or recipe pack bundle locally (requires NAMESPACE or RECIPE_PACK, and VERSION; optional OUT_DIR)
ifeq ($(strip $(NAMESPACE))$(strip $(RECIPE_PACK)),)
	$(error NAMESPACE or RECIPE_PACK parameter is required. Usage: make release-bundle NAMESPACE=Radius.Data VERSION=0.1.0 | make release-bundle RECIPE_PACK=kubernetes VERSION=0.1.0)
endif
ifneq ($(and $(strip $(NAMESPACE)),$(strip $(RECIPE_PACK))),)
	$(error NAMESPACE and RECIPE_PACK are mutually exclusive. Set exactly one of them)
endif
ifndef VERSION
	$(error VERSION parameter is required. Usage: make release-bundle NAMESPACE=Radius.Data VERSION=0.1.0)
endif
	@if [ -n "$(RECIPE_PACK)" ]; then \
		RECIPE_PACK="$(RECIPE_PACK)" VERSION="$(VERSION)" OUT_DIR="$(OUT_DIR)" ./.github/scripts/release/build-recipe-pack-bundle.sh; \
	else \
		NAMESPACE="$(NAMESPACE)" VERSION="$(VERSION)" OUT_DIR="$(OUT_DIR)" ./.github/scripts/release/build-namespace-bundle.sh; \
	fi
