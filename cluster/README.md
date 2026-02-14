# Magento Platform - Kubernetes Cluster Definition

This directory contains the complete Kubernetes cluster configuration for the Magento e-commerce platform. It is designed to be deployed via **ArgoCD** using a **GitOps** approach with **blue/green deployments**.

## 📁 Directory Structure

```
cluster/
├── base/                    # Shared Kubernetes manifests (all environments)
│   ├── kustomization.yaml
│   ├── magento-web-deployment-blue.yaml
│   ├── magento-web-deployment-green.yaml
│   ├── magento-cron-deployment.yaml
│   ├── magento-consumer-deployment.yaml
│   ├── magento-service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── pdb.yaml
│   ├── configmaps.yaml
│   └── external-secrets.yaml
│
├── overlays/               # Environment-specific customizations
│   ├── dev/
│   │   └── kustomization.yaml
│   └── stage/
│       └── kustomization.yaml
│
├── services/              # Supporting services (non-production)
│   ├── varnish/
│   ├── redis/
│   └── opensearch/
│
├── monitoring/            # Observability stack
│   ├── alloy/
│   ├── loki/
│   └── grafana/
│
├── argocd/               # ArgoCD Application definitions
│   ├── app-stage.yaml
│   └── app-of-apps.yaml
│
└── scripts/              # Helper scripts
    ├── switch-traffic.sh
    └── refresh-db.sh
```

## 🎯 Key Concepts

### Blue/Green Deployments

Traffic switching is handled by changing the **Service selector** between `color: blue` and `color: green`. No DNS changes, no downtime.

**Current State:**
- `magento-svc` → Routes to the **active** deployment (check `selector.color` in `base/magento-service.yaml`)
- `magento-svc-blue` → Always routes to blue pods (for testing)
- `magento-svc-green` → Always routes to green pods (for testing)

**Deployment Flow:**
1. Deploy new version to the **inactive** color (e.g., green)
2. Test via `magento-svc-green` service
3. Switch traffic by changing `magento-svc` selector to `color: green`
4. Rollback instantly by switching back to `color: blue`

### Three-Deployment Architecture

All three use the **same Docker image**, different entrypoints:

| Deployment | Purpose | Scaling | Command |
|------------|---------|---------|---------|
| **magento-web** | HTTP requests (Nginx + PHP-FPM) | Memory-heavy, auto-scales | `php-fpm` |
| **magento-cron** | Scheduled tasks | 1 replica | `bin/magento cron:run` |
| **magento-consumer** | SQS queue processing | CPU-heavy, auto-scales | `bin/magento queue:consumers:start` |

### Kustomize Overlays

Base manifests are **shared across environments**. Overlays apply environment-specific patches:

- **Image tags** → Updated by CI pipeline
- **Replica counts** → Dev: 1, Stage: 2, Prod: 5+
- **Resource limits** → Smaller in dev, larger in prod
- **Hostnames** → `stage.example.com`, `prod.example.com`

## 🚀 Quick Start (Local Testing with K3s + LocalStack)

### 1. Start Local Environment

From the project root:

```bash
make up
```

### 2. Create Namespace

```bash
make kubectl create namespace stage

```


### 3. Deploy to K3s

```bash
make kubectl apply -k cluster/overlays/stage

#which would be equivalent to
export KUBECONFIG=$(pwd)/kubeconfig/kubeconfig.yaml && kubectl delete -k cluster/overlays/stage 2>/dev/null || true && kubectl apply -k cluster/overlays/stage
```

### 4. Verify Deployment

```bash
make kubectl get pods -n stage
make kubectl get svc -n stage
make kubectl get ingress -n stage

#or directly 
export KUBECONFIG=$(pwd)/kubeconfig/kubeconfig.yaml && echo "=== Services ===" && kubectl get svc -n stage && echo -e "\n=== Ingresses ===" && kubectl get ingress -n stage && echo -e "\n=== HPAs ===" && kubectl get hpa -n stage && echo -e "\n=== PDBs ===" && kubectl get pdb -n stage


```

### 5. Test Blue/Green Switch

```bash
# Check current traffic destination
make kubectl get svc magento-svc -n stage -o jsonpath='{.spec.selector.color}'

# Switch to green
make kubectl patch svc magento-svc -n stage -p '{"spec":{"selector":{"color":"green"}}}'

# Switch back to blue
make kubectl patch svc magento-svc -n stage -p '{"spec":{"selector":{"color":"blue"}}}'
```

## 🔐 Secrets Management

Uses **External Secrets Operator** syncing from **AWS Secrets Manager** (or LocalStack in dev).

Required secrets:
- `magento/db/credentials` → Database connection
- `magento/redis/credentials` → Redis connection
- `magento/sqs/credentials` → SQS queue URLs

## 📊 Monitoring & Logging

### Two-Tier Logging

| Tier | Content | Destination | Retention |
|------|---------|-------------|-----------|
| **L1** | General logs (HTTP, PHP errors, cron) | Loki / Grafana | 30 days |
| **L2** | Sensitive (payments, admin, PII) | S3 bucket (encrypted) | 1 year |

**Alloy DaemonSet** routes logs based on channel labels configured in Magento.

## 🛠️ Configuration Files

### Base Manifests

- **Deployments**: Blue, Green, Cron, Consumer
- **Services**: Main service (traffic switch), dedicated blue/green services
- **Ingress**: ALB routing, separate endpoints for blue/green testing
- **HPA**: Auto-scaling for web and consumer pods
- **PDB**: Prevents too many pods from being killed during maintenance
- **ConfigMaps**: PHP settings, Nginx config, Magento env vars
- **ExternalSecrets**: References to AWS Secrets Manager

### Stage Overlay

- Sets namespace to `stage`
- Configures image tag (updated by CI)
- Patches replica counts to 2
- Sets memory limits to 1Gi
- Configures IRSA role ARN
- Points to LocalStack endpoints for local dev

## 📝 CI/CD Integration

### Image Tag Updates

GitLab CI updates the image tag in `overlays/stage/kustomization.yaml`:

```bash
cd cluster/overlays/stage
kustomize edit set image magento=123456789.dkr.ecr.../magento:v1.2.3
git commit -am "deploy v1.2.3 to stage"
git push
```

ArgoCD detects the change and deploys automatically.

### Traffic Switching

Use the helper script:

```bash
./cluster/scripts/switch-traffic.sh blue  # Switch to blue
./cluster/scripts/switch-traffic.sh green # Switch to green
```

## 🔄 Deployment Workflow

### 1. Initial Deployment

```bash
# Blue is live by default
kubectl apply -k cluster/overlays/stage
```

### 2. Deploy New Version to Green

```bash
# CI pipeline updates image tag for green deployment
# ArgoCD syncs and deploys green pods
# Blue continues serving traffic
```

### 3. Test Green

```bash
# Access via dedicated green service
curl http://magento-green.stage.example.com
```

### 4. Switch Traffic

```bash
./cluster/scripts/switch-traffic.sh green
# Traffic instantly flows to green
# Blue remains running for rollback
```

### 5. Rollback (if needed)

```bash
./cluster/scripts/switch-traffic.sh blue
# Instant rollback, no rebuild needed
```

## 🎯 Resource Requirements

### Stage Environment (per deployment)

| Component | Replicas | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|----------|-------------|----------------|-----------|--------------|
| Web (Blue) | 2-10 (HPA) | 250m | 512Mi | 1000m | 1Gi |
| Web (Green) | 2-10 (HPA) | 250m | 512Mi | 1000m | 1Gi |
| Cron | 1 | 100m | 256Mi | 500m | 512Mi |
| Consumer | 2-8 (HPA) | 250m | 512Mi | 1000m | 1Gi |

### Total (Active + Standby)

- **Min**: ~3 GB RAM, ~1.5 CPU cores
- **Max (during scale-up)**: ~20 GB RAM, ~18 CPU cores

## 📚 Related Documentation

- **Architecture Overview**: See `../decsription.md`
- **Local Development**: See `../README.md`
- **ArgoCD Setup**: See `argocd/README.md`
- **Terraform Infrastructure**: Separate `magento-staging-infrastructure` repository

## 🐛 Troubleshooting

### Pods Not Starting

```bash
make kubectl describe pod <pod-name> -n stage
make kubectl logs <pod-name> -n stage -c php-fpm
```

### Image Pull Errors

```bash
# Check ECR credentials
make kubectl get secrets -n stage
make kubectl describe sa magento -n stage
```

### Service Not Routing Traffic

```bash
# Check selector matches pod labels
make kubectl get svc magento-svc -n stage -o yaml
make kubectl get pods -n stage --show-labels
```

### HPA Not Scaling

```bash
# Check metrics-server is running
make kubectl get deployment metrics-server -n kube-system
make kubectl top pods -n stage
```

## 🔗 Useful Commands

```bash
# Watch pod status
make kubectl get pods -n stage -w

# Port-forward to test locally
make kubectl port-forward -n stage svc/magento-svc 8080:80

# Check HPA status
make kubectl get hpa -n stage

# View pod logs
make kubectl logs -n stage -l component=web -f

# Execute command in pod
make kubectl exec -it -n stage <pod-name> -c php-fpm -- bash

# Restart deployment
make kubectl rollout restart deployment/magento-web-blue -n stage
```

## 📄 License

This configuration is part of the Magento platform infrastructure project.