# =============================================================================
# ZOA Access Lambda Module — RC-Only Session Management
# =============================================================================
# Deploys the ZOA Access Lambda behind an API Gateway v2 (HTTP API).
# This runs in the RC account ONLY with NO VPC attachment.
#
# The Access Lambda uses the same container image as api/worker Lambdas
# with HANDLER_MODE=access. It handles:
#   - Session lifecycle (start, stop, list, history)
#   - Target discovery (list targets within a deployment)
#   - Approval stubs (501 until approval workflow epic)
#   - Identity recording (SigV4 caller → DynamoDB)
#
# Architecture: SRE laptop → API Gateway → Access Lambda → DynamoDB + ECS
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  function_name = "${var.regional_id}-zoa-access"

  common_tags = merge(var.tags, {
    Component = "zoa"
    ManagedBy = "terraform"
    Region    = var.regional_id
  })
}

# =============================================================================
# KMS Key for CloudWatch Log Encryption (FedRAMP AU-09)
# =============================================================================

resource "aws_kms_key" "access_logs" {
  description             = "KMS key for ZOA Access Lambda CloudWatch log encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.function_name}"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_name}-logs-kms"
  })
}

resource "aws_kms_alias" "access_logs" {
  name          = "alias/${local.function_name}-logs"
  target_key_id = aws_kms_key.access_logs.key_id
}

# =============================================================================
# CloudWatch Log Group
# =============================================================================

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.access_logs.arn

  depends_on = [aws_kms_key.access_logs]

  tags = merge(local.common_tags, {
    Name = "${local.function_name}-logs"
  })
}

# =============================================================================
# Lambda Function — HANDLER_MODE=access (no VPC)
# =============================================================================

resource "aws_lambda_function" "access" {
  function_name = local.function_name
  description   = "ZOA Access Lambda for ${var.regional_id} - session lifecycle, target discovery"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.image_uri
  architectures = ["arm64"]
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      HANDLER_MODE       = "access"
      SESSIONS_TABLE     = var.sessions_table_name
      TARGETS_SSM_PREFIX = var.targets_ssm_prefix
      AUDIT_TABLE        = var.audit_table_name
      KMS_KEY_ARN        = var.kms_key_arn
      DEPLOYMENT_NAME    = var.deployment_name
    }
  }

  tags = merge(local.common_tags, {
    Name        = local.function_name
    HandlerMode = "access"
  })
}

# =============================================================================
# API Gateway v2 (HTTP API)
# =============================================================================

resource "aws_apigatewayv2_api" "access" {
  name          = local.function_name
  protocol_type = "HTTP"
  description   = "ZOA Access API for ${var.regional_id} - session management and target discovery"

  tags = local.common_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.access.id
  name        = "$default"
  auto_deploy = true

  tags = local.common_tags
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.access.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.access.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.access.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.access.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.access.execution_arn}/*/*"
}

# =============================================================================
# Custom Domain (optional — gated by var.custom_domain)
# =============================================================================

resource "aws_apigatewayv2_domain_name" "access" {
  count       = var.custom_domain != "" ? 1 : 0
  domain_name = var.custom_domain

  domain_name_configuration {
    certificate_arn = var.acm_certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_api_mapping" "access" {
  count       = var.custom_domain != "" ? 1 : 0
  api_id      = aws_apigatewayv2_api.access.id
  domain_name = aws_apigatewayv2_domain_name.access[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "access" {
  count   = var.custom_domain != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.custom_domain
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.access[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.access[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# =============================================================================
# WAF WebACL (optional — gated by var.enable_waf)
# =============================================================================

resource "aws_wafv2_web_acl" "access" {
  count       = var.enable_waf ? 1 : 0
  name        = local.function_name
  description = "WAF for ZOA Access API Gateway in ${var.regional_id}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.function_name}-rate-limit"
    }
  }

  rule {
    name     = "aws-common-rules"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.function_name}-common-rules"
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.function_name}-known-bad-inputs"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = local.function_name
  }

  tags = local.common_tags
}

resource "aws_wafv2_web_acl_association" "access" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = aws_wafv2_web_acl.access[0].arn
}

# =============================================================================
# IAM Role for Lambda Execution
# =============================================================================

resource "aws_iam_role" "lambda" {
  name        = "${local.function_name}-lambda"
  description = "Execution role for ZOA Access Lambda in ${var.regional_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_name}-lambda-role"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB: Read/Write sessions, Read targets, Write audit
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${local.function_name}-dynamodb"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SessionsReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:DescribeTable",
        ]
        Resource = [
          "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.sessions_table_name}",
          "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.sessions_table_name}/index/*",
        ]
      },
      # Targets read via SSM (see lambda_ssm policy below)
      {
        Sid    = "AuditWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
        ]
        Resource = [
          "arn:aws:dynamodb:${data.aws_region.current.name}:*:table/${var.audit_table_name}",
        ]
      },
    ]
  })
}

# ECS: RunTask, StopTask, DescribeTasks for boundary session management
resource "aws_iam_role_policy" "lambda_ecs" {
  name = "${local.function_name}-ecs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Component" = "zoa"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}

# STS: AssumeRole for cross-account ECS access (MC accounts)
resource "aws_iam_role_policy" "lambda_sts" {
  count = length(var.mc_account_ids) > 0 ? 1 : 0
  name  = "${local.function_name}-sts"
  role  = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Resource = [
        for account_id in var.mc_account_ids :
        "arn:aws:iam::${account_id}:role/*-zoa-boundary-access"
      ]
    }]
  })
}

# SSM: Deployment discovery (Central Account) and target registration (RC Account)
resource "aws_iam_role_policy" "lambda_ssm" {
  name = "${local.function_name}-ssm"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DeploymentDiscovery"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/zoa/deployments/*"
      },
      {
        Sid    = "TargetDiscovery"
        Effect = "Allow"
        Action = [
          "ssm:GetParametersByPath",
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/zoa/targets/*"
      },
    ]
  })
}

# KMS: Encrypt/decrypt with the ZOA KMS key
resource "aws_iam_role_policy" "lambda_kms" {
  name = "${local.function_name}-kms"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      Resource = var.kms_key_arn
    }]
  })
}

# ECR: Pull Lambda container image
resource "aws_iam_role_policy" "lambda_ecr" {
  name = "${local.function_name}-ecr"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Resource = "arn:aws:ecr:*:*:repository/*-zoa-lambda"
    }]
  })
}
