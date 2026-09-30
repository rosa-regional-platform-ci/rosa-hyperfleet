# =============================================================================
# ZOA Deployment Autodiscovery — SSM Parameter Store
# =============================================================================
# Written by the RC Terraform pipeline into the Central Account so the SRE
# CLI can discover all deployments from a single account. The aws.central
# provider is configured by the RC config — in pipelines it uses a named
# profile pointing at the central account; for local dev it falls through
# to ambient credentials.
#
# The parameter stores a JSON object with the deployment's Function URL,
# invoker role ARN, and metadata. Multiple deployments (including ephemeral)
# coexist under the same /zoa/deployments/ prefix.
# =============================================================================

resource "aws_ssm_parameter" "deployment" {
  provider    = aws.central
  name        = "/zoa/deployments/${var.deployment_name}"
  type        = "String"
  description = "ZOA deployment discovery for ${var.deployment_name}"

  value = jsonencode({
    access_url       = aws_lambda_function_url.access.function_url
    invoker_role_arn = aws_iam_role.invoker.arn
    region           = data.aws_region.current.name
    account_id       = data.aws_caller_identity.current.account_id
    deployment_name  = var.deployment_name
  })

  tags = merge(local.common_tags, {
    Name = "/zoa/deployments/${var.deployment_name}"
  })
}
