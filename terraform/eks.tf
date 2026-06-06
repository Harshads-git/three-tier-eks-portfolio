# ─────────────────────────────────────────────────────────────────────────────
# terraform/eks.tf — EKS Cluster and Managed Node Group
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT IS EKS (Elastic Kubernetes Service)?
# ─────────────────────────────────────────────────────────────────────────────
# EKS is AWS's managed Kubernetes control plane service.
# AWS manages:
#   - The API server (kube-apiserver)
#   - etcd (cluster state database)
#   - Controller Manager (handles Deployment, ReplicaSet controllers)
#   - Scheduler (assigns pods to nodes)
#   - Control plane high availability (3 replicas across AZs)
#   - Control plane upgrades
# You manage:
#   - Worker nodes (EC2 instances running kubelet, container runtime)
#   - Node group configuration (instance type, count, scaling)
#   - Add-ons (CoreDNS, kube-proxy, vpc-cni, EBS CSI)
#   - Cluster access control (aws-auth ConfigMap)
#
# EKS CLUSTER vs EKS NODE GROUP:
# ─────────────────────────────────────────────────────────────────────────────
# EKS Cluster:  The control plane. Costs $0.10/hour. Always on.
# Node Group:   EC2 instances that run your pods. Costs per EC2 instance.
#               Can be scaled to 0 (saves money when not running pods).
#               Can have multiple node groups (general, spot, GPU, etc.)
#
# USING terraform-aws-modules/eks:
# ─────────────────────────────────────────────────────────────────────────────
# Without module: 400+ lines of aws_eks_cluster, aws_eks_node_group,
#   aws_iam_role, aws_iam_role_policy_attachment (×4), aws_security_group,
#   aws_security_group_rule (×several), aws_cloudwatch_log_group, etc.
# With module: ~80 lines. The module is the EKS community standard.
# ─────────────────────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"
  # v20.x is the current major version (v20 refactored the module significantly)
  # Use ~> to allow 20.9, 20.10, etc. but not 21.x (breaking changes)

  # ─────────────────────────────────────────────────────────────────────────
  # CLUSTER IDENTITY
  # ─────────────────────────────────────────────────────────────────────────
  cluster_name    = local.eks_name
  cluster_version = var.cluster_version
  # cluster_version: "1.29"
  # EKS supports n, n-1, n-2 versions at any time.
  # Upgrade process: upgrade control plane first → then node groups.

  # ─────────────────────────────────────────────────────────────────────────
  # CONTROL PLANE LOGGING
  # ─────────────────────────────────────────────────────────────────────────
  # EKS can send control plane logs to CloudWatch Logs.
  # Useful for security auditing and debugging cluster-level issues.
  # Each log type is stored in a separate CloudWatch log group.
  cluster_enabled_log_types = ["api", "audit", "authenticator"]
  # api:            API server requests (who called what API endpoint)
  # audit:          K8s audit log (who did what to which resource)
  # authenticator:  Authentication attempts (AWS IAM auth to K8s)
  # controllerManager, scheduler: Control plane internals (noisy, disable for cost)

  # ─────────────────────────────────────────────────────────────────────────
  # NETWORKING
  # ─────────────────────────────────────────────────────────────────────────
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  # Worker nodes are placed in PRIVATE subnets (no direct internet access).
  # They reach the internet via the NAT Gateway (to pull Docker images, etc.)

  control_plane_subnet_ids = module.vpc.private_subnets
  # Control plane ENIs (Elastic Network Interfaces) are also in private subnets.
  # The EKS API server endpoint is accessible from within the VPC.

  # ─────────────────────────────────────────────────────────────────────────
  # API SERVER ENDPOINT ACCESS
  # ─────────────────────────────────────────────────────────────────────────
  # cluster_endpoint_public_access: Allow kubectl from your laptop (internet).
  # cluster_endpoint_private_access: Allow kubectl from within the VPC.
  cluster_endpoint_public_access  = true   # ← Required for local development
  cluster_endpoint_private_access = true   # ← Required for CI/CD in VPC (Day 24)

  # cluster_endpoint_public_access_cidrs: Restrict public access to specific IPs.
  # For maximum security: only allow your office/home IP.
  # For portfolio: allow all (0.0.0.0/0) for simplicity.
  # For production: restrict to VPN/office CIDR.
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

  # ─────────────────────────────────────────────────────────────────────────
  # CLUSTER ADD-ONS
  # ─────────────────────────────────────────────────────────────────────────
  # Add-ons are managed K8s components installed and updated by AWS.
  # Using managed add-ons instead of Helm charts means AWS auto-updates them
  # during K8s version upgrades.
  cluster_addons = local.cluster_addons
  # Installs: CoreDNS, kube-proxy, vpc-cni (see locals.tf for details)

  # ─────────────────────────────────────────────────────────────────────────
  # OIDC PROVIDER — Required for IRSA
  # ─────────────────────────────────────────────────────────────────────────
  # Creates an IAM OIDC provider for this cluster.
  # Required for IRSA (IAM Roles for Service Accounts) — used by:
  #   - ALB Ingress Controller (k8s/alb-controller/serviceaccount.yaml)
  #   - EBS CSI Driver
  #   - Cluster Autoscaler (Day 13)
  enable_irsa = true

  # ─────────────────────────────────────────────────────────────────────────
  # NODE GROUP ACCESS — kubectl exec, cluster-admin
  # ─────────────────────────────────────────────────────────────────────────
  # Allows the IAM role that creates the cluster to access it via kubectl.
  # Without this: terraform apply succeeds but kubectl returns Unauthorized.
  enable_cluster_creator_admin_permissions = true

  # ─────────────────────────────────────────────────────────────────────────
  # MANAGED NODE GROUP
  # ─────────────────────────────────────────────────────────────────────────
  # A Managed Node Group is a group of EC2 instances managed by EKS.
  # EKS handles: node provisioning, AMI selection, kubelet config,
  #              node lifecycle (replacing failed nodes), K8s version upgrades.
  #
  # You can have multiple node groups for different workload types:
  #   general: mixed workloads (our case)
  #   spot:    interruptible, 70% cheaper (stateless workloads)
  #   memory:  r5.large (MongoDB, in-memory caches)
  #   gpu:     ml workloads
  eks_managed_node_groups = {
    general = {
      # ── INSTANCE CONFIGURATION ────────────────────────────────────────
      instance_types = [var.node_instance_type]
      # t3.medium: 2 vCPU, 4 GiB — adequate for all 3 tiers
      # List supports mixed instances (Spot diversification):
      # instance_types = ["t3.medium", "t3a.medium", "t3.large"]

      # ── SCALING ────────────────────────────────────────────────────────
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size
      # Cluster Autoscaler (Day 13) manages actual count between min and max.
      # desired_size is the INITIAL count — CA overrides it at runtime.

      # ── STORAGE ────────────────────────────────────────────────────────
      disk_size = 20
      # 20 GiB EBS gp2 root volume per EC2 node.
      # Stores: container runtime images, pod logs, emptyDir volumes.
      # Node image cache: Docker images can be 100-500 MB each.
      # 20 GiB is adequate for 5-10 cached container images.

      # ── AMI TYPE ────────────────────────────────────────────────────────
      ami_type = "AL2_x86_64"
      # AL2_x86_64: Amazon Linux 2 for x86_64 (standard EKS nodes)
      # AL2_ARM_64: For Graviton (ARM) instances (t4g, m6g, c6g) — cheaper
      # BOTTLEROCKET_x86_64: Minimal container-focused OS (more secure)
      # WINDOWS_CORE_2022_x86_64: Windows containers (not relevant here)

      # ── UPDATE CONFIGURATION ────────────────────────────────────────────
      update_config = {
        max_unavailable_percentage = 33
        # During node group updates (AMI upgrade, K8s version upgrade):
        # Allow at most 33% of nodes to be unavailable at once.
        # With 2 nodes: only 1 node updated at a time (66% = 1.32 → ceil = 2, min 1)
        # With 3 nodes: 1 node at a time (33% = 0.99 → ceil = 1)
      }

      # ── K8S LABELS ──────────────────────────────────────────────────────
      labels = local.node_labels
      # Labels on Node objects (for nodeSelector in pod specs)
      # kubectl get nodes --show-labels

      # ── TAINTS ──────────────────────────────────────────────────────────
      # No taints on the general node group (all pods can run here)
      # In multi-group setups: add taints to dedicated nodes:
      # taints = [{ key = "spot", value = "true", effect = "NO_SCHEDULE" }]
      # Then pods with toleration { key="spot" } can schedule on spot nodes.

      # ── TAGS ────────────────────────────────────────────────────────────
      tags = merge(local.common_tags, {
        Name = "${local.name_prefix}-general-node"
        # Cluster Autoscaler needs these tags to discover node groups:
        "k8s.io/cluster-autoscaler/enabled"                     = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"         = "owned"
      })
    }
  }

  # ─────────────────────────────────────────────────────────────────────────
  # CLUSTER-LEVEL TAGS
  # ─────────────────────────────────────────────────────────────────────────
  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# EBS CSI DRIVER — Required for MongoDB PVC (StatefulSet Day 5)
# ─────────────────────────────────────────────────────────────────────────────
#
# The EBS CSI (Container Storage Interface) Driver enables K8s to:
#   1. Dynamically provision EBS volumes when a PVC is created
#   2. Attach/detach EBS volumes to EC2 nodes as pods move
#   3. Expand EBS volumes (if StorageClass has allowVolumeExpansion: true)
#
# WITHOUT EBS CSI DRIVER:
#   kubectl apply -f k8s/mongo/statefulset.yaml
#   kubectl get pvc -n three-tier
#   → mongo-data-mongo-0   Pending   (stuck forever — no provisioner!)
#
# WITH EBS CSI DRIVER:
#   PVC created → CSI driver provisions EBS volume → PVC Bound → MongoDB starts
#
# IRSA FOR EBS CSI:
# The EBS CSI Driver needs AWS IAM permissions to create/attach EBS volumes.
# We create an IAM role with the managed policy AmazonEBSCSIDriverPolicy,
# linked to the EBS CSI Driver's ServiceAccount via IRSA.

resource "aws_iam_role" "ebs_csi_driver" {
  name = "${local.name_prefix}-ebs-csi-driver-role"

  # Trust policy: allows the EBS CSI Driver's ServiceAccount to assume this role.
  # The ServiceAccount in namespace kube-system, name ebs-csi-controller-sa
  # is created by the EBS CSI Driver add-on automatically.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
        # OIDC provider ARN — unique to this EKS cluster
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  # AWS Managed Policy: grants all permissions the EBS CSI Driver needs.
  # Includes: ec2:CreateVolume, ec2:AttachVolume, ec2:DetachVolume,
  #           ec2:DeleteVolume, ec2:DescribeVolumes, etc.
  role = aws_iam_role.ebs_csi_driver.name
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = local.ebs_csi_addon_name
  addon_version            = "v1.29.1-eksbuild.1"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  # resolve_conflicts_on_create: What to do if the add-on is already installed.
  # OVERWRITE: Replace existing configuration with Terraform's values.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  # PRESERVE: Keep any manual modifications to the add-on configuration.

  tags = local.common_tags

  depends_on = [module.eks]
}
