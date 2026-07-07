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

# Per-namespace releases are cut by the release-namespace.yaml workflow. These
# targets mirror the workflow steps for local inspection and dry runs. Git tags
# (Radius.<Category>/vX.Y.Z) are the single source of truth for versions.

BUMP ?= minor
OUT_DIR ?= dist

.PHONY: list-namespaces
list-namespaces: ## List releasable namespaces (Radius.<Category>)
	@./.github/scripts/release/list-namespaces.sh

.PHONY: next-version
next-version: ## Show current/next version for a namespace (requires NAMESPACE; optional BUMP=patch|minor|major, PRERELEASE_LABEL)
ifndef NAMESPACE
	$(error NAMESPACE parameter is required. Usage: make next-version NAMESPACE=Radius.Data BUMP=minor)
endif
	@NAMESPACE="$(NAMESPACE)" BUMP="$(BUMP)" PRERELEASE_LABEL="$(PRERELEASE_LABEL)" ./.github/scripts/release/next-version.sh

.PHONY: release-bundle
release-bundle: ## Build a namespace manifest bundle locally (requires NAMESPACE, VERSION; optional OUT_DIR)
ifndef NAMESPACE
	$(error NAMESPACE parameter is required. Usage: make release-bundle NAMESPACE=Radius.Data VERSION=0.1.0)
endif
ifndef VERSION
	$(error VERSION parameter is required. Usage: make release-bundle NAMESPACE=Radius.Data VERSION=0.1.0)
endif
	@NAMESPACE="$(NAMESPACE)" VERSION="$(VERSION)" OUT_DIR="$(OUT_DIR)" ./.github/scripts/release/build-namespace-bundle.sh
