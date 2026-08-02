# AWS Cost Analysis — Three-Tier EKS Portfolio

## Monthly Cost Breakdown

| Service | Component | Unit Cost | Qty | Monthly Cost |
|---|---|---|---|---|
| **EKS** | Control plane | $0.10/hr | 1 | **$73** |
| **EC2** | t3.medium worker nodes | $0.0416/hr | 2 | **$60** |
| **EBS** | Node root volumes (20 GiB gp2 each) | $0.10/GB | 40 GB | **$4** |
| **EBS** | MongoDB PVC (5 GiB gp2) | $0.10/GB | 5 GB | **$0.50** |
| **EBS** | Prometheus storage (10 GiB gp2) | $0.10/GB | 10 GB | **$1** |
| **EBS** | Grafana + AlertManager (4 GiB gp2) | $0.10/GB | 4 GB | **$0.40** |
| **NAT Gateway** | 1× NAT (private subnet egress) | $0.045/hr | 1 | **$33** |
| **NAT Gateway** | Data processing | $0.045/GB | ~5 GB | **$0.23** |
| **ALB** | Application Load Balancer | $0.008/hr | 1 | **$5.84** |
| **ALB** | LCU (Load Balancer Capacity Units) | $0.008/LCU | ~5 LCU | **$2.88** |
| **ECR** | Container image storage | $0.10/GB | ~2 GB | **$0.20** |
| **S3** | Terraform state storage | $0.023/GB | <1 GB | **$0.01** |
| **DynamoDB** | Terraform lock table | On-demand | low | **$0.01** |
| **CloudWatch** | EKS control plane logs | $0.50/GB | ~1 GB | **$0.50** |
| | | | **TOTAL** | **~$181/month** |

---

## Cost by Environment

```
Development (cluster running 8 hrs/day, weekdays only):
  EC2:  $60 × (8/24) × (20/30) = $13.33
  EKS:  $73 (always-on, minimal cost to pause)
  NAT:  $33 × (8/24) × (20/30) = $7.33
  Rest: ~$10
  Total: ~$103/month (savings of $78/month vs always-on)

Production (always-on, 24×7):
  Total: ~$181/month (as above)

Cost Control Tip: terraform destroy between dev sessions
  Saves: EC2 ($60) + NAT ($33) = $93/month
  EKS control plane cannot be "paused" — must destroy/recreate ($73)
  Create/destroy in ~20 minutes: terraform apply / terraform destroy
```

---

## Cost Optimization Strategies

### 1. Spot Instances — 60-70% EC2 Savings

```hcl
# terraform/eks.tf — Add a spot node group alongside general group
eks_managed_node_groups = {
  general = { ... }  # Keep on-demand for critical pods

  spot = {
    instance_types = ["t3.medium", "t3a.medium", "t3.large"]
    # Multiple instance types = more spot capacity available

    capacity_type = "SPOT"
    # SPOT: AWS can terminate with 2-minute notice
    # Price: ~$0.0125/hr vs $0.0416/hr (70% savings)

    min_size = 0
    desired_size = 2
    max_size = 10

    # Taints: prevent critical pods from running on spot
    taints = [{
      key    = "spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
    # Pods with toleration: [{key="spot",operator="Equal",value="true"}]
    # can run on spot nodes. Others cannot.
  }
}

# Move frontend to spot (stateless, tolerates interruption):
# k8s/frontend/deployment.yaml:
# tolerations:
#   - key: spot
#     operator: Equal
#     value: "true"
#     effect: NoSchedule
```

Savings: `2 spot nodes × $0.0125 × 720 = $18/month` vs `$60/month` on-demand

### 2. Single NAT Gateway vs Per-AZ NAT

```hcl
# Current (portfolio):
single_nat_gateway = true      # 1 NAT = $33/month

# Production (HA):
single_nat_gateway     = false
one_nat_gateway_per_az = true   # 2 NAT = $66/month
# Trade-off: $33/month for cross-AZ NAT resilience
```

### 3. Savings Plans — Up to 40% EC2 Savings

If running the cluster continuously for 12 months:
- **1-year Compute Savings Plan**: ~27% discount on EC2 (no upfront)
- **1-year Reserved Instance**: ~37% discount (upfront payment)
- **3-year Reserved**: up to 54% off

Savings: `$60/month EC2 × 0.37 savings = $22/month saved`

### 4. Cluster Autoscaler Scale-Down to 1 Node Off-Hours

```hcl
# terraform/helm.tf — Cluster Autoscaler config
set {
  name  = "extraArgs.scale-down-unneeded-time"
  value = "5m"
}
# With scale-down enabled:
#   Off-hours: all pods on node-1 → CA terminates node-2
#   Saves: 1 t3.medium ($30/month) when running 12 hrs/day
```

### 5. ECR Lifecycle Policies (Already Implemented)

```
Current lifecycle policy: keep 10 images
10 images × 90 MB/image = 900 MB = $0.09/month
vs no lifecycle policy = unlimited growth
```

### 6. CloudWatch Log Retention

```bash
# Default: CloudWatch logs retained forever ($0.50/GB/month)
# Set 30-day retention on EKS control plane log groups:
aws logs put-retention-policy \
  --log-group-name /aws/eks/three-tier-eks-cluster/cluster \
  --retention-in-days 30
```

---

## Cost vs Development Time Analysis

```
Cost to run cluster for interview/portfolio project:

Option 1: Always-on (bad)
  $181/month × 3 months prep = $543

Option 2: Destroy when not using (recommended)
  terraform apply before working   (~20 min)
  terraform destroy after working  (~15 min)
  Average: 4 hrs/day, 20 days/month = 80 hrs
  Cost: $0.10 × 80 (EKS) + $0.0416 × 80 × 2 (EC2) + $0.045 × 80 (NAT)
      = $8 + $6.66 + $3.60 = ~$18.26/month

Option 3: Minimal always-on
  Keep: EKS ($73) + ECR ($0.20) + S3/DynamoDB ($0.02) = $73.22/month
  Spin up EC2 nodes only when actively working
```

---

## Budget Alerts Setup

```bash
# Set up AWS Budgets to alert before overspending
aws budgets create-budget \
  --account-id <ACCOUNT_ID> \
  --budget '{
    "BudgetName": "three-tier-eks-monthly",
    "BudgetLimit": {"Amount": "200", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "FORECASTED",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "your-email@example.com"
    }]
  }]'
# Alert at 80% of $200 = alert when forecast reaches $160
```
