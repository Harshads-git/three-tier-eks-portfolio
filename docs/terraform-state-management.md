# Terraform State Management & Remote Backend

## Why Terraform State Matters

Terraform maintains a **state file** (`terraform.tfstate`) that maps your configuration to real AWS resources. It's how Terraform knows:
- Which resources already exist (to avoid recreating them)
- What the current configuration of each resource is (to compute diffs)
- Dependencies between resources (to determine apply order)

```
You write: aws_vpc.main { cidr = "10.0.0.0/16" }

Terraform state stores:
{
  "resource": "aws_vpc.main",
  "id": "vpc-0abc123def456789",    ← the REAL AWS resource ID
  "cidr_block": "10.0.0.0/16",
  "state": "available"
}

Next `terraform plan`:
  Reads current state → compares to config → shows diff → applies only changes
```

**Without state**: Terraform tries to CREATE everything on every apply. Your VPC already exists? It tries to create another one — and fails.

---

## Local State vs Remote State

```
Local State (terraform.tfstate on your laptop):
  ┌──────────────┐
  │  Your Laptop │
  │ tfstate file │
  └──────────────┘
  ❌ Only you can run terraform apply
  ❌ No locking — simultaneous applies corrupt state
  ❌ Laptop crashes = state lost = you've lost the mapping to AWS resources
  ❌ State may contain secrets (leaked in git if accidentally committed)

Remote State (S3 + DynamoDB):
  ┌──────────────┐    read/write    ┌───────────────────┐
  │  Your Laptop │ ──────────────► │  S3 (tfstate)     │
  └──────────────┘                 │  Versioned + KMS  │
                                   └───────────────────┘
  ┌─────────────────┐  lock/unlock  ┌───────────────────┐
  │ GitHub Actions  │ ──────────── │  DynamoDB (locks) │
  └─────────────────┘              └───────────────────┘
  ✅ Shared across team and CI/CD
  ✅ DynamoDB locking prevents concurrent applies
  ✅ S3 versioning = rollback to previous state if corrupted
  ✅ KMS encryption = sensitive values encrypted at rest
  ✅ Public access blocked = state not exposed
```

---

## Remote Backend Configuration

```hcl
terraform {
  backend "s3" {
    bucket         = "three-tier-eks-terraform-state"
    key            = "three-tier-portfolio/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true                              # KMS encryption
    dynamodb_table = "three-tier-eks-terraform-locks"  # State locking
  }
}
```

The `key` supports multi-environment state isolation in ONE bucket:
```
s3://three-tier-eks-terraform-state/
  ├── three-tier-portfolio/terraform.tfstate       ← production
  ├── three-tier-portfolio-dev/terraform.tfstate   ← development
  └── three-tier-portfolio-staging/terraform.tfstate ← staging
```

---

## Bootstrap Flow (One-Time Setup)

The state bucket cannot be created by Terraform itself (circular dependency). Run the bootstrap script once:

```bash
export BUCKET_NAME="three-tier-eks-terraform-state-<your-account-id>"
export AWS_REGION="us-east-1"
./scripts/setup-terraform-backend.sh
```

What the script creates:

| Resource | Configuration | Why |
|---|---|---|
| S3 Bucket | Globally unique name | Stores `terraform.tfstate` |
| S3 Versioning | Enabled | Restore previous state if corrupted |
| S3 Encryption | `aws:kms` | State may contain secrets |
| S3 Public Access | Blocked | Prevent accidental public exposure |
| DynamoDB Table | `PAY_PER_REQUEST` | State locking (prevents concurrent applies) |

---

## Terraform Workflow

```bash
# 1. Initialize — download providers, configure backend
cd terraform/
terraform init
# Output: "Successfully configured the backend S3!"
# Downloads: hashicorp/aws ~5.47, hashicorp/kubernetes ~2.27, hashicorp/helm ~2.13

# 2. Plan — show what will be created/changed/destroyed
terraform plan -var-file=terraform.tfvars
# Output: "Plan: 47 to add, 0 to change, 0 to destroy."
# Review carefully! Especially for 'destroy' operations.

# 3. Apply — create the infrastructure
terraform apply -var-file=terraform.tfvars
# Output: "Apply complete! Resources: 47 added."
# Takes ~15 minutes for EKS cluster creation.

# 4. Configure kubectl
aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1
kubectl get nodes   # Verify cluster is accessible

# 5. Destroy (teardown) — delete ALL infrastructure
terraform destroy -var-file=terraform.tfvars
# ⚠️  This deletes the EKS cluster, VPC, all resources.
# Required for cost control between development sessions.
```

---

## State Operations Reference

```bash
# View all resources in state
terraform state list

# View details of a specific resource
terraform state show aws_vpc.this

# Remove a resource from state (without deleting from AWS)
# Use case: if Terraform and AWS diverge (manual changes)
terraform state rm aws_vpc.this

# Import an existing AWS resource into state
# Use case: resource created manually, now manage it with Terraform
terraform import aws_vpc.this vpc-0abc123def456789

# Force-unlock a stuck lock (if apply was interrupted)
terraform force-unlock <LOCK_ID>
# Get LOCK_ID from: aws dynamodb scan --table-name three-tier-eks-terraform-locks

# View current outputs
terraform output                         # all outputs
terraform output configure_kubectl       # specific output
terraform output -raw cluster_endpoint   # raw value (no quotes)
```

---

## Variable Files

```
terraform/
├── variables.tf           ← Variable DECLARATIONS (type, description, default)
├── terraform.tfvars       ← Variable VALUES for production (gitignored!)
├── terraform.tfvars.example  ← Template with placeholder values (committed)
└── environments/
    ├── dev.tfvars         ← Development overrides
    └── prod.tfvars        ← Production values
```

Example `terraform.tfvars.example` (safe to commit):
```hcl
# Copy this file to terraform.tfvars and fill in real values
aws_region         = "us-east-1"
environment        = "production"
cluster_name       = "three-tier-eks-cluster"
cluster_version    = "1.29"
node_instance_type = "t3.medium"
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 4
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
```

---

## VPC Architecture — Subnet Tagging (Critical)

The most common EKS deployment failure: missing subnet tags.

```
Required tags for ALB Controller to work:

Public subnets (where ALB is placed):
  kubernetes.io/cluster/<cluster-name> = "shared"
  kubernetes.io/role/elb               = "1"   ← MISSING = ALB creation fails!

Private subnets (where EKS nodes run):
  kubernetes.io/cluster/<cluster-name> = "shared"
  kubernetes.io/role/internal-elb      = "1"
```

The `terraform-aws-modules/vpc` module applies these tags automatically when you use `public_subnet_tags` and `private_subnet_tags` input variables (configured in `vpc.tf`).

---

## Cost Breakdown (t3.medium, us-east-1, 2 nodes)

| Resource | Cost |
|---|---|
| EKS Control Plane | $0.10/hour = $72/month |
| 2× t3.medium EC2 | $0.0416/hour each = $60/month |
| NAT Gateway | $0.045/hour = $32/month + data transfer |
| ALB | ~$0.008/hour = $18/month + LCU |
| ECR Storage | ~$0.10/GB = ~$1/month |
| S3 State | ~$0.023/GB = negligible |
| DynamoDB Locks | PAY_PER_REQUEST = negligible |
| **Total** | **~$183/month** |

> **Cost control**: Run `terraform destroy` when not actively working. EKS control plane costs $0.10/hour even when idle. Always destroy at end of each session during development.

---

## Files in This Terraform Foundation

| File | Purpose |
|---|---|
| `versions.tf` | Provider version constraints |
| `main.tf` | Provider config, S3 backend, Kubernetes/Helm provider |
| `variables.tf` | All input variable declarations with validation |
| `vpc.tf` | VPC, subnets, NAT Gateway via community module |
| `outputs.tf` | All values exported after apply (cluster endpoint, ECR URLs) |
| `.gitignore` | Prevents state files, .terraform/, and tfvars from being committed |
| `scripts/setup-terraform-backend.sh` | One-time bootstrap for S3 + DynamoDB |
