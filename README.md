# Magento E-Commerce Platform — Kubernetes & Infrastructure Configuration

## Table of Contents

1. [Design Decisions](#1-design-decisions)
2. [Repository Structure](#2-repository-structure)
3. [AWS Infrastructure (magento-staging-infrastructure)](#3-aws-infrastructure)
4. [EKS Cluster Configuration](#4-eks-cluster-configuration)
5. [Namespace Strategy](#5-namespace-strategy)
6. [Magento Application Deployments](#6-magento-application-deployments)
7. [Blue/Green Deployment Mechanism](#7-bluegreen-deployment-mechanism)
8. [ArgoCD — GitOps Engine](#8-argocd--gitops-engine)
9. [Kustomize Overlays](#9-kustomize-overlays)
10. [In-Cluster Supporting Services](#10-in-cluster-supporting-services)
11. [Logging Architecture (Alloy + Loki + Grafana)](#11-logging-architecture)
12. [Secrets Management](#12-secrets-management)
13. [Networking & Ingress](#13-networking--ingress)
14. [CI/CD Pipeline Workflow](#14-cicd-pipeline-workflow)
15. [magento-platform Repository — Layout & Bootstrapping](#15-magento-platform-repository--layout--bootstrapping)
16. [Terraform Infrastructure Repository Layout](#16-terraform-infrastructure-repository-layout)

---

## 1. Design Decisions

### Container-Based Deployment (Not Code Branch)

All deployments use immutable Docker images rather than deploying from code branches directly. Rationale:

- **Immutable artifacts** — what you test is exactly what you deploy; no environment drift.
- **Trivial rollbacks** — point to a previous image tag instead of reverting code.
- **Fits Kubernetes natively** — pods pull a tagged image, no build-on-deploy.
- **Encapsulates dependencies** — Magento's PHP extensions, Composer packages, Nginx config are all baked in.

The deployment flow: `code commit → build Docker image → push to ECR → update image tag in cluster config repo → ArgoCD syncs`.

### GitOps Approach

All cluster state is defined declaratively in Git. No manual `kubectl apply`. Changes to what runs in the cluster happen by committing to the configuration repository. ArgoCD watches the repo and reconciles the cluster to match.

### Manual Deployment Triggers (No Continuous Deployment)

Propagation to staging is triggered manually. The CI pipeline builds and tests automatically, but promoting a build to the staging environment requires a deliberate human action. This provides a controlled, audit-trailed deployment process.

### Tooling Choices

| Tool | Purpose | Why |
|------|---------|-----|
| **ArgoCD** | GitOps deployment engine | Free, CNCF graduated, watches Git and reconciles K8s state |
| **Kustomize** | Manifest templating per environment | Simpler than Helm, native to kubectl, no template syntax — just YAML patches |
| **Terraform (terragrunt)** | AWS infrastructure provisioning | Industry standard IaC, modular, state-managed |
| **GitLab CI** | CI pipeline | Already in use, handles build/test/image-push jobs |
| **External Secrets Operator** | Secrets sync from AWS Secrets Manager | Production-grade, audit trails, GitOps-compatible |

---


## 2. AWS Infrastructure

### AWS Services Summary

| Category | Service | Purpose |
|----------|---------|---------|
| Compute | **EKS** | Kubernetes runtime |
| Database | **RDS MySQL** | Magento DB (golden snapshot for stage) |
| Cache | **ElastiCache Redis** (prod) / in-cluster (stage) | Sessions + backend cache |
| Storage | **S3** | Media bucket, backups bucket, L2 sensitive logs bucket |
| Storage | **EFS** (optional) | Shared filesystem if S3 adapter is insufficient |
| Registry | **ECR** | Container image registry |
| Messaging | **SQS FIFO** | Communication with related microservices, dead-letter queues |
| Networking | **ALB** (via AWS LB Controller) | L7 ingress into EKS |
| Networking | **NAT Gateway** | Outbound internet from private subnets (payment gateways, shipping APIs) |
| Networking | **VPC Endpoints** | Private paths to S3, ECR, SQS, Secrets Manager (no internet needed) |
| DNS/CDN | **Cloudflare** (external) | DNS, CDN, WAF, SSL termination |
| Secrets | **AWS Secrets Manager** | DB credentials, API keys, third-party tokens |
| IaC State | **S3 + DynamoDB** | Terraform state storage and locking |
| IAM | **IRSA** | Per-pod AWS permissions via IAM Roles for Service Accounts |

### VPC Design

- Multi-AZ deployment across at least 2 availability zones.
- **Public subnets**: ALB, NAT Gateway.
- **Private subnets**: EKS worker nodes, RDS, ElastiCache — no direct internet exposure.
- **VPC Endpoints** for S3, ECR, SQS, and Secrets Manager to keep AWS-to-AWS traffic off the internet and reduce NAT Gateway costs.

### NAT Gateway

Required because pods in private subnets need outbound internet access for:

- Magento connecting to third-party payment gateways (Stripe, PayPal).
- Webhook calls to external services.
- Shipping API integrations, email services.

VPC endpoints handle AWS-internal traffic (S3, ECR, SQS, Secrets Manager), so NAT is only needed for truly external calls. NAT charges per GB processed, so minimize its usage via VPC endpoints.

### IRSA (IAM Roles for Service Accounts)

IRSA connects a Kubernetes service account to an AWS IAM role, enabling per-pod permissions without hardcoded credentials.

How it works: when a pod starts, Kubernetes injects a short-lived token. The AWS SDK exchanges this token for temporary credentials automatically. No keys stored anywhere, credentials rotate on their own.

IRSA roles in this setup:

| Service Account | IAM Role | Permissions |
|----------------|----------|-------------|
| `alloy` | `alloy-role` | `s3:PutObject` on L2 logs bucket |
| `magento` | `magento-role` | `sqs:SendMessage` / `sqs:ReceiveMessage`, `s3:GetObject` / `s3:PutObject` on media bucket |
| `argocd` | `argocd-role` | ECR pull, read access to cluster config |
| `external-secrets` | `external-secrets-role` | `secretsmanager:GetSecretValue` |

---

## 3. EKS Cluster Configuration

### Managed Node Groups

EKS uses managed node groups — AWS handles the EC2 instances, patching, and scaling. Node groups are defined in Terraform.

### EKS Add-ons (Installed via Terraform)

| Add-on | Purpose |
|--------|---------|
| **AWS Load Balancer Controller** | Creates and manages ALB based on Kubernetes Ingress resources |
| **EBS CSI Driver** | Enables persistent volumes backed by EBS |
| **CoreDNS** | In-cluster DNS resolution |
| **Metrics Server** | Pod resource metrics for HPA (Horizontal Pod Autoscaler) |

---

## 4. Namespace Strategy

| Namespace | Purpose |
|-----------|------------|
| `stage` | Staging deployments — blue + green slots for Magento |
| `argocd` | ArgoCD operator and its components |
| `monitoring` | Alloy (log collector), Loki, Grafana, External Secrets Operator |

Namespaces are organizational labels. They don't create network or filesystem boundaries. A DaemonSet in the `monitoring` namespace still runs pods on every node, including nodes hosting `stage` pods.

---

## 5. Magento Application Deployments

The application is split into four separate Kubernetes Deployments for independent scaling and fault isolation:

### magento-nginx Deployment

- **Container**: Nginx only
- **Purpose**: HTTP termination, static file serving, reverse proxy to PHP-FPM
- **Scaling**: Lightweight, connection/throughput-based (3-10 replicas based on network load)
- **Resources**: 64Mi-128Mi RAM per pod

### magento-php-fpm Deployment

- **Container**: PHP-FPM only
- **Purpose**: PHP request processing
- **Scaling**: Memory and CPU-heavy. Scale up on traffic peaks (e.g., Black Friday might need 15-20 replicas)
- **Resources**: 512Mi-2Gi RAM per pod
- **Service**: Internal ClusterIP service on port 9000 for nginx to connect

### magento-cron Deployment

- **Container**: Single container running `bin/magento cron:run`.
- **Purpose**: Magento scheduled tasks (indexing, email queue, cache cleanup).
- **Scaling**: Typically 1 replica.

### magento-consumer Deployment

- **Container**: Single container running `bin/magento queue:consumers:start`.
- **Purpose**: Long-running PHP process that listens for SQS messages (order processing, inventory updates, email sending).
- **Scaling**: CPU-heavy. Scale independently from web pods (Black Friday might need 10 PHP-FPM pods but only 2 consumer pods).

The nginx and php-fpm deployments use separate Docker images built from `Dockerfile.nginx` and `Dockerfile.php-fpm`. The cron and consumer deployments use the same image as php-fpm but with different entrypoint commands. This separation enables:
- Independent scaling of web tier (nginx) vs application tier (PHP-FPM)
- Fault isolation (PHP crash doesn't kill nginx)
- Optimized resource allocation per component
- Separate update and rollback strategies

### Additional Kubernetes Resources

| Resource | Purpose |
|----------|---------|
| **Service** (`magento-svc`) | Routes traffic to blue or green nginx pods via label selector |
| **Service** (`magento-php-fpm`) | Internal service routing nginx to blue or green PHP-FPM pods |
| **Ingress** | Routing rules for the ALB (e.g., `stage.flowers.ua`) |
| **HPA** (Horizontal Pod Autoscaler) | Auto-scales nginx and PHP-FPM pods based on CPU/memory metrics |
| **PDB** (Pod Disruption Budget) | Prevents Kubernetes from killing too many pods during node maintenance |
| **ConfigMaps** | Non-secret configuration: PHP settings, Nginx config |
| **ExternalSecrets** | Tells External Secrets Operator what to pull from AWS Secrets Manager |

---

## 6. Blue/Green Deployment Mechanism

### How It Works

The traffic switching mechanism uses **Kubernetes label selectors**. It requires no DNS changes, no load balancer reconfiguration, no restarts.

**Blue Deployment** — pods labeled `color: blue`.
**Green Deployment** — pods labeled `color: green`.
**Service** (`magento-svc`) — has a selector `color: blue` (or `color: green`).

Kubernetes constantly watches all pods and maintains a list of pod IPs matching the selector. Traffic is forwarded only to matching pods.

### Deployment Flow (Alternating Pattern)

1. **Initial state**: Blue is live, serving traffic. Service selector: `color: blue`.
2. **Deploy new version to green**: CI pipeline updates the green deployment's image tag in the cluster config repo. ArgoCD syncs — green pods start with the new version.
3. **Verify green**: Green is accessible at a separate URL (e.g., `stage-green.domain.com`). QA tests here. Blue still serves all main traffic.
4. **Switch traffic** (manual trigger): CI job updates the service selector from `color: blue` to `color: green` in Git. ArgoCD applies it. Traffic instantly flows to green.
5. **Rollback ready**: Blue pods stay running (idle). If green has issues, flip the selector back to `color: blue`. Takes seconds — no rebuild needed.
6. **Next deployment**: Targets blue (the current standby). Colors alternate each time.

### Why Alternating (Not Relabeling)

The alternating pattern avoids modifying or destroying the known-good deployment. If you relabeled green to blue and sunset the old blue, you'd have a moment where the new version restarts and the old is gone — no fallback. With alternating, both versions stay running; you only change a pointer.

**Recommendation**: Keep the inactive color running for 24-48 hours after a switch. If no issues, scale it down to save resources.

---

## 7. ArgoCD — GitOps Engine

### What ArgoCD Does

ArgoCD watches the `magento-platform` Git repository. When it detects a new commit (e.g., an image tag change), it compares the desired state in Git with what's actually running in the cluster, then reconciles — updating pods, services, etc. to match.

### ArgoCD Lives in the Cluster Config Repo

ArgoCD's own configuration lives in the `argocd/` folder of `magento-platform`. This is the **"app of apps" pattern** — ArgoCD watches its own config folder and manages itself.

### ArgoCD Application CRDs

Each ArgoCD Application is a YAML file that says "watch this folder in this repo, deploy it to this namespace."

```yaml
# argocd/app-stage.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: magento-stage
  namespace: argocd
spec:
  source:
    repoURL: https://gitlab.com/your-org/magento-platform.git
    path: overlays/stage
  destination:
    server: https://kubernetes.default.svc
    namespace: stage
  syncPolicy:
    # Manual sync — ArgoCD detects drift but waits for manual approval
    # or automated: automated: { prune: true, selfHeal: true }
```

### ArgoCD Application Definitions

| Application File | Watches | Deploys To |
|-------------------|---------|------------|
| `app-stage.yaml` | `overlays/stage/` | `stage` namespace |
| `app-services.yaml` | `services/` | `stage` namespace (in-cluster Varnish, Redis, OpenSearch) |
| `app-monitoring.yaml` | `monitoring/` | `monitoring` namespace |
| `app-of-apps.yaml` | `argocd/` folder itself | `argocd` namespace (self-management) |

### ArgoCD Components (in `argocd` namespace)

| Component | K8s Resource Type | Purpose |
|-----------|-------------------|---------|
| ArgoCD Server | Deployment | Web UI + API, watches the Git repo |
| App Controller | Deployment | Sync manager, reconciles desired vs actual state |

---

## 8. Kustomize Overlays

### What They Are

Kustomize overlays are **environment-specific customization layers**. They sit on top of a shared base and override specific values (image tag, replica count, resource limits) without duplicating the full manifest files.

("Kustomize" = customize with a K. "Overlay" = a layer placed on top of the base to override values.)

### How They Work

```
base/                          ← Full deployment specs (shared across environments)
overlays/
  stage/
    kustomization.yaml         ← "Use base, but change these things for stage"
  dev/
    kustomization.yaml         ← "Use base, but change these things for dev"
```

### Example Stage Overlay

```yaml
# overlays/stage/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

# CI pipeline updates this image tag in step 2:
images:
  - name: magento
    newName: 123456789.dkr.ecr.eu-west-1.amazonaws.com/magento
    newTag: feature-xyz-abc1234

patches:
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: magento-blue
      spec:
        replicas: 2
        template:
          spec:
            containers:
              - name: php-fpm
                resources:
                  limits:
                    memory: "1Gi"
```

### What the CI Pipeline Does

When promoting a build to stage, the GitLab CI job runs:

```bash
cd magento-platform/overlays/stage
kustomize edit set image magento=123456789.dkr.ecr.../magento:feature-xyz-abc1234
git commit -am "deploy feature-xyz-abc1234 to stage"
git push
```

ArgoCD detects the commit, sees the new image tag, and deploys accordingly.

---

## 9. In-Cluster Supporting Services

These run **inside the cluster for stage/dev only** to save cost. In production, use AWS managed equivalents (ElastiCache, CloudFront, Amazon OpenSearch).

| Service | K8s Resource Type | Purpose | Production Equivalent |
|---------|-------------------|---------|----------------------|
| **Varnish** | Deployment + Service + ConfigMap (VCL) | Full-page cache for Magento | CloudFront or managed Varnish |
| **Redis** | Deployment + Service | Session storage + backend cache | ElastiCache Redis |
| **OpenSearch** | StatefulSet + Service | Magento catalog search | Amazon OpenSearch Service |

These are single-replica, non-HA deployments. If stage Redis restarts for 30 seconds, nobody loses money. The tradeoff is cost vs. fidelity — some teams prefer managed services for stage to catch configuration-specific issues.

---

## 10. Logging Architecture

### Two-Tier Logging (L1 / L2)

| Tier | Sensitivity | Destination | Retention | Access |
|------|-------------|-------------|-----------|--------|
| **L1** | General application logs (HTTP access, PHP errors, cron output, system logs) | Loki (or remote Grafana via Alloy push) | 30 days | All developers |
| **L2** | Sensitive logs (payment/checkout events, admin actions, customer PII-adjacent, DB migration logs, auth/session events) | S3 bucket (SSE-KMS encrypted, restricted IAM, VPC endpoint only) | 1 year, then Glacier after 90 days | Authorized personnel only |

### Log Collection Chain

```
Container stdout/stderr
    → Node disk (/var/log/pods/...)        [automatic by Kubernetes]
    → Alloy reads from disk                [DaemonSet, one per node, hostPath volume mount]
    → Alloy classifies by channel label    [pipeline rules in Alloy config]
    → L1 goes to Loki (or remote Grafana) [via Loki remote_write or push]
    → L2 goes to S3                        [via VPC endpoint, authenticated by IRSA]
```

### Who Decides What's L1 vs L2?

Two pieces work together:

1. **The Magento application** tags sensitive log entries with a channel label (e.g., `channel=payment`, `channel=admin_auth`, `channel=customer_pii`). Configured in Magento's `env.php` or a custom Monolog handler.
2. **Alloy (the log scraper)** routes based on those labels. Its config contains a pipeline rule: if `channel=payment|admin_auth|customer_pii`, send to S3. Everything else goes to Loki.

### Alloy Configuration (Conceptual)

```
// Discover and tail all pod logs on this node
loki.source.kubernetes "pods" {
  targets = discovery.kubernetes.pods.targets
}

// Route based on labels
loki.process "classifier" {
  stage.match {
    selector = '{channel=~"payment|admin_auth|customer_pii"}'
    loki.write "s3_sink" { ... }    // L2: send to S3
  }
  loki.write "loki_sink" { ... }    // L1: everything else to Loki
}
```

### Alloy DaemonSet

A DaemonSet guarantees exactly one Alloy pod runs on every node (EC2 instance). If you have 5 nodes, you get 5 Alloy pods. If a 6th node is added, Kubernetes automatically places an Alloy pod on it.

The DaemonSet lives in the `monitoring` namespace but its pods run on every node, reading logs from all containers regardless of namespace (logs are just files on the node's disk — namespaces don't create filesystem boundaries).

### Grafana (Remote Setup)

If Grafana already exists in a separate datacenter, the recommended approach is **Option C: Push instead of pull**. Alloy pushes L1 logs directly to the remote Grafana's Loki instance via `remote_write`. This eliminates the need for Loki inside the cluster. L2 logs still go to S3 separately.

Alternatively, run a lightweight in-cluster Grafana for real-time operational dashboards, and use the remote Grafana for long-term analytics.

### Monitoring Namespace Components

| Component | K8s Resource Type | Purpose |
|-----------|-------------------|---------|
| Alloy | DaemonSet | Log collector, L1/L2 classification and routing |
| Loki | StatefulSet | L1 log storage (30-day retention) — optional if pushing to remote Grafana |
| Grafana | Deployment | Dashboards + alerts — optional if using remote Grafana |
| External Secrets Operator | Deployment | Syncs secrets from AWS Secrets Manager into K8s secrets |

---

## 11. Secrets Management

Uses **External Secrets Operator** (ESO) pointing to **AWS Secrets Manager**.

How it works: ESO runs in the cluster and watches `ExternalSecret` custom resources. Each resource says "pull secret X from AWS Secrets Manager and create a Kubernetes Secret from it." The operator syncs periodically.

This is GitOps-compatible — the `ExternalSecret` YAML files are committed to Git (they contain no actual secret values, only references). The real secrets live in AWS Secrets Manager, which provides audit trails and rotation.

Secrets managed:

- Database credentials (RDS).
- Third-party API keys (payment gateways, shipping, email).
- Internal service tokens.

---

## 12. Networking & Ingress

### Traffic Flow

```
User → Cloudflare (DNS, CDN, WAF, SSL) → ALB (in public subnet) → Kubernetes Ingress → Service → Pods
```

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **Cloudflare** | External | DNS resolution, CDN caching, WAF protection, SSL termination |
| **ALB** | Public subnet | L7 load balancer, managed by AWS Load Balancer Controller based on Kubernetes Ingress resources |
| **Ingress** | Kubernetes resource | Routing rules (e.g., `stage.flowers.ua` → `magento-svc`) |
| **Service** (`magento-svc`) | Kubernetes resource | Internal load balancer, routes to blue or green pods via label selector |
| **NAT Gateway** | Public subnet | Outbound internet for pods in private subnets |
| **VPC Endpoints** | Private network | Private paths to S3, ECR, SQS, Secrets Manager |

### ECR Image Tagging Strategy

Images are tagged with branch name and commit hash:

- `magento:main-abc1234`
- `magento:feature-xyz-abc1234`
- `magento:stage-latest` (mutable convenience tag)

ECR lifecycle policies clean old images automatically.

---

## 13. CI/CD Pipeline Workflow

### Dev Environment (Fully Automated)

1. Developer pushes code to `magento-app`, any branch.
2. GitLab CI automatically builds Docker image, runs tests.
3. Image pushed to ECR.
4. CI updates `magento-platform` overlays/dev with new image tag.
5. ArgoCD deploys to dev namespace automatically.

### Stage Environment (Manual Triggers, Blue/Green)

1. Developer is happy with dev testing. Manually triggers **"promote to stage"** job.
2. GitLab CI builds (or reuses) the image, pushes to ECR.
3. CI commits the new image tag to `magento-platform` overlays/stage (green slot).
4. ArgoCD detects the change, deploys green pods with new version.
5. Blue still serves all main traffic. Green is accessible at a separate URL for QA.
6. QA verifies green. Manually triggers **"switch traffic"** job.
7. CI commits service selector change (`color: blue` → `color: green`) to the cluster config repo.
8. ArgoCD applies — traffic instantly flows to green.
9. Blue pods remain running as standby for instant rollback.

### Rollback (Manual Trigger)

A dedicated **"rollback"** job flips the service selector back to the previous color. No rebuild needed — the old pods are still running. Takes seconds.

### Database Management

- **Golden snapshot**: RDS snapshot used to create fresh stage databases. A helper script (`refresh-stage-db.sh`) recreates the stage DB from this snapshot.
- **Migrations**: Handled by Magento itself (`bin/magento setup:upgrade`). Runs as part of the deployment process.

### GitLab CI Jobs Detail

Two repositories use GitLab CI:

#### magento-app Repository Jobs

**Purpose:** Build and test application code, push Docker images to ECR.

| Job | Trigger | Stage | Action |
|-----|---------|-------|--------|
| `build` | Automatic | `build` | Build `magento-nginx` and `magento-php-fpm` images, tag as `${BRANCH}-${SHA}`, push to ECR |
| `test` | Automatic | `test` | Run PHPUnit, static analysis, Magento compilation check |
| `auto-deploy-to-dev` | Automatic (feature branches) | `promote` | Clone `magento-platform`, update `overlays/dev/kustomization.yaml`, commit, push |
| `promote-to-stage` | **Manual** (main branch) | `promote` | Clone `magento-platform`, update `overlays/stage/kustomization.yaml` (green slot), commit, push |

**Required GitLab CI Variables:**
- `AWS_ACCOUNT_ID`, `AWS_REGION` - For ECR access
- `GITLAB_TOKEN` - To push to magento-platform repo

#### magento-platform Repository Jobs

**Purpose:** Validate manifests, bootstrap clusters, manage traffic switching, database operations.

| Job | Trigger | Stage | Action |
|-----|---------|-------|--------|
| `validate-manifests` | Automatic | `validate` | Run `kubectl --dry-run` and `kustomize build` on all overlays |
| `bootstrap-cluster` | **Manual** (one-time) | `bootstrap` | Install ArgoCD, deploy ArgoCD Application for the environment |
| `update-image-tag` | **Manual** | `ops` | Update `overlays/default/kustomization.yaml` with new image tag (parameter: `IMAGE_TAG`), commit to Git |
| `switch-traffic-to-green-staging` | **Manual** | `switch` | Run `scripts/switch-traffic.sh green`, commit selector changes (staging cluster) |
| `switch-traffic-to-blue-staging` | **Manual** | `switch` | Run `scripts/switch-traffic.sh blue` (rollback staging cluster) |
| `switch-traffic-to-green-production` | **Manual** | `switch` | Run `scripts/switch-traffic.sh green` (production cluster) |
| `switch-traffic-to-blue-production` | **Manual** | `switch` | Run `scripts/switch-traffic.sh blue` (rollback production cluster) |
| `scale-down-inactive-staging` | **Manual** | `ops` | Scale inactive deployment to 0 replicas in staging (run after 24-48h) |
| `scale-down-inactive-production` | **Manual** | `ops` | Scale inactive deployment to 0 replicas in production (run after 24-48h) |

**Required GitLab CI Variables:**
- `KUBECONFIG_STAGING` (base64-encoded) - Staging cluster access
- `KUBECONFIG_PRODUCTION` (base64-encoded) - Production cluster access
- `GITLAB_TOKEN` - To commit changes back to repo

**Bootstrap Job Details:**

The `bootstrap-cluster` job is a one-time setup job run after creating a fresh EKS cluster. It:
1. Installs ArgoCD in the cluster
2. Deploys the ArgoCD Application that watches the Git repository
3. Enables GitOps automation for all future deployments

**Variables:**
- `KUBECONFIG` - Defaults to `$KUBECONFIG_STAGING`, override with `$KUBECONFIG_PRODUCTION` for production
- `ENVIRONMENT` - Defaults to `staging`, set to `production` for production cluster

**Usage:**
- For staging: Trigger job with defaults (no variable overrides needed)
- For production: Override variables when triggering: `KUBECONFIG=$KUBECONFIG_PRODUCTION` and `ENVIRONMENT=production`

**Script:** Executes `cluster/scripts/bootstrap-cluster.sh [staging|production]`

---

## 14. magento-platform Repository — Layout & Bootstrapping

### Purpose

This repository is the **single source of truth for everything running inside the Kubernetes cluster**. ArgoCD watches it and reconciles the cluster to match. Every change to what runs in the cluster — a new deployment, an image tag update, a config change, a traffic switch — is a Git commit to this repo.

It does **not** create the cluster or AWS resources (that's `magento-staging-infrastructure`). It assumes the cluster already exists and defines what goes inside it.

### Bootstrapping the Repository

#### Step 1: Create the GitLab repo

```bash
git init magento-platform
cd magento-platform
```

#### Step 2: Create the directory structure

```bash
mkdir -p base
mkdir -p overlays/dev overlays/stage
mkdir -p services/varnish services/redis services/opensearch
mkdir -p monitoring
mkdir -p argocd
mkdir -p scripts
```

#### Step 3: Populate in this order

The recommended order for creating files (each step builds on the previous):

1. **`base/`** — Start here. Define the core Magento workloads (deployments, services, ingress). These are the shared manifests that all environments inherit from.
2. **`overlays/stage/`** — Create the stage-specific patches (image tag, replica count, resource limits, ingress hostname). This is what ArgoCD will watch for the staging environment.
3. **`services/`** — Add the in-cluster supporting services (Varnish, Redis, OpenSearch). These are cheap alternatives to managed AWS services for non-production environments.
4. **`monitoring/`** — Add Alloy DaemonSet, Loki, Grafana (or just Alloy if pushing to remote Grafana). Add the External Secrets Operator deployment.
5. **`argocd/`** — Create ArgoCD Application CRDs that point to each of the above folders. This is what tells ArgoCD what to watch and where to deploy.
6. **`scripts/`** — Add helper scripts for traffic switching and DB refresh.

#### Step 4: Bootstrap the cluster (one-time automated setup)

After creating the EKS cluster and adding its kubeconfig to GitLab CI variables, bootstrap it using the GitLab CI job:

1. **Export cluster kubeconfig:**
```bash
# For staging cluster
kubectl config view --raw | base64 -w 0
# Add to GitLab: Settings → CI/CD → Variables → KUBECONFIG_STAGING
```

2. **Trigger bootstrap job:**
   - Go to **CI/CD → Pipelines → Run Pipeline**
   - Select `bootstrap-cluster` job
   - For staging: Run with defaults (no variable overrides)
   - For production: Set `KUBECONFIG=$KUBECONFIG_PRODUCTION` and `ENVIRONMENT=production`

3. **What the bootstrap job does:**
   - Installs ArgoCD in the cluster
   - Deploys the ArgoCD Application for the environment
   - ArgoCD then automatically deploys all Magento components

**Alternative (manual bootstrap):**

If you prefer manual setup:

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Deploy ArgoCD Application
kubectl apply -f argocd/app-staging.yaml  # For staging
# or
kubectl apply -f argocd/app-production.yaml  # For production
```

**Note:** The GitLab CI bootstrap job is the recommended approach as it's automated, auditable, and repeatable.

### Full Directory Layout

```
magento-platform/
│
├── base/                                        # Shared Kubernetes manifests (all environments inherit from here)
│   ├── kustomization.yaml                       #   Kustomize entrypoint — lists all resources in this folder
│   ├── magento-web-deployment.yaml              #   Blue: Nginx + PHP-FPM pod spec
│   ├── magento-web-deployment-green.yaml        #   Green: identical spec, different color label
│   ├── magento-cron-deployment.yaml             #   Cron scheduler (same image, different entrypoint)
│   ├── magento-consumer-deployment.yaml         #   SQS queue consumer (same image, different entrypoint)
│   ├── magento-service.yaml                     #   Service with selector: color=blue (this is the traffic switch)
│   ├── ingress.yaml                             #   ALB routing rules
│   ├── hpa.yaml                                 #   Horizontal Pod Autoscaler for web pods
│   ├── pdb.yaml                                 #   Pod Disruption Budget
│   ├── configmaps.yaml                          #   Non-secret config: PHP settings, Nginx config
│   └── external-secrets.yaml                    #   References to AWS Secrets Manager entries
│
├── overlays/                                    # Per-environment customization layers
│   ├── dev/
│   │   └── kustomization.yaml                   #   Dev: image tag, 1 replica, small resources
│   └── stage/
│       ├── kustomization.yaml                   #   Stage: image tag, 2+ replicas, medium resources
│       ├── configmap-patch.yaml                 #   Stage-specific Magento env config (DB host, Redis host, etc.)
│       └── ingress-patch.yaml                   #   stage.flowers.ua
│
├── services/                                    # In-cluster supporting services (stage/dev only, saves cost)
│   ├── varnish/
│   │   ├── deployment.yaml                      #   Single-replica Varnish for full-page caching
│   │   ├── service.yaml                         #   ClusterIP service
│   │   └── configmap.yaml                       #   VCL configuration
│   ├── redis/
│   │   ├── deployment.yaml                      #   Single-replica Redis for sessions + cache
│   │   └── service.yaml
│   └── opensearch/
│       ├── statefulset.yaml                     #   Single-replica OpenSearch for catalog search
│       └── service.yaml
│
├── monitoring/                                  # Observability stack
│   ├── alloy-daemonset.yaml                     #   Log collector — one pod per node, L1/L2 routing
│   ├── alloy-configmap.yaml                     #   Alloy pipeline config (classification rules, destinations)
│   ├── loki-statefulset.yaml                    #   Optional: in-cluster Loki for L1 logs
│   ├── grafana-deployment.yaml                  #   Optional: in-cluster Grafana dashboards
│   └── external-secrets-operator.yaml           #   ESO deployment — syncs AWS Secrets Manager → K8s Secrets
│
├── argocd/                                      # ArgoCD Application definitions (app-of-apps pattern)
│   ├── app-stage.yaml                           #   Watches overlays/stage → deploys to stage namespace
│   ├── app-services.yaml                        #   Watches services/ → deploys to stage namespace
│   ├── app-monitoring.yaml                      #   Watches monitoring/ → deploys to monitoring namespace
│   └── app-of-apps.yaml                         #   Watches this argocd/ folder → self-management
│
└── scripts/                                     # Helper scripts called by GitLab CI jobs
    ├── switch-traffic.sh                        #   Flip service selector blue↔green, commit, push
    └── refresh-stage-db.sh                      #   Recreate stage DB from golden RDS snapshot
```

### Suggested README.md for the Repository

The following can be used as the `README.md` at the root of `magento-platform`:

```markdown
# magento-platform

Kubernetes cluster configuration for the Magento e-commerce platform.
Managed by ArgoCD via GitOps — every commit to this repo is
automatically reconciled into the cluster.

## What this repo contains

| Folder | Purpose |
|--------|---------|
| `base/` | Shared K8s manifests: Magento web/cron/consumer deployments, services, ingress, autoscaling |
| `overlays/` | Per-environment patches: image tags, replica counts, resource limits |
| `services/` | In-cluster Varnish, Redis, OpenSearch (non-production only) |
| `monitoring/` | Alloy log collector, Loki, Grafana, External Secrets Operator |
| `argocd/` | ArgoCD Application definitions (app-of-apps self-management) |
| `scripts/` | Blue/green traffic switching, DB refresh from golden snapshot |

## How deployments work: Complete Workflow Example

**Scenario:** Developer deploys a new payment gateway feature to staging

1. **Developer** → `magento-app` repository
   - Pushes feature branch `feature/stripe-integration`
   - Tool: Git

2. **GitLab CI** → `magento-app` repository → **Automatic**
   - Job: `build`
   - Action: Builds nginx + php-fpm images, tags as `feature-stripe-integration-a1b2c3d`, pushes to ECR

3. **GitLab CI** → `magento-app` repository → **Automatic**
   - Job: `test`
   - Action: Runs PHPUnit tests and static analysis

4. **Developer** → `magento-app` repository
   - Creates Pull Request, gets approval, merges to `main`
   - Tool: GitLab UI

5. **GitLab CI** → `magento-app` repository → **Automatic**
   - Job: `build` (on main branch)
   - Action: Rebuilds images with tag `main-e4f5g6h`, pushes to ECR

6. **Developer/DevOps** → `magento-platform` repository → **MANUAL ACTION**
   - **Clicks** `update-stage-image` manual job button in GitLab UI
   - **Provides parameter:** `IMAGE_TAG=main-e4f5g6h`
   - Tool: GitLab UI

7. **GitLab CI** → `magento-platform` repository → **Automatic**
   - Job: `update-stage-image` script
   - Action: Updates `overlays/stage/kustomization.yaml` with `newTag: main-e4f5g6h`, commits and pushes to Git

8. **ArgoCD** → `magento-platform` repository → **Automatic**
   - Detects new commit (polls every 3 minutes)
   - Action: Syncs cluster state, deploys green pods with image `magento-php-fpm:main-e4f5g6h` (nginx uses standard `nginx:1.24-alpine`)

9. **ArgoCD** → Kubernetes cluster → **Automatic**
   - Green pods start running alongside blue pods
   - Blue still serves all traffic at `stage.flowers.ua`
   - Green accessible at `stage-green.flowers.ua` for testing

10. **QA Engineer** → Browser → **Manual Testing**
    - Tests new payment gateway feature on green deployment
    - URL: `stage-green.flowers.ua`

11. **DevOps** → `magento-platform` repository → **MANUAL ACTION**
    - **Clicks** `switch-traffic-to-green` manual job button
    - Tool: GitLab UI

12. **GitLab CI** → `magento-platform` repository → **Automatic**
    - Job: `switch-traffic-to-green` script
    - Action: Runs `scripts/switch-traffic.sh green stage`, patches `magento-svc` and `magento-php-fpm` services with selector `color: green`

13. **ArgoCD** → Kubernetes cluster → **Automatic**
    - Detects service selector changes, applies them
    - Traffic instantly switches from blue to green

14. **End Users** → Browser
    - Now automatically hitting green deployment at `stage.flowers.ua`
    - No downtime, instant traffic switch

15. **DevOps** → Monitoring
    - Monitors green deployment for 24-48 hours
    - Blue pods remain running for instant rollback if needed

16. **DevOps** → `magento-platform` repository → **MANUAL ACTION** (after 24-48h)
    - **Clicks** `scale-down-inactive` manual job button
    - Tool: GitLab UI

17. **GitLab CI** → Kubernetes cluster → **Automatic**
    - Job: `scale-down-inactive` script
    - Action: Detects active color, scales inactive deployment to 0 replicas (both nginx and php-fpm)
    - Blue pods terminated to save resources (~$100-200/month savings)

**Emergency Rollback (before cleanup):** DevOps clicks `switch-traffic-to-blue` job → traffic reverts to blue in seconds (no rebuild)

**Rollback (after cleanup):** Redeploy to inactive color first (2-3 min), then switch traffic

**Key Takeaways:**
- **Two repositories:** `magento-app` (application code) and `magento-platform` (Kubernetes config)
- **Three manual gates:** Merge PR, promote to stage, switch traffic
- **ArgoCD automates:** All Kubernetes state changes based on Git commits
- **No direct kubectl:** All changes via Git + GitLab CI + ArgoCD

## Related repositories

| Repo | Contents |
|------|----------|
| `magento-app` | Application code, Dockerfile, `.gitlab-ci.yml` |
| `magento-infrastructure` | Terraform/Terragrunt — VPC, EKS, RDS, S3, SQS, IAM |
```



## Glossary

| Term | Plain English |
|------|---------------|
| **ArgoCD Application CRD** | A YAML file that tells ArgoCD "watch this folder, deploy to this namespace" |
| **App of Apps pattern** | ArgoCD watching its own config folder — it manages itself |
| **DaemonSet** | Guarantees exactly one pod per node (used for Alloy log collection) |
| **Deployment** | Says "run N copies of this pod somewhere in the cluster" |
| **StatefulSet** | Like Deployment but with stable storage and identities (used for Loki, OpenSearch) |
| **HPA** | Horizontal Pod Autoscaler — auto-scales pods based on CPU/memory metrics |
| **PDB** | Pod Disruption Budget — prevents K8s from killing too many pods during maintenance |
| **IRSA** | IAM Roles for Service Accounts — per-pod AWS permissions, no hardcoded keys |
| **Kustomize overlay** | Environment-specific customization layer on top of shared base manifests |
| **VPC Endpoint** | Private network path to AWS services, stays within AWS, no internet needed |
| **ExternalSecret** | K8s resource telling ESO what to pull from AWS Secrets Manager |
| **Golden snapshot** | RDS database snapshot used to create fresh stage databases |