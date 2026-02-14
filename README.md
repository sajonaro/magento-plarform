# Magento Platform - Local Development Environment

This Docker Compose setup provides a local development environment that mirrors the production infrastructure described in `decsription.md`.

## Components

### 1. **K3s (Lightweight Kubernetes)**
- Local Kubernetes cluster for testing deployments
- Accessible at `https://localhost:6443`
- Kubeconfig automatically generated in `./kubeconfig/kubeconfig.yaml`

### 2. **LocalStack (AWS Services Emulation)**
- Emulates AWS services locally
- Accessible at `http://localhost:4566`
- Pre-configured services:
  - **S3**: Media bucket, backups bucket, L2 logs bucket
  - **SQS**: FIFO queues for orders, emails, and dead-letter queue
  - **Secrets Manager**: Database and Redis credentials
  - **ECR**: Container registry (available but not pre-configured)
  - **IAM**: For IRSA simulation

### 3. **Auto-Initialization**
- Automatically creates all AWS resources mentioned in the description
- Sets up S3 buckets, SQS queues, and Secrets Manager entries on startup

## Prerequisites

- Docker Engine 20.10+
- Docker Compose 2.0+
- make (optional, for convenience commands)
- kubectl (for interacting with k3s)
- aws-cli (for testing LocalStack)

## Quick Start

### 1. Start the Environment

```bash
make up
```

This will:
- Create necessary directories
- Start LocalStack and k3s
- Initialize AWS resources in LocalStack
- Generate kubeconfig

### 2. Check Status

```bash
make status
```

### 3. Configure kubectl

```bash
export KUBECONFIG=$(pwd)/kubeconfig/kubeconfig.yaml
kubectl get nodes
```

```bash
# or simply use the shortcut (make kubectl)
make kubectl get namespaces
make kubectl get nodes
# etc..
```


### 4. Test LocalStack

```bash
# Set LocalStack environment
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-west-1

# List S3 buckets
aws s3 ls

# List SQS queues
aws sqs list-queues

# List secrets
aws secretsmanager list-secrets
```

### 5. Stop the Environment

```bash
make down
```

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make up` | Start all services (k3s + LocalStack) |
| `make down` | Stop and remove all services |
| `make restart` | Restart all services |
| `make status` | Show status of all services |
| `make logs` | Tail logs from all services |
| `make logs-k3s` | Tail logs from k3s only |
| `make logs-localstack` | Tail logs from LocalStack only |
| `make clean` | Remove all containers, volumes, and generated files |
| `make test-k8s` | Test Kubernetes cluster connectivity |
| `make test-localstack` | Test LocalStack connectivity |
| `make shell-k3s` | Open shell in k3s container |
| `make shell-localstack` | Open shell in LocalStack container |
| `make help` | Show all available commands |

## Pre-Configured AWS Resources

### S3 Buckets
- `magento-media` - Media storage
- `magento-backups` - Database and file backups
- `magento-logs-l2` - Sensitive logs (L2 tier)

### SQS Queues (FIFO)
- `magento-orders.fifo` - Order processing queue
- `magento-emails.fifo` - Email delivery queue
- `magento-dlq.fifo` - Dead-letter queue

### Secrets Manager
- `magento/db/credentials` - Database connection details
- `magento/redis/credentials` - Redis connection details

## Directory Structure

```
.
├── docker-compose.yml          # Main compose file
├── Makefile                    # Management commands
├── README.md                   # This file
├── decsription.md             # Architecture documentation
├── kubeconfig/                # Generated k3s kubeconfig
│   └── kubeconfig.yaml
├── localstack-data/           # Persistent LocalStack data
├── k3s-manifests/             # Custom k3s manifests (auto-deployed)
└── init-scripts/              # Initialization scripts
```

## Accessing Services

### Kubernetes API
```bash
export KUBECONFIG=$(pwd)/kubeconfig/kubeconfig.yaml
kubectl cluster-info
kubectl get all --all-namespaces
```

### LocalStack Dashboard
```bash
# LocalStack endpoint
curl http://localhost:4566/_localstack/health
```

### ArgoCD (After Deployment)
Once you deploy ArgoCD to the k3s cluster:
```bash
# Port-forward ArgoCD UI
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Access at: https://localhost:8080
```

## Integration with magento-platform Repository

This local environment simulates the AWS infrastructure described in `decsription.md`. To deploy the actual Magento application:

1. **Clone the magento-platform repository** (when created):
   ```bash
   git clone <magento-platform-repo-url>
   cd magento-platform
   ```

2. **Install ArgoCD in k3s**:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

3. **Configure ArgoCD to watch the repository**:
   ```bash
   kubectl apply -f argocd/app-of-apps.yaml
   ```

4. **Update overlays to use LocalStack**:
   In `overlays/dev/configmap-patch.yaml`, point to LocalStack endpoints:
   ```yaml
   AWS_ENDPOINT_URL: http://localstack:4566
   AWS_S3_ENDPOINT: http://localstack:4566
   AWS_SQS_ENDPOINT: http://localstack:4566
   ```

## Troubleshooting

### k3s not starting
```bash
# Check logs
make logs-k3s

# Restart
make restart
```

### Kubeconfig not generated
```bash
# Wait a bit longer, then regenerate
sleep 30
make kubeconfig
```

### LocalStack services not ready
```bash
# Check health
docker-compose exec localstack curl http://localhost:4566/_localstack/health

# Restart LocalStack
docker-compose restart localstack
```

### Can't connect to k3s
```bash
# Ensure kubeconfig is set
export KUBECONFIG=$(pwd)/kubeconfig/kubeconfig.yaml

# Test connectivity
kubectl get nodes
```

## Production vs Local Differences

| Component | Production (AWS) | Local (This Setup) |
|-----------|------------------|---------------------|
| Kubernetes | EKS | k3s |
| S3 | AWS S3 | LocalStack S3 |
| SQS | AWS SQS | LocalStack SQS |
| Secrets | AWS Secrets Manager | LocalStack Secrets Manager |
| RDS | AWS RDS MySQL | Not included (use in-cluster MySQL or external) |
| ElastiCache | AWS ElastiCache Redis | Not included (use in-cluster Redis) |
| ECR | AWS ECR | LocalStack ECR or local registry |

## Next Steps

1. Deploy supporting services (Redis, OpenSearch, Varnish) to k3s
2. Deploy External Secrets Operator pointing to LocalStack
3. Deploy Alloy, Loki, Grafana for logging
4. Set up ArgoCD for GitOps workflow
5. Deploy Magento application workloads

## Clean Up

To completely remove everything:
```bash
make clean
```

This removes:
- All containers
- All volumes (k3s data, LocalStack data)
- Generated kubeconfig

## Support

For issues related to:
- **Architecture**: See `decsription.md`
- **Docker Compose**: Check `docker-compose.yml`
- **Makefile commands**: Run `make help`