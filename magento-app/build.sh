#!/bin/bash

set -e

echo "🔨 Building Magento Hello World Docker image..."

# Build the image
docker build -t magento-hello-world:latest .

echo "✅ Image built successfully!"
echo ""
echo "Image: magento-hello-world:latest"
echo ""
echo "To test locally:"
echo "  docker run -p 8080:80 magento-hello-world:latest"
echo ""
echo "To deploy to cluster:"
echo "  ./deploy.sh"