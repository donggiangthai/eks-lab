# Phase 1b: EKS control plane, access entries, core add-ons and a small "system"
# managed node group. Application capacity comes from Karpenter in phase 2.

data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "${path.module}/../10-network/terraform.tfstate"
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.26"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.network.vpc_id
  subnet_ids = local.network.private_subnet_ids

  # --- API endpoint ---------------------------------------------------------
  # LAB SHORTCUT: public endpoint locked to my IP so kubectl works from the laptop.
  # PRODUCTION: endpoint_public_access = false, reach it over VPN / SSM / a bastion.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs
  endpoint_private_access      = true # nodes talk to the API server inside the VPC

  # --- Who can use kubectl ----------------------------------------------------
  # "API" = EKS access entries only; the legacy aws-auth ConfigMap is ignored.
  # ECS mapping: in ECS, IAM policies on ecs:* are the whole story. In EKS, IAM only
  # *authenticates*; an access entry maps that IAM principal to Kubernetes permissions.
  authentication_mode = "API"
  # Gives whoever runs `terraform apply` (my SSO role) cluster-admin via an access entry.
  enable_cluster_creator_admin_permissions = true

  # --- Workload IAM -----------------------------------------------------------
  # Using EKS Pod Identity (the eks-pod-identity-agent add-on below) instead of IRSA,
  # so no per-cluster IAM OIDC provider is created. Closest analogue to ECS task roles.
  enable_irsa = false

  # --- Encryption -------------------------------------------------------------
  # EKS already envelope-encrypts Kubernetes secrets with an AWS-owned key.
  # LAB SHORTCUT: no customer-managed KMS key (would linger 7+ days in PendingDeletion).
  # PRODUCTION: add a CMK if compliance requires key ownership / rotation control.
  create_kms_key    = false
  encryption_config = null

  # --- Control plane logs -----------------------------------------------------
  # audit = who did what; authenticator = why an IAM principal was/wasn't let in.
  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 1

  deletion_protection = false # PRODUCTION: true

  # --- Add-ons ----------------------------------------------------------------
  addons = {
    # Installed before nodes exist so nodes join with the right CNI config.
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          # Prefix delegation: each ENI slot gets a /28 (16 IPs) instead of 1 IP.
          # t4g.medium: 17 pods max without it, 110 with it.
          # ECS mapping: same problem ENI trunking solves for awsvpc tasks.
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {} # already tolerates the CriticalAddonsOnly taint
  }

  # --- System node group ------------------------------------------------------
  # ECS mapping: an ASG-backed capacity provider reserved for cluster plumbing
  # (CoreDNS, LB controller, Karpenter). On-demand on purpose: Karpenter must not run
  # on the Spot capacity it manages. Apps run on Karpenter nodes (phase 2).
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD" # Graviton
      instance_types = ["t4g.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        "node-role" = "system"
      }

      # Only pods that tolerate this land here (CoreDNS does by default; phase-2
      # controllers get the toleration in their Helm values).
      taints = {
        critical = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Karpenter's EC2NodeClass will select this SG for the nodes it launches.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
