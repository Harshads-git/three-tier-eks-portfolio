# EKS Cluster Architecture & Node Group Configuration

## What EKS Manages vs What You Manage

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        EKS = Managed Control Plane                          │
│                                                                             │
│  AWS MANAGES (Control Plane — $0.10/hour):                                 │
│  ┌─────────────┐  ┌───────────┐  ┌──────────────────┐  ┌─────────────┐   │
│  │ kube-apiserver│ │   etcd    │  │ Controller Manager│  │  Scheduler  │   │
│  │ (3 replicas) │  │ (3 AZs)   │  │  (Deployments,   │  │ (pod to    │   │
│  │              │  │           │  │   ReplicaSets)   │  │  node)     │   │
│  └─────────────┘  └───────────┘  └──────────────────┘  └─────────────┘   │
│                                                                             │
│  YOU MANAGE (Worker Nodes — per EC2 hour):                                 │
│  ┌──────────────────────────────┐  ┌──────────────────────────────────┐   │
│  │    EKS Managed Node Group    │  │  Add-ons (CoreDNS, kube-proxy,  │   │
│  │    (t3.medium EC2 instances) │  │  vpc-cni, EBS CSI Driver)       │   │
│  │    kubelet + containerd      │  │  Your workloads (Deployments)   │   │
│  └──────────────────────────────┘  └──────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## EKS Cluster Configuration Choices

| Setting | Value | Reason |
|---|---|---|
| `cluster_version` | `1.29` | Latest stable, EKS-supported |
| `endpoint_public_access` | `true` | Local kubectl from laptop |
| `endpoint_private_access` | `true` | CI/CD pipelines within VPC |
| `enable_irsa` | `true` | IRSA for ALB controller, EBS CSI |
| `cluster_enabled_log_types` | api, audit, authenticator | Security and debugging |
| `enable_cluster_creator_admin_permissions` | `true` | Terraform IAM role gets kubectl admin |

---

## Managed Node Group — t3.medium Sizing

```
t3.medium: 2 vCPU, 4 GiB RAM

Available for pods (after K8s system overhead):
  4096 MB - 700 MB (kube-system DaemonSets) ≈ 3396 MB per node
  2000m CPU - 200m (system) ≈ 1800m CPU per node

Pod resource requests (two nodes):
  MongoDB:    256 MB + 250m CPU  (node 1)
  Backend ×2: 256 MB + 200m CPU  (split across nodes)
  Frontend ×2: 128 MB + 100m CPU (split across nodes)
  ALB Ctrl:    50 MB +  50m CPU  (kube-system)
  ─────────────────────────────────────
  Total:      ~890 MB + ~600m CPU per node (well within t3.medium)
```

---

## Cluster Add-ons Explained

| Add-on | Purpose | Required |
|---|---|---|
| **CoreDNS** | Kubernetes DNS — resolves `mongo-service.three-tier.svc.cluster.local` | ✅ Yes |
| **kube-proxy** | Network rules (iptables) for ClusterIP service routing | ✅ Yes |
| **vpc-cni** | Assigns real VPC IPs to pods (not overlay network) | ✅ Yes for EKS |
| **EBS CSI Driver** | Dynamically provisions EBS volumes for PVCs (MongoDB) | ✅ Yes for MongoDB |

### Why EBS CSI Driver Needs IRSA

```
Without EBS CSI Driver:
  kubectl apply -f k8s/mongo/statefulset.yaml
  kubectl get pvc -n three-tier
  NAME                  STATUS    VOLUME
  mongo-data-mongo-0    Pending   (stuck — no one to provision the EBS volume!)

With EBS CSI Driver (+ IRSA role with AmazonEBSCSIDriverPolicy):
  StatefulSet created → PVC created →
  EBS CSI Driver calls ec2:CreateVolume (via IRSA) →
  EBS volume provisioned → PVC Bound →
  mongo-0 pod mounts /data/db → MongoDB starts ✅
```

---

## ECR — Container Image Registry

### Why ECR vs Docker Hub

| Factor | ECR | Docker Hub |
|---|---|---|
| **Auth** | IAM (automatic in EKS) | Docker login required |
| **Network** | Same AWS region = fast pulls | Internet = slower, egress costs |
| **Security** | Private by default | Public unless paid plan |
| **Scanning** | Amazon Inspector (free basic) | Manual or paid |
| **Cost** | $0.10/GB/month | Free tier limited |
| **Integration** | Native AWS IAM, CloudTrail | External |

### ECR Security Settings

```
IMMUTABLE_TAGS: tag 'v1.0.0' can NEVER be overwritten
  → Ensures every deployment to :v1.0.0 always uses the exact same image
  → Prevents "it worked yesterday, same tag, different image" incidents

scan_on_push: true
  → Every image scanned for CVEs immediately after push
  → aws ecr describe-image-scan-findings --repository-name three-tier-backend
  → In CI/CD (Day 24): fail pipeline if CRITICAL CVEs found

Lifecycle Policy:
  Keep 10 tagged images (sha-abc123f pattern)
  Delete untagged images after 1 day
  → ~900MB ECR storage → ~$0.09/month
```

### ECR Image Tagging Strategy

```
Our CI/CD (Day 24) tags images with git commit SHA:
  sha-a1b2c3d  ← short git commit hash

Benefits:
  - Immutable: every git commit = unique image tag
  - Traceable: tag links image back to exact code that built it
  - Rollback: kubectl set image deployment/backend backend=<ecr>:sha-a1b2c3d
  - Audit: "who deployed this?" = git log sha-a1b2c3d

ECR repository URL structure:
  <account_id>.dkr.ecr.<region>.amazonaws.com/<repo-name>:<tag>
  123456789012.dkr.ecr.us-east-1.amazonaws.com/three-tier-backend:sha-abc1234
```

---

## Terraform Resource Graph (Day 10 Resources)

```
data.aws_caller_identity.current
data.aws_availability_zones.available
data.aws_region.current
       │
       ▼
locals (name_prefix, ecr_registry, common_tags, cluster_addons)
       │
       ├──────────────────────────────────┐
       ▼                                  ▼
module.vpc                          module.ecr_backend
  (VPC, subnets, NAT GW)            module.ecr_frontend
       │                               (ECR repos, lifecycle policies)
       ▼
module.eks
  (EKS cluster, node group, OIDC)
       │
       ├── aws_iam_role.ebs_csi_driver
       │   aws_iam_role_policy_attachment.ebs_csi_driver
       │   aws_eks_addon.ebs_csi_driver
       │
       └── [Day 13: ALB Controller IAM role, Cluster Autoscaler]

Total resources after Day 10:
  ~47 AWS resources managed by Terraform
```

---

## Terraform Apply Timeline

```
terraform apply starts
│
│ 0:00 — VPC, subnets, IGW, route tables created (parallel, ~2 min)
│ 1:30 — NAT Gateway created, EIP allocated (~2 min)
│ 3:00 — ECR repositories created (~30 sec)
│ 3:30 — EKS control plane creation begins (slow!)
│          API server, etcd, controller-manager, scheduler
│
│ 3:30 ─────────────────────── 15:00 — EKS control plane (~12 min)
│
│ 15:00 — OIDC provider created, cluster add-ons installed
│ 15:30 — Node group creation begins
│
│ 15:30 ─────────────── 18:00 — EC2 nodes joining cluster (~3 min)
│
│ 18:00 — EBS CSI Driver add-on installed
│ 18:30 — terraform apply complete
│
Total: ~18-20 minutes for a brand new EKS cluster
```

---

## Verification Commands (After terraform apply)

```bash
# 1. Configure kubectl
aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1

# 2. Verify cluster
kubectl cluster-info
kubectl get nodes -o wide   # Should show 2 Ready nodes

# 3. Verify add-ons
kubectl get pods -n kube-system
# Should show: coredns, kube-proxy (on each node), aws-node (vpc-cni), ebs-csi-controller

# 4. Verify EBS CSI driver IRSA
kubectl get serviceaccount ebs-csi-controller-sa -n kube-system -o yaml
# Should show: eks.amazonaws.com/role-arn annotation

# 5. Check ECR repositories
aws ecr describe-repositories --region us-east-1
# Should show: three-tier-eks-cluster-backend, three-tier-eks-cluster-frontend

# 6. Quick PVC test (MongoDB will use this in Day 19)
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp2
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc test-pvc   # Should show Bound within 30 seconds
kubectl delete pvc test-pvc
```
