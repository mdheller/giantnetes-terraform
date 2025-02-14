variable "arn_region" {
  type = "string"
}

variable "aws_account" {
  type = "string"
}

variable "vpn_instance_enabled" {
  default = false
}

# gridscale
variable "external_vpn_cidr_0" {
  type = "string"
}

# vultr
variable "external_vpn_cidr_1" {
  type = "string"
}

variable "bastion_subnet_ids" {
  type = "list"
}

variable "container_linux_ami_id" {
  type = "string"
}

variable "cluster_name" {
  type = "string"
}

variable "external_ipsec_subnet" {
  type    = "string"
  default = "172.18.0.0/29"
}

variable "ignition_bucket_id" {
  type = "string"
}

variable "iam_region" {
  type = "string"
}

variable "instance_type" {
  type = "string"
}

variable "user_data" {
  type = "string"
}

variable "volume_type" {
  type    = "string"
  default = "gp2"
}

variable "dns_zone_id" {
  type = "string"
}

variable "volume_size_root" {
  type    = "string"
  default = 50
}

variable "vpc_cidr" {
  type = "string"
}

variable "vpc_id" {
  type = "string"
}

variable "route53_enabled" {
  default = true
}

variable "s3_bucket_tags" {}
