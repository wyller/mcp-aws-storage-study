terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Day 4: EBS snapshots, restore and first-access latency. Runbook in README.md.
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
    Lab         = "ebs-snapshots"
    Day         = "4"
    ManagedBy   = "terraform"
    Stack       = "terraform/ebs-snapshots"
  }
}

variable "volume_size" {
  description = "Size of the gp3 data volume, in GiB"
  type        = number
  default     = 20
}

variable "instance_type" {
  description = "EC2 instance type; its EBS limits come from describe-instance-types"
  type        = string
  default     = "t3.micro"
}

# Each label is one aws_ebs_snapshot. Adding a label takes a new snapshot of the data volume
# (the earlier ones stay as they are), unless snapshot_ids adopts one taken outside Terraform;
# removing a label deletes that snapshot only.
# Order matters for the lab, not for Terraform: add one label per apply, after the data step.
# Snapshots bill per GB-month of the blocks they hold; never archive one in a lab (90-day minimum).
variable "snapshots" {
  description = "Labels of the snapshots to keep of the data volume, e.g. [\"s1\", \"s2\"]"
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.snapshots : can(regex("^[a-z0-9-]{1,20}$", s))])
    error_message = "Snapshot labels: lowercase letters, digits and '-', up to 20 characters."
  }
}

# Snapshots taken by scripts/ebs-snapshots.sh take (freeze -> CreateSnapshot -> thaw, which an apply
# can't do: it shows no sign of when AWS accepted the snapshot). The import block below adopts each one
# into aws_ebs_snapshot.data[label], so destroy still removes it. Drop a label here when dropping it above.
variable "snapshot_ids" {
  description = "Snapshots to adopt into the state, label => snapshot ID, e.g. { s1 = \"snap-...\" }"
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k, id in var.snapshot_ids : contains(var.snapshots, k) && can(regex("^snap-[0-9a-f]+$", id))])
    error_message = "Each snapshot_ids key must be in snapshots, and each value a snap-... ID."
  }
}

# Changing it from one label to another replaces the restored volume. Unmount it first and check
# with lab-ebs detach-ready: a mounted volume leaves the detach in "busy" until it is unmounted.
variable "restore_from" {
  description = "Label of the snapshot to restore as a new volume on /dev/sdg; null for none"
  type        = string
  default     = null

  validation {
    condition     = var.restore_from == null || contains(var.snapshots, coalesce(var.restore_from, "-"))
    error_message = "restore_from must be one of the labels in snapshots."
  }
}

# A restored volume can be larger than the snapshot (the filesystem then needs resize2fs), never smaller.
variable "restored_size" {
  description = "Size of the restored volume, in GiB; null keeps the snapshot size"
  type        = number
  default     = null

  validation {
    condition     = var.restored_size == null || coalesce(var.restored_size, 0) >= var.volume_size
    error_message = "restored_size can't be smaller than the snapshot (volume_size)."
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# AMI Ubuntu 24.04 LTS (SSM agent preinstalled)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

# Same AZ for the instance and every volume; it comes from the AZ list, not from a resource,
# so a change in a volume never defers it to apply time (Day 1 lesson: that replaced the EC2).
data "aws_subnet" "lab" {
  availability_zone = data.aws_availability_zones.available.names[0]
  default_for_az    = true
}

# SSM profile, created in terraform/iam-compartilhado (kept between days)
data "aws_iam_instance_profile" "lab" {
  name = "lab-storage-ec2-profile"
}


#---------------- EC2, reached only through Session Manager ----------------


# No ingress rule: Session Manager only needs outbound 443 from the agent.
resource "aws_security_group" "lab" {
  name_prefix = "lab-ebs-snap-"
  description = "Day 4 EBS snapshots lab, no ingress"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab-ebs-snap-sg"
  }
}

resource "aws_instance" "lab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.lab.id]

  iam_instance_profile = data.aws_iam_instance_profile.lab.name

  # Public IPv4 (US$ 0.005/h) is what lets the agent reach SSM without NAT or interface
  # endpoints (three endpoints would cost ~US$ 0.03/h). Nothing listens: the SG has no ingress.
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  # Installs fio and /usr/local/bin/lab-ebs. Editing files/lab-ebs.sh changes user_data, and the
  # provider applies it with a stop/start of the instance: mounts and /tmp are lost.
  user_data = templatefile("${path.module}/files/cloud-init.yaml.tftpl", {
    lab_ebs_gzb64 = base64gzip(file("${path.module}/files/lab-ebs.sh"))
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true

    tags = merge(local.tags, {
      Name = "lab-ebs-snap-root"
    })
  }

  tags = {
    Name = "lab-ebs-snap-ec2"
  }

  # A newer Ubuntu AMI published mid-lab would replace the instance on the next apply.
  lifecycle {
    ignore_changes = [ami]
  }
}


#---------------- Data volume and its snapshots ----------------


# The account has EBS encryption by default off, so it is set here (key alias/aws/ebs).
# Snapshots of an encrypted volume, and volumes restored from them, are encrypted too.
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.lab.availability_zone

  size       = var.volume_size
  type       = "gp3"
  iops       = 3000
  throughput = 125
  encrypted  = true

  tags = {
    Name = "lab-ebs-snap-data"
  }
}

# Only detached by the destroy, which terminates the instance next anyway: stopping it first
# keeps a still-mounted volume from leaving the detach in "busy" until it times out.
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.lab.id

  stop_instance_before_detaching = true
}

# CreateSnapshot captures the volume at the moment of the call; Terraform then waits for
# "completed". Snapshots that need a freeze are taken by the script and adopted (snapshot_ids).
# The script uses this same description and these tags, so the import shows no diff.
resource "aws_ebs_snapshot" "data" {
  for_each = var.snapshots

  volume_id   = aws_ebs_volume.data.id
  description = "Day 4 lab: data volume, snapshot ${each.key}"

  tags = {
    Name          = "lab-ebs-snap-${each.key}"
    SnapshotLabel = each.key
  }

  timeouts {
    create = "30m"
  }
}


# Already-imported IDs are a no-op on later plans.
import {
  for_each = var.snapshot_ids
  to       = aws_ebs_snapshot.data[each.key]
  id       = each.value
}


#---------------- Volume restored from one snapshot ----------------


# No volume_initialization_rate and no fast snapshot restore on purpose: the lab measures the
# default lazy loading from S3. Both bill extra (FSR is US$ 0.75 per DSU-hour per AZ).
resource "aws_ebs_volume" "restored" {
  count = var.restore_from == null ? 0 : 1

  availability_zone = aws_ebs_volume.data.availability_zone
  snapshot_id       = aws_ebs_snapshot.data[var.restore_from].id

  size       = coalesce(var.restored_size, var.volume_size)
  type       = "gp3"
  iops       = 3000
  throughput = 125
  encrypted  = true

  tags = {
    Name         = "lab-ebs-snap-restored"
    RestoredFrom = var.restore_from
  }
}

resource "aws_volume_attachment" "restored" {
  count = var.restore_from == null ? 0 : 1

  device_name = "/dev/sdg"
  volume_id   = aws_ebs_volume.restored[0].id
  instance_id = aws_instance.lab.id
}


#---------------- Outputs ----------------


output "instance_id" {
  value = aws_instance.lab.id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "snapshot_ids" {
  value = { for k, s in aws_ebs_snapshot.data : k => s.id }
}

output "restored_volume_id" {
  value = one(aws_ebs_volume.restored[*].id)
}
