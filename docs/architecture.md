# Architecture Overview

## The Three-Tier Pattern

A **three-tier architecture** is a software design pattern that separates an application into three logical and physical computing tiers:

```
┌────────────────────────────────────────────────────────────────────┐
│                    THREE-TIER ARCHITECTURE                          │
│                                                                      │
│   TIER 1: PRESENTATION (Frontend)                                   │
│   ┌─────────────────────────────────────┐                          │
│   │  React SPA served via Nginx         │                          │
│   │  • Handles all UI rendering         │                          │
│   │  • Communicates ONLY with Backend   │                          │
│   │  • Runs as Docker container on K8s  │                          │
│   └──────────────────┬──────────────────┘                          │
│                       │ HTTP/REST (JSON)                            │
│                       ▼                                              │
│   TIER 2: LOGIC (Backend)                                           │
│   ┌─────────────────────────────────────┐                          │
│   │  Node.js + Express REST API         │                          │
│   │  • Processes all business logic     │                          │
│   │  • Validates input data             │                          │
│   │  • Manages data operations          │                          │
│   │  • Runs as Docker container on K8s  │                          │
│   └──────────────────┬──────────────────┘                          │
│                       │ Mongoose/MongoDB Wire Protocol              │
│                       ▼                                              │
│   TIER 3: DATA (Database)                                           │
│   ┌─────────────────────────────────────┐                          │
│   │  MongoDB (Kubernetes StatefulSet)   │                          │
│   │  • Persists all application data    │                          │
│   │  • Accessible ONLY from Backend     │                          │
│   │  • Uses EBS PersistentVolume        │                          │
│   └─────────────────────────────────────┘                          │
└────────────────────────────────────────────────────────────────────┘
```

---

## Why Three-Tier Architecture?

| Concern | Benefit |
|---|---|
| **Separation of Concerns** | Each tier has a single responsibility. Frontend doesn't know how data is stored. |
| **Independent Scaling** | High traffic? Scale only the frontend pods. Heavy computation? Scale only backend. |
| **Security Isolation** | Database is never directly exposed. Only the backend can talk to MongoDB. |
| **Independent Deployment** | Update the frontend without touching the backend or database. |
| **Technology Flexibility** | Swap React for Vue, or MongoDB for PostgreSQL, without rewriting everything. |

---

## AWS EKS Deployment Architecture

```
Internet
    │
    ▼
┌───────────────────────────────────────────────────────────────┐
│                     AWS Region (us-west-2)                     │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                  VPC (10.0.0.0/16)                       │  │
│  │                                                           │  │
│  │  ┌─── Availability Zone A ──┐  ┌── Availability Zone B─┐│  │
│  │  │                          │  │                        ││  │
│  │  │  Public Subnet           │  │  Public Subnet         ││  │
│  │  │  ┌────────────────────┐  │  │  ┌─────────────────┐  ││  │
│  │  │  │  ALB (Ingress)     │  │  │  │  NAT Gateway    │  ││  │
│  │  │  └────────────────────┘  │  │  └─────────────────┘  ││  │
│  │  │                          │  │                        ││  │
│  │  │  Private Subnet          │  │  Private Subnet        ││  │
│  │  │  ┌────────────────────┐  │  │  ┌─────────────────┐  ││  │
│  │  │  │   EKS Worker Node  │  │  │  │  EKS Worker Node│  ││  │
│  │  │  │  ┌──────────────┐  │  │  │  │  ┌───────────┐  │  ││  │
│  │  │  │  │ Frontend Pod │  │  │  │  │  │Backend Pod│  │  ││  │
│  │  │  │  ├──────────────┤  │  │  │  │  ├───────────┤  │  ││  │
│  │  │  │  │ Backend Pod  │  │  │  │  │  │Mongo Pod  │  │  ││  │
│  │  │  │  └──────────────┘  │  │  │  │  └───────────┘  │  ││  │
│  │  │  └────────────────────┘  │  │  └─────────────────┘  ││  │
│  │  └──────────────────────────┘  └────────────────────────┘│  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                                │
│  Supporting Services:                                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
│  │  ECR     │ │  S3      │ │ DynamoDB │ │  CloudWatch Logs │ │
│  │(Registry)│ │(TF State)│ │(TF Lock) │ │  (App Logs)      │ │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────────┘ │
└───────────────────────────────────────────────────────────────┘
```

---

## Request Flow (End-to-End)

```
User Browser
     │
     │ HTTPS request (e.g., GET https://app.harshads.dev/)
     ▼
Route 53 (DNS)
     │
     │ Resolves to ALB DNS name
     ▼
Application Load Balancer (ALB)
     │
     │ Rules:
     │   /api/*  ──────────► Backend Service (ClusterIP:5000)
     │   /*      ──────────► Frontend Service (ClusterIP:80)
     ▼
Kubernetes Service (ClusterIP)
     │
     │ kube-proxy routes to a healthy Pod
     ▼
Pod (Frontend: Nginx | Backend: Node.js)
     │
     │ (Only Backend) Mongoose connection to:
     ▼
MongoDB Pod (ClusterIP, port 27017)
     │
     │ Reads/Writes to:
     ▼
EBS PersistentVolume (gp2, 5Gi)
```

---

## Technology Decision Log

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Container Orchestration | EKS (Managed K8s) | ECS, Docker Swarm | Industry standard, rich ecosystem |
| IaC | Terraform | CloudFormation, CDK | Multi-cloud, HCL readability, module ecosystem |
| Database | MongoDB | RDS PostgreSQL | Document model fits task data; StatefulSet practice |
| Ingress | AWS ALB Controller | Nginx Ingress | Native AWS integration, no extra NLB cost |
| CI/CD | GitHub Actions | Jenkins, CircleCI | Native GitHub integration, OIDC AWS auth |
| Package Manager | Helm | Kustomize, raw YAML | Templating, release management, rollbacks |
| Monitoring | kube-prometheus-stack | Datadog, New Relic | Open source, K8s native, cost-free |

---

## Reference Architecture

> This project was built as an **original portfolio project** inspired by the reference architecture:
> [LondheShubham153/three-tier-eks-iac](https://github.com/LondheShubham153/three-tier-eks-iac)
>
> All code was written from scratch with production-grade improvements,
> annotations, and additional DevSecOps practices layered on top.
