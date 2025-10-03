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

# Makefile for Radius Resource Types and Recipes Testing
#
# This Makefile provides standardized commands for testing resource types 
# locally and in CI/CD pipelines. It supports Kubernetes recipe testing
# with automated setup, validation, and cleanup.
#
# Help:
#   make help                    # Show all available targets
#
# Environment Setup:
#   make install-radius		     # Install Radius CLI
#   make create-cluster		     # Create a local k3d Kubernetes cluster for testing
#   make delete-cluster		     # Delete the local k3d Kubernetes cluster
#
# Developement and testing:
#   make lint					# Lint all resource types and recipes
#   make build		            # Build all resource types and recipes
#   make test					# Run automated tests for all recipes

SHELL := /bin/bash
ARROW := \033[34;1m=>\033[0m

# order matters for these
include ./.github/build/help.mk ./.github/build/environment.mk ./.github/build/test.mk