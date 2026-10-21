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

  default_tags {
    tags = {
      Environment = "lab"
      Projeto     = "storage-study"
      Dia         = "2-s3"
    }
  }
}

# Sem EC2, KMS nem endpoint neste bloco: o 403 é provocado com as identidades que já
# existem. O readonly-user (ReadOnlyAccess) é o "cliente" e a terraform-lab-role é o admin.
# Nada de IAM é criado ou alterado: todo o cenário fica na bucket policy.

variable "negar_list_readonly" {
  description = "Nega s3:ListBucket ao readonly-user neste bucket (o 404 de objeto inexistente vira 403)"
  type        = bool
  default     = false
}

variable "force_destroy" {
  description = "Deixa o destroy apagar todas as versões e delete markers. Só vale depois de um apply com true."
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  readonly_arn = "arn:aws:iam::${local.account_id}:user/readonly-user"
}

resource "aws_s3_bucket" "lab" {
  # Nome global: o ID da conta evita colisão sem precisar do provider random.
  bucket        = "lab-s3-dia2-${local.account_id}"
  force_destroy = var.force_destroy

  tags = {
    Name = "lab-s3-dia2"
  }
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket = aws_s3_bucket.lab.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ACLs desligadas: só as policies decidem o acesso (já é o padrão desde 2023; aqui fica explícito).
resource "aws_s3_bucket_ownership_controls" "lab" {
  bucket = aws_s3_bucket.lab.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "lab" {
  bucket = aws_s3_bucket.lab.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256): sem chave KMS, sem custo por requisição de criptografia.
resource "aws_s3_bucket_server_side_encryption_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Rede de segurança caso o destroy fique para depois: versões antigas e uploads
# incompletos cobram GB-mês mesmo sem aparecer no `aws s3 ls`.
resource "aws_s3_bucket_lifecycle_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id

  rule {
    id     = "limpa-versoes-antigas"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    # Delete marker sem nenhuma versão por baixo não serve para nada; o lifecycle o remove.
    expiration {
      expired_object_delete_marker = true
    }
  }

  rule {
    id     = "aborta-multipart"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.lab]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "NegaSemTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.lab.arn,
      "${aws_s3_bucket.lab.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Cenário do 403 por deny explícito: o IAM do readonly-user permite s3:Get*, a bucket policy nega.
  statement {
    sid       = "NegaRestritoAoReadonly"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.lab.arn}/restrito/*"]

    principals {
      type        = "AWS"
      identifiers = [local.readonly_arn]
    }
  }

  # Cenário do 403 que esconde um 404: sem ListBucket, objeto inexistente responde 403.
  dynamic "statement" {
    for_each = var.negar_list_readonly ? [1] : []

    content {
      sid       = "NegaListAoReadonly"
      effect    = "Deny"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.lab.arn]

      principals {
        type        = "AWS"
        identifiers = [local.readonly_arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "lab" {
  bucket = aws_s3_bucket.lab.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.lab]
}

# Objetos fixos do Terraform. O teste de versionamento usa outra chave (versionamento/),
# criada pela CLI, para o Terraform não ver drift nem reverter as versões.
resource "aws_s3_object" "publico" {
  bucket       = aws_s3_bucket.lab.id
  key          = "publico/ola.txt"
  content      = "lab dia 2: objeto liberado para o readonly-user\n"
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_versioning.lab]
}

resource "aws_s3_object" "restrito" {
  bucket       = aws_s3_bucket.lab.id
  key          = "restrito/ola.txt"
  content      = "lab dia 2: objeto negado ao readonly-user pela bucket policy\n"
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_versioning.lab]
}

output "bucket" {
  value = aws_s3_bucket.lab.id
}

output "readonly_arn" {
  value = local.readonly_arn
}
