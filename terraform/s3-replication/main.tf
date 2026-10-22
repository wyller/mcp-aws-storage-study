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
      Day         = "3-s3-replication"
    }
  }
}

# Same-Region Replication (SRR): no inter-region transfer, only storage and requests on both sides.
# The role's permissions come from the managed policy lab-s3-replication, created by the user in the
# console (policies/lab-s3-replication.json). terraform-lab-role can't create policies; it can only
# attach the ones on its allow-list and pass lab-s3-repl-* roles to s3.amazonaws.com.

variable "replication_rule_enabled" {
  description = "Rule status. Objects written while it is false never replicate, not even after it is turned on."
  type        = bool
  default     = true
}

variable "delete_marker_replication" {
  description = "Replicate delete markers (a DELETE by version-id never replicates either way)"
  type        = bool
  default     = false
}

variable "deny_replicate_on_dst" {
  description = "Destination bucket policy denies s3:ReplicateObject to the replication role (objects end up FAILED)"
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
  account_id = data.aws_caller_identity.current.account_id

  # Global names: the account ID avoids collisions. The prefixes must match the managed policy
  # (lab-s3-repl-src-* / lab-s3-repl-dst-*), or replication fails with the rule looking fine.
  buckets = {
    src = "lab-s3-repl-src-${local.account_id}"
    dst = "lab-s3-repl-dst-${local.account_id}"
  }

  # Built, not read: terraform-lab-role has no iam:GetPolicy, so a data source would fail.
  replication_policy_arn = "arn:aws:iam::${local.account_id}:policy/lab-s3-replication"
}

#---------------- Buckets (same baseline as Day 2) ----------------

resource "aws_s3_bucket" "lab" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.force_destroy

  tags = {
    Name = "lab-s3-repl-${each.key}"
  }
}

resource "aws_s3_bucket_public_access_block" "lab" {
  for_each = aws_s3_bucket.lab

  bucket = each.value.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lab" {
  for_each = aws_s3_bucket.lab

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Replication requires versioning on both buckets.
resource "aws_s3_bucket_versioning" "lab" {
  for_each = aws_s3_bucket.lab

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3: replicates with no extra permission. SSE-KMS would need kms:Decrypt/Encrypt on the role (KMS day).
resource "aws_s3_bucket_server_side_encryption_configuration" "lab" {
  for_each = aws_s3_bucket.lab

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Safety net in case the destroy is postponed. Lifecycle actions are not replicated:
# each bucket needs its own rules.
resource "aws_s3_bucket_lifecycle_configuration" "lab" {
  for_each = aws_s3_bucket.lab

  bucket = each.value.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

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

#---------------- Bucket policies ----------------

data "aws_iam_policy_document" "bucket" {
  for_each = aws_s3_bucket.lab

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      each.value.arn,
      "${each.value.arn}/*",
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

  # Failure scenario: the role's IAM allows ReplicateObject, the destination denies it.
  # The rule still looks fine; only x-amz-replication-status and the metrics show it.
  dynamic "statement" {
    for_each = each.key == "dst" && var.deny_replicate_on_dst ? [1] : []

    content {
      sid       = "DenyReplicationRole"
      effect    = "Deny"
      actions   = ["s3:ReplicateObject"]
      resources = ["${each.value.arn}/*"]

      principals {
        type        = "AWS"
        identifiers = [aws_iam_role.replication.arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "lab" {
  for_each = aws_s3_bucket.lab

  bucket = each.value.id
  policy = data.aws_iam_policy_document.bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.lab]
}

#---------------- Replication role ----------------

# Trust policy as in the docs: only the S3 service assumes it.
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/setting-repl-config-perm-overview.html
data "aws_iam_policy_document" "replication_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

# The name must match lab-s3-repl-*: that's the only pattern terraform-lab-role can pass to S3.
resource "aws_iam_role" "replication" {
  name               = "lab-s3-repl-role"
  assume_role_policy = data.aws_iam_policy_document.replication_trust.json
}

resource "aws_iam_role_policy_attachment" "replication" {
  role       = aws_iam_role.replication.name
  policy_arn = local.replication_policy_arn
}

#---------------- Replication configuration ----------------

# Only objects under repl/ replicate, so the "outside the filter" test lives in the same bucket.
# Replication metrics are billed as CloudWatch custom metrics (4 per rule, prorated by the hour).
resource "aws_s3_bucket_replication_configuration" "lab" {
  bucket = aws_s3_bucket.lab["src"].id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "repl-prefix"
    status = var.replication_rule_enabled ? "Enabled" : "Disabled"

    filter {
      prefix = "repl/"
    }

    delete_marker_replication {
      status = var.delete_marker_replication ? "Enabled" : "Disabled"
    }

    destination {
      bucket        = aws_s3_bucket.lab["dst"].arn
      storage_class = "STANDARD"

      metrics {
        status = "Enabled"
      }
    }
  }

  # Versioning on both sides first; the policy attachment so the first PUTs don't fail
  # while the role has no permissions yet.
  depends_on = [
    aws_s3_bucket_versioning.lab,
    aws_iam_role_policy_attachment.replication,
  ]
}

output "src_bucket" {
  value = aws_s3_bucket.lab["src"].id
}

output "dst_bucket" {
  value = aws_s3_bucket.lab["dst"].id
}

output "replication_role_arn" {
  value = aws_iam_role.replication.arn
}
