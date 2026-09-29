# ECS Fargate ZOA Boundary Module
# Provides audited ZOA sessions in private EKS cluster VPCs via ECS Exec (SSM).
# Unlike the bastion module, boundary tasks have NO standing EKS access — all
# operations go through per-VPC Lambda Function URLs using the ZOA CLI.

locals {
  container_name               = "zoa-boundary"
  effective_log_retention_days = max(365, var.log_retention_days)

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
# FedRAMP AU-09: KMS Key for ZOA Boundary CloudWatch Log Encryption
# =============================================================================

resource "aws_kms_key" "boundary_logs" {
  description             = "KMS key for ZOA Boundary ECS CloudWatch log encryption (FedRAMP AU-09)"
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
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.cluster_id}/zoa-boundary"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-logs"
  })
}

resource "aws_kms_alias" "boundary_logs" {
  name          = "alias/${var.cluster_id}-zoa-boundary-logs"
  target_key_id = aws_kms_key.boundary_logs.key_id
}

# =============================================================================
# CloudWatch Log Group
# =============================================================================

resource "aws_cloudwatch_log_group" "boundary" {
  name              = "/ecs/${var.cluster_id}/zoa-boundary"
  retention_in_days = local.effective_log_retention_days
  kms_key_id        = aws_kms_key.boundary_logs.arn

  depends_on = [aws_kms_key.boundary_logs]

  tags = local.common_tags
}

# =============================================================================
# Security Group
# =============================================================================

resource "aws_security_group" "boundary" {
  name        = "${var.cluster_id}-zoa-boundary"
  description = "Security group for ZOA Boundary ECS tasks"
  vpc_id      = var.vpc_id

  # Allow all outbound traffic (needed for SSM endpoints, NAT to Function URL, future break-glass EKS API)
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

  # Enable ECS Exec logging
  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.boundary.name
      }
    }
  }

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
