#!/bin/bash

# Blue/Green Traffic Switching Script
# Usage: ./switch-traffic.sh <blue|green> [namespace]

set -e

COLOR=$1
NAMESPACE=${2:-stage}

if [[ ! "$COLOR" =~ ^(blue|green)$ ]]; then
    echo "Error: Invalid color. Use 'blue' or 'green'"
    echo "Usage: $0 <blue|green> [namespace]"
    exit 1
fi

echo "🔄 Switching traffic to $COLOR in namespace $NAMESPACE..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo "Error: Namespace '$NAMESPACE' does not exist"
    exit 1
fi

# Get current color
CURRENT_COLOR=$(kubectl get svc magento-svc -n "$NAMESPACE" -o jsonpath='{.spec.selector.color}' 2>/dev/null || echo "unknown")
echo "📊 Current traffic destination: $CURRENT_COLOR"

if [ "$CURRENT_COLOR" = "$COLOR" ]; then
    echo "✅ Traffic is already routed to $COLOR. No action needed."
    exit 0
fi

# Check if target deployment exists and is ready
READY_REPLICAS=$(kubectl get deployment "magento-web-$COLOR" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED_REPLICAS=$(kubectl get deployment "magento-web-$COLOR" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

echo "📈 $COLOR deployment status: $READY_REPLICAS/$DESIRED_REPLICAS replicas ready"

if [ "$READY_REPLICAS" != "$DESIRED_REPLICAS" ] || [ "$READY_REPLICAS" = "0" ]; then
    echo "⚠️  Warning: $COLOR deployment is not fully ready!"
    read -p "Do you want to proceed anyway? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
        echo "❌ Traffic switch cancelled."
        exit 1
    fi
fi

# Perform the switch
echo "🔀 Patching service selector to $COLOR..."
kubectl patch svc magento-svc -n "$NAMESPACE" -p "{\"spec\":{\"selector\":{\"color\":\"$COLOR\"}}}"

# Verify the switch
NEW_COLOR=$(kubectl get svc magento-svc -n "$NAMESPACE" -o jsonpath='{.spec.selector.color}')
if [ "$NEW_COLOR" = "$COLOR" ]; then
    echo "✅ Traffic successfully switched to $COLOR!"
    echo ""
    echo "📝 Next steps:"
    echo "  - Monitor pods: kubectl get pods -n $NAMESPACE -l color=$COLOR"
    echo "  - Check logs: kubectl logs -n $NAMESPACE -l color=$COLOR -f"
    echo "  - Rollback if needed: $0 $CURRENT_COLOR $NAMESPACE"
else
    echo "❌ Traffic switch verification failed!"
    exit 1
fi