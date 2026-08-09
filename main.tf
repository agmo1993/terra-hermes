# Latest Ubuntu 24.04 LTS (amd64) AMI, resolved from Canonical's public SSM parameter.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Default VPC and its subnets. When var.availability_zone is set, the subnet list
# is filtered to that AZ; otherwise the first subnet in the VPC is used.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  dynamic "filter" {
    for_each = var.availability_zone == "" ? [] : [var.availability_zone]
    content {
      name   = "availability-zone"
      values = [filter.value]
    }
  }
}

# --- IAM: instance role granting SSM Session Manager access (no SSH needed) ---
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hermes" {
  name               = "${var.name}-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.hermes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "hermes" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.hermes.name
}

# --- Security group: selected inbound ports for prototyping; all outbound ---
resource "aws_security_group" "hermes" {
  name        = "${var.name}-sg"
  description = "SG for the hermes agent instance - selected inbound ports for web prototyping, all outbound."
  vpc_id      = data.aws_vpc.default.id

  # One inbound rule per port in var.allowed_ports, open to the world.
  # Intended for prototyping on a trusted account — tighten cidr_blocks
  # or remove ports you don't need before sharing the instance.
  dynamic "ingress" {
    for_each = toset(var.allowed_ports)
    content {
      description = "Allow TCP/${ingress.value} from anywhere (prototyping)"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

# user_data is assembled as: an `export` header built from the Terraform
# variables, followed by the static startup script (which reads everything from
# the environment). Secrets are injected via env exports rather than being
# interpolated into the script body.
#
# SECURITY: this rendered user_data — including provider_api_key and
# telegram_bot_token — is stored in Terraform STATE and exposed via the Instance
# Metadata Service. Harden by sourcing those secrets from SSM Parameter Store /
# Secrets Manager through an instance IAM role instead (see templates/hermes-startup.sh).
locals {
  hermes_env_exports = <<-EOT
#!/bin/bash
export HERMES_USER='${var.hermes_user}'
export MODEL_PROVIDER='${var.model_provider}'
export MODEL_NAME='${local.resolved_model}'
export PROVIDER_KEY_ENV_VAR='${local.resolved_key_env_var}'
export PROVIDER_BASE_ENV_VAR='${local.resolved_base_env_var}'
export MODEL_BASE_URL='${local.resolved_base_url}'
export PROVIDER_API_KEY='${var.provider_api_key}'
export TELEGRAM_BOT_TOKEN='${var.telegram_bot_token}'
export TELEGRAM_ALLOWED_USERS='${var.telegram_allowed_users}'
export HERMES_INSTALL_COMMAND='${var.hermes_install_command}'
export GITHUB_TOKEN='${var.github_token}'
EOT

  hermes_user_data = join("\n", [
    local.hermes_env_exports,
    file("${path.module}/templates/hermes-startup.sh"),
  ])
}

# --- EC2 instance running the hermes agent ---
resource "aws_instance" "hermes" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.hermes.id]
  iam_instance_profile        = aws_iam_instance_profile.hermes.name
  associate_public_ip_address = true

  user_data                   = local.hermes_user_data
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # enforce IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  tags = {
    Name = var.name
  }
}
