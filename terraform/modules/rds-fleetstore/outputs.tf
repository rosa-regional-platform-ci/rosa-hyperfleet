# =============================================================================
# RDS FleetStore Module Outputs
# =============================================================================

output "endpoint" {
  description = "RDS instance endpoint (host:port)"
  value       = aws_db_instance.fleetstore.endpoint
}

output "address" {
  description = "RDS instance hostname"
  value       = aws_db_instance.fleetstore.address
}

output "port" {
  description = "RDS instance port"
  value       = aws_db_instance.fleetstore.port
}

output "database_name" {
  description = "Database name"
  value       = aws_db_instance.fleetstore.db_name
}

output "dsn_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the FleetStore DSN"
  value       = aws_secretsmanager_secret.fleetstore_dsn.arn
}

output "dsn_secret_name" {
  description = "Name of the Secrets Manager secret containing the FleetStore DSN"
  value       = aws_secretsmanager_secret.fleetstore_dsn.name
}

output "master_password_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the master password"
  value       = aws_secretsmanager_secret.fleetstore_master.arn
}

output "security_group_id" {
  description = "Security group ID for the RDS instance"
  value       = aws_security_group.fleetstore.id
}

output "kms_key_arn" {
  description = "KMS key ARN used for RDS encryption"
  value       = aws_kms_key.fleetstore.arn
}

output "instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.fleetstore.id
}
