# Symlinked into every stack as shared_providers.tf.

locals {
  lab_tags = {
    Project   = "eks-lab"
    Owner     = "thaidg"
    ManagedBy = "terraform"
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Guardrail: plan/apply fail immediately if credentials resolve to any other account.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.lab_tags
  }
}
