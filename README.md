<div align="center">

# ☸️ Three-Tier EKS Portfolio

### Production-grade Kubernetes infrastructure built from scratch over 20 days

[![CI — Build, Test & Scan](https://img.shields.io/github/actions/workflow/status/Harshads-git/three-tier-eks-portfolio/ci.yml?branch=main&label=CI&logo=github-actions&logoColor=white&color=2ea44f)](https://github.com/Harshads-git/three-tier-eks-portfolio/actions/workflows/ci.yml)
[![CD — Deploy to EKS](https://img.shields.io/github/actions/workflow/status/Harshads-git/three-tier-eks-portfolio/cd.yml?branch=main&label=CD&logo=github-actions&logoColor=white&color=0075ca)](https://github.com/Harshads-git/three-tier-eks-portfolio/actions/workflows/cd.yml)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform&logoColor=white)](https://github.com/Harshads-git/three-tier-eks-portfolio/tree/main/terraform)
[![Kubernetes](https://img.shields.io/badge/Platform-Kubernetes%201.29-326CE5?logo=kubernetes&logoColor=white)](https://github.com/Harshads-git/three-tier-eks-portfolio/tree/main/k8s)
[![AWS](https://img.shields.io/badge/Cloud-AWS-FF9900?logo=amazon-aws&logoColor=white)](https://aws.amazon.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<br/>

**A complete three-tier web application (React + Node.js + MongoDB) deployed on Amazon EKS with full production DevOps tooling: Infrastructure as Code, GitOps CI/CD, zero-trust networking, auto-scaling, observability, and disaster recovery.**

[📋 Architecture](#-architecture) • [🚀 Quick Start](#-quick-start) • [⚙️ Tech Stack](#️-technology-stack) • [📂 Structure](#-project-structure) • [📚 Docs](#-documentation)

</div>

---

## 🎯 What Was Built

This project demonstrates **production-grade DevOps engineering** across a 20-day build — one hour per day, four meaningful commits per day.

| Layer | What | Technology |
|---|---|---|
| **Application** | React SPA + Node.js REST API + MongoDB | Docker multi-stage builds |
| **Container Registry** | Immutable image tags, lifecycle policies | Amazon ECR |
| **Orchestration** | Kubernetes on EKS, HPA, StatefulSet | Amazon EKS v1.29 |
| **Infrastructure** | VPC, subnets, nodes, IAM — 100% code | Terraform + S3/DynamoDB backend |
| **CI Pipeline** | Test → Build → Trivy scan → K8s validate | GitHub Actions |
| **CD Pipeline** | OIDC auth → ECR push → Rolling deploy | GitHub Actions + OIDC |
| **Networking** | ALB Ingress, zero-trust NetworkPolicies | AWS ALB Controller |
| **Auto-scaling** | Pod HPA (CPU 70%) + Node CA | Kubernetes HPA + Cluster Autoscaler |
| **Observability** | Metrics, dashboards, 8 alert rules | Prometheus + Grafana + AlertManager |
| **Security** | No stored credentials, IRSA, NetworkPolicy | OIDC federation, pod-level IAM |
| **Resilience** | PDB, ResourceQuota, LimitRange | Kubernetes policy resources |
| **Load Testing** | Smoke, load, stress, HPA validation | k6 |
| **Operations** | Runbook, DR plan, cost analysis | Docs + helper scripts |

---

## 🏗️ Architecture

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│                  AWS Application Load Balancer               │
│  Rules: /* → frontend:80    /api/* → backend:5000           │
└─────────────────┬───────────────────────┬────────────────────┘
                  │                       │
       ┌──────────▼─────────┐  ┌─────────▼──────────┐
       │   Frontend (Nginx)  │  │  Backend (Node.js)  │
       │   React SPA         │  │  Express REST API   │
       │   replicas: 2-5     │  │  replicas: 2-5      │
       │   HPA: CPU 70%      │  │  HPA: CPU 70%       │
       └────────────────────┘  └──────────┬───────────┘
                                          │ :27017
                               ┌──────────▼───────────┐
                               │  MongoDB StatefulSet  │
                               │  5 GiB EBS PVC       │
                               │  PDB: minAvailable=1  │
                               └──────────────────────┘
```

```
┌─────────────────────────── AWS VPC (10.0.0.0/16) ──────────────────────────┐
│                                                                             │
│  Public Subnets:  ALB  ──  NAT Gateway                                     │
│                                │                                            │
│  Private Subnets: ┌────────────────────────────────────────────────────┐   │
│                   │         EKS Worker Nodes (EC2 t3.medium)           │   │
│                   │  ┌─────────────────┐  ┌─────────────────────────┐  │   │
│                   │  │  Node AZ-1a     │  │  Node AZ-1b             │  │   │
│                   │  │  frontend pod   │  │  frontend pod           │  │   │
│                   │  │  backend pod    │  │  backend pod (HPA pods) │  │   │
│                   │  │  mongo-0 pod    │  │                         │  │   │
│                   │  └─────────────────┘  └─────────────────────────┘  │   │
│                   └────────────────────────────────────────────────────┘   │
│                                                                             │
│  ECR  ──  S3 (TF state)  ──  DynamoDB (TF lock)  ──  EKS Control Plane    │
└─────────────────────────────────────────────────────────────────────────────┘
```

> **Full Mermaid diagrams** (rendered on GitHub): [`docs/diagrams.md`](docs/diagrams.md)

---

## ⚙️ Technology Stack

### Cloud & Infrastructure
![AWS](https://img.shields.io/badge/AWS-FF9900?style=for-the-badge&logo=amazon-aws&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)
![Helm](https://img.shields.io/badge/Helm-0F1689?style=for-the-badge&logo=helm&logoColor=white)

### Application
![React](https://img.shields.io/badge/React-20232A?style=for-the-badge&logo=react&logoColor=61DAFB)
![Node.js](https://img.shields.io/badge/Node.js-339933?style=for-the-badge&logo=node.js&logoColor=white)
![MongoDB](https://img.shields.io/badge/MongoDB-4EA94B?style=for-the-badge&logo=mongodb&logoColor=white)
![Nginx](https://img.shields.io/badge/Nginx-009639?style=for-the-badge&logo=nginx&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)

### CI/CD & Security
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)
![Trivy](https://img.shields.io/badge/Trivy-1904DA?style=for-the-badge&logo=aqua-security&logoColor=white)

### Observability
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=for-the-badge&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-F46800?style=for-the-badge&logo=grafana&logoColor=white)
![k6](https://img.shields.io/badge/k6-7D64FF?style=for-the-badge&logo=k6&logoColor=white)

---

## ✨ Key Engineering Highlights

### 🔐 Zero Stored Credentials (OIDC Federation)
```
GitHub Actions ──JWT──▶ AWS STS ──validates──▶ GitHub OIDC Provider
                              └──▶ Temporary credentials (1hr TTL)
```
No `AWS_ACCESS_KEY_ID` anywhere. GitHub's OIDC JWT authenticates directly to AWS STS. The trust policy's `StringLike` condition scopes access to **this repository only**.

### 🔒 Zero-Trust Networking
```yaml
# Default: deny ALL traffic in the namespace
# Then explicitly allow only:
#   ALB → frontend (port 80)
#   frontend → backend (port 5000)
#   backend → MongoDB (port 27017)  ← frontend cannot reach MongoDB directly!
#   all pods → CoreDNS (port 53)
```

### 📈 Production-Grade Auto-Scaling
```
CPU > 70% for 15s → HPA calculates: ceil(2 × 80/70) = 3 replicas
3 pods still > 70% → HPA scales to 4, then 5 (maxReplicas)
Load drops → 5-minute stabilization window → scale down to 2
```

### 🔄 Zero-Downtime Deployments
```yaml
strategy:
  rollingUpdate:
    maxSurge: 1          # Start new pod before removing old one
    maxUnavailable: 0    # Never go below desired replicas during update
```

### 💰 Cost-Optimized Architecture
```
Portfolio mode: terraform destroy between sessions → ~$18/month
Production: always-on with Spot node group → ~$100/month
Budget alert: AWS Budgets alert at 80% of $200 threshold
```

---

## 🚀 Quick Start

### Prerequisites

```bash
# Required tools
aws --version          # AWS CLI v2
terraform --version    # Terraform 1.7.5+
kubectl version        # kubectl 1.29+
helm version           # Helm 3.14+
```

### Step 1: Clone and Configure

```bash
git clone https://github.com/Harshads-git/three-tier-eks-portfolio.git
cd three-tier-eks-portfolio

# Copy and fill in your values
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit: aws_region, cluster_name, account_id
```

### Step 2: Bootstrap Terraform Backend

```bash
# Creates S3 bucket + DynamoDB table for remote state
chmod +x scripts/setup-terraform-backend.sh
./scripts/setup-terraform-backend.sh
```

### Step 3: Provision Infrastructure

```bash
cd terraform
terraform init
terraform plan    # Review: VPC, EKS, ECR, IAM, S3
terraform apply   # ~18-20 minutes
```

### Step 4: Deploy Application

```bash
# Configure kubectl
aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1

# Apply all Kubernetes manifests
kubectl apply -f k8s/mongo/namespace.yaml
kubectl apply -f k8s/resource-quota/
kubectl apply -f k8s/network-policies/
kubectl apply -f k8s/mongo/
kubectl apply -f k8s/backend/
kubectl apply -f k8s/frontend/
kubectl apply -f k8s/pdb/

# Wait for ALB to provision (2-3 minutes)
kubectl get ingress three-tier-ingress -n three-tier -w
```

### Step 5: Set GitHub Secrets

In your fork: **Settings → Secrets and variables → Actions**

| Secret | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `ALB_DNS` | Output of: `kubectl get ingress -n three-tier -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'` |
| `TF_STATE_BUCKET` | S3 bucket name from Step 2 |
| `TF_LOCK_TABLE` | `three-tier-eks-terraform-locks` |

### Step 6: Install Monitoring (Optional)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values k8s/monitoring/prometheus-stack-values.yaml

kubectl apply -f k8s/monitoring/servicemonitors.yaml
kubectl apply -f k8s/monitoring/alerting-rules.yaml

# Access Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open: http://localhost:3000 (admin / ThreeTierPortfolio2024!)
```

### Cleanup (Save Money)

```bash
# Remove K8s resources (deletes ALB)
kubectl delete namespace three-tier

# Destroy all AWS infrastructure
cd terraform && terraform destroy
# ~15 minutes. Saves ~$163/month.
```

---

## 📂 Project Structure

```
three-tier-eks-portfolio/
│
├── 📁 app/                          # Application source code
│   ├── backend/                     # Node.js Express API
│   │   ├── Dockerfile               # Multi-stage build (node:18-alpine)
│   │   ├── server.js                # Express app, MongoDB connection
│   │   └── package.json
│   └── frontend/                    # React application
│       ├── Dockerfile               # Multi-stage: build → nginx:alpine
│       ├── nginx.conf               # SPA routing, security headers
│       └── src/                     # React components
│
├── 📁 k8s/                          # Kubernetes manifests
│   ├── mongo/                       # StatefulSet, Service, PVC, Secret
│   ├── backend/                     # Deployment, Service, HPA, ConfigMap
│   ├── frontend/                    # Deployment, Service, HPA
│   ├── ingress/                     # ALB Ingress with routing rules
│   ├── network-policies/            # Zero-trust NetworkPolicies
│   ├── pdb/                         # PodDisruptionBudgets
│   ├── resource-quota/              # ResourceQuota + LimitRange
│   └── monitoring/                  # Prometheus stack values, ServiceMonitors
│
├── 📁 terraform/                    # Infrastructure as Code
│   ├── main.tf                      # VPC module configuration
│   ├── eks.tf                       # EKS cluster + node groups
│   ├── ecr.tf                       # Container registries
│   ├── iam.tf                       # IRSA roles (GitHub, ALB, CA, EBS)
│   ├── helm.tf                      # Helm releases (ALB ctrl, CA, metrics)
│   ├── variables.tf                 # Input variables
│   ├── outputs.tf                   # Output values (ECR URLs, cluster name)
│   └── terraform.tfvars.example     # Template for your values
│
├── 📁 .github/workflows/            # CI/CD pipelines
│   ├── ci.yml                       # Test → Build → Trivy → Validate
│   ├── cd.yml                       # OIDC → ECR push → Rolling deploy
│   ├── terraform.yml                # Plan-on-PR, Apply-on-merge
│   └── load-tests.yml               # Weekly k6 performance tests
│
├── 📁 k6/load-tests/                # Performance test scripts
│   ├── smoke-test.js                # 1 VU, 1 min — sanity check
│   ├── load-test.js                 # 0→50 VU ramp — HPA validation
│   ├── stress-test.js               # 0→200 VU — breaking point
│   └── hpa-validation.js            # Baseline + trigger scenarios
│
├── 📁 scripts/                      # Operational helper scripts
│   ├── setup-terraform-backend.sh   # Bootstrap S3/DynamoDB state backend
│   └── cluster-health-check.sh     # Daily health check with color output
│
└── 📁 docs/                         # Architecture & operations documentation
    ├── architecture.md              # System design, decisions, trade-offs
    ├── diagrams.md                  # 5 Mermaid diagrams
    ├── cicd-pipeline.md             # CI/CD workflow reference
    ├── observability.md             # Prometheus/Grafana guide
    ├── security-hardening.md        # 6-layer defense model
    ├── load-testing.md              # k6 testing guide
    ├── runbook.md                   # Incident response procedures
    ├── cost-analysis.md             # AWS cost breakdown
    ├── disaster-recovery.md         # RTO/RPO, backup, restore
    └── interview-prep.md            # 12 technical Q&As
```

---

## 🔄 CI/CD Pipeline

```
┌─────────────────────────────────────────────────────────┐
│ Every Pull Request (ci.yml)                             │
│                                                         │
│  test-backend ──┐                                       │
│  test-frontend ─┤─→ build+scan ─→ validate ─→ ✅ gate  │
│  (parallel)    ─┘   (Trivy SARIF)  (kubeconform)       │
└─────────────────────────────────────────────────────────┘
         │ merge to main
         ▼
┌─────────────────────────────────────────────────────────┐
│ Every Merge (cd.yml)                                    │
│                                                         │
│  OIDC auth (no keys!) ─→ ECR push ─→ kubectl set image │
│                          (parallel)    rolling update   │
│                                        rollout status   │
└─────────────────────────────────────────────────────────┘
         │ PR to main with terraform/** changes
         ▼
┌─────────────────────────────────────────────────────────┐
│ Pull Request (terraform.yml)                            │
│                                                         │
│  terraform plan ─→ post as PR comment                  │
│  reviewer sees: "Plan: 3 to add, 0 to destroy"         │
│  merge ─→ terraform apply (auto-approve)               │
└─────────────────────────────────────────────────────────┘
```

---

## 📊 Observability

| Signal | Tool | Details |
|---|---|---|
| **Metrics** | Prometheus + Grafana | 30-day retention, 8 custom alert rules |
| **Dashboards** | Grafana | Cluster, pods, nodes, MongoDB |
| **Alerts** | AlertManager | PodCrashLooping, HighMemory, MongoDBDisk |
| **Logs** | CloudWatch Container Insights | EKS control plane + node logs |
| **Load Tests** | k6 | Weekly automated, HPA validation |

**Key alert rules:**
- 🚨 `PodCrashLooping` — >2 restarts/5min → **critical**
- 🚨 `HighMemoryUtilization` — >90% of limit → **critical** (OOMKill imminent)
- ⚠️ `HPAAtMaxReplicas` — at max replicas 15min → **warning**
- ⚠️ `MongoDBDiskRunningLow` — <20% free → **warning**

---

## 📚 Documentation

| Document | Description |
|---|---|
| [Architecture](docs/architecture.md) | System design, component inventory, design decisions |
| [Diagrams](docs/diagrams.md) | 5 Mermaid diagrams (AWS infra, CI/CD, K8s topology, IRSA, HPA) |
| [CI/CD Pipeline](docs/cicd-pipeline.md) | Workflow reference, secrets guide |
| [Observability](docs/observability.md) | Prometheus/Grafana setup, PromQL queries |
| [Security Hardening](docs/security-hardening.md) | 6-layer defense model |
| [Load Testing](docs/load-testing.md) | k6 guide, HPA scaling timeline |
| [Runbook](docs/runbook.md) | Incident response for every alert |
| [Cost Analysis](docs/cost-analysis.md) | AWS cost breakdown, optimization strategies |
| [Disaster Recovery](docs/disaster-recovery.md) | RTO/RPO targets, backup procedures |
| [Interview Prep](docs/interview-prep.md) | 12 technical Q&As with depth answers |

---

## 🏗️ Built in 20 Days

| Phase | Days | Focus |
|---|---|---|
| **Foundation** | 1–4 | App development, Dockerization, K8s manifests |
| **Networking** | 5–8 | Ingress, HPA, RBAC, SecurityContext |
| **Infrastructure** | 9–11 | Terraform VPC/EKS, IAM/IRSA, Helm operators |
| **Automation** | 12–15 | CI/CD pipelines, monitoring, load testing |
| **Operations** | 16–17 | Runbook, cost analysis, architecture docs |
| **Polish** | 18–20 | README, cleanup, final validation |

**4 commits/day × 20 days = 80 commits** of production-quality, annotated infrastructure code.

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and PR guidelines.

---

<div align="center">

**Built by [Harshad](https://github.com/Harshads-git) | Reference: [LondheShubham153/three-tier-eks-iac](https://github.com/LondheShubham153/three-tier-eks-iac)**

⭐ **Star this repo** if you found it helpful for your DevOps learning journey!

</div>
