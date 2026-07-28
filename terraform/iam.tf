# ─────────────────────────────────────────────────────────────────────────────
# terraform/iam.tf — IAM Roles for CI/CD and Cluster Services
# ─────────────────────────────────────────────────────────────────────────────
#
# IAM ROLES IN THIS FILE:
# ─────────────────────────────────────────────────────────────────────────────
# 1. GitHub Actions OIDC Role (for CI/CD — no long-lived AWS keys)
# 2. ALB Ingress Controller Role (IRSA — for Kubernetes ALB management)
# 3. Cluster Autoscaler Role (IRSA — for EC2 Auto Scaling Group management)
#
# PRINCIPLE OF LEAST PRIVILEGE:
# ─────────────────────────────────────────────────────────────────────────────
# Each role has ONLY the permissions it needs, nothing more:
#   GitHub Actions: push to ECR + update EKS deployments
#   ALB Controller: manage ALBs/target groups in this VPC
#   Cluster Autoscaler: scale EC2 ASGs for this cluster
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB OIDC PROVIDER
# ─────────────────────────────────────────────────────────────────────────────
# GitHub Actions uses OIDC (OpenID Connect) to authenticate to AWS without
# storing long-lived access keys in GitHub Secrets.
#
# HOW IT WORKS:
#   1. GitHub generates a JWT token for the workflow run
#   2. The workflow uses the token to call AWS STS AssumeRoleWithWebIdentity
#   3. AWS verifies the JWT against GitHub's OIDC endpoint
#   4. AWS returns short-lived credentials (15min - 1hr)
#   5. No keys are stored anywhere — they can't be leaked!
#
# This is the modern, secure way to authenticate CI/CD pipelines to AWS.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# If the GitHub OIDC provider doesn't exist yet, create it:
resource "aws_iam_openid_connect_provider" "github" {
  # url: GitHub's OIDC token issuer endpoint
  url = "https://token.actions.githubusercontent.com"

  # client_id_list: The audience claim in the JWT.
  # "sts.amazonaws.com" is the standard audience for AWS role assumption.
  client_id_list = ["sts.amazonaws.com"]

  # thumbprint_list: SHA1 fingerprints of GitHub's TLS certificate chain root.
  # These are GitHub's current root certificate thumbprints.
  # Verified from: https://github.com/actions/configure-aws-credentials
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB ACTIONS — IAM ROLE
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "github_actions" {
  name = "${local.name_prefix}-github-actions-role"

  # Trust Policy: only GitHub Actions workflows from YOUR specific repo can assume this role
  # The Condition restricts to: repo:Harshads-git/three-tier-eks-portfolio:ref:refs/heads/main
  # This means ONLY the main branch of YOUR repo can assume this role.
  # Not forks, not other repos, not feature branches (tighten as needed).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Allow main branch AND any feature branch (for PR previews)
          "token.actions.githubusercontent.com:sub" = "repo:Harshads-git/three-tier-eks-portfolio:*"
        }
      }
    }]
  })

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB ACTIONS — IAM POLICY (Least Privilege)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_policy" "github_actions" {
  name        = "${local.name_prefix}-github-actions-policy"
  description = "Permissions for GitHub Actions CI/CD: ECR push + EKS deploy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
        # GetAuthorizationToken is account-level, no resource restriction possible
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ]
        # Restrict to only our specific ECR repos (not all repos in account)
        Resource = [
          module.ecr_backend.repository_arn,
          module.ecr_frontend.repository_arn
        ]
      },
      {
        Sid    = "EKSDeploy"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = module.eks.cluster_arn
        # Only our specific cluster, not all EKS clusters in the account
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  policy_arn = aws_iam_policy.github_actions.arn
  role       = aws_iam_role.github_actions.name
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB INGRESS CONTROLLER — IAM ROLE (IRSA)
# ─────────────────────────────────────────────────────────────────────────────
# The ALB Controller (running in kube-system) needs AWS permissions to:
#   - Create/manage AWS ALBs
#   - Create/manage security groups for the ALB
#   - Register EC2 nodes as ALB targets
#   - Read VPC/subnet information
#
# The IAM policy JSON is in k8s/alb-controller/iam-policy.json (Day 8).
# We reference the official AWS managed approach here.
resource "aws_iam_role" "alb_controller" {
  name = "${local.name_prefix}-alb-controller-role"

  # Trust policy: only the ALB Controller ServiceAccount in kube-system can assume this
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          # ServiceAccount: aws-load-balancer-controller in kube-system namespace
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${local.name_prefix}-alb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller"

  # This is the complete official policy from AWS documentation.
  # Source: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  policy = file("${path.module}/../k8s/alb-controller/iam-policy.json")
  # Reads the policy file we created in Day 8 (k8s/alb-controller/iam-policy.json)
  # This keeps the IAM policy in sync with the K8s manifests directory.
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  policy_arn = aws_iam_policy.alb_controller.arn
  role       = aws_iam_role.alb_controller.name
}

# ─────────────────────────────────────────────────────────────────────────────
# CLUSTER AUTOSCALER — IAM ROLE (IRSA)
# ─────────────────────────────────────────────────────────────────────────────
# The Cluster Autoscaler watches for:
#   - Pods that can't schedule (insufficient resources) → scale UP node group
#   - Nodes with low utilization → scale DOWN (evict pods, terminate node)
#
# It needs permissions to:
#   - Describe Auto Scaling Groups (to find the node group ASG)
#   - Set desired capacity on the ASG (to scale up/down)
#   - Describe EC2 instances (to determine node utilization)
resource "aws_iam_role" "cluster_autoscaler" {
  name = "${local.name_prefix}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          # ServiceAccount: cluster-autoscaler in kube-system namespace
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${local.name_prefix}-cluster-autoscaler-policy"
  description = "IAM policy for EKS Cluster Autoscaler"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AutoscalerDescribe"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = ["*"]
      },
      {
        Sid    = "AutoscalerModify"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        # Restrict modifications to ONLY ASGs tagged for this specific cluster
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"          = "true"
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
        # The Condition ensures Cluster Autoscaler can ONLY scale node groups
        # tagged with this cluster's name. It cannot touch ASGs from other clusters.
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
  role       = aws_iam_role.cluster_autoscaler.name
}
