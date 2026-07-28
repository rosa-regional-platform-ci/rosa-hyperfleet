output "table_arns" {
  description = "Map of table name → ARN for all CRD tables."
  value       = { for k, t in aws_dynamodb_table.crd : k => t.arn }
}

output "table_names" {
  description = "Set of all provisioned CRD table names."
  value       = keys(aws_dynamodb_table.crd)
}
