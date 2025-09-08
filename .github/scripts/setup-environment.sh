#!/bin/bash
set -e

# Script: Setup Kubernetes environment and initialize Radius
# This script sets up k3d cluster, installs rad CLI, and initializes the default environment

echo "Setting up k3d cluster..."
k3d cluster create --agents 2 -p "80:80@loadbalancer" --k3s-arg "--disable=traefik@server:*" --k3s-arg "--disable=servicelb@server:*" --registry-create reciperegistry:51351

echo "Verifying ORAS installation..."
oras version

echo "Downloading rad CLI..."
RAD_VERSION="${1:-edge}"
wget -q "https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh" -O - | /bin/bash -s "$RAD_VERSION"

echo "Initializing default environment..."
rad install kubernetes --set rp.publicEndpointOverride=localhost --skip-contour-install
rad group create default
rad workspace create kubernetes default --group default
rad group switch default
rad env create default
rad env switch default

echo "✅ Environment setup completed successfully"