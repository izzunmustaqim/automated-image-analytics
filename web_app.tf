# =============================================================================
# Full-Stack Web App Extension (Frontend & API)
# =============================================================================

locals {
  api_lambda_function = "${local.project_name}-api"
  api_lambda_handler  = "api_function.lambda_handler"
  frontend_bucket     = "my-cs-ai-dashboard-${data.aws_caller_identity.current.account_id}" # Make globally unique
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  S3 — Frontend Website Hosting                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

resource "aws_s3_bucket" "frontend" {
  bucket        = local.frontend_bucket
  force_destroy = true
  tags = {
    Project     = local.project_name
    Environment = "dev"
  }
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend_public_read" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# Add CORS to the SOURCE bucket so the browser can upload via presigned URLs
resource "aws_s3_bucket_cors_configuration" "source_images_cors" {
  bucket = aws_s3_bucket.source_images.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST", "GET", "HEAD"]
    allowed_origins = ["*"] # In production, restrict to frontend URL
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Lambda — API Backend                                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

data "archive_file" "api_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/api_function.py"
  output_path = "${path.module}/api_deployment_package.zip"
}

resource "aws_iam_role" "api_lambda_exec" {
  name               = "${local.project_name}-api-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# IAM Policy: DynamoDB Read (Scan/Query)
resource "aws_iam_role_policy" "api_dynamodb_read" {
  name   = "api_dynamodb_read"
  role   = aws_iam_role.api_lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["dynamodb:Scan", "dynamodb:Query", "dynamodb:GetItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.image_metadata.arn
      }
    ]
  })
}

# IAM Policy: S3 Generate Presigned URLs (GetObject & PutObject)
resource "aws_iam_role_policy" "api_s3_presigned" {
  name   = "api_s3_presigned"
  role   = aws_iam_role.api_lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:GetObject", "s3:PutObject"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.source_images.arn}/*"
      }
    ]
  })
}

# IAM Policy: CloudWatch Logs
resource "aws_iam_role_policy_attachment" "api_cloudwatch" {
  role       = aws_iam_role.api_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_cloudwatch_access.arn # Reuse existing CloudWatch policy
}

resource "aws_lambda_function" "api_processor" {
  function_name    = local.api_lambda_function
  role             = aws_iam_role.api_lambda_exec.arn
  handler          = local.api_lambda_handler
  runtime          = local.lambda_runtime
  timeout          = 10
  memory_size      = 128
  filename         = data.archive_file.api_lambda_zip.output_path
  source_code_hash = data.archive_file.api_lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = local.dynamodb_table
      S3_BUCKET_NAME      = local.s3_bucket_name
    }
  }
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  API Gateway (REST API)                                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

resource "aws_api_gateway_rest_api" "api" {
  name        = "${local.project_name}-api"
  description = "REST API for Image Analytics Dashboard"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api_processor.invoke_arn
}

resource "aws_api_gateway_deployment" "api" {
  depends_on = [aws_api_gateway_integration.lambda]
  rest_api_id = aws_api_gateway_rest_api.api.id
}

resource "aws_api_gateway_stage" "api" {
  deployment_id = aws_api_gateway_deployment.api.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "dev"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Outputs                                                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

output "frontend_url" {
  description = "URL of the static website"
  value       = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
}

output "api_gateway_url" {
  description = "URL of the API Gateway"
  value       = "${aws_api_gateway_stage.api.invoke_url}/"
}
