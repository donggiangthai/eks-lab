output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "cluster_primary_security_group_id" {
  value = module.eks.cluster_primary_security_group_id
}

output "system_node_iam_role_arn" {
  value = module.eks.eks_managed_node_groups["system"].iam_role_arn
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --profile ${var.aws_profile} --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}
