terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "aws_region" {
  default = "us-east-1"
}

variable "app_name" {
  default = "bulletin-board"
}

# ── DynamoDB Table ────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "posts" {
  name           = "bulletin-posts"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "postId"

  attribute {
    name = "postId"
    type = "S"
  }

  tags = {
    Name        = "bulletin-posts"
    Environment = "production"
    App         = var.app_name
  }
}

# ── Lambda Function ───────────────────────────────────────────────────────────
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "api" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.app_name}-api"
  role             = "arn:aws:iam::468993955563:role/LabRole"
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.posts.name
    }
  }

  tags = {
    App = var.app_name
  }
}

# ── API Gateway ───────────────────────────────────────────────────────────────
resource "aws_api_gateway_rest_api" "api" {
  name        = "${var.app_name}-api"
  description = "Bulletin Board REST API"
}

# /posts resource
resource "aws_api_gateway_resource" "posts" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "posts"
}

# /posts/{eventId} resource
resource "aws_api_gateway_resource" "post_id" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.posts.id
  path_part   = "{eventId}"
}

# ── Lambda Permission ─────────────────────────────────────────────────────────
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# ── Lambda URI ────────────────────────────────────────────────────────────────
locals {
  lambda_uri = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${aws_lambda_function.api.arn}/invocations"
}

# GET /posts
resource "aws_api_gateway_method" "get_posts" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.posts.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_posts" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.posts.id
  http_method             = aws_api_gateway_method.get_posts.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_uri
}

# POST /posts
resource "aws_api_gateway_method" "post_posts" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.posts.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post_posts" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.posts.id
  http_method             = aws_api_gateway_method.post_posts.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_uri
}

# OPTIONS /posts (CORS preflight)
resource "aws_api_gateway_method" "options_posts" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.posts.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_posts" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.posts.id
  http_method = aws_api_gateway_method.options_posts.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_posts_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.posts.id
  http_method = aws_api_gateway_method.options_posts.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_posts_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.posts.id
  http_method = aws_api_gateway_method.options_posts.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.options_posts]
}

# DELETE /posts/{eventId}
resource "aws_api_gateway_method" "delete_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.post_id.id
  http_method   = "DELETE"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "delete_post" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.post_id.id
  http_method             = aws_api_gateway_method.delete_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_uri
}

# OPTIONS /posts/{eventId} (CORS preflight)
resource "aws_api_gateway_method" "options_post_id" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.post_id.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_post_id" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.post_id.id
  http_method = aws_api_gateway_method.options_post_id.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_post_id_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.post_id.id
  http_method = aws_api_gateway_method.options_post_id.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_post_id_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.post_id.id
  http_method = aws_api_gateway_method.options_post_id.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.options_post_id]
}

# ── Deploy API ────────────────────────────────────────────────────────────────
resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.posts,
      aws_api_gateway_resource.post_id,
      aws_api_gateway_method.get_posts,
      aws_api_gateway_method.post_posts,
      aws_api_gateway_method.delete_post,
      aws_api_gateway_integration.get_posts,
      aws_api_gateway_integration.post_posts,
      aws_api_gateway_integration.delete_post,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.get_posts,
    aws_api_gateway_integration.post_posts,
    aws_api_gateway_integration.delete_post,
    aws_api_gateway_integration_response.options_posts_200,
    aws_api_gateway_integration_response.options_post_id_200,
  ]
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.api.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "prod"
}

# ── S3 Static Website ─────────────────────────────────────────────────────────
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.app_name}-frontend-${random_id.suffix.hex}"
  tags   = { App = var.app_name }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  index_document { suffix = "index.html" }
  error_document { key    = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend_public" {
  bucket     = aws_s3_bucket.frontend.id
  depends_on = [aws_s3_bucket_public_access_block.frontend]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
    }]
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "website_url" {
  value       = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
  description = "S3 static website URL"
}

output "api_gateway_url" {
  value       = "${aws_api_gateway_stage.prod.invoke_url}/posts"
  description = "API Gateway invoke URL for /posts"
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.posts.name
}

output "lambda_function_name" {
  value = aws_lambda_function.api.function_name
}
