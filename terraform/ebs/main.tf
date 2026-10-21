
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Changing size/IOPS/throughput in an apply becomes a modify-volume: up to 4 per volume in a
# rolling 24 h window, each one only after the previous one reaches "completed".
# Size can't shrink.
variable "volume_size" {
  description = "Size of the gp3 data volume, in GiB"
  type        = number
  default     = 20
}

variable "volume_iops" {
  description = "gp3 IOPS (3000 included in the price)"
  type        = number
  default     = 3000

  validation {
    condition     = var.volume_iops >= 3000 && var.volume_iops <= 500 * var.volume_size
    error_message = "gp3: IOPS between 3000 and 500 per GiB of volume."
  }
}

variable "volume_throughput" {
  description = "gp3 throughput, in MiB/s (125 included in the price)"
  type        = number
  default     = 125

  validation {
    condition     = var.volume_throughput >= 125 && var.volume_throughput <= var.volume_iops / 4
    error_message = "gp3: throughput between 125 MiB/s and 0.25 MiB/s per IOPS."
  }
}

variable "instance_type" {
  description = "EC2 instance type; its EBS limits come from describe-instance-types"
  type        = string
  default     = "t3.micro"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_ebs_volume" "lab" {
  availability_zone = data.aws_availability_zones.available.names[0]

  size       = var.volume_size
  type       = "gp3"
  iops       = var.volume_iops
  throughput = var.volume_throughput
  encrypted  = true

  tags = {
    Name        = "lab-sre-storage"
    Environment = "lab"
  }
}

output "volume_id" {
  value = aws_ebs_volume.lab.id
}


#---------------- EC2 that uses the EBS volume ----------------


# AMI Ubuntu 24.04 LTS
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

# Default VPC
data "aws_vpc" "default" {
  default = true
}

# Subnet in the same AZ as the EBS volume. Reads the AZ from the volume's source, not from the volume:
# referencing the resource defers this data source to apply time when the volume changes,
# and a "known after apply" subnet_id forces the EC2 to be replaced.
data "aws_subnet" "lab" {
  availability_zone = data.aws_availability_zones.available.names[0]
  default_for_az    = true
}

# SSM profile, created in terraform/iam-compartilhado (kept between days)
data "aws_iam_instance_profile" "lab" {
  name = "lab-storage-ec2-profile"
}

resource "aws_security_group" "lab" {
  name_prefix = "lab-storage-"
  description = "EC2 storage lab"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "lab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.lab.id]

  iam_instance_profile = data.aws_iam_instance_profile.lab.name

  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 12
    encrypted   = true
  }

  tags = {
    Name = "lab-sre-storage-ec2"
  }
}

# Attach the existing EBS volume to the EC2
resource "aws_volume_attachment" "lab" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.lab.id
  instance_id = aws_instance.lab.id
}

output "instance_id" {
  value = aws_instance.lab.id
}

output "public_ip" {
  value = aws_instance.lab.public_ip
}
