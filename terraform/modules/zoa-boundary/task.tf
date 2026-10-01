# ZOA Boundary ECS task — audited session container for ZOA operations
# in private EKS cluster VPCs via ECS Exec (SSM).

# =============================================================================
# Task Definition
# =============================================================================

resource "aws_ecs_task_definition" "boundary" {
  family                   = "${var.cluster_id}-zoa-boundary"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.boundary_image
      essential = true

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== ZOA Boundary Session ==="
          echo "Started at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
          echo "Cluster:    $ZOA_TARGET"
          echo "Deployment: $ZOA_DEPLOYMENT"
          echo ""

          echo "Available tools:"
          for tool in zoa aws kubectl jq; do
            if command -v "$tool" &>/dev/null; then
              echo "  - $tool"
            else
              echo "  - $tool (not found)"
            fi
          done
          echo ""

          export PS1="[\u@zoa:$ZOA_DEPLOYMENT/$ZOA_TARGET] \w \$ "

          echo "=== Boundary ready for connections ==="
          echo "Execute TAs with: zoa run <action> [args]"
          echo "List actions:     zoa actions"
          echo ""

          # Keep container running for ECS Exec sessions
          echo "Boundary is ready. Waiting for ECS Exec connections..."
          echo "Container will stay running until the task is stopped."
          echo ""

          # Infinite wait - container stays alive for exec sessions
          while true; do
            sleep 3600
          done
        EOF
      ]

      environment = [
        {
          name  = "ZOA_API_URL"
          value = var.zoa_function_url
        },
        {
          name  = "ZOA_TARGET"
          value = var.cluster_id
        },
        {
          name  = "ZOA_DEPLOYMENT"
          value = var.deployment_name
        },
        {
          name  = "AWS_REGION"
          value = data.aws_region.current.region
        },
        {
          name  = "ZOA_BREAKGLASS_ROLE_ARN"
          value = ""
        },
        # Claude Code Bedrock integration — auto-detects model in the task's region.
        # AWS_REGION above + CLAUDE_CODE_USE_BEDROCK enables region-local inference.
        {
          name  = "CLAUDE_CODE_USE_BEDROCK"
          value = "1"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.boundary.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "boundary"
        }
      }

      # Required for ECS Exec
      linuxParameters = {
        initProcessEnabled = true
      }
    }
  ])

  tags = local.common_tags
}

# =============================================================================
# Task Role — ZOA CLI access + ECS Exec (SSM)
# =============================================================================
# No EKS access by design — boundary containers operate exclusively through
# per-VPC Lambda Function URLs. Break-glass will add sts:AssumeRole to
# specific roles via var.breakglass_role_arns in a future epic.

resource "aws_iam_role" "task" {
  name = "${var.cluster_id}-zoa-boundary-task"

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

  tags = local.common_tags
}

resource "aws_iam_role_policy" "task_ssm" {
  name = "ssm-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMMessages"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsDescribeGroups"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.boundary.arn}:*"
      },
      {
        Sid    = "KMSForECSExec"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = local.encryption_kms_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "task_ssm_params" {
  name = "ssm-params"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMParameterRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${local.account_id}:parameter/zoa/deployments/*"
      }
    ]
  })
}

# Lambda Function URL — ZOA CLI calls the per-VPC Lambda from inside the container.
# Function URLs are public HTTPS endpoints; traffic goes through NAT Gateway.
resource "aws_iam_role_policy" "task_lambda" {
  name = "lambda-function-url"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeFunctionURL"
      Effect = "Allow"
      Action = [
        "lambda:InvokeFunctionUrl",
      ]
      Resource = var.zoa_lambda_function_arn
      Condition = {
        StringEquals = {
          "lambda:FunctionUrlAuthType" = "AWS_IAM"
        }
      }
    }]
  })
}

# Bedrock — Claude Code uses Amazon Bedrock for AI assistance.
# Scoped to deployment region only (no cross-region inference).
resource "aws_iam_role_policy" "task_bedrock" {
  count = length(var.allowed_bedrock_models) > 0 ? 1 : 0
  name  = "bedrock-invoke"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BedrockInvokeModel"
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      Resource = [
        for model in var.allowed_bedrock_models :
        "arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/${model}"
      ]
    }]
  })
}

# Break-glass STS AssumeRole — empty by default, populated by break-glass epic
resource "aws_iam_role_policy" "task_breakglass" {
  count = length(var.breakglass_role_arns) > 0 ? 1 : 0
  name  = "breakglass-assume-role"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BreakglassAssumeRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = var.breakglass_role_arns
      }
    ]
  })
}
