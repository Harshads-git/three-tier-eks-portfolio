# ─────────────────────────────────────────────────────────────────────────────
# terraform/variables.tf — All Input Variable Declarations
# ─────────────────────────────────────────────────────────────────────────────
#
# VARIABLE DECLARATION ANATOMY:
# ─────────────────────────────────────────────────────────────────────────────
# variable "name" {
#   type        = string|number|bool|list|map|object  (required for clarity)
#   description = "What this variable controls"       (required for docs)
#   default     = value                               (optional; no default = required input)
#   validation { ... }                               (optional; enforce constraints)
# }
#
# VARIABLE PRECEDENCE (highest to lowest):
#   1. -var="key=value" CLI flag
#   2. -var-file="terraform.tfvars" CLI flag
#   3. terraform.tfvars file (auto-loaded if present)
#   4. *.auto.tfvars files (auto-loaded alphabetically)
#   5. TF_VAR_name environment variables
#   6. Default values declared here
#   7. Interactive prompt (if no default and no other value)
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# CORE SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  type        = string
  description = "AWS region to deploy all resources in. EKS, VPC, ECR, and ALB will all be in this region."
  default     = "us-east-1"

  validation {
    # Validates format: us-east-1, eu-west-2, ap-southeast-1, etc.
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]{1}$", var.aws_region))
    error_message = "aws_region must be a valid AWS region (e.g., us-east-1, eu-west-2)."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment name. Used in resource names and tags."
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be one of: development, staging, production."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS CLUSTER SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster. Used in resource names across VPC, IAM, and EKS."
  default     = "three-tier-eks-cluster"

  validation {
    # EKS cluster names: lowercase alphanumeric and hyphens, 1-100 chars
    condition     = can(regex("^[a-z0-9-]{1,100}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, max 100 chars."
  }
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for the EKS cluster. Check AWS docs for supported versions."
  default     = "1.29"
  # EKS supported versions: typically n, n-1, n-2 (e.g., 1.29, 1.28, 1.27)
  # AWS end-of-life dates: check https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
}

# ─────────────────────────────────────────────────────────────────────────────
# NODE GROUP SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

variable "node_instance_type" {
  type        = string
  description = "EC2 instance type for EKS worker nodes. Determines CPU/memory available for pods."
  default     = "t3.medium"
  # INSTANCE TYPE GUIDE FOR THIS PROJECT:
  #   t3.small  (2 vCPU,  2 GiB): Bare minimum. May have OOM issues with MongoDB.
  #   t3.medium (2 vCPU,  4 GiB): Recommended for this portfolio project.
  #   t3.large  (2 vCPU,  8 GiB): Comfortable headroom for all 3 tiers.
  #   t3a.medium: AMD-based, ~10% cheaper than t3.medium, same specs.
  #
  # RESOURCE MATH for t3.medium (4 GiB = 4096 MB):
  #   K8s system overhead: ~700 MB (kube-system, aws-node, coredns)
  #   MongoDB: 256 MB request, 512 MB limit
  #   Backend (2 pods): 256 MB total request
  #   Frontend (2 pods): 128 MB total request
  #   Buffer: ~456 MB
  #   → t3.medium is the minimum for running all 3 tiers comfortably.
}

variable "node_desired_size" {
  type        = number
  description = "Desired number of EC2 worker nodes in the EKS node group."
  default     = 2
  # 2 nodes: both tiers can run on separate nodes (pod anti-affinity).
  # With 2 nodes in 2 AZs, any single-AZ failure still leaves 1 node running.
}

variable "node_min_size" {
  type        = number
  description = "Minimum number of EC2 worker nodes (Cluster Autoscaler lower bound)."
  default     = 1
  # Set to 1 to allow complete scale-down during off-hours (saves cost).
  # Set to 2 for high availability (pod anti-affinity won't work with 1 node).
}

variable "node_max_size" {
  type        = number
  description = "Maximum number of EC2 worker nodes (Cluster Autoscaler upper bound)."
  default     = 4
  # 4 nodes max: balances cost control with scaling capacity.
  # With 4 nodes, you can run up to 5 backend + 5 frontend + 1 mongo pods.
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC. All subnets will be carved from this range."
  default     = "10.0.0.0/16"
  # 10.0.0.0/16 gives 65,536 IP addresses (more than enough for any portfolio project).
  # Common VPC CIDRs: 10.0.0.0/16, 172.16.0.0/16, 192.168.0.0/16
  # Avoid overlapping with on-premises networks if using VPN/Direct Connect.
}

variable "availability_zones" {
  type        = list(string)
  description = "List of Availability Zones for VPC subnets. Use 2+ for high availability."
  default     = ["us-east-1a", "us-east-1b"]
  # 2 AZs: if one AZ has an outage, pods shift to the other AZ.
  # Change these if using a different region (e.g., eu-west-1a, eu-west-1b).
  # EKS requires at least 2 AZs for high availability.
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for private subnets (EKS worker nodes, MongoDB). Not internet-accessible."
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
  # Private subnets have NO route to the internet gateway.
  # EC2 nodes (EKS workers) live here — they access the internet via NAT Gateway.
  # MongoDB lives here — no internet exposure at all.
  # /24 = 256 IPs per subnet (251 usable — AWS reserves 5 per subnet).
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for public subnets (ALB, NAT Gateway). Internet-accessible."
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
  # Public subnets have a route to the Internet Gateway.
  # ONLY the ALB and NAT Gateway live here.
  # The ALB is internet-facing (receives traffic from users).
  # The NAT Gateway allows private subnet resources to reach the internet (outbound only).
  # Using /24 in the 10.0.101-102.x range to avoid overlap with private subnets.
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

variable "ecr_image_retention_count" {
  type        = number
  description = "Number of container images to keep in ECR per repository. Older images are auto-deleted."
  default     = 10
  # ECR lifecycle policies auto-delete old images to control storage costs.
  # Keep the last 10 images: enough for rollback history without excessive storage.
  # At ~50MB per image: 10 images × 2 repos = ~1 GB ECR storage (~$0.10/month)
}
