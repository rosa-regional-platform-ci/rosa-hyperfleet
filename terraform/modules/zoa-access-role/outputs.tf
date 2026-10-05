output "arn" {
  description = "Access Lambda execution role ARN (MC boundary trust + RC Access Lambda)."
  value       = aws_iam_role.access_lambda.arn
}

output "name" {
  description = "Access Lambda execution role name."
  value       = aws_iam_role.access_lambda.name
}

output "id" {
  description = "Access Lambda execution role ID."
  value       = aws_iam_role.access_lambda.id
}
