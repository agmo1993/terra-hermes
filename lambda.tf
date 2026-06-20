# =============================================================================
# Lambda: Process SES emails → Hermes webhook
# =============================================================================

# -----------------------------------------------------------------------------
# IAM Role for Lambda
# -----------------------------------------------------------------------------
resource "aws_iam_role" "email_processor" {
  count = var.enable_email_processing ? 1 : 0
  name  = "${var.name}-email-processor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "email_processor_logs" {
  count = var.enable_email_processing ? 1 : 0
  role       = aws_iam_role.email_processor[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "email_processor_perms" {
  count = var.enable_email_processing ? 1 : 0
  role   = aws_iam_role.email_processor[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = var.email_s3_bucket_name != "" ? "${aws_s3_bucket.emails[0].arn}/*" : "*"
      },
      {
        Effect = "Allow"
        Action = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = var.enable_email_processing ? aws_dynamodb_table.email_metadata[0].arn : "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# DynamoDB: Email metadata table
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "email_metadata" {
  count = var.enable_email_processing ? 1 : 0
  name           = "${var.name}-email-metadata"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "message_id"
  attribute {
    name = "message_id"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# -----------------------------------------------------------------------------
# Lambda Function (code packaged separately)
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "email_processor" {
  count = var.enable_email_processing ? 1 : 0

  function_name = "${var.name}-email-processor"
  runtime       = "python3.11"
  role          = aws_iam_role.email_processor[0].arn
  handler       = "lambda_email_processor.handler"
  timeout       = 60
  memory_size   = 256
  architectures = ["x86_64"]

  # Package the lambda code
  filename         = "lambda_email_processor.zip"
  source_code_hash = filebase64sha256("lambda_email_processor.zip")

  environment {
    variables = {
      EMAIL_TABLE         = aws_dynamodb_table.email_metadata[0].name
      HERMES_WEBHOOK_URL  = "http://${aws_instance.hermes.private_ip}:8000/webhook/email"
      HERMES_WEBHOOK_SECRET=var.hermes_webhook_secret
      SES_SEND_FROM       = "Hermes <noreply@${var.ses_domain}>"
      AWS_REGION          = var.region
    }
  }
}

# SNS → Lambda subscription
resource "aws_lambda_event_source_mapping" "sns_to_lambda" {
  count = var.enable_email_processing ? 1 : 0
  event_source_arn = aws_sns_topic.email_received[0].arn
  function_name    = aws_lambda_function.email_processor[0].arn
  batch_size       = 10
  maximum_batching_window_in_seconds = 30
}

# Permission for SNS to invoke Lambda
resource "aws_lambda_permission" "sns_invoke" {
  count = var.enable_email_processing ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_processor[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.email_received[0].arn
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "email_processor_lambda_arn" {
  description = "Lambda function ARN for email processing"
  value       = var.enable_email_processing ? aws_lambda_function.email_processor[0].arn : null
}

output "email_metadata_table" {
  description = "DynamoDB table for email metadata"
  value       = var.enable_email_processing ? aws_dynamodb_table.email_metadata[0].name : null
}