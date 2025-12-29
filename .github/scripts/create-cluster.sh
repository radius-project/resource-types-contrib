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
# This script sets up KinD cluster with OIDC support for Azure Workload Identity,
# installs rad CLI, and initializes the default environment

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
validate_command "kind"
validate_command "kubectl"
validate_command "docker"

echo "Setting up KinD cluster..."

# Check if this is for Azure deployments by looking for AZURE_TENANT_ID
AZURE_WORKLOAD_IDENTITY_ENABLED="false"
KIND_CLUSTER_NAME="radius"

if [[ -n "${AZURE_TENANT_ID:-}" ]]; then
    echo "Azure Tenant ID detected. Checking for OIDC configuration..."
    
    # Populate the following environment variables for Azure workload identity from secrets.
    # AZURE_OIDC_ISSUER_PUBLIC_KEY
    # AZURE_OIDC_ISSUER_PRIVATE_KEY
    # AZURE_OIDC_ISSUER
    if [[ -n "${TEST_AZURE_OIDC_JSON:-}" ]]; then
        echo "Extracting OIDC configuration from TEST_AZURE_OIDC_JSON..."

        # Safely parse JSON secret into environment variables
        AZURE_OIDC_ISSUER_PUBLIC_KEY=$(echo "$TEST_AZURE_OIDC_JSON" | jq -r '.AZURE_OIDC_ISSUER_PUBLIC_KEY // empty')
        AZURE_OIDC_ISSUER_PRIVATE_KEY=$(echo "$TEST_AZURE_OIDC_JSON" | jq -r '.AZURE_OIDC_ISSUER_PRIVATE_KEY // empty')
        AZURE_OIDC_ISSUER=$(echo "$TEST_AZURE_OIDC_JSON" | jq -r '.AZURE_OIDC_ISSUER // empty')
        
        # Mask derived secrets in GitHub Actions logs
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "::add-mask::$AZURE_OIDC_ISSUER_PUBLIC_KEY"
            echo "::add-mask::$AZURE_OIDC_ISSUER_PRIVATE_KEY"
            echo "::add-mask::$AZURE_OIDC_ISSUER"
        fi
    fi
    
    # Validate required OIDC variables are set
    if [[ -z "${AZURE_OIDC_ISSUER_PUBLIC_KEY:-}" ]] || [[ -z "${AZURE_OIDC_ISSUER_PRIVATE_KEY:-}" ]] || [[ -z "${AZURE_OIDC_ISSUER:-}" ]]; then
        echo "Error: OIDC configuration is required for Azure Workload Identity but not found."
        echo "Please ensure the TEST_AZURE_OIDC_JSON secret is set correctly in GitHub."
        exit 1
    fi
    
    echo "Using provided OIDC configuration..."
    AZURE_WORKLOAD_IDENTITY_ENABLED="true"
fi

if [[ "${AZURE_WORKLOAD_IDENTITY_ENABLED}" == "true" ]]; then
    # Decode OIDC issuer keys if they were provided as base64
    if [[ -n "${AZURE_OIDC_ISSUER_PUBLIC_KEY:-}" ]] && [[ -n "${AZURE_OIDC_ISSUER_PRIVATE_KEY:-}" ]]; then
        echo "$AZURE_OIDC_ISSUER_PUBLIC_KEY" | base64 -d > sa.pub
        echo "$AZURE_OIDC_ISSUER_PRIVATE_KEY" | base64 -d > sa.key
    fi
    
    echo "Creating KinD cluster with OIDC support..."
    
    cat <<EOF | kind create cluster --name ${KIND_CLUSTER_NAME} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
    - hostPath: ./sa.pub
      containerPath: /etc/kubernetes/pki/sa.pub
    - hostPath: ./sa.key
      containerPath: /etc/kubernetes/pki/sa.key
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        service-account-issuer: $AZURE_OIDC_ISSUER
        service-account-key-file: /etc/kubernetes/pki/sa.pub
        service-account-signing-key-file: /etc/kubernetes/pki/sa.key
    controllerManager:
      extraArgs:
        service-account-private-key-file: /etc/kubernetes/pki/sa.key
EOF
    
    echo "Installing Azure Workload Identity webhook..."
    # Install Azure Workload Identity webhook (requires Helm)
    if command -v helm &> /dev/null; then
        helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts || true
        helm repo update
        
        helm install workload-identity-webhook \
            azure-workload-identity/workload-identity-webhook \
            --namespace radius-default \
            --create-namespace \
            --version 1.3.0 \
            --set azureTenantID="${AZURE_TENANT_ID}" \
            --wait || echo "Warning: Failed to install Azure Workload Identity webhook. Azure Recipes may not work."
        
        echo "Waiting for webhook to be fully registered..."
        for i in {1..30}; do
            if kubectl get mutatingwebhookconfiguration azure-wi-webhook-mutating-webhook-configuration &>/dev/null; then
                echo "✓ Webhook configuration registered"
                sleep 5  # Give it a few extra seconds to be fully functional
                break
            fi
            echo "Waiting for webhook configuration... ($i/30)"
            sleep 2
        done
    else
        echo "Warning: Helm is not installed. Skipping Azure Workload Identity webhook installation."
        echo "Azure Recipes will not work without this component."
    fi
fi

if [[ -z "${AZURE_TENANT_ID:-}" ]]; then
    echo "No Azure Tenant ID found. Creating basic KinD cluster..."
    kind create cluster --name ${KIND_CLUSTER_NAME}
fi

echo "Setting up local container registry..."
# Create a local registry for recipes if it doesn't exist
if ! docker ps | grep -q "reciperegistry"; then
    docker run -d --restart=always -p 5000:5000 --name reciperegistry registry:2
    
    # Connect the registry to the KinD network so pods can access it
    docker network connect kind reciperegistry || true
    
    # Document the local registry for KinD
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5000"
    hostFromContainerRuntime: "reciperegistry:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
    
    echo "✓ Local registry running at localhost:5000 (accessible from pods as reciperegistry:5000)"
else
    echo "✓ Local registry already running at localhost:5000"
fi

if [[ "${AZURE_WORKLOAD_IDENTITY_ENABLED}" == "true" ]]; then
  if [[ -z "${AZURE_CLIENT_ID:-}" ]]; then
    echo "Error: AZURE_CLIENT_ID must be set to install Radius with Azure Workload Identity."
    echo "Ensure the environment variable is available before running make create-radius-cluster."
    exit 1
  fi
fi

echo "Installing Radius on Kubernetes..."
if [[ "${AZURE_WORKLOAD_IDENTITY_ENABLED}" == "true" ]]; then
  rad install kubernetes \
      --set rp.publicEndpointOverride=localhost:8081 \
      --skip-contour-install \
      --set dashboard.enabled=false \
      --set global.azureWorkloadIdentity.enabled=true
else
  rad install kubernetes \
      --set rp.publicEndpointOverride=localhost:8081 \
      --skip-contour-install \
      --set dashboard.enabled=false
fi

echo "Installing Dapr on Kubernetes..."
helm repo add dapr https://dapr.github.io/helm-charts --force-update >/dev/null 2>&1
helm repo update >/dev/null 2>&1
helm upgrade --install dapr dapr/dapr \
  --namespace dapr-system \
  --create-namespace \
  --wait \
  --set global.ha.enabled=false

echo "Configuring RBAC for Radius dynamic-rp service account (HorizontalPodAutoscaler support)..."
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: radius-hpa-manager
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: radius-hpa-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: radius-hpa-manager
subjects:
- kind: ServiceAccount
  name: dynamic-rp
  namespace: radius-system
EOF

echo "Restarting Radius dynamic-rp deployment to pick up new permissions..."
kubectl rollout restart deployment dynamic-rp -n radius-system
kubectl rollout status deployment dynamic-rp -n radius-system --timeout=120s

echo "✅ Radius installation completed successfully"
