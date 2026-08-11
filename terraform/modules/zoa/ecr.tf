# =============================================================================
# ECR Repositories for ZOA Container Images
# =============================================================================
# Private ECR repos with OU-scoped cross-account pull access.
# MC Lambdas (different account, same region) pull using the same image URI.
# Images are mirrored from Quay via crane (registry-to-registry, no docker).

resource "aws_ecr_repository" "lambda" {
  name                 = "${var.regional_id}-zoa-lambda"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.environment == "ephemeral"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.zoa.arn
  }

  tags = merge(local.common_tags, { Name = "${var.regional_id}-zoa-lambda" })
}


# --- Lifecycle policies: keep last 20 images ---

resource "aws_ecr_lifecycle_policy" "lambda" {
  repository = aws_ecr_repository.lambda.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}


# --- Cross-account pull policies ---
# Allows MC accounts (via OU path) and Lambda service (for image optimization)

resource "aws_ecr_repository_policy" "lambda" {
  repository = aws_ecr_repository.lambda.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOUPull"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
        }
      },
      {
        Sid       = "LambdaCrossAccountRetrieval"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
      },
    ]
  })
}


# --- Mirror images from Quay → ECR (skip if tag already exists) ---

resource "null_resource" "mirror_lambda" {
  count = var.zoa_image_tag != "" ? 1 : 0

  triggers = {
    image_tag = var.zoa_image_tag
    repo      = aws_ecr_repository.lambda.repository_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      if aws ecr describe-images --repository-name ${aws_ecr_repository.lambda.name} \
          --image-ids imageTag=${var.zoa_image_tag} 2>/dev/null | grep -q imageDigest; then
        echo "zoa-lambda:${var.zoa_image_tag} already in ECR, skipping"
      else
        crane auth login ${split("/", aws_ecr_repository.lambda.repository_url)[0]} \
          -u AWS -p $(aws ecr get-login-password --region ${data.aws_region.current.id})
        crane copy ${var.zoa_quay_repository}:${var.zoa_image_tag} \
          ${aws_ecr_repository.lambda.repository_url}:${var.zoa_image_tag}
        echo "zoa-lambda:${var.zoa_image_tag} mirrored to ECR"
      fi
    EOT
  }

  depends_on = [aws_ecr_repository.lambda]
}


data "aws_region" "current" {}
