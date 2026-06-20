# SES Email Integration for Hermes

This Terraform module adds AWS SES email receiving/sending capabilities to your Hermes agent, replacing services like agentmail.

## Architecture

```
Incoming Email → SES → S3 (raw .eml) → SNS → Lambda (parse) → Hermes Webhook (:8000)
                                                          ↓
                                                   DynamoDB (metadata)
                                                          ↓
                                                   Hermes Agent (Telegram/skills)
```

## Prerequisites

1. **Domain in Route 53** - You must own a domain managed by Route 53
2. **SES Production Access** - Request via AWS Console or CLI
3. **Unique S3 Bucket Name** - Globally unique bucket for email storage

## Configuration

Add to your `terraform.tfvars`:

```hcl
# Required for email processing
ses_domain              = "hermes.yourdomain.com"      # Subdomain for Hermes
route53_hosted_zone_name = "yourdomain.com."           # With trailing dot!
email_s3_bucket_name    = "hermes-emails-prod-12345"   # Globally unique
enable_email_processing = true
hermes_webhook_secret   = "openssl rand -hex 32"       # 64-char hex string

# Add port 8000 for webhook
allowed_ports = [3000, 4000, 5000, 5173, 8000, 8080, 8443, 8888]
```

## Deployment

```bash
# 1. Build Lambda package
zip lambda_email_processor.zip lambda_email_processor.py

# 2. Deploy
terraform init
terraform plan
terraform apply

# 3. Request SES production access
aws sesv2 put-account-details \
  --mail-type TRANSACTIONAL \
  --production-access-enabled \
  --region us-east-1
```

## Verification

```bash
# Check SES verification status
aws ses get-identity-verification-attributes --identities hermes.yourdomain.com

# Check DKIM
aws ses get-identity-dkim-attributes --identities hermes.yourdomain.com

# Test sending
aws ses send-email \
  --from "Hermes <noreply@hermes.yourdomain.com>" \
  --to "test@example.com" \
  --subject "Test" \
  --text "Hello from Hermes!"

# Test receiving: send email to test@hermes.yourdomain.com
# Check logs: aws logs tail /aws/lambda/hermes-email-processor --follow
```

## Hermes Integration

### Webhook Skill (Auto-installed)
Receives emails at `http://<instance-ip>:8000/webhook/email`, stores in `~/.hermes/emails.jsonl`, notifies via Telegram.

### SES Send Email Skill
Located at `skills/ses-send-email/tool.py`. Provides `send_email` tool for Hermes agents.

Usage in Hermes:
```
You: /send_email to:user@example.com subject:"Hello" body:"Sent from Hermes via SES!"
```

## Files Added

| File | Purpose |
|------|---------|
| `ses.tf` | SES domain verification, DKIM, Route53 records, S3, SNS, receipt rules |
| `lambda.tf` | Lambda processor, IAM, DynamoDB, SNS subscription |
| `lambda_email_processor.py` | Lambda code: parse emails, forward to Hermes webhook |
| `skills/ses-send-email/tool.py` | Hermes tool for sending emails via SES |
| `templates/hermes-startup.sh` | Updated to install webhook skill auto-magically |
| `variables.tf` | New variables for email configuration |
| `main.tf` | Passes `HERMES_WEBHOOK_SECRET` to instance |

## Cost Estimate (10k emails/month)

| Service | Monthly Cost |
|---------|--------------|
| SES (receive + send) | ~$1.00 |
| S3 (10 GB) | ~$0.30 |
| Lambda (1M invocations) | ~$0.20 |
| SNS (100k publishes) | ~$0.50 |
| DynamoDB (on-demand) | ~$1.00 |
| Route 53 | ~$0.50 |
| **Total** | **~$3.50/month** |

## Security Notes

- Webhook uses HMAC-SHA256 signature verification (`HERMES_WEBHOOK_SECRET`)
- Lambda uses instance IAM role for SES/S3/DynamoDB access
- S3 bucket encrypted with SSE-AES256
- Emails auto-expire after 90 days (TTL in DynamoDB)
- Security group opens port 8000 only when `enable_email_processing = true`

## Troubleshooting

**Emails not received?**
- Check SES receipt rule is active: `aws ses describe-active-receipt-rule-set`
- Verify MX record: `dig MX hermes.yourdomain.com`
- Check Lambda logs: CloudWatch → `/aws/lambda/hermes-email-processor`

**Webhook not called?**
- Verify security group allows port 8000
- Check Lambda environment has correct `HERMES_WEBHOOK_URL`
- Test webhook: `curl -X POST http://<ip>:8000/health`

**Can't send emails?**
- Request SES production access (sandbox mode limits to verified addresses)
- Check DKIM/SPF/DMARC alignment
- Verify `SES_SEND_FROM` uses verified domain