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

# Makefile for Radius Resource Types and Recipes Testing
#
# This Makefile provides standardized commands for testing resource types 
# locally and in CI/CD pipelines. It supports Kubernetes recipe testing
# with automated setup, validation, and cleanup.
#
# Quick Start:
#   make help                    # Show all available targets
#   make install-radius          # Set up local test environment  
#   make test-bicep-recipes      # Test Kubernetes Bicep recipes
#
# Common Workflow:
#   make install-radius VERSION=edge
#   make create-workspace
#   make create-resource-types
#   make test-bicep-recipes

SHELL := /bin/bash
ARROW := \033[34;1m=>\033[0m

# order matters for these
include ./.github/build/help.mk ./.github/build/validation.mk