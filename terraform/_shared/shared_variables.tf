# Symlinked into every stack as shared_variables.tf so all stacks can read the
# same terraform/lab.tfvars without "undeclared variable" warnings.

variable "account_id" {
  description = "AWS account the lab is allowed to run in (provider refuses any other)"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile. Pinned explicitly so Terraform never falls back to a default/prod profile"
  type        = string
  default     = "lab"
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "cluster_name" {
  type    = string
  default = "eks-lab"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint"
  type        = list(string)
}
