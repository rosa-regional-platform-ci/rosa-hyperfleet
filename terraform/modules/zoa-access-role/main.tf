locals {
  role_name = "${var.regional_id}-zoa-access-lambda"

  common_tags = merge(var.tags, {
    Component = "zoa"
    function  = "zoa"
    ManagedBy = "terraform"
    module    = "zoa-access-role"
    Region    = var.regional_id
  })
}

# RC-only execution role for the ZOA Access Lambda.
# Owned here (not in zoa-access) so zoa-boundary trust policies can reference a
# stable principal ARN in the same apply as boundary and access, without splitting
# role creation across ad-hoc stack files or optional module flags.

resource "aws_iam_role" "access_lambda" {
  name        = local.role_name
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
    Name = "${local.role_name}-role"
  })
}
