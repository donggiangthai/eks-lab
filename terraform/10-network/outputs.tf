output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "azs" {
  value = local.azs
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}
