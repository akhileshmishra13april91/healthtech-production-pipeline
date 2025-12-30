provider "aws" {
  region = var.aws_region
}

# --- 1. S3 Data Lake (The Entry Point) ---
resource "aws_s3_bucket" "data_lake" {
  bucket        = "healthtech-unified-ingest-${var.env}-${random_id.suffix.hex}"
  force_destroy = true
}

resource "random_id" "suffix" { byte_length = 4 }

# Enable EventBridge Notifications (CRITICAL for Event-Driven Architecture)
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket      = aws_s3_bucket.data_lake.id
  eventbridge = true
}

# --- 2. EventBridge Rule (Loop Prevention) ---
resource "aws_cloudwatch_event_rule" "clean_upload_rule" {
  name        = "trigger-pipeline-clean-${var.env}"
  description = "Triggers ONLY on clean uploads in 'incoming/' prefix"
  event_pattern = jsonencode({
    source      = ["aws.s3"],
    detail-type = ["Object Created"],
    detail = {
      bucket = { name = [aws_s3_bucket.data_lake.id] },
      object = { 
        # SAFETY: Only triggers on 'incoming/'. Ignores 'raw_email/', 'temp/'
        key = [{ "prefix": "incoming/" }] 
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sfn_target" {
  rule      = aws_cloudwatch_event_rule.clean_upload_rule.name
  target_id = "StartStepFunctions"
  arn       = aws_sfn_state_machine.pipeline.arn
  role_arn  = aws_iam_role.eventbridge_role.arn
}

# --- 3. Step Functions State Machine ---
resource "aws_sfn_state_machine" "pipeline" {
  name     = "HealthTechPipeline-${var.env}"
  role_arn = aws_iam_role.sfn_role.arn
  definition = templatefile("${path.module}/../src/statemachine/pipeline.asl.json", {
    RouterArn        = aws_lambda_function.document_router.arn
    SplitterArn      = aws_lambda_function.content_splitter.arn
    BedrockArn       = aws_lambda_function.bedrock_guardrail.arn
    IngestArn        = aws_lambda_function.fhir_ingest.arn
  })
}

# --- 4. SES Receipt Rule (Email Ingest) ---
resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "healthtech-rules-${var.env}"
}

resource "aws_ses_receipt_rule" "email_ingest" {
  name          = "store-raw-email"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = ["ingest@${var.domain_name}"]
  enabled       = true
  scan_enabled  = true

  # Action 1: Dump RAW MIME to 'raw_email/' (EventBridge ignores this)
  s3_action {
    bucket_name       = aws_s3_bucket.data_lake.id
    object_key_prefix = "raw_email/"
    position          = 1
    topic_arn         = aws_sns_topic.new_email.arn
  }
}

# SNS Topic to trigger MIME Extractor
resource "aws_sns_topic" "new_email" {
  name = "new-email-arrival-${var.env}"
}

resource "aws_sns_topic_subscription" "mime_trigger" {
  topic_arn = aws_sns_topic.new_email.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.mime_extractor.arn
}

# --- 5. Lambda Functions ---

# MIME Extractor Lambda
data "archive_file" "mime_extractor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/functions/mime_extractor"
  output_path = "${path.module}/lambda_zips/mime_extractor.zip"
}

resource "aws_lambda_function" "mime_extractor" {
  filename         = data.archive_file.mime_extractor_zip.output_path
  function_name    = "mime-extractor-${var.env}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.mime_extractor_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 60

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.id
    }
  }
}

resource "aws_lambda_permission" "sns_invoke_mime" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mime_extractor.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.new_email.arn
}

# Document Router Lambda
data "archive_file" "document_router_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/functions/document_router"
  output_path = "${path.module}/lambda_zips/document_router.zip"
}

resource "aws_lambda_function" "document_router" {
  filename         = data.archive_file.document_router_zip.output_path
  function_name    = "document-router-${var.env}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.document_router_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 60

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.id
    }
  }
}

# Content Splitter Lambda
data "archive_file" "content_splitter_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/functions/content_splitter"
  output_path = "${path.module}/lambda_zips/content_splitter.zip"
}

resource "aws_lambda_function" "content_splitter" {
  filename         = data.archive_file.content_splitter_zip.output_path
  function_name    = "content-splitter-${var.env}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.content_splitter_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 300

  # ATTACH THIS LAYER (Check the ARN for your region: us-east-1 example below)
  # This provides Pandas and NumPy automatically.
  layers = ["arn:aws:lambda:us-east-1:336392948345:layer:AWSSDKPandas-Python311:12"]

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.id
    }
  }
}

# Bedrock Guardrail Lambda
data "archive_file" "bedrock_guardrail_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/functions/bedrock_guardrail"
  output_path = "${path.module}/lambda_zips/bedrock_guardrail.zip"
}

resource "aws_lambda_function" "bedrock_guardrail" {
  filename         = data.archive_file.bedrock_guardrail_zip.output_path
  function_name    = "bedrock-guardrail-${var.env}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.bedrock_guardrail_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 120

  environment {
    variables = {
      BUCKET_NAME      = aws_s3_bucket.data_lake.id
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }
}

# FHIR Ingest Lambda
data "archive_file" "fhir_ingest_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/functions/fhir_ingest"
  output_path = "${path.module}/lambda_zips/fhir_ingest.zip"
}

resource "aws_lambda_function" "fhir_ingest" {
  filename         = data.archive_file.fhir_ingest_zip.output_path
  function_name    = "fhir-ingest-${var.env}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.fhir_ingest_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 120

  environment {
    variables = {
      BUCKET_NAME        = aws_s3_bucket.data_lake.id
      HEALTHLAKE_DS_ID   = aws_healthlake_fhir_datastore.store.id
      HEALTHLAKE_DS_ARN  = aws_healthlake_fhir_datastore.store.arn
      HEALTHLAKE_ID      = aws_healthlake_fhir_datastore.store.id
    }
  }
}

# Get Presigned URL Lambda
data "archive_file" "get_presigned_url_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/functions/get_presigned_url"
  output_path = "${path.module}/lambda_zips/get_presigned_url.zip"
}

resource "aws_lambda_function" "get_presigned_url" {
  filename         = data.archive_file.get_presigned_url_zip.output_path
  function_name    = "get-presigned-url-${var.env}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.get_presigned_url_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 30

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.id
    }
  }
}

# --- 6. API Gateway (HTTP API) ---
resource "aws_apigatewayv2_api" "http_api" {
  name          = "healthtech-api-${var.env}"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "PUT", "POST"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

# --- Integration: Connect API to Lambda ---
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.get_presigned_url.invoke_arn
}

resource "aws_apigatewayv2_route" "get_url_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /get-url"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# --- Permission: Allow API GW to invoke Lambda ---
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_presigned_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# --- Output the URL for your Frontend ---
output "api_gateway_url" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}
