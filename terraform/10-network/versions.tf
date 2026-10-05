terraform {
  required_version = ">= 1.10"

  # Lab: local state (gitignored). Production: S3 backend with use_lockfile = true.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59, < 7.0"
    }
  }
}
