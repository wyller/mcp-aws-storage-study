terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Day 5: EFS Regional shared by two clients in two AZs. Runbook in README.md.
# Every resource carries Lab/Day tags, so leftovers outside the state are easy to find.
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Environment = "lab"
    Lab         = "efs"
    Day         = "5"
    ManagedBy   = "terraform"
    Stack       = "terraform/efs"
  }

  # POSIX identity the "app" access point forces on every NFS call, whatever the client user is.
  app_uid = 1001
  app_gid = 1001
  # A second identity with no rights on the app directory, for the permission tests.
  other_uid = 1002
  other_gid = 1002

  # "a" and "b" for names and for_each keys, so an AZ swap never renames a resource.
  clients = { for az in var.azs : substr(az, -1, 1) => az }
}

variable "azs" {
  description = "The two AZs for the mount targets and the clients (t3.micro is not offered in us-east-1e)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) == 2 && length(distinct(var.azs)) == 2
    error_message = "azs must hold exactly two different AZs."
  }
}

variable "instance_type" {
  description = "EC2 instance type of both clients"
  type        = string
  default     = "t3.micro"
}

# Troubleshooting toggle: false removes the NFS rule from the mount target SG (in-place update).
# A new mount then hangs until a timeout, instead of failing at once like an IAM or TLS denial.
variable "nfs_ingress_enabled" {
  description = "Allow TCP 2049 from the client SG to the mount targets"
  type        = bool
  default     = true
}

# Troubleshooting toggle: true lets anonymous clients (no "iam" mount option) mount and write, still
# only with TLS. It isolates the TLS deny: "try noiam" then mounts and "try notls" is still refused.
variable "allow_anonymous" {
  description = "Also allow ClientMount/ClientWrite to anonymous clients (TLS still required)"
  type        = bool
  default     = false
}

# AL2023 ships amazon-efs-utils in its repos (TLS and IAM mounts need it). On Ubuntu it has to be
# built from source with Rust, which a t3.micro with 1 GiB would take too long to do on first boot.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "lab" {
  for_each = local.clients

  vpc_id            = data.aws_vpc.default.id
  availability_zone = each.value
  default_for_az    = true
}

# SSM profile, created in terraform/iam-compartilhado (kept between days, never changed here).
# Its role gets EFS access from the file system policy below, not from an identity policy.
data "aws_iam_instance_profile" "lab" {
  name = "lab-storage-ec2-profile"
}


#---------------- Security groups ----------------


# No ingress rule: Session Manager only needs outbound 443 from the agent. NFS goes out on 2049.
resource "aws_security_group" "client" {
  name_prefix = "lab-efs-client-"
  description = "Day 5 EFS lab clients, no ingress"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab-efs-client-sg"
  }
}

# NFS only from the client SG. No egress block: Terraform removes the default allow-all, and a
# mount target never opens connections (the replies go out through connection tracking).
resource "aws_security_group" "mount_target" {
  name_prefix = "lab-efs-mt-"
  description = "Day 5 EFS mount targets, NFS from the lab clients only"
  vpc_id      = data.aws_vpc.default.id

  # Attribute syntax, not a dynamic block: in provider 6.x "ingress" is an Optional+Computed attribute
  # (attributes as blocks). Zero dynamic blocks means "not set", which keeps whatever AWS has, so
  # nfs_ingress_enabled = false planned "No changes" (2026-10-29). An explicit [] removes the rule.
  # Every field is set, matching the state, so true plans no change against the rule as it is.
  ingress = var.nfs_ingress_enabled ? [{
    description      = "NFS from the lab clients"
    from_port        = 2049
    to_port          = 2049
    protocol         = "tcp"
    security_groups  = [aws_security_group.client.id]
    cidr_blocks      = []
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    self             = false
  }] : []

  tags = {
    Name = "lab-efs-mt-sg"
  }
}


#---------------- File system ----------------


# Regional (no availability_zone_name), General Purpose, Elastic. The provider default is bursting,
# so throughput_mode is explicit. Encrypted at rest with the AWS managed key aws/elasticfilesystem.
# No lifecycle_policy: IA and Archive bill per GB read and per transition, and keep 128 KiB per file.
resource "aws_efs_file_system" "lab" {
  creation_token   = "lab-efs-day5"
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = true

  tags = {
    Name = "lab-efs"
  }
}

# The API default is already off for Regional file systems, but the console default is on, and an
# automatic backup creates recovery points in AWS Backup that a destroy does not delete. Explicit.
resource "aws_efs_backup_policy" "lab" {
  file_system_id = aws_efs_file_system.lab.id

  backup_policy {
    status = "DISABLED"
  }
}

# One per AZ. The file system DNS name resolves, inside the VPC, to the mount target of the
# client's own AZ: same-AZ traffic has no data transfer charge, cross-AZ is US$ 0.01/GB each way.
resource "aws_efs_mount_target" "lab" {
  for_each = local.clients

  file_system_id  = aws_efs_file_system.lab.id
  subnet_id       = data.aws_subnet.lab[each.key].id
  security_groups = [aws_security_group.mount_target.id]
}

# Every NFS call through it runs as 1001:1001, and the client sees /lab as its root. EFS creates
# /lab on the first mount through this access point, owned by 1001:1001 with mode 0750.
resource "aws_efs_access_point" "app" {
  file_system_id = aws_efs_file_system.lab.id

  posix_user {
    uid = local.app_uid
    gid = local.app_gid
  }

  root_directory {
    path = "/lab"

    creation_info {
      owner_uid   = local.app_uid
      owner_gid   = local.app_gid
      permissions = "0750"
    }
  }

  tags = {
    Name = "lab-efs-ap-app"
  }
}

# Same file system, seen from "/" as 1002:1002: it can list "/" but not enter /lab (0750, not its owner
# nor its group). No creation_info, because "/" always exists.
resource "aws_efs_access_point" "other" {
  file_system_id = aws_efs_file_system.lab.id

  posix_user {
    uid = local.other_uid
    gid = local.other_gid
  }

  root_directory {
    path = "/"
  }

  tags = {
    Name = "lab-efs-ap-other"
  }
}

# Replaces the default policy (any client that reaches a mount target gets full access):
# - only the lab instance role mounts and writes, and only through a mount target;
# - ClientRootAccess is not granted, so root on the clients is squashed to 65534 when mounting
#   without an access point (with one, the access point identity wins anyway);
# - no TLS, no access: a plain NFS mount and an anonymous one (no "iam" option) are both refused,
#   unless allow_anonymous adds the anonymous statement.
resource "aws_efs_file_system_policy" "lab" {
  file_system_id = aws_efs_file_system.lab.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(var.allow_anonymous ? [
      {
        Sid       = "AnonymousMountAndWrite"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource  = aws_efs_file_system.lab.arn
        Condition = { Bool = { "elasticfilesystem:AccessedViaMountTarget" = "true" } }
      },
      ] : [], [
      {
        Sid       = "LabRoleMountAndWrite"
        Effect    = "Allow"
        Principal = { AWS = data.aws_iam_instance_profile.lab.role_arn }
        Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource  = aws_efs_file_system.lab.arn
        Condition = { Bool = { "elasticfilesystem:AccessedViaMountTarget" = "true" } }
      },
      {
        Sid       = "DenyWithoutTls"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "*"
        Resource  = aws_efs_file_system.lab.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ])
  })
}


#---------------- Two clients, reached only through Session Manager ----------------


resource "aws_instance" "client" {
  for_each = local.clients

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.lab[each.key].id
  vpc_security_group_ids = [aws_security_group.client.id]

  iam_instance_profile = data.aws_iam_instance_profile.lab.name

  # Public IPv4 (US$ 0.005/h each) is what lets the agent reach SSM and dnf reach the AL2023 repos
  # without NAT or interface endpoints. Nothing listens: the SG has no ingress.
  associate_public_ip_address = true

  # The EFS mount helper reads the role credentials from IMDS (iam option); it supports IMDSv2.
  metadata_options {
    http_tokens = "required"
  }

  # The account default for t3 (checked 2026-10-29). Explicit, because it bills: if the average CPU
  # over the instance's life goes above the 20% baseline, the surplus costs US$ 0.05 per vCPU-hour
  # (worst case, 100% for 4 h: ~US$ 0.36 per instance). "standard" would throttle cloud-init and fio
  # to the baseline instead, since t3 gets no launch credits. scripts/efs-lab.sh metrics shows it.
  credit_specification {
    cpu_credits = "unlimited"
  }

  # Installs amazon-efs-utils, fio and /usr/local/bin/lab-efs, and writes /etc/lab-efs.env with the
  # IDs. Editing files/lab-efs.sh changes user_data, and the provider applies it with a stop/start
  # of the instance: mounts are lost (nothing goes to /etc/fstab).
  user_data = templatefile("${path.module}/files/cloud-init.yaml.tftpl", {
    lab_efs_gzb64 = base64gzip(file("${path.module}/files/lab-efs.sh"))
    env = join("\n", [
      "FS_ID=${aws_efs_file_system.lab.id}",
      "AP_APP=${aws_efs_access_point.app.id}",
      "AP_OTHER=${aws_efs_access_point.other.id}",
      "CLIENT=${each.key}",
      "REGION=us-east-1",
    ])
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true

    tags = merge(local.tags, {
      Name = "lab-efs-root-${each.key}"
    })
  }

  tags = {
    Name = "lab-efs-client-${each.key}"
  }

  # A newer AL2023 AMI published mid-lab would replace both instances on the next apply.
  # user_data: once running, the helpers come from the repo inside each SSM command
  # (scripts/efs-lab.sh), so editing files/lab-efs.sh must not stop and start both clients on the
  # next apply (the SG test of step 8 is an apply). A new instance still gets the current file.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}


#---------------- Outputs ----------------


output "file_system_id" {
  value = aws_efs_file_system.lab.id
}

output "file_system_dns_name" {
  value = aws_efs_file_system.lab.dns_name
}

output "mount_targets" {
  value = { for k, mt in aws_efs_mount_target.lab : k => { az = mt.availability_zone_name, ip = mt.ip_address, id = mt.id } }
}

output "access_point_ids" {
  value = { app = aws_efs_access_point.app.id, other = aws_efs_access_point.other.id }
}

output "instance_ids" {
  value = { for k, i in aws_instance.client : k => i.id }
}
