variable "vpc_cidr" {
  description = "Chosen not to overlap existing VPCs in the account, so peering/VPN stays possible later"
  type        = string
  default     = "10.42.0.0/16"
}
