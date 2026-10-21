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
      Project     = "storage-study"
      Day         = "2-s3"
    }
  }
}

# No EC2, KMS or endpoint in this block: the 403 is triggered with identities that already
# exist. readonly-user (ReadOnlyAccess) is the "client" and terraform-lab-role is the admin.
# No IAM is created or changed: the whole scenario lives in the bucket policy.

variable "deny_list_to_readonly" {
  description = "Deny s3:ListBucket to readonly-user on this bucket (a missing object's 404 becomes 403)"
  type        = bool
  default     = false
}

variable "force_destroy" {
  description = "Let destroy delete every version and delete marker. Only takes effect after an apply with true."
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  readonly_arn = "arn:aws:iam::${local.account_id}:user/readonly-user"
}

resource "aws_s3_bucket" "lab" {
  # Global name: the account ID avoids collisions without the random provider.
  # Renaming a bucket forces a replace, so the name stays as first applied.
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

# ACLs disabled: only policies decide access (the default since 2023; explicit here).
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

# SSE-S3 (AES256): no KMS key, no per-request encryption cost.
resource "aws_s3_bucket_server_side_encryption_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Safety net in case the destroy is postponed: old versions and incomplete uploads
# are billed per GB-month even though `aws s3 ls` doesn't show them.
resource "aws_s3_bucket_lifecycle_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    # A delete marker with no versions under it is useless; lifecycle removes it.
    expiration {
      expired_object_delete_marker = true
    }
  }

  rule {
    id     = "abort-multipart"
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
    sid     = "DenyInsecureTransport"
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

  # Explicit-deny 403: readonly-user's IAM allows s3:Get*, the bucket policy denies it.
  statement {
    sid       = "DenyRestrictedToReadonly"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.lab.arn}/restricted/*"]

    principals {
      type        = "AWS"
      identifiers = [local.readonly_arn]
    }
  }

  # 403 hiding a 404: without ListBucket, a missing object answers 403.
  dynamic "statement" {
    for_each = var.deny_list_to_readonly ? [1] : []

    content {
      sid       = "DenyListToReadonly"
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

# Objects owned by Terraform. The versioning test uses another key (versioning/),
# created by the CLI, so Terraform sees no drift and doesn't revert the versions.
resource "aws_s3_object" "public" {
  bucket       = aws_s3_bucket.lab.id
  key          = "public/hello.txt"
  content      = "lab day 2: object allowed for readonly-user\n"
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_versioning.lab]
}

resource "aws_s3_object" "restricted" {
  bucket       = aws_s3_bucket.lab.id
  key          = "restricted/hello.txt"
  content      = "lab day 2: object denied to readonly-user by the bucket policy\n"
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_versioning.lab]
}

output "bucket" {
  value = aws_s3_bucket.lab.id
}

output "readonly_arn" {
  value = local.readonly_arn
}
