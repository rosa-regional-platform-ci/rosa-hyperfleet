# =============================================================================
# CloudWatch Exporter IAM Role and Policies
# =============================================================================

resource "aws_iam_role" "cloudwatch_exporter" {
  name        = "${var.cluster_name}-cloudwatch-exporter"
  description = "IAM role for CloudWatch Exporter to read CloudWatch metrics"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-cloudwatch-exporter"
    }
  )
}

resource "aws_iam_role_policy" "cloudwatch_exporter_metrics" {
  name = "${var.cluster_name}-cloudwatch-exporter-metrics"
  role = aws_iam_role.cloudwatch_exporter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "ResourceTagging"
        Effect = "Allow"
        Action = [
          "tag:GetResources",
        ]
        Resource = "*"
      },
      {
        Sid    = "ApiGatewayDiscovery"
        Effect = "Allow"
        Action = [
          "apigateway:GET",
        ]
        Resource = "*"
      },
      {
        Sid    = "RDSDiscovery"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "ELBDiscovery"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "AccountAliases"
        Effect = "Allow"
        Action = [
          "iam:ListAccountAliases",
        ]
        Resource = "*"
      },
      {
        Sid    = "LambdaDiscovery"
        Effect = "Allow"
        Action = [
          "lambda:ListFunctions",
          "lambda:ListTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "SQSDiscovery"
        Effect = "Allow"
        Action = [
          "sqs:ListQueues",
          "sqs:ListQueueTags",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "cloudwatch_exporter" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.cloudwatch_exporter.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-cloudwatch-exporter-pod-identity"
    }
  )
}
