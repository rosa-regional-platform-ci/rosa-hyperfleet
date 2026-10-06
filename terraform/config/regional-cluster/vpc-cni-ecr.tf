# Cross-account pull policies for the self-managed VPC CNI images.
#
# The repositories are intentionally created outside this configuration because
# the image build/publish process owns their contents. Terraform owns the RC
# repository policies so MC node roles can pull from the shared RC registry.
locals {
  vpc_cni_ecr_repositories = toset([
    "amazon/amazon-k8s-cni",
    "amazon/amazon-k8s-cni-init",
    "amazon/aws-network-policy-agent",
  ])
}

resource "aws_ecr_repository_policy" "vpc_cni" {
  for_each   = local.vpc_cni_ecr_repositories
  repository = each.value

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowManagementClusterPull"
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
    }]
  })
}
