# 🚀 Three-Tier Application on AWS EKS — Portfolio Project

[![CI Status](https://github.com/Harshads-git/three-tier-eks-portfolio/actions/workflows/ci-backend.yml/badge.svg)](https://github.com/Harshads-git/three-tier-eks-portfolio/actions)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform)](./terraform)
[![Kubernetes](https://img.shields.io/badge/Orchestration-Kubernetes-326CE5?logo=kubernetes)](./k8s)
[![AWS EKS](https://img.shields.io/badge/Cloud-AWS%20EKS-FF9900?logo=amazon-aws)](./terraform)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)

> **A production-grade, infrastructure-as-code portfolio project** demonstrating the full DevOps lifecycle of a three-tier web application deployed on AWS EKS using Terraform, Helm, GitHub Actions CI/CD, Prometheus, and Grafana.

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS Cloud                             │
│                                                              │
│  ┌─── VPC (Multi-AZ) ──────────────────────────────────┐   │
│  │                                                       │   │
│  │  Public Subnets        Private Subnets               │   │
│  │  ┌──────────┐         ┌────────────────────────┐    │   │
│  │  │  ALB     │────────▶│    EKS Node Group      │    │   │
│  │  │(Ingress) │         │  ┌──────┐  ┌────────┐ │    │   │
│  │  └──────────┘         │  │ FE   │  │  BE    │ │    │   │
│  │  ┌──────────┐         │  │React │  │Node.js │ │    │   │
│  │  │  NAT GW  │         │  └──────┘  └────────┘ │    │   │
│  │  └──────────┘         │         ┌───────────┐  │    │   │
│  │                        │         │  MongoDB  │  │    │   │
│  │                        │         │(StatefulSt│  │    │   │
│  │                        └────────────────────────┘    │   │
│  └───────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 📦 Tech Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Frontend** | React (SPA) + Nginx | User interface, served via Nginx container |
| **Backend** | Node.js + Express | REST API, business logic |
| **Database** | MongoDB | Persistent data storage (K8s StatefulSet) |
| **Containerization** | Docker (multi-stage) | Build and package each tier |
| **Orchestration** | Kubernetes (EKS) | Container scheduling and management |
| **IaC** | Terraform | AWS infrastructure provisioning |
| **Package Manager** | Helm | Kubernetes application packaging |
| **CI/CD** | GitHub Actions | Automated build, test, scan, and deploy |
| **Observability** | Prometheus + Grafana | Metrics collection and dashboards |
| **Security** | Trivy + Checkov + OPA | Vulnerability and policy scanning |
| **Registry** | Amazon ECR | Private container image storage |
| **Load Balancer** | AWS ALB Controller | Ingress to ALB provisioning |
| **Autoscaling** | Cluster Autoscaler + HPA | Pod and node-level autoscaling |

---

## 📁 Repository Structure

```
three-tier-eks-portfolio/
├── app/
│   ├── frontend/          # React SPA application
│   └── backend/           # Node.js/Express REST API
├── k8s/
│   ├── frontend/          # Frontend K8s manifests
│   ├── backend/           # Backend K8s manifests
│   ├── mongo/             # MongoDB StatefulSet manifests
│   ├── monitoring/        # Prometheus & Grafana configs
│   └── helm/              # Helm chart for the full application
├── terraform/             # All AWS infrastructure as Terraform
├── docs/                  # Architecture docs, runbooks, ADRs
├── .github/
│   ├── workflows/         # GitHub Actions CI/CD pipelines
│   └── ISSUE_TEMPLATE/    # Bug report & feature request templates
├── scripts/               # Helper shell scripts
├── Makefile               # Common developer commands
├── docker-compose.yml     # Local development environment
└── README.md
```

---

## 🚀 Quick Start (Local Development)

```bash
# 1. Clone the repository
git clone https://github.com/Harshads-git/three-tier-eks-portfolio.git
cd three-tier-eks-portfolio

# 2. Copy environment files
cp app/backend/.env.example app/backend/.env
cp app/frontend/.env.example app/frontend/.env

# 3. Start all services
make up

# 4. Access the app
# Frontend: http://localhost:3000
# Backend:  http://localhost:5000/health
# MongoDB:  localhost:27017
```

---

## 📚 Documentation

| Document | Description |
|---|---|
| [Architecture Overview](./docs/architecture.md) | System design and three-tier pattern explanation |
| [Repository Structure](./docs/repo-structure.md) | Folder conventions and organization |
| [Local Setup Guide](./docs/local-setup.md) | How to run the app locally |
| [VPC Architecture](./docs/vpc-architecture.md) | AWS networking design |
| [EKS Architecture](./docs/eks-architecture.md) | Kubernetes cluster design |
| [IAM & IRSA](./docs/iam-irsa.md) | Identity and access management |
| [CI/CD Pipeline](./docs/ci-cd.md) | GitHub Actions pipeline documentation |
| [Observability](./docs/observability.md) | Monitoring and alerting setup |
| [Troubleshooting](./docs/troubleshooting.md) | Common issues and fixes |
| [Cost Analysis](./docs/cost-analysis.md) | AWS cost breakdown |

---

## 🛡️ Skills Demonstrated

- ✅ **Infrastructure as Code** — Terraform modules for VPC, EKS, IAM, ECR
- ✅ **Container Engineering** — Multi-stage Dockerfiles, security hardening
- ✅ **Kubernetes** — Deployments, StatefulSets, HPA, RBAC, NetworkPolicy
- ✅ **Helm** — Custom chart templating with multi-environment values
- ✅ **CI/CD** — GitHub Actions with OIDC AWS auth, Trivy scanning, auto-rollback
- ✅ **Observability** — Prometheus metrics, Grafana dashboards, CloudWatch logs
- ✅ **Security** — IRSA, least-privilege IAM, OPA policies, Checkov scans
- ✅ **Networking** — VPC design, ALB Ingress, Service mesh concepts

---

## 📅 Project Timeline

This project was built over **30 days** at **1 hour/day** following a structured roadmap.
See the full [30-Day Roadmap](./docs/roadmap.md) for the daily breakdown.

---

## 👤 Author

**Harshad S** — [@Harshads-git](https://github.com/Harshads-git)

> *Reference architecture inspired by [LondheShubham153/three-tier-eks-iac](https://github.com/LondheShubham153/three-tier-eks-iac)*

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](./LICENSE) file for details.
