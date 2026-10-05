# Phase 1a: a dedicated 3-AZ VPC for the lab.
#
# ECS mapping: identical to what an ECS cluster on awsvpc mode needs. The difference
# is density: the VPC CNI gives every *pod* a real VPC IP (like awsvpc tasks), but a
# node packs far more pods than ECS packs tasks, so private subnets are sized large.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /19 per AZ (8k IPs) for nodes + pods; /24 per AZ for ALBs and the NAT gateway.
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 3, i)]      # 10.42.0.0/19, .32.0/19, .64.0/19
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 96 + i)] # 10.42.96.0/24, .97.0/24, .98.0/24

  enable_nat_gateway = true
  # LAB SHORTCUT: one NAT for all AZs (~$43/month saved per AZ).
  # PRODUCTION: one_nat_gateway_per_az = true, so an AZ outage doesn't kill egress for the others.
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # The AWS Load Balancer Controller discovers subnets by these tags:
  # internet-facing ALBs -> public subnets, internal ALBs/NLBs -> private subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    # Karpenter's EC2NodeClass selects the subnets to launch nodes into by this tag.
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# Free gateway endpoint: ECR image layers live in S3, so image pulls from private
# subnets skip NAT data-processing charges ($0.059/GB). Worth it in production too.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)

  tags = { Name = "${var.cluster_name}-s3" }
}
