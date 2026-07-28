# ─────────────────────────────────────────────────────────────────────────────
# terraform/helm.tf — Helm Chart Installations via Terraform
# ─────────────────────────────────────────────────────────────────────────────
#
# WHY INSTALL HELM CHARTS VIA TERRAFORM?
# ─────────────────────────────────────────────────────────────────────────────
# Cluster-level infrastructure (ALB Controller, Cluster Autoscaler, Metrics Server)
# is tightly coupled to the Terraform-managed cluster:
#   - They require IRSA roles that Terraform creates
#   - They must exist before application workloads (ALB Controller provisions the ALB)
#   - Their lifecycle (create/destroy) should match the cluster lifecycle
#
# Application-level charts (Prometheus, Grafana) go in separate Helm commands
# or a separate Terraform workspace (Day 16).
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# METRICS SERVER
# ─────────────────────────────────────────────────────────────────────────────
# Metrics Server collects CPU and memory metrics from all pods/nodes.
# Required for: kubectl top nodes, kubectl top pods, HPA (HorizontalPodAutoscaler)
# Without Metrics Server: HPA shows "Unknown" for metrics → cannot autoscale
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"

  # wait: Wait until all pods are Running before considering install complete
  wait    = true
  timeout = 300

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
    # Required in some EKS configurations where kubelet uses self-signed certs
    # Metrics Server verifies kubelet certificates — this disables cert verification
  }

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS LOAD BALANCER CONTROLLER
# ─────────────────────────────────────────────────────────────────────────────
# Watches for Ingress resources with class "alb" and provisions AWS ALBs.
# Without this: kubectl apply -f k8s/ingress.yaml → Ingress created but no ALB
# With this: Ingress annotated with alb → ALB provisioned in ~2 minutes
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  wait    = true
  timeout = 300

  # The ServiceAccount name must match the IRSA trust policy in iam.tf
  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
    # We create the ServiceAccount separately (or via the YAML in k8s/alb-controller/)
    # so we can annotate it with the IRSA role ARN
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
    # This annotation links the ServiceAccount to the IRSA role
    # Backslash escapes the dot in the annotation key
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
    # Required: Controller needs VPC ID to discover subnets for the ALB
  }

  # Enable shield, waf integrations (optional, set to false for cost control)
  set {
    name  = "enableShield"
    value = "false"
  }

  set {
    name  = "enableWaf"
    value = "false"
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.alb_controller
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# CLUSTER AUTOSCALER
# ─────────────────────────────────────────────────────────────────────────────
# Watches for unschedulable pods and scales EC2 node groups up/down.
# Scale UP:   Pod Pending (no room) → add EC2 node → pod schedules
# Scale DOWN: Node under-utilized → evict pods → terminate EC2 node
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.36.0"

  wait    = true
  timeout = 300

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
    # Auto-discovers node groups tagged with: k8s.io/cluster-autoscaler/<cluster-name>=owned
    # These tags are set in eks.tf node group configuration
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cluster_autoscaler.arn
  }

  # Scale-down configuration
  set {
    name  = "extraArgs.scale-down-delay-after-add"
    value = "5m"
    # Wait 5 minutes after a scale-up before considering scale-down
  }

  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = "10m"
    # Node must be unneeded for 10 minutes before being removed
  }

  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
    # Allow scaling down nodes that have pods with local storage (emptyDir)
    # Our app uses emptyDir for /tmp — set to false to allow scale-down
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.cluster_autoscaler,
    helm_release.metrics_server
  ]
}
