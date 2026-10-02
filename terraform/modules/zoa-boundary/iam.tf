# Shared IAM resources for the zoa-boundary module.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# =============================================================================
# Execution Role - For ECS agent operations (shared by all tasks)
# =============================================================================

resource "aws_iam_role" "execution" {
  name = "${var.cluster_id}-zoa-boundary-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-execution-role"
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_kms_logs" {
  name = "kms-cloudwatch-logs"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DecryptLogGroupKMS"
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      Resource = local.encryption_kms_arn
    }]
  })
}
