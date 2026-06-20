# =============================================================================
# SES Email Receiving with Existing Route 53 Hosted Zone
# =============================================================================

# -----------------------------------------------------------------------------
# Data: Look up your existing Route 53 hosted zone
# -----------------------------------------------------------------------------
data "aws_route53_zone" "existing" {
  count = var.enable_email_processing && var.route53_hosted_zone_name != "" ? 1 : 0
  name  = var.route53_hosted_zone_name
}

# -----------------------------------------------------------------------------
# SES: Verify domain identity
# -----------------------------------------------------------------------------
resource "aws_ses_domain_identity" "hermes" {
  count  = var.enable_email_processing && var.ses_domain != "" ? 1 : 0
  domain = var.ses_domain
}

# SES: DKIM verification tokens (we'll create CNAME records for these)
resource "aws_ses_domain_dkim" "hermes" {
  count  = var.enable_email_processing && var.ses_domain != "" ? 1 : 0
  domain = aws_ses_domain_identity.hermes[0].domain
}

# -----------------------------------------------------------------------------
# Route 53: Create DKIM CNAME records in YOUR existing hosted zone
# -----------------------------------------------------------------------------
resource "aws_route53_record" "dkim" {
  count = var.enable_email_processing && var.ses_domain != "" ? 3 : 0

  zone_id = data.aws_route53_zone.existing[0].zone_id
  name    = "${aws_ses_domain_dkim.hermes[0].dkim_tokens[count.index]}.${var.route53_hosted_zone_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.hermes[0].dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# Route 53: Domain verification TXT record
resource "aws_route53_record" "ses_verification" {
  count = var.enable_email_processing && var.ses_domain != "" ? 1 : 0

  zone_id = data.aws_route53_zone.existing[0].zone_id
  name    = "_amazonses.${var.route53_hosted_zone_name}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.hermes[0].verification_token]
}

# Route 53: MX record for receiving email
resource "aws_route53_record" "mx" {
  count = var.enable_email_processing && var.ses_domain != "" ? 1 : 0

  zone_id = data.aws_route53_zone.existing[0].zone_id
  name    = var.route53_hosted_zone_name
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.${var.region}.amazonaws.com"]
}

# Optional: SPF record (recommended for sending reputation)
resource "aws_route53_record" "spf" {
  count = var.enable_email_processing && var.ses_domain != "" ? 1 : 0

  zone_id = data.aws_route53_zone.existing[0].zone_id
  name    = var.route53_hosted_zone_name
  type    = "TXT"
  ttl     = 300
  records = ["\"v=spf1 include:amazonses.com ~all\""]
}

# Optional: DMARC record (recommended)
resource "aws_route53_record" "dmarc" {
  count = var.enable_email_processing && var.ses_domain != "" ? 1 : 0

  zone_id = data.aws_route53_zone.existing[0].zone_id
  name    = "_dmarc.${var.route53_hosted_zone_name}"
  type    = "TXT"
  ttl     = 300
  records = ["\"v=DMARC1; p=quarantine; rua=mailto:dmarc@${var.ses_domain}\""]
}

# -----------------------------------------------------------------------------
# S3: Bucket for raw email storage
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "emails" {
  count = var.enable_email_processing && var.email_s3_bucket_name != "" ? 1 : 0
  bucket = var.email_s3_bucket_name

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  versioning {
    enabled = true
  }

  lifecycle_rule {
    enabled = true
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# S3 bucket policy: allow SES to write
resource "aws_s3_bucket_policy" "emails_ses" {
  count = var.enable_email_processing && var.email_s3_bucket_name != "" ? 1 : 0
  bucket = aws_s3_bucket.emails[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPuts"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = ["s3:PutObject", "s3:PutObjectAcl"]
      Resource  = "${aws_s3_bucket.emails[0].arn}/*"
      Condition = {
        StringEquals = { "aws:Referer" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# SNS: Topic for email events
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "email_received" {
  count = var.enable_email_processing ? 1 : 0
  name   = "${var.name}-email-received"
}

# -----------------------------------------------------------------------------
# SES: Receipt rule set + rule (S3 + SNS actions)
# -----------------------------------------------------------------------------
resource "aws_ses_receipt_rule_set" "hermes" {
  count = var.enable_email_processing ? 1 : 0
  name  = "${var.name}-email-rules"
}

resource "aws_ses_receipt_rule" "store_and_notify" {
  count = var.enable_email_processing ? 1 : 0

  rule_set_name = aws_ses_receipt_rule_set.hermes[0].name
  name          = "store-and-notify"
  enabled       = true
  tls_policy    = "Require"
  recipients    = var.ses_domain != "" ? ["@${var.ses_domain}"] : []

  s3_action {
    bucket_name      = aws_s3_bucket.emails[0].id
    object_key_prefix = "incoming/"
    kms_key_arn      = ""
  }

  sns_action {
    topic_arn = aws_sns_topic.email_received[0].arn
    encoding  = "UTF-8"
  }

  scan_enabled = true
}

resource "aws_ses_active_receipt_rule_set" "hermes" {
  count = var.enable_email_processing ? 1 : 0
  rule_set_name = aws_ses_receipt_rule_set.hermes[0].name
}

# -----------------------------------------------------------------------------
# Outputs for verification
# -----------------------------------------------------------------------------
output "ses_domain_verification_token" {
  description = "TXT record value for domain verification (also created in Route53 automatically)"
  value       = var.enable_email_processing && var.ses_domain != "" ? aws_ses_domain_identity.hermes[0].verification_token : null
  sensitive   = false
}

output "ses_dkim_tokens" {
  description = "DKIM CNAME tokens (also created in Route53 automatically)"
  value       = var.enable_email_processing && var.ses_domain != "" ? aws_ses_domain_dkim.hermes[0].dkim_tokens : null
  sensitive   = false
}

output "ses_mx_endpoint" {
  description = "MX record endpoint for receiving email"
  value       = "inbound-smtp.${var.region}.amazonaws.com"
}

output "email_s3_bucket" {
  description = "S3 bucket for raw email storage"
  value       = var.enable_email_processing ? aws_s3_bucket.emails[0].id : null
}