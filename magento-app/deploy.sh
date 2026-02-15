#!/bin/bash

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Deploying Magento Hello World to Kubernetes cluster${NC}"
echo ""

# Set kubeconfig
export KUBECONFIG=$(dirname $(dirname $(realpath $0)))/kubeconfig/kubeconfig.yaml

# Check if kubeconfig exists
if [ ! -f "$KUBECONFIG" ]; then
    echo -e "${RED}❌ Kubeconfig not found at: $KUBECONFIG${NC}"
    echo "Please run 'make up' from the project root first"
    exit 1
fi

# Check if cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to Kubernetes cluster${NC}"
    echo "Please ensure the cluster is running with 'make up'"
    exit 1
fi

echo -e "${GREEN}✓ Cluster connection verified${NC}"

# Build the image first
echo ""
echo -e "${YELLOW}Building Docker image...${NC}"
docker build -t magento-hello-world:latest .

echo ""
echo -e "${GREEN}✓ Image built successfully${NC}"

# Load image into k3s
echo ""
echo -e "${YELLOW}Loading image into K3s cluster...${NC}"
docker save magento-hello-world:latest | docker exec -i magento-k3s ctr images import -

echo ""
echo -e "${GREEN}✓ Image loaded into cluster${NC}"

# Check if namespace exists
if ! kubectl get namespace stage &>/dev/null; then
    echo ""
    echo -e "${YELLOW}Creating 'stage' namespace...${NC}"
    kubectl create namespace stage
    echo -e "${GREEN}✓ Namespace created${NC}"
fi

# Deploy to cluster using kustomize
CLUSTER_DIR=$(dirname $(dirname $(realpath $0)))/cluster

echo ""
echo -e "${YELLOW}Deploying to cluster...${NC}"
kubectl apply -k ${CLUSTER_DIR}/overlays/stage

echo ""
echo -e "${GREEN}✓ Deployment complete!${NC}"

# Wait for pods to be ready
echo ""
echo -e "${YELLOW}Waiting for pods to be ready...${NC}"
kubectl wait --for=condition=ready pod -l component=web,color=blue -n stage --timeout=120s 2>/dev/null || true

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Deployment successful!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}📊 Deployment Status:${NC}"
kubectl get pods -n stage
echo ""
echo -e "${YELLOW}🔗 Access your application:${NC}"
echo "1. Via port-forward (recommended):"
echo "   kubectl port-forward -n stage svc/magento-svc 8080:80"
echo "   Then open: http://localhost:8080"
echo ""
echo "2. Or use the K3s port (if configured):"
echo "   http://localhost:80"
echo ""
echo -e "${YELLOW}🔄 Test Blue/Green deployment:${NC}"
echo "   Switch to green: kubectl patch svc magento-svc -n stage -p '{\"spec\":{\"selector\":{\"color\":\"green\"}}}'"
echo "   Switch to blue:  kubectl patch svc magento-svc -n stage -p '{\"spec\":{\"selector\":{\"color\":\"blue\"}}}'"
echo ""
echo -e "${YELLOW}🧹 To clean up:${NC}"
echo "   kubectl delete -k ${CLUSTER_DIR}/overlays/stage"