# ─────────────────────────────────────────────────────────────────────────────
# terraform/vpc.tf — VPC, Subnets, NAT Gateway, Internet Gateway
# ─────────────────────────────────────────────────────────────────────────────
#
# THREE-TIER VPC ARCHITECTURE:
# ─────────────────────────────────────────────────────────────────────────────
#
#                    INTERNET
#                       │
#              Internet Gateway (IGW)
#                       │
#        ┌──────────────┴──────────────────┐
#        │         PUBLIC SUBNETS           │
#        │   10.0.101.0/24  10.0.102.0/24  │
#        │   (us-east-1a)   (us-east-1b)   │
#        │                                  │
#        │   [ALB]          [NAT Gateway]   │
#        └──────────────────────────────────┘
#                       │
#                  NAT Gateway
#                  (outbound only)
#                       │
#        ┌──────────────┴──────────────────┐
#        │         PRIVATE SUBNETS          │
#        │   10.0.1.0/24    10.0.2.0/24    │
#        │   (us-east-1a)   (us-east-1b)   │
#        │                                  │
#        │   [EKS Nodes]  [EKS Nodes]       │
#        │   [MongoDB]    [Backend pods]    │
#        │   [Frontend]                     │
#        └──────────────────────────────────┘
#
# SUBNET TAGGING FOR EKS (CRITICAL):
# ─────────────────────────────────────────────────────────────────────────────
# EKS and the ALB Controller use specific tags to discover subnets:
#
# Private subnets (EKS nodes):
#   kubernetes.io/cluster/<cluster-name> = "shared" or "owned"
#   kubernetes.io/role/internal-elb      = "1"
#   → EKS schedules worker nodes in these subnets
#   → Internal LBs (if any) are placed here
#
# Public subnets (ALB):
#   kubernetes.io/cluster/<cluster-name> = "shared" or "owned"
#   kubernetes.io/role/elb               = "1"
#   → The AWS LB Controller discovers these subnets for internet-facing ALBs
#   → WITHOUT this tag, ALB creation fails with "unable to find subnets" error!
#
# USING THE OFFICIAL terraform-aws-modules/vpc MODULE:
# ─────────────────────────────────────────────────────────────────────────────
# Instead of writing 200+ lines of VPC resources manually (aws_vpc, aws_subnet,
# aws_internet_gateway, aws_nat_gateway, aws_route_table, etc.), we use the
# official community module. It:
#   1. Creates all VPC components correctly
#   2. Applies all required EKS subnet tags automatically
#   3. Is maintained by AWS and community (secure, up-to-date)
#   4. Has been battle-tested by thousands of production deployments
# ─────────────────────────────────────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"
  # Pin to 5.x — major version changes may break EKS tag behavior

  # ─────────────────────────────────────────────────────────────────────────
  # BASIC VPC SETTINGS
  # ─────────────────────────────────────────────────────────────────────────
  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # ─────────────────────────────────────────────────────────────────────────
  # NAT GATEWAY
  # ─────────────────────────────────────────────────────────────────────────
  # enable_nat_gateway: Private subnet resources can initiate outbound internet
  # connections (e.g., pulling Docker images from ECR, calling AWS APIs).
  # Without NAT Gateway: EC2 nodes in private subnets can't reach the internet.
  enable_nat_gateway = true

  # single_nat_gateway: Use ONE NAT Gateway shared across all private subnets.
  # Cost comparison:
  #   single_nat_gateway = true:  1 NAT Gateway = $32/month + data transfer
  #   single_nat_gateway = false: 1 per AZ = $64/month + data transfer
  # For this portfolio: single is fine (production would use one per AZ for HA)
  single_nat_gateway = true

  # one_nat_gateway_per_az: Deploy a NAT Gateway in EACH AZ.
  # With true: if us-east-1a AZ fails, private subnets in us-east-1b
  #   can still reach the internet via their own NAT Gateway.
  # With false (single): if the NAT Gateway's AZ fails → all private subnets lose internet.
  # For production: set single=false, one_per_az=true. For portfolio: single=true.
  one_nat_gateway_per_az = false

  # ─────────────────────────────────────────────────────────────────────────
  # DNS SETTINGS (Required for EKS)
  # ─────────────────────────────────────────────────────────────────────────
  # enable_dns_hostnames: EC2 instances get public DNS hostnames.
  # Required for EKS nodes to resolve their own hostname.
  enable_dns_hostnames = true

  # enable_dns_support: Uses AWS's internal DNS resolver (169.254.169.253).
  # Required for K8s CoreDNS and service discovery within the cluster.
  # Without this, pods cannot resolve service names (e.g., mongo-service).
  enable_dns_support = true

  # ─────────────────────────────────────────────────────────────────────────
  # SUBNET TAGS (CRITICAL for EKS and ALB)
  # ─────────────────────────────────────────────────────────────────────────
  # The AWS LB Controller reads these tags to find which subnets to use.
  # Missing these tags is the #1 cause of "Cannot find subnets" ALB errors.

  private_subnet_tags = {
    # "shared": multiple EKS clusters can share this subnet
    # "owned": only this cluster uses this subnet (stricter, prevents accidental sharing)
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"

    # Tells ALB controller to use private subnets for internal load balancers.
    # For internet-facing ALB: use public subnets (tag below).
    "kubernetes.io/role/internal-elb" = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"

    # Tells ALB controller: "create internet-facing ALBs in these public subnets"
    # Without this: `alb.ingress.kubernetes.io/scheme: internet-facing` fails!
    "kubernetes.io/role/elb" = "1"
  }

  # ─────────────────────────────────────────────────────────────────────────
  # ADDITIONAL TAGS
  # ─────────────────────────────────────────────────────────────────────────
  tags = {
    Name    = "${var.cluster_name}-vpc"
    Cluster = var.cluster_name
  }
}
