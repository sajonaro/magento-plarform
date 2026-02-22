#!/bin/bash
# Bootstrap a fresh EKS cluster with ArgoCD and Magento application
# 
# Usage: ./bootstrap-cluster.sh [staging|production]
# 
# Note: This script operates on whatever cluster the current kubeconfig points to.

set -e

ENVIRONMENT=${1:-staging}

echo "Bootstrapping $ENVIRONMENT cluster..."
echo "Cluster: $(kubectl config current-context)"

# 1. Install ArgoCD
echo "→ Installing ArgoCD..."
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD
echo "→ Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# 2. Deploy ArgoCD Application for this environment
echo "→ Deploying ArgoCD Application for $ENVIRONMENT..."
if [ "$ENVIRONMENT" = "production" ]; then
  kubectl apply -f cluster/argocd/app-production.yaml
else
  kubectl apply -f cluster/argocd/app-staging.yaml
fi

echo " Cluster bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Check ArgoCD application status:"
echo "     kubectl get applications -n argocd"
echo ""
echo "  2. Access ArgoCD UI:"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "  3. Get ArgoCD admin password:"
echo "     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  4. Watch Magento deployment:"
echo "     kubectl get pods -w"