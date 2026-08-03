# System Architecture — Three-Tier EKS Portfolio

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AWS CLOUD (us-east-1)                               │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    VPC: 10.0.0.0/16                                  │   │
│  │                                                                      │   │
│  │  ┌─────────────────────────┐   ┌─────────────────────────┐          │   │
│  │  │  PUBLIC SUBNET          │   │  PUBLIC SUBNET          │          │   │
│  │  │  10.0.101.0/24 (us-e-1a)│   │  10.0.102.0/24 (us-e-1b)│          │   │
│  │  │  ┌────────────┐         │   │  ┌────────────┐         │          │   │
│  │  │  │ NAT Gateway│         │   │  │ (future AZ)│         │          │   │
│  │  │  └─────┬──────┘         │   │  └────────────┘         │          │   │
│  │  └────────┼────────────────┘   └─────────────────────────┘          │   │
│  │           │                                                          │   │
│  │  ┌────────┼────────────────┐   ┌─────────────────────────┐          │   │
│  │  │ PRIVATE SUBNET          │   │  PRIVATE SUBNET         │          │   │
│  │  │ 10.0.1.0/24 (us-e-1a)  │   │  10.0.2.0/24 (us-e-1b)  │          │   │
│  │  │                         │   │                          │          │   │
│  │  │ ┌──────────────────┐    │   │ ┌──────────────────┐    │          │   │
│  │  │ │   EC2 (Worker 1) │    │   │ │   EC2 (Worker 2) │    │          │   │
│  │  │ │   t3.medium       │    │   │ │   t3.medium       │    │          │   │
│  │  │ │ ┌──────────────┐  │    │   │ │ ┌──────────────┐  │    │          │   │
│  │  │ │ │ frontend pod │  │    │   │ │ │ frontend pod │  │    │          │   │
│  │  │ │ │ backend  pod │  │    │   │ │ │ backend  pod │  │    │          │   │
│  │  │ │ │ mongo    pod │  │    │   │ │ │ (HPA pods)   │  │    │          │   │
│  │  │ │ └──────────────┘  │    │   │ │ └──────────────┘  │    │          │   │
│  │  │ └──────────────────┘    │   │ └──────────────────┘    │          │   │
│  │  └─────────────────────────┘   └─────────────────────────┘          │   │
│  │                                                                      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────────────┐   │
│  │    ECR     │  │     S3     │  │  DynamoDB  │  │    EKS Managed     │   │
│  │ (backend   │  │ (Terraform │  │ (State     │  │  Control Plane     │   │
│  │  frontend  │  │  state)    │  │  Locking)  │  │  (3 AZs, HA)      │   │
│  │  images)   │  │            │  │            │  │                    │   │
│  └────────────┘  └────────────┘  └────────────┘  └────────────────────┘   │
│                                                                             │
│  Internet → Route53/ALB → VPC (NodePort) → K8s Service → pods              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Inventory

### Infrastructure Layer (Terraform)

| Component | Service | Config | Purpose |
|---|---|---|---|
| VPC | AWS VPC | 10.0.0.0/16, 2 AZs | Network isolation |
| Public Subnets | AWS Subnet | /24 per AZ | ALB, NAT Gateway |
| Private Subnets | AWS Subnet | /24 per AZ | EKS nodes (no direct internet) |
| NAT Gateway | AWS NAT GW | Single (portfolio cost) | Private subnet internet egress |
| Internet Gateway | AWS IGW | 1 per VPC | Public subnet internet access |
| EKS Cluster | AWS EKS | v1.29, 2 nodes | Kubernetes control plane |
| Node Group | AWS EC2 | t3.medium, min=1, max=4 | Kubernetes worker nodes |
| ECR Backend | AWS ECR | Immutable, lifecycle=10 | Backend container images |
| ECR Frontend | AWS ECR | Immutable, lifecycle=10 | Frontend container images |
| S3 | AWS S3 | Versioned, encrypted | Terraform remote state |
| DynamoDB | AWS DynamoDB | PAY_PER_REQUEST | Terraform state locking |

### Application Layer (Kubernetes)

| Resource | Replicas | CPU Req/Limit | Memory Req/Limit | Notes |
|---|---|---|---|---|
| Frontend Deployment | 2 (HPA 2-5) | 50m/200m | 64Mi/128Mi | Nginx, static React |
| Backend Deployment | 2 (HPA 2-5) | 100m/500m | 128Mi/256Mi | Node.js Express API |
| MongoDB StatefulSet | 1 | 250m/1000m | 256Mi/512Mi | Data persistence via EBS |
| ALB Ingress | 1 (AWS managed) | N/A | N/A | Routes / and /api/* |
| Metrics Server | 1 | 100m/300m | 200Mi | Enables HPA |
| ALB Controller | 2 | 100m/200m | 128Mi | Provisions AWS ALB |
| Cluster Autoscaler | 1 | 100m/300m | 200Mi | Scales EC2 nodes |
| Prometheus | 1 | 100m/500m | 400Mi | Metrics storage 30d |
| Grafana | 1 | 100m/200m | 128Mi | Dashboards |

### Security Layer (IAM + NetworkPolicy)

| Identity | Type | Permissions | Scope |
|---|---|---|---|
| github-actions-role | IAM Role (OIDC) | ECR push + EKS describe | This repo only |
| alb-controller-role | IAM Role (IRSA) | ALB management | This VPC only |
| cluster-autoscaler-role | IAM Role (IRSA) | ASG scaling | This cluster's ASGs only |
| ebs-csi-driver-role | IAM Role (IRSA) | EBS volumes | Tag-restricted |
| NetworkPolicy: deny-all | K8s resource | Block all traffic | three-tier namespace |
| NetworkPolicy: allow-ingress | K8s resource | Explicit allows | tier-to-tier only |

---

## Design Decisions & Rationale

### 1. Why EKS over ECS, Lambda, or Elastic Beanstalk?

| Criteria | EKS | ECS | Lambda | Beanstalk |
|---|---|---|---|---|
| Portability | ✅ K8s is cloud-agnostic | ❌ AWS-specific | ❌ AWS-specific | ❌ AWS-specific |
| Control | ✅ Full control | Medium | ❌ Limited | ❌ Opinionated |
| Multi-tier apps | ✅ Native | ✅ OK | ❌ Complex | ✅ OK |
| Industry adoption | ✅ Dominant | Medium | High (FaaS) | Low |
| Resume value | ✅ Highest | Medium | High | Low |
| Cost (small app) | ❌ $73 control plane | Cheaper | Cheapest | Medium |

**Decision**: EKS chosen for industry-standard K8s experience and portability.

### 2. Why Terraform over CloudFormation or CDK?

```
CloudFormation: AWS-only. Templates are verbose JSON/YAML with limited expressiveness.
CDK:            AWS-only. Code-first but still CloudFormation underneath.
Pulumi:         Multi-cloud, code-first. Excellent but smaller community.
Terraform:      Multi-cloud, HCL DSL. Largest community, most job postings, best modules.

Decision: Terraform for:
  - Multi-cloud portability (same pattern works for GCP/Azure)
  - Module ecosystem (terraform-aws-modules/eks saves 400 lines)
  - State management (S3 backend with DynamoDB locking)
  - Industry standard (required skill in 90% of DevOps job postings)
```

### 3. Why S3 remote state over local state?

```
Problem with local state:
  terraform.tfstate on developer laptop
  → Developer A applies → changes saved locally
  → Developer B applies → doesn't see A's changes → duplicate resources!
  → Developer A's laptop stolen → state lost → Terraform can't manage resources

S3 remote state:
  → Single source of truth for all developers
  → DynamoDB locking: only one apply at a time (no concurrent corruption)
  → Versioned: roll back to previous state if corrupted
  → Encrypted at rest (KMS or SSE-S3)
```

### 4. Why single NAT Gateway? (and when to change)

```
Portfolio (current):
  single_nat_gateway = true → $33/month
  If us-east-1a NAT Gateway fails:
    Private subnet in us-east-1a loses internet → pods can't pull images
    But: pod scheduling might still work if pods can reach services within VPC

Production (should change to):
  single_nat_gateway = false
  one_nat_gateway_per_az = true → $66/month
  Each AZ has own NAT → no cross-AZ single point of failure
  Trade-off: $33/month for full NAT HA
```

### 5. Why IRSA over instance IAM roles?

```
Instance IAM Role (old pattern):
  All pods on a node SHARE the EC2 instance profile
  Backend pod can access S3 just because a kube-system pod needs S3
  → Violation of least privilege

IRSA (current pattern):
  Each pod gets its OWN IAM identity via ServiceAccount annotation
  Backend pod: no AWS permissions (doesn't need any)
  ALB Controller pod: only ALB/EC2 permissions
  EBS CSI pod: only EBS permissions
  → True pod-level least privilege
  → Credentials are short-lived (auto-rotated, never stored)
```

### 6. Why Immutable ECR tags?

```
Mutable (dangerous):
  Push :v1.0.0 → good code
  Push :v1.0.0 again → overwrites! Now it's broken code
  kubectl rollout undo → rolls back to :v1.0.0 → pulls broken code → still broken!

Immutable (our config: repository_image_tag_mutability = "IMMUTABLE"):
  Push :v1.0.0 → good code → locked forever
  Push :v1.0.0 again → ERROR: "tag already exists" → forced to use new tag
  kubectl rollout undo → always pulls the exact original good code ✅

Cost: Cannot overwrite = CI must always push new tags (git SHA pattern: sha-abc1234)
```

---

## Traffic Flow — User Request to MongoDB

```
Browser
  │ HTTP request: GET / or GET /api/tasks
  ▼
ALB (AWS Application Load Balancer)
  │ ALB listener: port 80
  │ ALB routing rules:
  │   path /api/* → Target Group: backend pods (port 5000)
  │   path /*    → Target Group: frontend pods (port 80)
  ▼
Kubernetes NodePort Service
  │ frontend-service: NodePort 30080 → ClusterIP → pod:80
  │ backend-service:  NodePort 30050 → ClusterIP → pod:5000
  ▼
Pod (selected by kube-proxy iptables rules)
  │ Frontend: Nginx serves index.html + static JS/CSS
  │ Backend:  Express.js handles REST API
  ▼
MongoDB (if backend request)
  │ Internal DNS: mongo-service.three-tier.svc.cluster.local
  │ StatefulSet pod: mongo-0
  │ EBS volume: /data/db (persistent across pod restarts)
  ▼
Response returns through same path
```

---

## Kubernetes Internal Networking

```
Pod IP assignment (VPC CNI):
  Pod gets a REAL VPC IP (e.g., 10.0.1.47)
  NOT a virtual overlay IP (no flannel/calico overlay)
  ALB target-type: ip → ALB talks directly to pod IP

Service types used:
  ClusterIP (mongo-service):
    Virtual IP: 10.96.43.129
    Only reachable within cluster
    Backend resolves: mongo-service → 10.96.43.129 → pod 10.0.1.89

  NodePort (frontend-service, backend-service):
    EC2 node port: 30080 (frontend), 30050 (backend)
    ALB registers EC2 node IPs as targets
    ALB → Node IP:30080 → kube-proxy → pod IP:80

DNS resolution (CoreDNS):
  mongo-service           → 10.96.43.129 (cluster-local)
  mongo-service.three-tier → same
  mongo-service.three-tier.svc.cluster.local → same (full FQDN)
```
