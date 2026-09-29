# =============================================================================
# ZOA Access Module Outputs
# =============================================================================

output "api_gateway_url" {
  description = "API Gateway endpoint URL for the ZOA Access API"
  value       = aws_apigatewayv2_api.access.api_endpoint
}

output "api_gateway_id" {
  description = "API Gateway ID"
  value       = aws_apigatewayv2_api.access.id
}

output "lambda_function_arn" {
  description = "ARN of the ZOA Access Lambda function"
  value       = aws_lambda_function.access.arn
}

output "lambda_function_name" {
  description = "Name of the ZOA Access Lambda function"
  value       = aws_lambda_function.access.function_name
}

output "ssm_parameter_arn" {
  description = "ARN of the SSM deployment discovery parameter"
  value       = aws_ssm_parameter.deployment.arn
}
