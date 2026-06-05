# ─────────────────────────────────────────────────────────────────────────────
# terraform/outputs.tf — All Output Value Declarations
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT ARE TERRAFORM OUTPUTS?
# ─────────────────────────────────────────────────────────────────────────────
# Outputs expose values from your Terraform configuration:
#   1. Displayed in the terminal after `terraform apply`
#   2. Readable with: terraform output <output_name>
#   3. Used by other Terraform modules via: module.<name>.<output>
#   4. Used by scripts and CI/CD pipelines to configure kubectl, Helm, etc.
#
# SENSITIVE OUTPUTS:
# ─────────────────────────────────────────────────────────────────────────────
# sensitive = true: Terraform hides the value in terminal output (shows <sensitive>).
# The value IS stored in state (still readable via `terraform output -raw <name>`).
# Use for: passwords, tokens, private keys, connection strings.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# VPC OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID — used by EKS, security groups, and the ALB controller."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs — EKS worker nodes are deployed here."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "List of public subnet IDs — ALB and NAT Gateway are deployed here."
  value       = module.vpc.public_subnets
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS CLUSTER OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name — used in kubeconfig and ALB controller Helm values."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint — used by kubectl and Terraform K8s provider."
  value       = module.eks.cluster_endpoint
  sensitive   = true
  # Marked sensitive: the endpoint URL reveals cluster infrastructure details.
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate — used to verify the API server's TLS cert."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version running on the EKS cluster."
  value       = module.eks.cluster_version
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL — needed to create IRSA IAM roles (ALB controller, Cluster Autoscaler)."
  value       = module.eks.cluster_oidc_issuer_url
  # Example: https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE1234567890
  # Used in IAM trust policy: "Federated": "arn:aws:iam::123:oidc-provider/<this-url-without-https>"
}

# ─────────────────────────────────────────────────────────────────────────────
# KUBECONFIG OUTPUT — Key for CI/CD Integration
# ─────────────────────────────────────────────────────────────────────────────

output "configure_kubectl" {
  description = "Command to configure kubectl to point to this EKS cluster. Run this after terraform apply."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
  # After `terraform apply` completes, run this exact command:
  #   aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1
  # This adds/updates the kubeconfig entry for this cluster.
  # Verify with: kubectl cluster-info
  #              kubectl get nodes -n three-tier
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "backend_ecr_repository_url" {
  description = "ECR repository URL for the backend image. Used in docker push and K8s deployment.yaml."
  value       = module.ecr_backend.repository_url
  # Example: 123456789012.dkr.ecr.us-east-1.amazonaws.com/three-tier-backend
  # Use in: docker tag three-tier-backend:local <this-url>:latest
  # Use in: k8s/backend/deployment.yaml image field
}

output "backend_ecr_repository_arn" {
  description = "ECR repository ARN for the backend — used in IAM policies for CI/CD role."
  value       = module.ecr_backend.repository_arn
}

output "frontend_ecr_repository_url" {
  description = "ECR repository URL for the frontend image."
  value       = module.ecr_frontend.repository_url
}

output "frontend_ecr_repository_arn" {
  description = "ECR repository ARN for the frontend."
  value       = module.ecr_frontend.repository_arn
}

output "ecr_registry" {
  description = "ECR registry URL (without repository path) — used in docker login command."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  # ECR login command:
  #   aws ecr get-login-password --region <region> | \
  #     docker login --username AWS --password-stdin <this-output>
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS ACCOUNT OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "aws_account_id" {
  description = "AWS Account ID — used in ARN construction and ECR registry URL."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region where all resources are deployed."
  value       = var.aws_region
}
