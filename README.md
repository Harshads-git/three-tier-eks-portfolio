<div align="center">

# ⚔️ CloudForge EKS Platform

### Production-Grade Cloud Native Platform on AWS EKS
**GitOps (ArgoCD) • Canary Rollouts (Argo Rollouts) • Zero-Trust Governance (Kyverno, Cosign) • Terraform IaC**

[![CI — Build, Test & Scan](https://img.shields.io/github/actions/workflow/status/Harshads-git/three-tier-eks-portfolio/ci.yml?branch=main&label=CI&logo=github-actions&logoColor=white&color=2ea44f)](https://github.com/Harshads-git/three-tier-eks-portfolio/actions/workflows/ci.yml)
[![CD — Deploy to EKS](https://img.shields.io/github/actions/workflow/status/Harshads-git/three-tier-eks-portfolio/cd.yml?branch=main&label=CD&logo=github-actions&logoColor=white&color=0075ca)](https://github.com/Harshads-git/three-tier-eks-portfolio/actions/workflows/cd.yml)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform&logoColor=white)](https://github.com/Harshads-git/three-tier-eks-portfolio/tree/main/terraform)
[![Kubernetes](https://img.shields.io/badge/Platform-Kubernetes%201.29-326CE5?logo=kubernetes&logoColor=white)](https://github.com/Harshads-git/three-tier-eks-portfolio/tree/main/k8s)
[![AWS](https://img.shields.io/badge/Cloud-AWS-FF9900?logo=amazon-aws&logoColor=white)](https://aws.amazon.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<br/>

**CloudForge EKS** is an enterprise-grade cloud-native platform hosting a full three-tier web application (React + Node.js Express + MongoDB) deployed on Amazon EKS. Built from the ground up to demonstrate production platform engineering: automated GitOps continuous reconciliation, zero-downtime canary rollouts with Prometheus analysis, cryptographically attested supply-chain security (Sigstore Cosign & CycloneDX SBOM), dynamic secret synchronization via AWS Secrets Manager & IRSA, shift-left policy admission control (Kyverno), and automated disaster recovery.

[📋 Architecture](#-architecture) • [🚀 Quick Start](#-quick-start) • [⚙️ Tech Stack](#️-technology-stack) • [📂 Structure](#-project-structure) • [📚 Docs](#-documentation)

</div>

---

## 🎯 What Was Built

**CloudForge EKS** demonstrates **production-grade platform engineering** across a structured 30-day curriculum — 4 meaningful, architecture-first commits per day.

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
# Option A: Automated apply script (ordered dependencies + status wait)
chmod +x scripts/k8s-apply.sh
./scripts/k8s-apply.sh

# Option B: Via Makefile
make k8s-apply

# Option C: Manual kubectl apply in order
aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1
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
│   ├── rollouts/                    # Argo Rollouts Canary & AnalysisTemplates
│   ├── external-secrets/            # External Secrets Operator & AWS Secrets Manager sync
│   ├── kyverno/                     # Kyverno Admission Controller & ClusterPolicies
│   ├── karpenter/                   # Karpenter v1 NodePool & EC2NodeClass specs
│   ├── chaos/                       # Chaos Mesh operator & Pod/NetworkChaos experiments
│   ├── backup/                      # Velero backup storage locations & daily schedules
│   ├── network-policies/            # Zero-trust NetworkPolicies
│   ├── pdb/                         # PodDisruptionBudgets
│   ├── resource-quota/              # ResourceQuota + LimitRange
│   └── monitoring/                  # Prometheus stack, ServiceMonitors
│       ├── opentelemetry/           # OpenTelemetry Collector deployment & pipeline
│       └── jaeger/                  # Jaeger distributed trace store & query UI
│
├── 📁 terraform/                    # Infrastructure as Code
│   ├── main.tf                      # VPC module configuration
│   ├── eks.tf                       # EKS cluster + node groups
│   ├── ecr.tf                       # Container registries
│   ├── iam.tf                       # IRSA roles (GitHub, ALB, CA, EBS)
│   ├── karpenter.tf                 # Karpenter IRSA, SQS interruption queue, Node Role
│   ├── velero.tf                    # S3 backup bucket, lifecycle & Velero IRSA role
│   ├── helm.tf                      # Helm releases (ALB ctrl, CA, metrics)
│   ├── variables.tf                 # Input variables
│   ├── outputs.tf                   # Output values (ECR URLs, cluster name)
│   └── terraform.tfvars.example     # Template for your values
│
├── 📁 .github/workflows/            # CI/CD pipelines
│   ├── ci.yml                       # Test → Build → Trivy → Validate
│   ├── cd.yml                       # OIDC → ECR push → Rolling deploy
│   ├── terraform.yml                # Plan-on-PR, Apply-on-merge
│   ├── load-tests.yml               # Weekly k6 performance tests
│   └── supply-chain.yml             # Cosign keyless signing & Syft SBOM generation
│
├── 📁 k6/load-tests/                # Performance test scripts
│   ├── smoke-test.js                # 1 VU, 1 min — sanity check
│   ├── load-test.js                 # 0→50 VU ramp — HPA validation
│   ├── stress-test.js               # 0→200 VU — breaking point
│   └── hpa-validation.js            # Baseline + trigger scenarios
│
├── 📁 scripts/                      # Operational helper scripts
│   ├── setup-terraform-backend.sh   # Bootstrap S3/DynamoDB state backend
│   ├── cluster-health-check.sh     # Daily health check with color output
│   ├── k8s-apply.sh                # Ordered manifest deployment with readiness checks
│   ├── seed-aws-secrets.sh         # Idempotent AWS Secrets Manager seeding
│   ├── generate-sbom.sh            # Syft CycloneDX and SPDX SBOM generator
│   ├── run-chaos-experiment.sh     # Automated Chaos Mesh test harness & metric audit
│   └── disaster-recovery-drill.sh  # Automated Velero disaster recovery drill & RTO scorecard
│
├── 📁 gitops/                       # ArgoCD GitOps control plane
│   ├── root-application.yaml        # App-of-Apps master bootstrap manifest
│   ├── argocd/                      # ArgoCD Helm values, Kustomize, project RBAC
│   └── apps/                        # Child Application CRDs (mongo, backend, frontend, ingress)
│
├── 📁 docs/                         # Architecture & operations documentation
│   ├── architecture.md              # System design, decisions, trade-offs
│   ├── diagrams.md                  # 5 Mermaid diagrams
│   ├── cicd-pipeline.md             # CI/CD workflow reference
│   ├── observability.md             # Prometheus/Grafana guide
│   ├── security-hardening.md        # 6-layer defense model
│   ├── load-testing.md              # k6 testing guide
│   ├── runbook.md                   # Incident response procedures
│   ├── cost-analysis.md             # AWS cost breakdown
│   ├── disaster-recovery.md         # RTO/RPO, backup, restore
│   ├── validation-checklist.md      # End-to-end verification checklist
│   ├── retrospective.md             # 20-day project retrospective & lessons learned
│   ├── gitops-argocd.md             # Declarative continuous delivery guide
│   ├── canary-deployments.md        # Progressive Canary delivery with Argo Rollouts
│   ├── secrets-management.md        # Dynamic secret synchronization via IRSA
│   ├── policy-as-code.md            # Shift-left admission control policies & compliance
│   ├── supply-chain-security.md     # Sigstore Cosign signing, SBOM & attestations
│   ├── karpenter-autoscaling.md     # Next-gen just-in-time node provisioning & Spot consolidation
│   ├── distributed-tracing.md       # Request waterfalls & profiling via OpenTelemetry & Jaeger
│   └── interview-prep.md            # 12 technical Q&As
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
| [Validation Checklist](docs/validation-checklist.md) | Step-by-step verification commands & expected outputs |
| [Retrospective](docs/retrospective.md) | 20-day project retrospective, key decisions, production gap analysis |
| [GitOps (ArgoCD)](docs/gitops-argocd.md) | Declarative App-of-Apps continuous delivery & self-healing |
| [Canary Deployments](docs/canary-deployments.md) | Progressive delivery with Argo Rollouts & Prometheus analysis |
| [Secrets Management (ESO)](docs/secrets-management.md) | Dynamic secret synchronization via AWS Secrets Manager & IRSA |
| [Policy as Code (Kyverno)](docs/policy-as-code.md) | Shift-left admission control policies & compliance guardrails |
| [Supply Chain Security](docs/supply-chain-security.md) | Sigstore keyless signing, CycloneDX SBOM & Kyverno admission gates |
| [Karpenter Autoscaling](docs/karpenter-autoscaling.md) | Next-gen just-in-time node provisioning & Spot consolidation |
| [Distributed Tracing](docs/distributed-tracing.md) | Request waterfalls & profiling via OpenTelemetry & Jaeger |
| [Chaos Engineering](docs/chaos-experiments.md) | Chaos Mesh fault injection, PDB resilience & failure recovery audit |
| [Backup & Disaster Recovery](docs/backup-and-recovery.md) | Enterprise Velero state replication, EBS snapshots & RTO/RPO SLAs |
| [Interview Prep](docs/interview-prep.md) | 12 technical Q&As with depth answers |

---

## 🏗️ 30-Day Platform Roadmap

| Phase | Days | Focus & Deliverables | Status |
|---|---|---|---|
| **Foundation** | 1–4 | Scaffold, React SPA, Node.js API, MongoDB, Docker multi-stage | ✅ Done |
| **Networking & Security** | 5–8 | Namespace, Services, StatefulSet, Ingress ALB, RBAC, SecurityContext | ✅ Done |
| **IaC Infrastructure** | 9–11 | Terraform VPC, EKS cluster, IAM/IRSA, EBS CSI, Load Balancer Controller | ✅ Done |
| **Automation & Tests** | 12–15 | GitHub Actions (CI/CD/TF), NetworkPolicies, Prometheus/Grafana, k6 suite | ✅ Done |
| **Operations & SRE** | 16–17 | Runbook, Cost Analysis, Health Checks, Disaster Recovery, Diagrams | ✅ Done |
| **Showcase & DX** | 18–20 | Master README, Makefile, .pre-commit, `k8s-apply.sh`, Validation & Retrospective | ✅ Done |
| **Advanced GitOps & Secrets**| 21–23 | ArgoCD App-of-Apps, Canary Rollouts, External Secrets Operator | ✅ Done |
| **Enterprise Governance & Scaling**| 24–26 | Kyverno Policy-as-Code, Cosign Image Signing, SBOM, Karpenter v1 | ✅ Done |
| **Observability & Resilience** | 27–30 | OpenTelemetry Distributed Tracing, Chaos Testing, Velero Backup | 🔄 In Progress |

**4 commits/day with architecture-first commit bodies explaining the WHY.**

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and PR guidelines.

---

<div align="center">

**Built by [Harshad](https://github.com/Harshads-git) | Reference: [LondheShubham153/three-tier-eks-iac](https://github.com/LondheShubham153/three-tier-eks-iac)**

⭐ **Star this repo** if you found it helpful for your DevOps learning journey!

</div>
