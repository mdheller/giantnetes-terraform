locals {
  default_ssh_access_subnet = "0.0.0.0/0"

  # If behind VPN allow SSH access only from VPN subnet.
  ssh_access_subnet = "${var.with_public_access ? local.default_ssh_access_subnet : var.external_ipsec_subnet}"

  # In China there is no tags for s3 buckets
  s3_ignition_bastion_key = "${element(concat(aws_s3_bucket_object.ignition_bastion_with_tags.*.key, aws_s3_bucket_object.ignition_bastion_without_tags.*.key), 0)}"

  common_tags = "${map(
    "giantswarm.io/installation", "${var.cluster_name}",
    "kubernetes.io/cluster/${var.cluster_name}", "owned"
  )}"
}

data "aws_region" "current" {}

resource "aws_instance" "bastion" {
  count                = "${var.bastion_count}"
  ami                  = "${var.container_linux_ami_id}"
  instance_type        = "${var.instance_type}"
  iam_instance_profile = "${aws_iam_instance_profile.bastion.name}"

  associate_public_ip_address = "${var.with_public_access}"
  source_dest_check           = false
  subnet_id                   = "${var.bastion_subnet_ids[count.index]}"
  vpc_security_group_ids      = ["${aws_security_group.bastion.id}"]

  root_block_device {
    volume_type = "${var.volume_type}"
    volume_size = "${var.volume_size_root}"
  }

  user_data = "${data.ignition_config.s3.rendered}"

  tags = {
    Name                         = "${var.cluster_name}-bastion${count.index}"
    "giantswarm.io/installation" = "${var.cluster_name}"
  }
}

resource "aws_security_group" "bastion" {
  name   = "${var.cluster_name}-bastion"
  vpc_id = "${var.vpc_id}"

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow access from vpc
  ingress {
    from_port   = 10
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["${var.vpc_cidr}"]
  }

  # Allow access from vpc
  ingress {
    from_port   = 10
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = ["${var.vpc_cidr}"]
  }

  # Allow SSH from everywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${local.ssh_access_subnet}"]
    self        = true
  }

  tags = {
    Name                         = "${var.cluster_name}-bastion"
    "giantswarm.io/installation" = "${var.cluster_name}"
  }
}

resource "aws_route53_record" "bastion" {
  count   = "${var.route53_enabled ? var.bastion_count : 0}"
  zone_id = "${var.dns_zone_id}"
  name    = "bastion${count.index + 1}"
  type    = "A"

  # Add "public_ip" or "private_ip" depending on "with_public_access" parameter.
  records = ["${var.with_public_access ? element(aws_instance.bastion.*.public_ip, count.index) : element(aws_instance.bastion.*.private_ip, count.index)}"]
  ttl     = "300"
}

# To avoid 16kb user_data limit upload CoreOS ignition config to a s3 bucket.
# Ignition supports s3 out-of-the-box.
resource "aws_s3_bucket_object" "ignition_bastion_with_tags" {
  count   = "${var.s3_bucket_tags ? 1 : 0}"
  bucket  = "${var.ignition_bucket_id}"
  key     = "${var.cluster_name}-ignition-bastion.json"
  content = "${var.user_data}"
  acl     = "private"

  server_side_encryption = "AES256"

  tags = "${merge(
    local.common_tags,
    map(
      "Name", "${var.cluster_name}-ignition-bastion"
    )
  )}"
}

resource "aws_s3_bucket_object" "ignition_bastion_without_tags" {
  count   = "${var.s3_bucket_tags ? 0 : 1}"
  bucket  = "${var.ignition_bucket_id}"
  key     = "${var.cluster_name}-ignition-bastion.json"
  content = "${var.user_data}"
  acl     = "private"

  server_side_encryption = "AES256"
}

data "ignition_config" "s3" {
  replace {
    source       = "${format("s3://%s/%s", var.ignition_bucket_id, local.s3_ignition_bastion_key)}"
    verification = "sha512-${sha512(var.user_data)}"
  }
}

resource "aws_vpc_endpoint" "cloudwatch" {
  count              = "${var.forward_logs_enabled ? 1 : 0}"
  vpc_id             = "${var.vpc_id}"
  service_name       = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type  = "Interface"
  security_group_ids = ["${aws_security_group.bastion.id}"]
  subnet_ids         = ["${var.bastion_subnet_ids[0]}", "${var.bastion_subnet_ids[1]}"]
}
