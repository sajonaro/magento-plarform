# Magento Hello World E-Commerce App

A simple e-commerce "Hello World" application that demonstrates Kubernetes deployment with Blue/Green strategy.

## 📦 What's Included

- **index.php** - Main e-commerce storefront with 6 sample products
- **health_check.php** - Health check endpoint for Kubernetes probes
- **Dockerfile** - Container image definition (PHP 8.1 + Nginx)
- **build.sh** - Script to build the Docker image
- **deploy.sh** - Automated deployment script to Kubernetes cluster

## 🚀 Quick Start

### 1. Build the Docker Image

```bash
cd magento-app
./build.sh
```

This creates a Docker image called `magento-hello-world:latest`.

### 2. Test Locally (Optional)

```bash
docker run -p 8080:80 magento-hello-world:latest
```

Then open http://localhost:8080 in your browser.

### 3. Deploy to Kubernetes Cluster

**Prerequisites**: Make sure the K3s cluster is running:
```bash
cd ..
make up
```

**Deploy the app**:
```bash
cd magento-app
./deploy.sh
```

The deployment script will:
- ✅ Build the Docker image
- ✅ Load it into the K3s cluster
- ✅ Update the cluster configuration
- ✅ Deploy to the `stage` namespace
- ✅ Wait for pods to be ready

### 4. Access the Application

**Option 1: Port Forward (Recommended)**
```bash
export KUBECONFIG=$(pwd)/../kubeconfig/kubeconfig.yaml
kubectl port-forward -n stage svc/magento-svc 8080:80
```
Then open: http://localhost:8080

**Option 2: Direct K3s Access**

If you've configured K3s port 80, you can access directly at http://localhost

## 🎨 Features

- **6 Sample Products**: Gaming Laptop, Smartphone, Headphones, etc.
- **Shopping Cart**: Add items to cart (client-side demo)
- **Cluster Info Display**: Shows pod name, PHP version, server time
- **Responsive Design**: Mobile-friendly layout
- **Health Check Endpoint**: `/health_check.php` for Kubernetes probes

## 🔄 Blue/Green Deployment Testing

The app is deployed with both blue and green versions. Switch between them:

```bash
export KUBECONFIG=$(pwd)/../kubeconfig/kubeconfig.yaml

# Check current version
kubectl get svc magento-svc -n stage -o jsonpath='{.spec.selector.color}'

# Switch to green
kubectl patch svc magento-svc -n stage -p '{"spec":{"selector":{"color":"green"}}}'

# Switch back to blue
kubectl patch svc magento-svc -n stage -p '{"spec":{"selector":{"color":"blue"}}}'
```

## 📊 Monitoring

**Check pod status**:
```bash
kubectl get pods -n stage
```

**View logs**:
```bash
kubectl logs -n stage -l component=web -f
```

**Check services**:
```bash
kubectl get svc -n stage
```

## 🧹 Cleanup

**Remove the deployment**:
```bash
kubectl delete -k ../cluster/overlays/stage
```

**Stop the cluster**:
```bash
cd ..
make down
```

## 🛠️ Technical Stack

- **PHP 8.1** - Application runtime
- **Nginx** - Web server
- **Alpine Linux** - Base image (lightweight)
- **Kubernetes** - Orchestration platform
- **Kustomize** - Configuration management

## 📝 How It Works

1. **Dockerfile** creates a container with:
   - PHP-FPM running on port 9000
   - Nginx running on port 80
   - Both services started via `/start.sh`

2. **deploy.sh** script:
   - Builds the Docker image
   - Imports it into K3s using `ctr images import`
   - Updates Kustomize configuration
   - Deploys using `kubectl apply -k`

3. **Kubernetes resources** deployed:
   - 2 Deployments (blue + green)
   - 3 Services (main + blue + green)
   - HPAs, PDBs, ConfigMaps, Ingresses

## 🔗 Related Documentation

- Main cluster definition: `../cluster/README.md`
- Test results: `../cluster/TEST_RESULTS.md`
- Architecture overview: `../decsription.md`

## 💡 Tips

- The pod name changes each time you deploy - watch the "Deployment Information" section on the web page
- You can see which pod is serving your request by refreshing the page
- Test blue/green switching by opening multiple browser tabs and switching colors

## 🎯 Next Steps

- Add a real database (MySQL/PostgreSQL)
- Implement Redis for session management
- Add product images
- Create API endpoints
- Implement user authentication
- Connect to SQS queues for order processing