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
| **Terraform / OpenTofu** | AWS infrastructure provisioning | Industry standard IaC, modular, state-managed |
| **GitLab CI** | CI pipeline | Already in use, handles build/test/image-push jobs |
| **External Secrets Operator** | Secrets sync from AWS Secrets Manager | Production-grade, audit trails, GitOps-compatible |

---

## 2. Repository Structure

Three repositories with clear separation of concerns:

| Repository | Contents | Change Frequency |
|------------|----------|-----------------|
| **magento-app** | Application code, Dockerfile, `.gitlab-ci.yml`, `composer.json` | Every code change |
| **magento-platform** | Kubernetes manifests, Kustomize overlays, ArgoCD config, monitoring config, helper scripts | Every deployment |
| **magento-staging-infrastructure** | Terraform/OpenTofu definitions for all AWS resources (VPC, EKS, RDS, S3, SQS, etc.) | Rarely — infrastructure changes only |

The naming is deliberate:

- `magento-platform` — the single source of truth for everything that runs **inside** the Kubernetes cluster: application workloads, supporting services, monitoring, and ArgoCD itself. It defines the platform, not the infrastructure underneath it.
- `magento-staging-infrastructure` — makes clear this is the staging environment's foundation. Production would be a separate repo or environment folder.

---

## 3. AWS Infrastructure

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

## 4. EKS Cluster Configuration

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

## 5. Namespace Strategy

| Namespace | Purpose |
|-----------|---------|
| `stage` | Staging deployments — blue + green slots for Magento |
| `argocd` | ArgoCD operator and its components |
| `monitoring` | Alloy (log collector), Loki, Grafana, External Secrets Operator |

Namespaces are organizational labels. They don't create network or filesystem boundaries. A DaemonSet in the `monitoring` namespace still runs pods on every node, including nodes hosting `stage` pods.

---

## 6. Magento Application Deployments

The application is split into three separate Kubernetes Deployments (not sidecar containers in one pod) for independent scaling and fault isolation:

### magento-web Deployment

- **Containers**: Nginx + PHP-FPM (two containers in the same pod).
- **Purpose**: Handles all HTTP requests.
- **Scaling**: Memory-heavy. Scale up on traffic peaks (e.g., Black Friday might need 10 replicas).

### magento-cron Deployment

- **Container**: Single container running `bin/magento cron:run`.
- **Purpose**: Magento scheduled tasks (indexing, email queue, cache cleanup).
- **Scaling**: Typically 1 replica.

### magento-consumer Deployment

- **Container**: Single container running `bin/magento queue:consumers:start`.
- **Purpose**: Long-running PHP process that listens for SQS messages (order processing, inventory updates, email sending).
- **Scaling**: CPU-heavy. Scale independently from web pods (Black Friday might need 10 web pods but only 2 consumer pods).

All three use the **same Docker image** — they differ only in the entrypoint command. This keeps the image build pipeline simple: one image, multiple deployment manifests.

### Additional Kubernetes Resources

| Resource | Purpose |
|----------|---------|
| **Service** (`magento-svc`) | Routes traffic to blue or green pods via label selector |
| **Ingress** | Routing rules for the ALB (e.g., `stage.yourdomain.com`) |
| **HPA** (Horizontal Pod Autoscaler) | Auto-scales web pods based on CPU/memory metrics |
| **PDB** (Pod Disruption Budget) | Prevents Kubernetes from killing too many pods during node maintenance |
| **ConfigMaps** | Non-secret configuration: PHP settings, Nginx config |
| **ExternalSecrets** | Tells External Secrets Operator what to pull from AWS Secrets Manager |

---

## 7. Blue/Green Deployment Mechanism

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

## 8. ArgoCD — GitOps Engine

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

## 9. Kustomize Overlays

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

## 10. In-Cluster Supporting Services

These run **inside the cluster for stage/dev only** to save cost. In production, use AWS managed equivalents (ElastiCache, CloudFront, Amazon OpenSearch).

| Service | K8s Resource Type | Purpose | Production Equivalent |
|---------|-------------------|---------|----------------------|
| **Varnish** | Deployment + Service + ConfigMap (VCL) | Full-page cache for Magento | CloudFront or managed Varnish |
| **Redis** | Deployment + Service | Session storage + backend cache | ElastiCache Redis |
| **OpenSearch** | StatefulSet + Service | Magento catalog search | Amazon OpenSearch Service |

These are single-replica, non-HA deployments. If stage Redis restarts for 30 seconds, nobody loses money. The tradeoff is cost vs. fidelity — some teams prefer managed services for stage to catch configuration-specific issues.

---

## 11. Logging Architecture

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

## 12. Secrets Management

Uses **External Secrets Operator** (ESO) pointing to **AWS Secrets Manager**.

How it works: ESO runs in the cluster and watches `ExternalSecret` custom resources. Each resource says "pull secret X from AWS Secrets Manager and create a Kubernetes Secret from it." The operator syncs periodically.

This is GitOps-compatible — the `ExternalSecret` YAML files are committed to Git (they contain no actual secret values, only references). The real secrets live in AWS Secrets Manager, which provides audit trails and rotation.

Secrets managed:

- Database credentials (RDS).
- Third-party API keys (payment gateways, shipping, email).
- Internal service tokens.

---

## 13. Networking & Ingress

### Traffic Flow

```
User → Cloudflare (DNS, CDN, WAF, SSL) → ALB (in public subnet) → Kubernetes Ingress → Service → Pods
```

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **Cloudflare** | External | DNS resolution, CDN caching, WAF protection, SSL termination |
| **ALB** | Public subnet | L7 load balancer, managed by AWS Load Balancer Controller based on Kubernetes Ingress resources |
| **Ingress** | Kubernetes resource | Routing rules (e.g., `stage.yourdomain.com` → `magento-svc`) |
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

## 14. CI/CD Pipeline Workflow

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

---

## 15. magento-platform Repository — Layout & Bootstrapping

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

#### Step 4: Install ArgoCD in the cluster (one-time)

Before ArgoCD can watch this repo, it needs to be installed in the cluster. This is typically done via Helm or plain manifests, run once manually:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Then configure ArgoCD to authenticate with your GitLab repo (SSH key or deploy token).

#### Step 5: Apply the app-of-apps

Point ArgoCD at the `argocd/` folder. From this point on, ArgoCD manages itself and everything else from Git:

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

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
│       └── ingress-patch.yaml                   #   stage.yourdomain.com
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

## How deployments work

1. GitLab CI (in `magento-app`) builds a Docker image and pushes to ECR.
2. CI updates the image tag in `overlays/stage/kustomization.yaml` and commits here.
3. ArgoCD detects the commit, deploys the new version to the green slot.
4. After QA verification, a manual CI job switches the service selector (blue↔green).

## Related repositories

| Repo | Contents |
|------|----------|
| `magento-app` | Application code, Dockerfile, `.gitlab-ci.yml` |
| `magento-staging-infrastructure` | Terraform/OpenTofu — VPC, EKS, RDS, S3, SQS, IAM |
```

---

## 16. Terraform Infrastructure Repository Layout

```
magento-staging-infrastructure/
│
├── modules/
│   ├── vpc/
│   │   ├── main.tf                          # VPC, public/private subnets, route tables
│   │   ├── nat.tf                           # NAT Gateway
│   │   ├── endpoints.tf                     # VPC endpoints for S3, ECR, SQS, Secrets Manager
│   │   └── variables.tf
│   │
│   ├── eks/
│   │   ├── main.tf                          # EKS cluster, managed node groups
│   │   ├── addons.tf                        # AWS LB Controller, EBS CSI Driver, CoreDNS, Metrics Server
│   │   ├── irsa.tf                          # IAM roles for service accounts (Alloy, Magento, ArgoCD)
│   │   └── variables.tf
│   │
│   ├── rds/
│   │   ├── main.tf                          # MySQL instance, Multi-AZ, parameter groups
│   │   ├── snapshots.tf                     # Golden snapshot management
│   │   ├── security_groups.tf               # Allow access only from EKS nodes
│   │   └── variables.tf
│   │
│   ├── elasticache/
│   │   ├── main.tf                          # Redis cluster mode (for prod)
│   │   ├── security_groups.tf
│   │   └── variables.tf
│   │
│   ├── s3/
│   │   ├── main.tf                          # Media bucket, backups bucket, L2 logs bucket
│   │   ├── lifecycle.tf                     # L2 logs: 90 days → Glacier, 1 year retention
│   │   ├── encryption.tf                    # SSE-KMS for L2 logs bucket
│   │   └── variables.tf
│   │
│   ├── sqs/
│   │   ├── main.tf                          # FIFO queues, dead-letter queues
│   │   └── variables.tf
│   │
│   ├── ecr/
│   │   ├── main.tf                          # Container registry, lifecycle policy to clean old images
│   │   └── variables.tf
│   │
│   ├── secrets_manager/
│   │   ├── main.tf                          # DB credentials, API keys, third-party tokens
│   │   └── variables.tf
│   │
│   ├── iam/
│   │   ├── main.tf                          # IRSA roles, CI/CD service account
│   │   ├── policies.tf                      # Fine-grained policies per service
│   │   └── variables.tf
│   │
│   └── cloudflare/
│       ├── main.tf                          # DNS records, WAF rules, SSL settings
│       └── variables.tf
│
├── environments/
│   └── stage/
│       ├── main.tf                          # Calls modules with stage-sized params
│       ├── terraform.tfvars                 # Small instance sizes, fewer nodes
│       └── backend.tf                       # S3 state bucket + DynamoDB lock
│
└── global/
    ├── main.tf                              # Shared across environments
    ├── ecr.tf                               # One registry shared by all environments
    ├── terraform_state.tf                   # S3 bucket and DynamoDB table for state
    └── iam_ci.tf                            # GitLab CI service account with deploy permissions
```

---

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