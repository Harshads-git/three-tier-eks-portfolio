# Declarative GitOps with ArgoCD — Architecture & Operations Guide

> **Core Philosophy:** Git is the single source of truth for the entire cluster state. No manual `kubectl apply` commands in production. If it is not committed to Git, it does not exist in the cluster.

---

## 1. Architecture Overview

ArgoCD operates as a Kubernetes controller that continuously compares the **desired state** stored in this Git repository with the **live state** running in the Amazon EKS cluster.

```
┌─────────────────────────────────────────────────────────────┐
│                       GitHub Repository                     │
│           https://github.com/Harshads-git/...               │
│                                                             │
│   gitops/root-application.yaml ── points to ──► gitops/apps/│
│                                                     │       │
│                     ┌───────────────────────────────┴───┐   │
│                     │ mongo-app.yaml (Wave 1)           │   │
│                     │ backend-app.yaml (Wave 2)         │   │
│                     │ frontend-app.yaml (Wave 3)        │   │
│                     │ ingress-app.yaml (Wave 4)         │   │
│                     └───────────────────────────────────┘   │
└───────────────────────────────┬─────────────────────────────┘
                                │ Pull (every 180s or webhook)
                                ▼
┌─────────────────────────────────────────────────────────────┐
│                      Amazon EKS Cluster                     │
│                                                             │
│  ┌───────────────────────── ArgoCD Control Plane ────────┐  │
│  │                                                       │  │
│  │   argocd-repo-server  ◄── clones and templates        │  │
│  │           │                                           │  │
│  │           ▼                                           │  │
│  │   argocd-application-controller                       │  │
│  │     (Continuous Reconciliation Loop: Sync & Self-Heal)│  │
│  │           │                                           │  │
│  │           ▼                                           │  │
│  │   argocd-server ── exposed via AWS ALB (Ingress)      │  │
│  │                                                       │  │
│  └───────────────────────────┬───────────────────────────┘  │
│                              │                              │
│         Reconciles into target namespaces                   │
│                              ▼                              │
│  ┌────────────────────── Namespace: three-tier ──────────┐  │
│  │  Wave 0: Quotas & NetworkPolicies                     │  │
│  │  Wave 1: StatefulSet (MongoDB) + EBS PVC              │  │
│  │  Wave 2: Deployment (Backend Express) + HPA           │  │
│  │  Wave 3: Deployment (Frontend React) + NodePort       │  │
│  │  Wave 4: Ingress (ALB Controller)                     │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Why GitOps (Pull) vs Traditional CI/CD (Push)?

| Metric | Traditional CI/CD (Push) | ArgoCD GitOps (Pull) |
|---|---|---|
| **Cluster Credentials** | Stored in GitHub Secrets / Runner | **Never leave the cluster** (In-cluster controller) |
| **Drift Detection** | None (manual `kubectl` changes go unnoticed) | **Real-time detection** (Flags `OutOfSync`) |
| **Self-Healing** | Requires pipeline re-run | **Automatic & instant** (Reverts cluster to git state) |
| **Audit Log** | Fragmented CI pipeline logs | **Git Commit History** (`git log` is the audit trail) |
| **Disaster Recovery** | Complex scripted re-deployment | **Single manifest apply** (`root-application.yaml`) |

---

## 3. The App-of-Apps Pattern

Instead of managing individual `Application` manifests for each microservice, this repository adopts the **App-of-Apps Pattern**:

1. A single **Root Application** (`gitops/root-application.yaml`) tracks the `gitops/apps/` directory.
2. The `gitops/apps/` directory contains individual child `Application` CRDs for each tier.
3. When new microservices or operational tooling are added to `gitops/apps/`, ArgoCD discovers, deploys, and synchronizes them without any manual intervention.

### Sync Wave Execution Order

Because Kubernetes services have strict startup dependencies (the API backend will crash loop if MongoDB is not reachable), ArgoCD **Sync Waves** (`argocd.argoproj.io/sync-wave`) enforce the deployment sequence:

```
Wave 0: Policies & Quotas
   │    (NetworkPolicies deny-all, ResourceQuota, LimitRange)
   ▼
Wave 1: Data Tier
   │    (MongoDB StatefulSet, Headless Service, PVC)
   ▼
Wave 2: Logic Tier
   │    (Node.js Express Deployment, HPA, ClusterIP)
   ▼
Wave 3: Presentation Tier
   │    (React Nginx Deployment, Service)
   ▼
Wave 4: Edge Routing
        (AWS Application Load Balancer Ingress)
```

Each wave must achieve a **Healthy** status before ArgoCD initiates the next wave.

---

## 4. Self-Healing in Action: Preventing Configuration Drift

ArgoCD continuously monitors the live Kubernetes cluster state. 

### Scenario: Unauthorized Manual Tampering
An engineer accidentally runs:
```bash
# Rogue manual change in cluster
kubectl scale deployment backend -n three-tier --replicas=10
```

### What Happens:
1. Within **5 seconds**, the `argocd-application-controller` detects a discrepancy between the live cluster (`replicas: 10`) and Git (`replicas: 2`).
2. The application transitions to `OutOfSync`.
3. Because `selfHeal: true` is configured in `syncPolicy`, ArgoCD immediately overwrites the live cluster state with the Git desired state.
4. The deployment is scaled back down to `2` replicas automatically.
5. An audit event is logged in ArgoCD.

---

## 5. Disaster Recovery in 3 Steps

If the entire AWS EKS cluster is destroyed or corrupted, full platform recovery requires only 3 commands:

```bash
# Step 1: Connect to new or replacement cluster
aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1

# Step 2: Deploy ArgoCD Control Plane
kubectl apply -k gitops/argocd/

# Step 3: Apply the App-of-Apps Root Manifest
kubectl apply -f gitops/root-application.yaml
```

ArgoCD automatically:
- Reads `gitops/apps/`
- Provisions the `three-tier` namespace
- Mounts EBS persistent volumes
- Deploys MongoDB, Backend, Frontend, and Ingress in the exact wave order
- Applies all NetworkPolicies and Prometheus monitoring targets

**Total Recovery Time:** `< 4 minutes`.

---

## 6. ArgoCD CLI Operations Cheat Sheet

```bash
# Log in to ArgoCD CLI
argocd login <ARGOCD_ALB_URL> --username admin --password <ADMIN_PASSWORD>

# Check status of the root application and all child apps
argocd app list

# View detailed sync and health tree
argocd app get root-application

# Trigger an immediate manual sync (bypassing the 180s polling interval)
argocd app sync three-tier-backend

# View live application logs through ArgoCD
argocd app logs three-tier-backend -n three-tier

# Perform a declarative rollback
argocd app rollback three-tier-backend
```
