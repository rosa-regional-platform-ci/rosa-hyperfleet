# Dedicated CMK for Bedrock invocation logs (not ZOA CMK). Created only when this
# stack enables logging and the account has no logging configuration yet.

resource "aws_kms_key" "invocation_logs" {
  count = local.create_bedrock_invocation_logging ? 1 : 0

  description             = "KMS key for Bedrock model invocation CloudWatch logs"
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
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = [
              "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.invocation_log_group_name}",
              "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.invocation_log_group_name}:*",
            ]
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "bedrock-invocation-logs"
  })
}

resource "aws_kms_alias" "invocation_logs" {
  count = local.create_bedrock_invocation_logging ? 1 : 0

  name          = "alias/bedrock-invocation-logs"
  target_key_id = aws_kms_key.invocation_logs[0].key_id
}

resource "aws_cloudwatch_log_group" "bedrock_invocations" {
  count = local.create_bedrock_invocation_logging ? 1 : 0

  name              = var.invocation_log_group_name
  retention_in_days = local.effective_log_retention_days
  kms_key_id        = aws_kms_key.invocation_logs[0].arn

  tags = merge(local.common_tags, {
    Name = "bedrock-invocation-logs"
  })
}

resource "aws_iam_role" "bedrock_logging" {
  count = local.create_bedrock_invocation_logging ? 1 : 0

  name        = var.invocation_logging_role_name
  description = "Account-level role for Bedrock to write invocation logs to CloudWatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "bedrock.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "bedrock_logging_cw" {
  count = local.create_bedrock_invocation_logging ? 1 : 0

  name = "cloudwatch-logs"
  role = aws_iam_role.bedrock_logging[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.bedrock_invocations[0].arn}:*"
    }]
  })
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  count = local.create_bedrock_invocation_logging ? 1 : 0

  logging_config {
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    text_data_delivery_enabled      = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock_invocations[0].name
      role_arn       = aws_iam_role.bedrock_logging[0].arn

      large_data_delivery_s3_config {
        bucket_name = ""
      }
    }
  }
}
