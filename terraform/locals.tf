# ─────────────────────────────────────────────────────────────────────────────
# terraform/locals.tf — Local Values (Computed, Reusable Constants)
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT ARE LOCALS?
# ─────────────────────────────────────────────────────────────────────────────
# locals {} defines named expressions you can reuse across the configuration.
# They are NOT variables (can't be overridden by -var) and NOT outputs (not exported).
# Think of them as constants computed from other values.
#
# USE LOCALS TO:
#   1. Avoid repeating complex expressions
#   2. Compute derived values from variables
#   3. Centralize naming conventions
#   4. Build common tag maps for resource groups
#
# Example without locals (repeated 10 times across .tf files):
#   name = "${var.cluster_name}-${var.environment}-backend"
#
# Example with locals (DRY - Don't Repeat Yourself):
#   name = local.backend_name
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # ─────────────────────────────────────────────────────────────────────────
  # NAMING CONVENTION
  # ─────────────────────────────────────────────────────────────────────────
  # All resource names follow: <cluster_name>-<component>
  # This ensures all AWS resources for this cluster are easily identifiable.

  # Common prefix for ALL resource names
  name_prefix = var.cluster_name
  # Example: "three-tier-eks-cluster"

  # Component-specific names
  eks_name        = local.name_prefix
  vpc_name        = "${local.name_prefix}-vpc"
  backend_ecr     = "${local.name_prefix}-backend"
  frontend_ecr    = "${local.name_prefix}-frontend"

  # ─────────────────────────────────────────────────────────────────────────
  # AWS ACCOUNT / REGION
  # ─────────────────────────────────────────────────────────────────────────
  account_id   = data.aws_caller_identity.current.account_id
  region       = var.aws_region
  ecr_registry = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # ─────────────────────────────────────────────────────────────────────────
  # COMMON TAGS — Applied to all resources via module tags inputs
  # ─────────────────────────────────────────────────────────────────────────
  # While the AWS provider default_tags handles most resource tags,
  # some modules accept their own tags input. We define them once here.
  common_tags = {
    Project     = "three-tier-eks-portfolio"
    Environment = var.environment
    ManagedBy   = "terraform"
    Cluster     = var.cluster_name
    Owner       = "Harshads-git"
  }

  # ─────────────────────────────────────────────────────────────────────────
  # EKS NODE GROUP LABELS
  # ─────────────────────────────────────────────────────────────────────────
  # Labels applied to K8s Node objects (not AWS tags).
  # Used for: nodeSelector in pod specs (schedule pods to specific node groups).
  # In multi-node-group setups: "role=general" vs "role=spot" vs "role=memory"
  node_labels = {
    "role"                          = "general"
    "node.kubernetes.io/cluster"    = var.cluster_name
    "node.kubernetes.io/node-group" = "general"
  }

  # ─────────────────────────────────────────────────────────────────────────
  # K8S CLUSTER ADDONS
  # ─────────────────────────────────────────────────────────────────────────
  # VPC CNI resolves pod IP addresses from the VPC CIDR.
  # Each pod gets a REAL VPC IP (not a virtual overlay IP like flannel).
  # This is what enables `target-type: ip` for ALB and inter-pod VPC routing.
  cluster_addons = {
    # CoreDNS: Kubernetes cluster DNS server.
    # Resolves: mongo-service.three-tier.svc.cluster.local → ClusterIP
    coredns = {
      most_recent = true
    }
    # kube-proxy: Maintains network rules on each node (iptables/ipvs).
    # Routes: ClusterIP:port → pod IP:targetPort
    kube-proxy = {
      most_recent = true
    }
    # vpc-cni: AWS VPC Container Network Interface.
    # Assigns VPC IPs directly to pods (native VPC networking).
    vpc-cni = {
      most_recent = true
    }
  }

  # ─────────────────────────────────────────────────────────────────────────
  # EBS CSI DRIVER ADD-ON
  # ─────────────────────────────────────────────────────────────────────────
  # The EBS CSI Driver enables PersistentVolumeClaims to dynamically provision
  # AWS EBS volumes. Required for MongoDB's StatefulSet PVC template (Day 5).
  # Without this, MongoDB's PVC will be stuck in "Pending" state forever.
  # Installed as a separate add-on (not in cluster_addons above) because
  # it requires its own IRSA role.
  ebs_csi_addon_name = "aws-ebs-csi-driver"
}
