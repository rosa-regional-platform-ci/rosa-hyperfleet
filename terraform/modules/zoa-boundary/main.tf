# ECS Fargate ZOA Boundary Module
# Provides audited ZOA sessions in private EKS cluster VPCs via ECS Exec (SSM).
# Boundary tasks have no standing EKS access (HyperFleet bastion may grant cluster access).
# All operations go through per-VPC Lambda Function URLs using the ZOA CLI.

locals {
  container_name               = "zoa-boundary"
  effective_log_retention_days = max(365, var.log_retention_days)
  encryption_kms_arn           = var.kms_key_arn

  # CloudWatch: container stdout (task startup) vs ECS Exec session transcripts (audit).
  boundary_container_log_group_name = "/ecs/${var.cluster_id}/zoa-boundary"
  boundary_exec_log_group_name      = "/ecs/${var.cluster_id}/zoa-boundary/ssm-sessions"

  common_tags = merge(
    var.tags,
    {
      function  = "zoa"
      module    = "zoa-boundary"
      Component = "zoa"
      ManagedBy = "terraform"
    }
  )
}

data "aws_region" "current" {}

# =============================================================================
# CloudWatch Log Groups (regional ZOA CMK — container vs ECS Exec session I/O)
# =============================================================================

resource "aws_cloudwatch_log_group" "boundary" {
  name              = local.boundary_container_log_group_name
  retention_in_days = local.effective_log_retention_days
  kms_key_id        = local.encryption_kms_arn

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-container-logs"
  })
}

resource "aws_cloudwatch_log_group" "boundary_exec" {
  name              = local.boundary_exec_log_group_name
  retention_in_days = local.effective_log_retention_days
  kms_key_id        = local.encryption_kms_arn

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-exec-logs"
  })
}

# =============================================================================
# Bedrock Model Invocation Logging (Account-Level)
# =============================================================================
# Captures per-invocation metadata: identity.arn, modelId, token counts.
# NO payload capture (prompts/responses) — SSM session recording already
# captures the human-readable conversation. This is for cost attribution only.

resource "aws_cloudwatch_log_group" "bedrock_invocations" {
  count             = var.enable_bedrock_logging ? 1 : 0
  name              = "/aws/bedrock/model-invocations"
  retention_in_days = local.effective_log_retention_days
  kms_key_id        = local.encryption_kms_arn

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-bedrock-invocations"
  })
}

resource "aws_iam_role" "bedrock_logging" {
  count       = var.enable_bedrock_logging ? 1 : 0
  name        = "${var.cluster_id}-bedrock-logging"
  description = "IAM role for Bedrock to write invocation logs to CloudWatch"

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
  count = var.enable_bedrock_logging ? 1 : 0
  name  = "cloudwatch-logs"
  role  = aws_iam_role.bedrock_logging[0].id

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
  count = var.enable_bedrock_logging ? 1 : 0

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

# =============================================================================
# Security Group
# =============================================================================

resource "aws_security_group" "boundary" {
  name        = "${var.cluster_id}-zoa-boundary"
  description = "Security group for ZOA Boundary ECS tasks"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary"
  })
}

# Allow boundary tasks to access EKS control plane (future break-glass)
resource "aws_security_group_rule" "eks_ingress_from_boundary" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = var.cluster_security_group_id
  source_security_group_id = aws_security_group.boundary.id
  description              = "Allow ZOA Boundary tasks to access EKS API"
}

# =============================================================================
# ECS Cluster (dedicated for ZOA Boundary tasks)
# =============================================================================

resource "aws_ecs_cluster" "boundary" {
  name = "${var.cluster_id}-zoa-boundary"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  # ECS Exec (FedRAMP AU-09): session data channel + exec transcript logging.
  # - kms_key_id: CMK for TLS/exec payload (task role + caller need kms:Decrypt/GenerateDataKey).
  # - cloud_watch_encryption_enabled=true REQUIRES the exec log group to use the same CMK
  #   (see AWS ECS Exec logging docs).
  configuration {
    execute_command_configuration {
      kms_key_id = local.encryption_kms_arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.boundary_exec.name
        cloud_watch_encryption_enabled = true
      }
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.boundary,
    aws_cloudwatch_log_group.boundary_exec,
  ]

  tags = local.common_tags
}

# =============================================================================
# Cleanup Running Tasks on Destroy
# =============================================================================
# This ensures any running boundary tasks are stopped before the cluster is destroyed.
# Without this, terraform destroy would fail if a task was left running.

resource "null_resource" "stop_boundary_tasks" {
  depends_on = [aws_ecs_cluster.boundary]

  triggers = {
    cluster_name = aws_ecs_cluster.boundary.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      echo "Stopping any running tasks in ECS cluster ${self.triggers.cluster_name}..."
      TASKS=$(aws ecs list-tasks --cluster ${self.triggers.cluster_name} --query 'taskArns[]' --output text 2>/dev/null || true)
      if [ -n "$TASKS" ] && [ "$TASKS" != "None" ]; then
        for TASK in $TASKS; do
          echo "Stopping task: $TASK"
          aws ecs stop-task --cluster ${self.triggers.cluster_name} --task $TASK --reason "Terraform destroy" || true
        done
        echo "Waiting for tasks to stop..."
        sleep 5
      else
        echo "No running tasks found"
      fi
    EOF
  }
}
