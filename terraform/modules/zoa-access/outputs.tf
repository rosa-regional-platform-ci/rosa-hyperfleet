# =============================================================================
# ZOA Access Module Outputs
# =============================================================================

output "function_url" {
  description = "Function URL endpoint for the ZOA Access Lambda"
  value       = aws_lambda_function_url.access.function_url
}

output "lambda_role_arn" {
  description = "ARN of the ZOA Access Lambda execution role"
  value       = aws_iam_role.lambda.arn
}

output "invoker_role_arn" {
  description = "ARN of the central-trusted invoker role (SREs assume this to call the Function URL)"
  value       = aws_iam_role.invoker.arn
}

output "lambda_function_arn" {
  description = "ARN of the ZOA Access Lambda function"
  value       = aws_lambda_function.access.arn
}

output "lambda_function_name" {
  description = "Name of the ZOA Access Lambda function"
  value       = aws_lambda_function.access.function_name
}

output "exec_scoped_role_arn" {
  description = "IAM role ARN vended on session join for RC boundary ECS Exec"
  value       = var.exec_scoped_role_arn
}

output "ssm_parameter_arn" {
  description = "ARN of the SSM deployment discovery parameter"
  value       = aws_ssm_parameter.deployment.arn
}
