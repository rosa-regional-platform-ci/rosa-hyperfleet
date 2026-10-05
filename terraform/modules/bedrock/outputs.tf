output "invocation_log_group_name" {
  description = "CloudWatch log group for Bedrock invocation metadata when this stack created logging; empty otherwise."
  value       = local.create_bedrock_invocation_logging ? aws_cloudwatch_log_group.bedrock_invocations[0].name : ""
}

output "invocation_logs_kms_key_arn" {
  description = "KMS key for Bedrock invocation logs when this stack created logging; empty otherwise."
  value       = local.create_bedrock_invocation_logging ? aws_kms_key.invocation_logs[0].arn : ""
}
