
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

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_ebs_volume" "lab" {
  availability_zone = data.aws_availability_zones.available.names[0]

  size       = 20
  type       = "gp3"
  iops       = 3000
  throughput = 125
  encrypted  = true

  tags = {
    Name        = "lab-sre-storage"
    Environment = "lab"
  }
}

output "volume_id" {
  value = aws_ebs_volume.lab.id
}


#---------------- ec2 para usar o ebs volume ----------------


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

# VPC padrão
data "aws_vpc" "default" {
  default = true
}

# Subnet na mesma AZ do EBS
data "aws_subnet" "lab" {
  availability_zone = aws_ebs_volume.lab.availability_zone
  default_for_az    = true
}

# Role para Session Manager
resource "aws_iam_role" "ec2_ssm" {
  name = "lab-storage-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "lab" {
  name = "lab-storage-ec2-profile"
  role = aws_iam_role.ec2_ssm.name
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
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.lab.id]

  iam_instance_profile = aws_iam_instance_profile.lab.name

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

# Anexar EBS existente à EC2
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
