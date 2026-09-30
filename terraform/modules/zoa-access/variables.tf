# =============================================================================
# ZOA Access Lambda Module Variables
# =============================================================================
# RC-only module — deploys the Access Lambda with Function URL (IAM auth)
# and an OU-trusted invoker role for cross-account SRE access.
# =============================================================================

variable "regional_id" {
  description = "Regional identifier (e.g., us-east-1). Used as base name for RC-scoped resources."
  type        = string
}

variable "image_uri" {
  description = "ECR image URI for the ZOA Lambda container (same image as api/worker, different HANDLER_MODE)."
  type        = string
}

variable "sessions_table_name" {
  description = "Name of the DynamoDB boundary-sessions table."
  type        = string
  default     = "boundary-sessions"
}

variable "targets_ssm_prefix" {
  description = "SSM path prefix for target registration (e.g., /zoa/targets/us-east-1). Each cluster writes its own parameter under this prefix."
  type        = string
  default     = ""
}

variable "audit_table_name" {
  description = "Name of the existing DynamoDB audit table for ZOA audit trail."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encrypting DynamoDB tables and Lambda logs."
  type        = string
}

variable "deployment_name" {
  description = "ZOA deployment name (e.g., us-east-1, us-east-1-eph-abc123). Written to SSM for autodiscovery."
  type        = string
}

variable "mc_ou_path" {
  description = "AWS Organizations OU path for cross-account trust (shared across all accounts in the environment, named mc_ou_path for historical reasons). Used by the invoker role trust policy."
  type        = string
}

variable "mc_account_ids" {
  description = "List of MC account IDs for cross-account ECS RunTask. Empty for RC-only deployments."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags to apply to all resources."
  type        = map(string)
  default     = {}
}
