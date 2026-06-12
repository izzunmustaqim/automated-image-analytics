# =============================================================================
# Automated Image Analytics — Terraform Infrastructure
# =============================================================================
# Architecture:
#   S3 (image upload) → Lambda (Python 3.11) → Rekognition → DynamoDB
#
# Cost: $0 under AWS Free Tier (1M Lambda requests, 25 GB DynamoDB,
#        5,000 Rekognition images/month for first 12 months).
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------------------------
# Local Variables
# ---------------------------------------------------------------------------
locals {
  project_name    = "automated-image-analytics"
  s3_bucket_name  = "my-cs-ai-source-images"
  dynamodb_table  = "ImageAnalysisMetadata"
  lambda_function = "image-analysis-processor"
  lambda_handler  = "lambda_function.lambda_handler"
  lambda_runtime  = "python3.11"
  lambda_timeout  = 30
  lambda_memory   = 256
}

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  S3 — Source Images Bucket                                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

resource "aws_s3_bucket" "source_images" {
  bucket        = local.s3_bucket_name
  force_destroy = true

  tags = {
    Project     = local.project_name
    Environment = "dev"
  }
}

# Block all public access — images are private
resource "aws_s3_bucket_public_access_block" "source_images" {
  bucket = aws_s3_bucket.source_images.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable server-side encryption (SSE-S3, free)
resource "aws_s3_bucket_server_side_encryption_configuration" "source_images" {
  bucket = aws_s3_bucket.source_images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Enable versioning for auditability
resource "aws_s3_bucket_versioning" "source_images" {
  bucket = aws_s3_bucket.source_images.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  DynamoDB — Image Analysis Metadata Table                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

resource "aws_dynamodb_table" "image_metadata" {
  name         = local.dynamodb_table
  billing_mode = "PAY_PER_REQUEST" # On-demand — no capacity planning, Free Tier eligible

  hash_key = "ImageID"

  attribute {
    name = "ImageID"
    type = "S"
  }

  tags = {
    Project     = local.project_name
    Environment = "dev"
  }
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  IAM — Lambda Execution Role (Principle of Least Privilege)              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Trust policy: allow Lambda service to assume this role
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Project = local.project_name
  }
}

# --- Policy: S3 GetObject (scoped to the source bucket only) ---
data "aws_iam_policy_document" "lambda_s3_access" {
  statement {
    sid    = "AllowGetObjectFromSourceBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = [
      "${aws_s3_bucket.source_images.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "lambda_s3_access" {
  name   = "${local.project_name}-lambda-s3-policy"
  policy = data.aws_iam_policy_document.lambda_s3_access.json
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_access.arn
}

# --- Policy: Rekognition DetectLabels (global — no resource-level scoping) ---
data "aws_iam_policy_document" "lambda_rekognition_access" {
  statement {
    sid    = "AllowDetectLabels"
    effect = "Allow"
    actions = [
      "rekognition:DetectLabels"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_rekognition_access" {
  name   = "${local.project_name}-lambda-rekognition-policy"
  policy = data.aws_iam_policy_document.lambda_rekognition_access.json
}

resource "aws_iam_role_policy_attachment" "lambda_rekognition" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_rekognition_access.arn
}

# --- Policy: DynamoDB PutItem (scoped to the metadata table only) ---
data "aws_iam_policy_document" "lambda_dynamodb_access" {
  statement {
    sid    = "AllowPutItemToMetadataTable"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem"
    ]
    resources = [
      aws_dynamodb_table.image_metadata.arn
    ]
  }
}

resource "aws_iam_policy" "lambda_dynamodb_access" {
  name   = "${local.project_name}-lambda-dynamodb-policy"
  policy = data.aws_iam_policy_document.lambda_dynamodb_access.json
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_dynamodb_access.arn
}

# --- Policy: CloudWatch Logs (scoped to this function's log group) ---
data "aws_iam_policy_document" "lambda_cloudwatch_access" {
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_function}:*"
    ]
  }
}

resource "aws_iam_policy" "lambda_cloudwatch_access" {
  name   = "${local.project_name}-lambda-cloudwatch-policy"
  policy = data.aws_iam_policy_document.lambda_cloudwatch_access.json
}

resource "aws_iam_role_policy_attachment" "lambda_cloudwatch" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_cloudwatch_access.arn
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Lambda — Image Analysis Processor                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Package the Python source into a zip for deployment
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/deployment_package.zip"
}

resource "aws_lambda_function" "image_processor" {
  function_name    = local.lambda_function
  description      = "Analyses uploaded images via Rekognition and stores metadata in DynamoDB"
  role             = aws_iam_role.lambda_exec.arn
  handler          = local.lambda_handler
  runtime          = local.lambda_runtime
  timeout          = local.lambda_timeout
  memory_size      = local.lambda_memory
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME  = local.dynamodb_table
      CONFIDENCE_THRESHOLD = "80"
    }
  }

  tags = {
    Project     = local.project_name
    Environment = "dev"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_s3,
    aws_iam_role_policy_attachment.lambda_rekognition,
    aws_iam_role_policy_attachment.lambda_dynamodb,
    aws_iam_role_policy_attachment.lambda_cloudwatch,
    aws_cloudwatch_log_group.lambda,
  ]
}

# CloudWatch Log Group — 14-day retention to stay within Free Tier
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function}"
  retention_in_days = 14

  tags = {
    Project = local.project_name
  }
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  S3 → Lambda Event Notification Trigger                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Allow S3 to invoke the Lambda function
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.source_images.arn
  source_account = data.aws_caller_identity.current.account_id
}

# Configure S3 bucket notifications for image uploads
resource "aws_s3_bucket_notification" "image_upload_trigger" {
  bucket = aws_s3_bucket.source_images.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpg"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpeg"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".png"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Outputs                                                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

output "s3_bucket_name" {
  description = "Name of the S3 source images bucket"
  value       = aws_s3_bucket.source_images.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 source images bucket"
  value       = aws_s3_bucket.source_images.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB metadata table"
  value       = aws_dynamodb_table.image_metadata.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB metadata table"
  value       = aws_dynamodb_table.image_metadata.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.image_processor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.image_processor.arn
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution IAM role"
  value       = aws_iam_role.lambda_exec.arn
}
