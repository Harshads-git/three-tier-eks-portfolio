# ─────────────────────────────────────────────────────────────────────────────
# terraform/data.tf — Data Sources (Read-Only AWS Resources)
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT IS A DATA SOURCE?
# ─────────────────────────────────────────────────────────────────────────────
# Data sources READ existing AWS resources — they never CREATE or MODIFY anything.
# Use them when:
#   1. You need info about resources managed OUTSIDE this Terraform config
#   2. You need AWS account metadata (caller identity, region, AZs)
#   3. You need to compute dynamic values from the AWS environment
#
# Syntax difference:
#   resource "aws_vpc" "main" { ... }   ← creates/manages a VPC
#   data "aws_vpc" "existing" { ... }   ← reads an existing VPC
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# AWS CALLER IDENTITY — Who is running Terraform?
# ─────────────────────────────────────────────────────────────────────────────
# Returns information about the AWS identity used by the current session.
# Called on every `terraform plan/apply` via AWS STS GetCallerIdentity API.
#
# Attributes available:
#   data.aws_caller_identity.current.account_id  → "123456789012"
#   data.aws_caller_identity.current.arn          → "arn:aws:iam::123456789012:user/harsha"
#   data.aws_caller_identity.current.user_id      → "AIDAXXXXXXXXXXXXXXXXX"
#
# Used for:
#   - ECR registry URL: "<account_id>.dkr.ecr.<region>.amazonaws.com"
#   - IAM ARN construction without hardcoding account IDs
#   - outputs.tf ecr_registry output
data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# AWS REGION — Current region
# ─────────────────────────────────────────────────────────────────────────────
# Returns info about the current AWS region.
# data.aws_region.current.name → "us-east-1"
# Used as a fallback when var.aws_region is not available in a sub-expression.
data "aws_region" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# AVAILABLE AVAILABILITY ZONES
# ─────────────────────────────────────────────────────────────────────────────
# Returns all AZs available in the current region.
# In us-east-1: ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1e", "us-east-1f"]
#
# filter: Only return AZs that are in "available" state (not impaired).
# Excludes: "information", "impaired" state AZs (rare but real AWS incidents).
#
# We use this to validate var.availability_zones against actual available AZs.
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
    # "opt-in-not-required" = standard AZ (no opt-in needed)
    # Excludes Local Zones (wavelength zones that require explicit opt-in)
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS CLUSTER AUTH TOKEN — For kubectl/K8s operations post-cluster creation
# ─────────────────────────────────────────────────────────────────────────────
# After the EKS cluster is created, we need an auth token to interact with it.
# This data source calls `aws eks get-token` and returns a short-lived token.
# Used by the Kubernetes and Helm providers in main.tf.
#
# Note: We use the exec {} approach in providers (main.tf) instead of this
# data source directly, because exec{} auto-refreshes the token, while
# this data source caches the token for the entire Terraform run.
# Keeping this here for reference and potential future use.
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
  # This data source is evaluated AFTER module.eks is created.
  # Terraform understands the implicit dependency.
}
