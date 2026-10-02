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
      # Grace period for SIGTERM before SIGKILL (Fargate default scale); allows exec/CW flush on stop.
      stopTimeout = 30
      user        = "1000"

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail
          export PATH="/usr/local/bin:/usr/local/aws-cli/v2/current/bin:/usr/bin:/bin"

          echo "=== ZOA Boundary Session ==="
          echo "Started at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
          echo "Cluster:    $ZOA_TARGET"
          echo "Deployment: $ZOA_DEPLOYMENT"
          echo "User:       $(id -un) (uid=$(id -u))"
          echo ""

          mkdir -p /home/sre/.claude
          {
            echo "# Active ZOA Boundary session"
            echo ""
            echo "| Field | Value |"
            echo "|-------|-------|"
            echo "| Deployment | $ZOA_DEPLOYMENT |"
            echo "| Target | $ZOA_TARGET |"
            echo "| AWS region | $AWS_REGION |"
            echo "| ZOA API | $ZOA_API_URL |"
            echo ""
            echo "See CLAUDE.md for architecture and allowed tools."
          } > /home/sre/.claude/ZOA_SESSION.md

          # ECS Exec transcript logging requires script + cat in the image (AWS ECS Exec docs).
          for bin in script cat; do
            if ! command -v "$bin" &>/dev/null; then
              echo "FATAL: missing $bin — ECS Exec cannot upload session transcripts to CloudWatch"
              exit 1
            fi
          done

          echo "Available tools:"
          for tool in zoa kubectl jq claude script; do
            if command -v "$tool" &>/dev/null; then
              echo "  - $tool"
            else
              echo "  - $tool (not found)"
            fi
          done
          if /usr/local/bin/aws --version &>/dev/null; then
            echo "  - aws"
          else
            echo "  - aws (not found at /usr/local/bin/aws)"
          fi
          echo ""

          export PS1="[\u@zoa:$ZOA_DEPLOYMENT/$ZOA_TARGET] \w \$ "

          echo "=== Boundary ready for connections ==="
          echo "Execute TAs with: zoa run <action> [args] --jira TICKET"
          echo "List actions:     zoa actions"
          echo ""

          echo "Boundary is ready. Waiting for ECS Exec connections..."
          echo "Container will stay running until the task is stopped."
          echo ""

          while true; do
            sleep 3600
          done
        EOF
      ]

      environment = flatten([
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
        {
          name  = "HOME"
          value = "/home/sre"
        },
        {
          name  = "CLAUDE_CODE_USE_MANTLE"
          value = "0"
        },
        {
          name  = "CLAUDE_CODE_USE_BEDROCK"
          value = "1"
        },
        {
          name  = "DISABLE_AUTOUPDATER"
          value = "1"
        },
        {
          name  = "ZOA_ECS_EXEC_COMMAND"
          value = var.ecs_exec_interactive_command
        },
        {
          name  = "ANTHROPIC_MODEL"
          value = local.claude_bedrock_invoke_model_id
        },
        {
          name  = "ANTHROPIC_DEFAULT_HAIKU_MODEL"
          value = local.claude_bedrock_invoke_model_id
        },
      ])

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.boundary.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "container"
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
        Sid    = "CloudWatchLogsExecSessions"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.boundary_exec.arn,
          "${aws_cloudwatch_log_group.boundary_exec.arn}:*",
        ]
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

# Classic Bedrock Invoke — Haiku via configured system inference profile.
resource "aws_iam_role_policy" "task_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvokeModelInRegion"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:GetInferenceProfile",
        ]
        Resource = [
          data.aws_bedrock_inference_profile.claude_haiku.inference_profile_arn,
        ]
      },
      {
        Sid    = "BedrockListInferenceProfiles"
        Effect = "Allow"
        Action = [
          "bedrock:ListInferenceProfiles",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowMarketplaceSubscriptionViaBedrock"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:CalledViaLast" = "bedrock.amazonaws.com"
          }
        }
      },
    ]
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
