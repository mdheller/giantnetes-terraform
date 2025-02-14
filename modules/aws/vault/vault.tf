locals {
  # In China there is no tags for s3 buckets
  s3_ignition_vault_key = "${element(concat(aws_s3_bucket_object.ignition_vault_with_tags.*.key, aws_s3_bucket_object.ignition_vault_without_tags.*.key), 0)}"

  common_tags = "${map(
    "giantswarm.io/installation", "${var.cluster_name}",
    "kubernetes.io/cluster/${var.cluster_name}", "owned"
  )}"
}

data "aws_availability_zones" "available" {}

# "Recreate" worker subnets in order to lookup CIDR blocks for security group
# node-exporter ruler.
data "aws_subnet" "worker_subnets" {
  # Workaround for a bug that claimed to be addressed by 0.12 version.
  # https://github.com/hashicorp/terraform/issues/12570
  count = "2"

  id = "${var.worker_subnet_ids[count.index]}"
}

resource "aws_instance" "vault" {
  count         = length("${aws_security_group.vault}")
  ami           = "${var.container_linux_ami_id}"
  instance_type = "${var.instance_type}"

  associate_public_ip_address = false
  iam_instance_profile        = "${aws_iam_instance_profile.vault.id}"
  source_dest_check           = false
  subnet_id                   = "${var.vault_subnet_ids[count.index]}"
  vpc_security_group_ids      = ["${aws_security_group.vault[count.index].id}"]

  lifecycle {
    # Vault provisioned also by Ansible,
    # so prevent recreation if user_data or ami changed.
    ignore_changes = ["ami", "user_data"]
  }

  root_block_device {
    volume_type = "${var.volume_type}"
    volume_size = "${var.volume_size_root}"
  }

  user_data = "${data.ignition_config.s3.rendered}"

  tags = {
    Name                         = "${var.cluster_name}-vault${count.index}"
    "giantswarm.io/installation" = "${var.cluster_name}"
  }
}

resource "aws_ebs_volume" "vault_etcd" {
  availability_zone = "${element(data.aws_availability_zones.available.names,0)}"
  size              = "${var.volume_size_etcd}"
  type              = "${var.volume_type}"

  tags = {
    Name                         = "${var.cluster_name}-vault"
    "giantswarm.io/installation" = "${var.cluster_name}"
  }
}

resource "aws_volume_attachment" "vault_etcd_ebs" {
  count         = "${var.vault_count}"
  device_name = "/dev/xvdc"
  volume_id   = "${aws_ebs_volume.vault_etcd.id}"
  instance_id = "${aws_instance.vault[count.index].id}"

  # Allows reattaching volume.
  skip_destroy = true
}

resource "aws_ebs_volume" "vault_logs" {
  availability_zone = "${element(data.aws_availability_zones.available.names,0)}"
  size              = "${var.volume_size_logs}"
  type              = "${var.volume_type}"

  tags = {
    Name                         = "${var.cluster_name}-vault"
    "giantswarm.io/installation" = "${var.cluster_name}"
  }
}

resource "aws_volume_attachment" "vault_logs_ebs" {
  count         = "${var.vault_count}"
  device_name = "/dev/xvdh"
  volume_id   = "${aws_ebs_volume.vault_logs.id}"
  instance_id = "${aws_instance.vault[count.index].id}"

  # Allows reattaching volume.
  skip_destroy = true
}

resource "aws_security_group" "vault" {
  count         = "${var.vault_count}"
  name   = "${var.cluster_name}-vault"
  vpc_id = "${var.vpc_id}"

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow Vault API from vpc
  ingress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = ["${var.vpc_cidr}"]
  }

  # Allow Vault API from guest-vpc
  # Required in case where Vault is used instead of KMS
  ingress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = ["${var.ipam_network_cidr}"]
  }

  # Allow SSH from vpc
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.vpc_cidr}"]
  }

  # Allow node-exporter from worker nodes.
  ingress {
    from_port   = 10300
    to_port     = 10300
    protocol    = "tcp"
    cidr_blocks = "${data.aws_subnet.worker_subnets.*.cidr_block}"
  }

  # Allow cert-exporter from worker nodes.
  ingress {
    from_port   = 9005
    to_port     = 9005
    protocol    = "tcp"
    cidr_blocks = "${data.aws_subnet.worker_subnets.*.cidr_block}"
  }

  tags = {
    Name                         = "${var.cluster_name}-vault"
    "giantswarm.io/installation" = "${var.cluster_name}"
  }
}

resource "aws_route53_record" "vault" {
  count   = "${var.route53_enabled ? var.vault_count : 0}"
  zone_id = "${var.dns_zone_id}"
  name    = "vault${count.index + 1}"
  type    = "A"

  records = ["${element(aws_instance.vault.*.private_ip, count.index)}"]
  ttl     = "300"
}

# To avoid 16kb user_data limit upload CoreOS ignition config to a s3 bucket.
# Ignition supports s3 out-of-the-box.
resource "aws_s3_bucket_object" "ignition_vault_with_tags" {
  count   = "${var.s3_bucket_tags ? 1 : 0}"
  bucket  = "${var.ignition_bucket_id}"
  key     = "${var.cluster_name}-ignition-vault.json"
  content = "${var.user_data}"
  acl     = "private"

  server_side_encryption = "AES256"

  tags = "${merge(
    local.common_tags,
    map(
      "Name", "${var.cluster_name}-ignition-vault"
    )
  )}"
}

# To avoid 16kb user_data limit upload CoreOS ignition config to a s3 bucket.
# Ignition supports s3 out-of-the-box.
resource "aws_s3_bucket_object" "ignition_vault_without_tags" {
  count   = "${var.s3_bucket_tags ? 0 : 1}"
  bucket  = "${var.ignition_bucket_id}"
  key     = "${var.cluster_name}-ignition-vault.json"
  content = "${var.user_data}"
  acl     = "private"

  server_side_encryption = "AES256"
}

data "ignition_config" "s3" {
  replace {
    source       = "${format("s3://%s/%s", var.ignition_bucket_id, local.s3_ignition_vault_key)}"
    verification = "sha512-${sha512(var.user_data)}"
  }
}
