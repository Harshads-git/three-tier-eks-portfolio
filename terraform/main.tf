# ─────────────────────────────────────────────────────────────────────────────
# terraform/main.tf — Root Module: Provider Config & Remote State Backend
# ─────────────────────────────────────────────────────────────────────────────
#
# FILE STRUCTURE CONVENTION:
# ─────────────────────────────────────────────────────────────────────────────
# main.tf       → provider configuration, terraform backend, module calls
# variables.tf  → all input variable declarations
# outputs.tf    → all output value declarations
# versions.tf   → required_providers and terraform version constraint
# *.tf          → specific resource files (vpc.tf, eks.tf, ecr.tf, iam.tf)
#
# WHY THIS SEPARATION?
# Files are small and focused. In large codebases, you can quickly find
# "where is the VPC defined?" (vpc.tf), "what inputs does this take?" (variables.tf)
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORM BACKEND — Remote State Storage
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT IS TERRAFORM STATE?
# terraform.tfstate is a JSON file that maps your Terraform config to real AWS resources.
# Without it, Terraform doesn't know what already exists and would try to recreate everything.
#
# WHERE TO STORE STATE:
#   Local (terraform.tfstate):
#     ✅ Simple for solo development
#     ❌ Breaks team collaboration (state not shared)
#     ❌ No locking (two people running tf apply simultaneously = corruption)
#     ❌ No backup (accidentally deleted = you lose the mapping)
#
#   S3 Remote Backend (our approach):
#     ✅ Shared state across team members
#     ✅ DynamoDB locking prevents simultaneous applies
#     ✅ Versioned S3 bucket (can restore previous state if corrupted)
#     ✅ Encrypted at rest (S3 server-side encryption)
#     ✅ Works with CI/CD pipelines (GitHub Actions Day 24)
#
# BACKEND BOOTSTRAPPING PROBLEM:
# ─────────────────────────────────────────────────────────────────────────────
# The S3 bucket and DynamoDB table used for state CANNOT be managed by the same
# Terraform config that uses them (chicken-and-egg problem).
#
# Solution: Create them manually (once) before running `terraform init`:
#   aws s3api create-bucket \
#     --bucket three-tier-eks-terraform-state \
#     --region us-east-1
#
#   aws s3api put-bucket-versioning \
#     --bucket three-tier-eks-terraform-state \
#     --versioning-configuration Status=Enabled
#
#   aws s3api put-bucket-encryption \
#     --bucket three-tier-eks-terraform-state \
#     --server-side-encryption-configuration \
#       '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]}'
#
#   aws dynamodb create-table \
#     --table-name three-tier-eks-terraform-locks \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region us-east-1
#
# See: scripts/setup-terraform-backend.sh for the full automated setup.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  backend "s3" {
    # S3 bucket for state storage
    # ⚠️  Replace with YOUR unique bucket name (S3 bucket names are globally unique)
    bucket = "three-tier-eks-terraform-state"

    # Path within the bucket for this state file.
    # Using a path allows multiple projects/environments in one bucket:
    #   three-tier-portfolio/dev/terraform.tfstate
    #   three-tier-portfolio/prod/terraform.tfstate
    key = "three-tier-portfolio/terraform.tfstate"

    region = "us-east-1"

    # Encrypt state at rest using AWS KMS.
    # Terraform state often contains sensitive data (RDS passwords, cert keys).
    encrypt = true

    # DynamoDB table for state locking.
    # When someone runs `terraform apply`, a lock entry is created in DynamoDB.
    # Other `terraform apply` attempts fail with a clear error message.
    # Lock is automatically released when apply completes (or force-unlock if stuck).
    dynamodb_table = "three-tier-eks-terraform-locks"

    # Profile (optional): Use a specific AWS CLI profile.
    # Useful when managing multiple AWS accounts.
    # profile = "three-tier-prod"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS PROVIDER CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region

  # Default tags applied to ALL AWS resources created by this Terraform config.
  # This is much better than adding tags to each resource individually:
  #   1. Consistent tagging across ALL resources
  #   2. Easy cost allocation by Project, Environment, etc.
  #   3. AWS Cost Explorer can filter by these tags
  #   4. AWS Config rules can enforce tag compliance
  default_tags {
    tags = {
      Project     = "three-tier-eks-portfolio"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "Harshads-git"
      Repository  = "https://github.com/Harshads-git/three-tier-eks-portfolio"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# KUBERNETES & HELM PROVIDERS
# ─────────────────────────────────────────────────────────────────────────────
# These providers need the EKS cluster to exist before they can be configured.
# We use `data` sources to pull the cluster connection details after EKS is created.
# The `depends_on` in modules ensures the correct apply order.

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # Uses the AWS CLI to get temporary credentials for kubectl.
    # The aws eks get-token command exchanges AWS credentials for a K8s token.
    # This avoids storing K8s tokens in Terraform state.
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
    "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region]
    }
  }
}
