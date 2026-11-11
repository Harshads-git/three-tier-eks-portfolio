# ─────────────────────────────────────────────────────────────────────────────
# terraform/velero.tf — S3 Storage & IAM IRSA Role for Velero Disaster Recovery
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE:
#   Provisions the AWS cloud resources required by Velero v1.14+ for enterprise
#   backup, point-in-time state replication, and disaster recovery:
#   1. Dedicated, encrypted, private S3 bucket for cluster etcd/CRD backups.
#   2. Fine-grained IAM policy granting S3 object access and EBS snapshot management.
#   3. OIDC-federated IAM Role (IRSA) allowing Velero's ServiceAccount to authenticate
#      without hardcoded static AWS credentials.
#
# ARCHITECTURE & RECOVERY OBJECTIVES:
#   - RPO (Recovery Point Objective): 24 hours (daily scheduled snapshots + on-demand)
#   - RTO (Recovery Time Objective): < 15 minutes (full cluster state recreation)
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# S3 BUCKET: VELERO CLOUD STORAGE LOCATION
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "velero" {
  bucket        = "${local.name_prefix}-velero-backups-${local.account_id}"
  force_destroy = false # Prevent accidental deletion of production backup snapshots

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-velero-backups"
    Component = "disaster-recovery"
  })
}

# Enforce S3 bucket versioning to protect against accidental backup deletion or ransomware
resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Server-Side Encryption (SSE-S3 AES-256)
resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public ingress to the backup repository
resource "aws_s3_bucket_public_access_block" "velero" {
  bucket = aws_s3_bucket.velero.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle management: Tier old backups to Standard-Infrequent Access, prune after 90 days
resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    id     = "velero-backup-lifecycle"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM POLICY: VELERO AWS PLUGIN PERMISSIONS
# ─────────────────────────────────────────────────────────────────────────────
# Velero requires permissions to:
# 1. Manage backup objects in the dedicated S3 bucket
# 2. Manage EBS Volume snapshots via AWS EC2 API for PersistentVolumes
resource "aws_iam_policy" "velero" {
  name        = "${local.name_prefix}-velero-policy"
  description = "Permissions for Velero to manage S3 backups and EBS volume snapshots"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2SnapshotPermissions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot"
        ]
        Resource = "*"
      },
      {
        Sid    = "S3BucketListPermissions"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.velero.arn
        ]
      },
      {
        Sid    = "S3ObjectManagementPermissions"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload"
        ]
        Resource = [
          "${aws_s3_bucket.velero.arn}/*"
        ]
      }
    ]
  })

  tags = merge(local.common_tags, {
    Component = "disaster-recovery"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM ROLE: IRSA TRUST POLICY FOR VELERO
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "velero" {
  name        = "${local.name_prefix}-velero-role"
  description = "IRSA role granting Velero pod identity access to S3 and EBS snapshots"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:velero:velero-server"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Component = "disaster-recovery"
  })
}

resource "aws_iam_role_policy_attachment" "velero" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────
output "velero_backup_bucket_name" {
  description = "S3 bucket name used for Velero disaster recovery backups"
  value       = aws_s3_bucket.velero.id
}

output "velero_role_arn" {
  description = "ARN of the IAM role for Velero IRSA pod identity"
  value       = aws_iam_role.velero.arn
}
