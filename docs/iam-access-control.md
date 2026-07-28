# IAM & Access Control Architecture

## Identity and Access Management Overview

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                         THREE-TIER EKS IAM ARCHITECTURE                        │
│                                                                               │
│  GitHub Actions                                                               │
│  (CI/CD Workflow)                                                             │
│       │ OIDC Token (JWT)                                                      │
│       │ No stored AWS keys!                                                   │
│       ▼                                                                       │
│  AWS STS ──────────────────────► github-actions-role                          │
│  AssumeRoleWithWebIdentity         ├── ECR: push backend/frontend images      │
│  (verifies JWT against             └── EKS: describe cluster (for kubeconfig) │
│   GitHub OIDC endpoint)                                                       │
│                                                                               │
│  EKS Cluster (kube-system pods)                                               │
│       │                                                                       │
│       ├── ALB Controller Pod                                                  │
│       │   OIDC Token → alb-controller-role                                   │
│       │   Permissions: ec2:*, elasticloadbalancing:*                         │
│       │   Creates: ALBs, Target Groups, Listeners, Rules                     │
│       │                                                                       │
│       ├── Cluster Autoscaler Pod                                              │
│       │   OIDC Token → cluster-autoscaler-role                               │
│       │   Permissions: autoscaling:SetDesiredCapacity (tagged ASGs only)     │
│       │   Creates: Scales EC2 node groups up/down                            │
│       │                                                                       │
│       └── EBS CSI Driver Pod (from Day 10)                                   │
│           OIDC Token → ebs-csi-driver-role                                   │
│           Permissions: ec2:CreateVolume, AttachVolume                        │
│           Creates: EBS volumes for MongoDB StatefulSet PVCs                  │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## GitHub Actions OIDC — No Stored AWS Credentials

### The Old Way (Never Do This)

```yaml
# ❌ BAD: GitHub Repository Secrets with long-lived keys
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

Problems with stored keys:
- Keys never expire (valid until manually rotated)
- If GitHub is breached → attacker has permanent AWS access
- Keys must be manually rotated (ops burden)
- Hard to audit "which workflow used these credentials and when?"

### The OIDC Way (Our Approach)

```yaml
# ✅ GOOD: OIDC — no keys stored anywhere
permissions:
  id-token: write   # Required for GitHub OIDC token
  contents: read

steps:
  - name: Configure AWS credentials (OIDC)
    uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789012:role/three-tier-eks-cluster-github-actions-role
      aws-region: us-east-1
      # GitHub generates a short-lived JWT token
      # AWS STS verifies it against GitHub OIDC endpoint
      # Returns temporary credentials (valid 1 hour max)
```

### Trust Policy — Restricting Which Repos Can Assume the Role

```json
{
  "Condition": {
    "StringLike": {
      "token.actions.githubusercontent.com:sub":
        "repo:Harshads-git/three-tier-eks-portfolio:*"
    }
  }
}
```

> **Critical**: Without the `StringLike` condition, ANY GitHub Actions workflow in ANY repo could assume your AWS role. Always restrict to your specific repository.

---

## IRSA — IAM Roles for Service Accounts (Pattern)

All three service roles (ALB Controller, Cluster Autoscaler, EBS CSI) follow the same IRSA pattern:

```
1. EKS cluster creates OIDC provider (enable_irsa = true in eks.tf)
   OIDC URL: https://oidc.eks.us-east-1.amazonaws.com/id/<CLUSTER_ID>

2. Create IAM Role with trust policy:
   Principal: Federated = oidc_provider_arn
   Condition: sub = "system:serviceaccount:<namespace>:<sa-name>"

3. Create/annotate Kubernetes ServiceAccount:
   annotations:
     eks.amazonaws.com/role-arn: arn:aws:iam::123:role/<role-name>

4. EKS webhook injects OIDC token into pod's volume mounts
   Path: /var/run/secrets/eks.amazonaws.com/serviceaccount/token

5. AWS SDK in pod calls STS AssumeRoleWithWebIdentity
   → Receives temporary credentials (1 hour, auto-refreshed)
   → No keys stored anywhere in the cluster!
```

---

## Least Privilege — What Each Role Can Do

### GitHub Actions Role
```
CAN:
  ✅ Push Docker images to: three-tier-backend, three-tier-frontend ECRs
  ✅ Get ECR authorization token (docker login)
  ✅ Describe EKS cluster (get kubeconfig)

CANNOT:
  ❌ Delete ECR repositories
  ❌ Modify other ECR repos (other projects in the account)
  ❌ Delete/create EKS clusters
  ❌ Access any other AWS services (S3, RDS, etc.)
```

### ALB Controller Role
```
CAN:
  ✅ Create/modify/delete ALBs (via Ingress controller)
  ✅ Create/modify security groups for ALBs
  ✅ Register EC2 nodes as ALB targets
  ✅ Read VPC, subnet, instance information

CANNOT:
  ❌ Delete non-ELB security groups
  ❌ Terminate EC2 instances
  ❌ Access S3, ECR, or other services
```

### Cluster Autoscaler Role
```
CAN:
  ✅ Describe ALL Auto Scaling Groups (read-only, account-wide)
  ✅ Set desired capacity on ASGs tagged: k8s.io/cluster-autoscaler/<cluster>=owned
  ✅ Terminate instances in tagged ASGs

CANNOT:
  ❌ Scale ASGs from OTHER clusters (tag condition restricts this)
  ❌ Create or delete ASGs
  ❌ Access EC2 instances directly
```

---

## Helm Chart Summary

| Chart | Purpose | Namespace | IRSA Role |
|---|---|---|---|
| `metrics-server` | CPU/memory metrics (enables HPA) | kube-system | None |
| `aws-load-balancer-controller` | Provisions ALBs from Ingress resources | kube-system | `alb-controller-role` |
| `cluster-autoscaler` | Scales EC2 node groups based on pod demand | kube-system | `cluster-autoscaler-role` |

### Install Order (managed by Terraform `depends_on`)

```
module.eks
    │
    ├── helm_release.metrics_server          ← No deps, installs first
    │
    ├── helm_release.aws_load_balancer_controller
    │   depends_on: [eks, iam_attachment.alb]
    │
    └── helm_release.cluster_autoscaler
        depends_on: [eks, iam_attachment.ca, metrics_server]
```

---

## Verifying IAM Roles After Apply

```bash
# 1. List all IAM roles created by Terraform
aws iam list-roles --query 'Roles[?contains(RoleName, `three-tier`)].RoleName'

# 2. Verify GitHub OIDC provider
aws iam list-open-id-connect-providers
# Look for: https://token.actions.githubusercontent.com

# 3. Check ALB Controller is using IRSA correctly
kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o yaml
# Should show: eks.amazonaws.com/role-arn annotation

# 4. Verify Cluster Autoscaler is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
# Should show: Running

# 5. Test GitHub Actions role (simulate from CLI)
aws sts assume-role \
  --role-arn arn:aws:iam::<ACCOUNT>:role/three-tier-eks-cluster-github-actions-role \
  --role-session-name test
# Should return: Credentials with AccessKeyId, SecretAccessKey, SessionToken
```
