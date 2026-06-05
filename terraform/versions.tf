# ─────────────────────────────────────────────────────────────────────────────
# terraform/versions.tf — Required Providers and Terraform Version Constraints
# ─────────────────────────────────────────────────────────────────────────────
#
# WHY A SEPARATE versions.tf?
# ─────────────────────────────────────────────────────────────────────────────
# Separating version constraints into their own file is a Terraform best practice:
#   - Easy to find and update version requirements
#   - Clear dependency documentation for new team members
#   - Prevents version drift across environments
#
# TERRAFORM VERSION CONSTRAINT SYNTAX:
# ─────────────────────────────────────────────────────────────────────────────
# "~> 1.7"    = >= 1.7, < 2.0  (allows patch and minor updates, not major)
# ">= 5.0"   = any version >= 5.0 (less restrictive)
# "= 5.31.0" = exactly this version (most restrictive, maximum reproducibility)
#
# For production: use "~>" to allow security patches but prevent breaking changes.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  # Minimum Terraform CLI version required to apply this configuration.
  # Terraform 1.7+ includes:
  #   - Improved moved blocks
  #   - Test framework improvements
  #   - Better state management
  required_version = "~> 1.7"

  required_providers {
    # AWS Provider — manages all AWS resources (VPC, EKS, ECR, IAM, etc.)
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.47"
      # 5.x is the current major version with full EKS support.
      # Allows minor updates (5.48, 5.49...) but not 6.x (breaking changes).
    }

    # TLS Provider — generates TLS certificates and RSA keys locally.
    # Used for: generating the EKS cluster's CA, node group key pairs.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    # Kubernetes Provider — manages K8s resources via Terraform.
    # Used for: applying the ALB Controller ServiceAccount, ConfigMaps.
    # Note: For most K8s resources, we use kubectl (scripts/) not Terraform.
    # Terraform manages K8s only for resources tightly coupled to AWS infra.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }

    # Helm Provider — installs Helm charts via Terraform.
    # Used for: AWS Load Balancer Controller, Cluster Autoscaler, metrics-server.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}
