# ─────────────────────────────────────────────────────────────────────────────
# terraform/ecr.tf — ECR Repositories for Backend and Frontend
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT IS ECR?
# ─────────────────────────────────────────────────────────────────────────────
# Amazon Elastic Container Registry (ECR) is a fully managed Docker container
# image registry — the AWS equivalent of Docker Hub.
#
# WHY ECR INSTEAD OF DOCKER HUB?
# ─────────────────────────────────────────────────────────────────────────────
# 1. SECURITY: Images stay within AWS (no public internet for image pulls in EKS)
# 2. IAM INTEGRATION: EKS nodes authenticate automatically via IAM (no docker login)
# 3. SPEED: ECR in the same region as EKS = fast pulls (<1s for cached layers)
# 4. LIFECYCLE POLICIES: Auto-delete old images to control storage costs
# 5. SCAN ON PUSH: Automatic CVE scanning via Amazon Inspector (free basic scan)
# 6. IMMUTABLE TAGS: Prevent overwriting existing image tags (accidental overwrites)
#
# USING terraform-aws-modules/ecr:
# The official ECR module handles:
#   - aws_ecr_repository (the registry)
#   - aws_ecr_lifecycle_policy (auto-delete old images)
#   - aws_ecr_repository_policy (IAM access control)
# ─────────────────────────────────────────────────────────────────────────────

module "ecr_backend" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.6"

  repository_name = local.backend_ecr
  # Name: "three-tier-eks-cluster-backend"
  # Full URL: <account>.dkr.ecr.us-east-1.amazonaws.com/three-tier-eks-cluster-backend

  # ─────────────────────────────────────────────────────────────────────────
  # IMAGE MUTABILITY
  # ─────────────────────────────────────────────────────────────────────────
  # IMMUTABLE: Cannot overwrite an existing tag (e.g., :v1.0.0 can't be replaced)
  # This is a CRITICAL production security setting:
  #   ✅ Prevents accidental overwrites ("oops, I pushed broken code to :v1.0.0")
  #   ✅ Audit trail: every :v1.0.0 always points to the same exact image
  #   ✅ Reproducible deployments: :v1.0.0 deployed today = same image next year
  # MUTABLE (AVOID): Tags can be overwritten (":latest" being pushed repeatedly)
  repository_image_tag_mutability = "IMMUTABLE"

  # ─────────────────────────────────────────────────────────────────────────
  # VULNERABILITY SCANNING
  # ─────────────────────────────────────────────────────────────────────────
  # scan_on_push: Automatically scan images for CVEs when pushed to ECR.
  # Uses Amazon Inspector (basic tier is free).
  # Results visible in ECR Console and via:
  #   aws ecr describe-image-scan-findings --repository-name <name> --image-id imageTag=<tag>
  repository_image_scanning_configuration = {
    scan_on_push = true
  }

  # ─────────────────────────────────────────────────────────────────────────
  # ENCRYPTION
  # ─────────────────────────────────────────────────────────────────────────
  # Encrypt container layers at rest with KMS.
  # Default: AES-256 (S3-managed key). KMS: customer-managed key.
  # For compliance (SOC2, HIPAA): use KMS. For portfolio: AES-256 is fine.
  repository_encryption_type = "AES256"

  # ─────────────────────────────────────────────────────────────────────────
  # LIFECYCLE POLICY — Auto-delete old images
  # ─────────────────────────────────────────────────────────────────────────
  # ECR storage costs: ~$0.10 per GB per month.
  # A backend image is ~90MB. 100 images = 9 GB = $0.90/month.
  # Lifecycle policies auto-expire old images to control costs.
  #
  # RULE 1: Keep only the last N images tagged with a git SHA (our CI/CD pattern)
  # RULE 2: Delete any untagged images older than 1 day
  #         (untagged: build artifacts that failed to get a proper tag)
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.ecr_image_retention_count} images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          # Matches tags like: v1.0.0, v1.2.3, sha-abc123f
          # Our CI/CD tags with git SHA: sha-$(git rev-parse --short HEAD)
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_image_retention_count
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })

  # ─────────────────────────────────────────────────────────────────────────
  # REPOSITORY POLICY — IAM Access Control
  # ─────────────────────────────────────────────────────────────────────────
  # Who can push/pull images to this ECR repository?
  # EKS nodes: need pull access (to run containers)
  # CI/CD role: needs push access (to push new images after build)
  # Both are granted via their IAM roles, not via the repository policy.
  # For this portfolio: no additional policy needed (default allows account-level IAM).
  # The module creates a permissive account-level policy by default.

  tags = local.common_tags
}

module "ecr_frontend" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.6"

  repository_name                 = local.frontend_ecr
  repository_image_tag_mutability = "IMMUTABLE"

  repository_image_scanning_configuration = {
    scan_on_push = true
  }

  repository_encryption_type = "AES256"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.ecr_image_retention_count} images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_image_retention_count
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })

  tags = local.common_tags
}
