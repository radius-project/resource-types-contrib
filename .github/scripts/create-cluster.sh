#!/bin/bash

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

set -e

# Script: Setup Kubernetes environment and initialize Radius
# This script sets up k3d cluster, installs rad CLI, and initializes the default environment

# Validation function
validate_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed or not found in PATH."
        exit 1
    fi
    echo "✓ $cmd is installed: $($cmd version)"
}

# Run validations
echo "Validating required dependencies..."
validate_command "k3d"
validate_command "oras"

echo "Setting up k3d cluster..."
k3d cluster create \
    -p "8081:80@loadbalancer" \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--disable=servicelb@server:*" \
    --registry-create reciperegistry:5000 \
    --wait

echo "Installing Radius on Kubernetes..."
rad install kubernetes --set rp.publicEndpointOverride=localhost:8081 --skip-contour-install --set dashboard.enabled=false

echo "✅ Radius installation completed successfully"
