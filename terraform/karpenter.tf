# ─────────────────────────────────────────────────────────────────────────────
# terraform/karpenter.tf — Karpenter v1 Controller & Node Infrastructure
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE:
#   Provisions AWS infrastructure for Karpenter next-gen autoscaler:
#   1. SQS Interruption Queue & EventBridge Rules (Spot 2-min warning & rebalance)
#   2. Karpenter Node IAM Role & Instance Profile (assumed by worker EC2 nodes)
#   3. Karpenter Controller IAM Role (IRSA — manages EC2 fleet directly)
#
# WHY KARPENTER OVER CLUSTER AUTOSCALER?
#   - Direct EC2 Fleet API calls (sub-45s node spin-up vs 3-5min in ASGs)
#   - Dynamic instance selection: no need to manage 20 separate ASGs for instance types
#   - Aggressive consolidation: automatically downscales/replaces underutilized nodes
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# 1. SQS INTERRUPTION QUEUE & EVENT RULES
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${local.name_prefix}-karpenter-interruption"
  message_retention_seconds = 300 # 5 minutes
  sqs_managed_sse_enabled   = true

  tags = merge(local.common_tags, {
    Component = "karpenter-autoscaler"
  })
}

# Policy allowing EventBridge to publish to the SQS queue
resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECREventsToSQS"
        Effect = "Allow"
        Principal = {
          Service = ["events.amazonaws.com", "sqs.amazonaws.com"]
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# EventBridge Rule: Spot Interruption Warnings (2-minute advance notice)
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${local.name_prefix}-karpenter-spot-interruption"
  description = "Routes EC2 Spot interruption warnings to Karpenter SQS"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# EventBridge Rule: Rebalance Recommendations
resource "aws_cloudwatch_event_rule" "rebalance_recommendation" {
  name        = "${local.name_prefix}-karpenter-rebalance"
  description = "Routes EC2 instance rebalance recommendations to Karpenter SQS"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "rebalance_recommendation" {
  rule      = aws_cloudwatch_event_rule.rebalance_recommendation.name
  target_id = "KarpenterRebalanceQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# EventBridge Rule: Instance State-Change Notifications
resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${local.name_prefix}-karpenter-state-change"
  description = "Routes EC2 instance state-change notifications to Karpenter SQS"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "KarpenterStateChangeQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. KARPENTER NODE IAM ROLE & INSTANCE PROFILE
# ─────────────────────────────────────────────────────────────────────────────
# Assumed by EC2 instances provisioned dynamically by Karpenter
resource "aws_iam_role" "karpenter_node" {
  name = "${local.name_prefix}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Component = "karpenter-node"
  })
}

# Standard EKS Worker Node Policies
resource "aws_iam_role_policy_attachment" "karpenter_node_eks" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${local.name_prefix}-karpenter-node-profile"
  role = aws_iam_role.karpenter_node.name

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. KARPENTER CONTROLLER IAM ROLE (IRSA)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_policy" "karpenter_controller" {
  name        = "${local.name_prefix}-karpenter-controller-policy"
  description = "Allows Karpenter controller to launch and terminate EC2 instances and read SQS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2FleetManagement"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeImages",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts"
        ]
        Resource = "*"
      },
      {
        Sid    = "PassNodeRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        Sid    = "SQSInterruptionAccess"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid    = "EKSClusterDescribe"
        Effect = "Allow"
        Action = "eks:DescribeCluster"
        Resource = module.eks.cluster_arn
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role" "karpenter_controller" {
  name = "${local.name_prefix}-karpenter-controller-role"

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
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:karpenter:karpenter"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Component = "karpenter-controller"
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────
output "karpenter_node_role_arn" {
  description = "ARN of the IAM role assumed by Karpenter provisioned nodes"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_instance_profile_name" {
  description = "Name of the instance profile assigned to Karpenter nodes"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_controller_role_arn" {
  description = "ARN of the IRSA IAM role for Karpenter controller"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_interruption_queue_name" {
  description = "Name of the SQS queue handling EC2 interruption notifications"
  value       = aws_sqs_queue.karpenter_interruption.name
}
