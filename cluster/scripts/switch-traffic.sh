#!/bin/bash

# Blue/Green Traffic Switching Script
# Usage: ./switch-traffic.sh <blue|green>
# 
# Note: This script operates on whatever cluster the current kubeconfig points to.
# Staging vs Production is determined by which cluster you're connected to,
# not by namespace parameter.

set -e

COLOR=$1

if [[ ! "$COLOR" =~ ^(blue|green)$ ]]; then
    echo "Error: Invalid color. Use 'blue' or 'green'"
    echo "Usage: $0 <blue|green>"
    exit 1
fi

echo "Switching traffic to $COLOR..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Get current color
CURRENT_COLOR=$(kubectl get svc magento-svc -o jsonpath='{.spec.selector.color}' 2>/dev/null || echo "unknown")
echo "Current traffic destination: $CURRENT_COLOR"

if [ "$CURRENT_COLOR" = "$COLOR" ]; then
    echo "Traffic is already routed to $COLOR. No action needed."
    exit 0
fi

# Check if target nginx deployment exists and is ready
NGINX_READY=$(kubectl get deployment "magento-nginx-$COLOR" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
NGINX_DESIRED=$(kubectl get deployment "magento-nginx-$COLOR" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

echo "Nginx $COLOR deployment: $NGINX_READY/$NGINX_DESIRED replicas ready"

# Check if target php-fpm deployment exists and is ready
PHP_READY=$(kubectl get deployment "magento-php-fpm-$COLOR" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
PHP_DESIRED=$(kubectl get deployment "magento-php-fpm-$COLOR" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

echo "PHP-FPM $COLOR deployment: $PHP_READY/$PHP_DESIRED replicas ready"

if [ "$NGINX_READY" != "$NGINX_DESIRED" ] || [ "$NGINX_READY" = "0" ] || [ "$PHP_READY" != "$PHP_DESIRED" ] || [ "$PHP_READY" = "0" ]; then
    echo "Warning: $COLOR deployments are not fully ready!"
    read -p "Do you want to proceed anyway? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
        echo "Traffic switch cancelled."
        exit 1
    fi
fi

# Perform the switch - update both nginx and php-fpm services
echo "Patching nginx service selector to $COLOR..."
kubectl patch svc magento-svc -p "{\"spec\":{\"selector\":{\"color\":\"$COLOR\"}}}"

echo "Patching php-fpm service selector to $COLOR..."
kubectl patch svc magento-php-fpm -p "{\"spec\":{\"selector\":{\"color\":\"$COLOR\"}}}"

# Verify the switch
NEW_COLOR=$(kubectl get svc magento-svc -o jsonpath='{.spec.selector.color}')
if [ "$NEW_COLOR" = "$COLOR" ]; then
    echo "Traffic successfully switched to $COLOR!"
    echo ""
    echo "Next steps:"
    echo "  - Monitor pods: kubectl get pods -l color=$COLOR"
    echo "  - Check logs: kubectl logs -l color=$COLOR -f"
    echo "  - Rollback if needed: $0 $CURRENT_COLOR"
else
    echo "Traffic switch verification failed!"
    exit 1
fi
