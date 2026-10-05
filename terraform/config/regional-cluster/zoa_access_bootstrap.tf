# =============================================================================
# ZOA Access Lambda execution role (bootstrap)
# =============================================================================
# Created before module.zoa_boundary so boundary IAM trust policies can reference
# a real principal ARN. module.zoa_access attaches policies and the Lambda
# function to this role (lambda_execution_role_arn).

resource "aws_iam_role" "zoa_access_lambda" {
  name        = "${var.regional_id}-zoa-access-lambda"
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

  tags = {
    Component = "zoa"
    function  = "zoa"
    ManagedBy = "terraform"
    Name      = "${var.regional_id}-zoa-access-lambda-role"
    Region    = var.regional_id
  }
}
