# ─────────────────────────────────────────────────────────────────────────────
# terraform/external-secrets-iam.tf — IAM IRSA Role for External Secrets Operator
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE:
#   Provides the External Secrets Operator (ESO) running in EKS with granular,
#   pod-level permissions to retrieve application secrets from AWS Secrets Manager
#   and AWS Systems Manager (SSM) Parameter Store via IRSA.
#
# SECURITY ARCHITECTURE:
#   1. Principle of Least Privilege:
#      - Restricted to secrets with prefix "three-tier/*"
#      - Read-only actions (GetSecretValue, DescribeSecret) — no delete/update!
#   2. IRSA Web Identity Federation:
#      - Only the ServiceAccount 'external-secrets-sa' in namespace 'external-secrets'
#        can assume this role. No static AWS credentials stored anywhere.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# IAM POLICY: SECRETS READ ACCESS
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_policy" "external_secrets" {
  name        = "${local.name_prefix}-external-secrets-policy"
  description = "Allows External Secrets Operator to read application secrets for Three-Tier EKS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        # Restrict strictly to this project's secret path
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:three-tier/*"
        ]
      },
      {
        Sid    = "SSMParameterStoreRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/three-tier/*"
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Component = "secrets-management"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM ROLE: IRSA TRUST POLICY
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "external_secrets" {
  name        = "${local.name_prefix}-external-secrets-role"
  description = "IRSA role for External Secrets Operator pod identity"

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
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Component = "secrets-management"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# POLICY ATTACHMENT
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────
output "external_secrets_role_arn" {
  description = "ARN of the IAM role for External Secrets Operator IRSA"
  value       = aws_iam_role.external_secrets.arn
}
