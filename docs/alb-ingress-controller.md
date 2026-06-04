# ALB Ingress Controller — Architecture & Configuration Guide

## Overview

The AWS Application Load Balancer (ALB) is the **single entry point** for all external traffic into the three-tier application. The **AWS Load Balancer Controller** (formerly ALB Ingress Controller) watches Kubernetes Ingress resources and automatically provisions and manages AWS ALBs.

---

## Architecture — From Browser to Pod

```
Browser
  │
  │ HTTPS → alb.amazonaws.com (internet-facing ALB)
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  AWS Application Load Balancer                                       │
│  Listener: HTTP :80  → Redirect to HTTPS :443                       │
│  Listener: HTTPS :443                                                │
│    ├── Rule 1: Path /api/*  → Target Group: backend-service:3001    │
│    └── Rule 2: Path /*      → Target Group: frontend-service:80     │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
           ┌───────────────┴──────────────┐
           │                              │
           ▼                              ▼
  EC2 Node (NodePort)           EC2 Node (NodePort)
  backend-service NodePort       frontend-service NodePort
           │                              │
           ▼                              ▼
  kube-proxy (iptables)         kube-proxy (iptables)
           │                              │
           ▼                              ▼
  backend pod (port 5000)       frontend pod (port 80)
  Node.js/Express               Nginx serving React
           │
           ▼
  mongodb-service:27017
  MongoDB StatefulSet
```

---

## AWS Load Balancer Controller — How It Works

```
1. You apply k8s/ingress.yaml to the cluster

2. The AWS LB Controller (running in kube-system namespace) detects the Ingress:
   kubectl get ingress three-tier-ingress -n three-tier

3. Controller reads annotations and calls AWS API:
   CreateLoadBalancer (internet-facing ALB in public subnets)
   CreateTargetGroup  (one per Service: frontend, backend)
   CreateListener     (HTTP:80 → redirect, HTTPS:443 → rules)
   CreateRule         (/api/* → backend TG, /* → frontend TG)

4. Controller registers EC2 nodes as targets in each Target Group
   (uses NodePort to route to the correct pods)

5. Controller updates Ingress status with the ALB DNS name:
   kubectl get ingress three-tier-ingress -n three-tier
   → HOSTS: *  ADDRESS: k8s-threetier-alb-abc123.us-east-1.elb.amazonaws.com

6. On future changes (new deployment, scaled pods):
   Controller updates Target Group targets automatically
   (no manual ALB configuration needed!)
```

---

## Ingress Annotations Reference

### Critical Annotations (Required)

| Annotation | Value | Purpose |
|---|---|---|
| `kubernetes.io/ingress.class` | `alb` | Selects AWS LB Controller |
| `alb.ingress.kubernetes.io/scheme` | `internet-facing` | Public ALB (vs `internal`) |
| `alb.ingress.kubernetes.io/target-type` | `instance` | Route to NodePort (vs `ip`) |

### TLS / HTTPS Annotations

| Annotation | Value | Purpose |
|---|---|---|
| `alb.ingress.kubernetes.io/listen-ports` | `[{"HTTP":80},{"HTTPS":443}]` | ALB listens on both ports |
| `alb.ingress.kubernetes.io/ssl-redirect` | `443` | Redirect HTTP → HTTPS |
| `alb.ingress.kubernetes.io/certificate-arn` | `arn:aws:acm:...` | TLS certificate from ACM |

### Health Check Annotations

| Annotation | Value | Purpose |
|---|---|---|
| `alb.ingress.kubernetes.io/healthcheck-path` | `/health` | Backend health check path |
| `alb.ingress.kubernetes.io/healthcheck-interval-seconds` | `15` | How often to check |
| `alb.ingress.kubernetes.io/healthy-threshold-count` | `2` | Successes to mark healthy |
| `alb.ingress.kubernetes.io/unhealthy-threshold-count` | `3` | Failures to mark unhealthy |

---

## IRSA — IAM Roles for Service Accounts

The ALB Controller needs AWS IAM permissions to create/modify ALBs. IRSA provides this **without storing credentials** in the cluster.

### IRSA Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  Kubernetes                     │  AWS                              │
│  ──────────                     │  ────                             │
│  ALB Controller Pod             │                                   │
│    runs with ServiceAccount     │  IAM Role:                        │
│    aws-load-balancer-controller │    AmazonEKSLoadBalancerRole       │
│    │                            │    Trust policy: oidc → SA        │
│    │ JWT token injected          │    Permissions: ec2:*, elb:*      │
│    │ (volume mount)              │                                   │
│    │                            │  OIDC Provider:                   │
│    ▼                            │    oidc.eks.region.amazonaws.com  │
│  AWS SDK calls                  │                                   │
│  STS AssumeRoleWithWebIdentity  │◄──── STS verifies JWT             │
│                                 │      returns temporary creds       │
│  ← Temporary credentials        │      (valid 1 hour, auto-refresh) │
│    (no keys stored anywhere!)   │                                   │
└─────────────────────────────────┴───────────────────────────────────┘
```

### Comparing Credential Methods

| Method | Security | Rotation | Complexity |
|---|---|---|---|
| Hardcoded access keys in YAML | ❌ Terrible | Manual | Low |
| Access keys in K8s Secrets | ❌ Poor (base64) | Manual | Low |
| Instance Profile on EC2 nodes | ⚠️ OK but overly broad | Auto | Medium |
| **IRSA (our approach)** | ✅ Excellent | Auto (1h) | Medium |
| EKS Pod Identity (newer) | ✅ Excellent | Auto | Low |

---

## Path-Based Routing Rules

```
ALB Listener Rules (evaluated in order, most specific first):

Priority 1: /api/* → backend-service:3001
  Matches: /api/tasks, /api/tasks/123, /api/users, /api/anything
  Routes to: backend pods (Node.js Express)

Priority 2: /* → frontend-service:80
  Matches: /, /tasks, /about, /static/js/main.js, everything else
  Routes to: frontend pods (Nginx React SPA)
```

> **Why order matters**: ALB evaluates rules by priority number. Lower number = higher priority. The `/api/*` rule must have a LOWER priority number (checked first) than `/*`.

---

## Verifying the Ingress

```bash
# 1. Check Ingress status
kubectl get ingress -n three-tier
# Look for ADDRESS column — this is your ALB DNS name

# 2. Describe for events (shows ALB provisioning progress)
kubectl describe ingress three-tier-ingress -n three-tier
# Look for events like: "Successfully reconciled"

# 3. Check ALB in AWS Console
# EC2 → Load Balancers → filter by tag: kubernetes.io/cluster/<cluster-name>

# 4. Test routing
ALB_DNS=$(kubectl get ingress three-tier-ingress -n three-tier \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test API route (should reach backend)
curl http://${ALB_DNS}/api/tasks

# Test frontend route (should return HTML)
curl -L http://${ALB_DNS}/ | head -20

# 5. Check ALB Controller logs (if Ingress isn't being provisioned)
kubectl logs -n kube-system \
    -l app.kubernetes.io/name=aws-load-balancer-controller \
    --tail=50
```

---

## Common Issues

| Issue | Symptom | Fix |
|---|---|---|
| ALB not provisioned | `ADDRESS` column empty after 5+ minutes | Check LB controller logs; verify IRSA annotation |
| 503 from ALB | Health checks failing | Verify pods are Ready; check NodePort accessibility |
| Redirect loop | HTTP → HTTPS → HTTP loop | Ensure `ssl-redirect: "443"` annotation is correct |
| Certificate error | Browser shows security warning | Verify ACM certificate ARN and domain matches |
| `/api` returns HTML | Frontend catches `/api` route | Ensure `/api` path rule has higher priority than `/` |
| Controller not watching | Ingress ignored | Verify `kubernetes.io/ingress.class: alb` annotation |

---

## ALB Controller Installation (Preview — Day 13)

```bash
# Install via Helm (requires IRSA role ARN first from Terraform)
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=three-tier-eks-cluster \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region=us-east-1 \
    --set vpcId=$(aws eks describe-cluster \
        --name three-tier-eks-cluster \
        --query "cluster.resourcesVpcConfig.vpcId" \
        --output text)

# Verify installation
kubectl get deployment -n kube-system aws-load-balancer-controller
```
