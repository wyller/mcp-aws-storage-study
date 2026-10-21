
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

# Mudar tamanho/IOPS/throughput num apply vira modify-volume: até 4 por volume numa
# janela móvel de 24 h, cada uma só depois da anterior chegar a "completed".
# O tamanho não pode diminuir.
variable "volume_size" {
  description = "Tamanho do gp3 de dados, em GiB"
  type        = number
  default     = 20
}

variable "volume_iops" {
  description = "IOPS do gp3 (3000 inclusos no preço)"
  type        = number
  default     = 3000

  validation {
    condition     = var.volume_iops >= 3000 && var.volume_iops <= 500 * var.volume_size
    error_message = "gp3: IOPS entre 3000 e 500 por GiB do volume."
  }
}

variable "volume_throughput" {
  description = "Throughput do gp3, em MiB/s (125 inclusos no preço)"
  type        = number
  default     = 125

  validation {
    condition     = var.volume_throughput >= 125 && var.volume_throughput <= var.volume_iops / 4
    error_message = "gp3: throughput entre 125 MiB/s e 0,25 MiB/s por IOPS."
  }
}

variable "instance_type" {
  description = "Tipo da EC2; os limites de EBS dela vêm de describe-instance-types"
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

# Subnet na mesma AZ do EBS. Lê a AZ da mesma fonte do volume, e não do volume:
# referenciar o recurso adia este data source para o apply quando o volume muda,
# e o subnet_id "known after apply" força o replace da EC2.
data "aws_subnet" "lab" {
  availability_zone = data.aws_availability_zones.available.names[0]
  default_for_az    = true
}

# Profile do SSM, criado em terraform/iam-compartilhado (fica entre os dias)
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
