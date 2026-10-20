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

# IAM reaproveitado entre os dias. Não custa nada parado, então fica fora do
# destroy diário dos stacks de lab (ex.: terraform/ebs).

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

output "instance_profile_name" {
  value = aws_iam_instance_profile.lab.name
}
