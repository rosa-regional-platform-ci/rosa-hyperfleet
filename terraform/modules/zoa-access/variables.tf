# =============================================================================
# ZOA Access Lambda Module Variables
# =============================================================================
# RC-only module — deploys the Access Lambda with Function URL (IAM auth)
# and a central-account-trusted invoker role for cross-account SRE access.
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

variable "central_account_id" {
  description = "AWS account ID of the environment Central Account (pipeline/CodeBuild home account). Only principals in this account may assume the invoker role."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.central_account_id))
    error_message = "central_account_id must be a 12-digit AWS account ID."
  }
}

variable "trusted_assumer_role_names" {
  description = "IAM role names in the Central Account allowed to assume the invoker role (full role ARNs are derived). Add future Red Hat SAML hub roles here."
  type        = list(string)

  default = ["OrganizationAccountAccessRole"]

  validation {
    condition     = length(var.trusted_assumer_role_names) > 0
    error_message = "trusted_assumer_role_names must contain at least one role name."
  }
}

variable "mc_account_ids" {
  description = "List of MC account IDs for cross-account ECS RunTask. Empty for RC-only deployments."
  type        = list(string)
  default     = []
}

variable "boundary_ecs_cluster_arn" {
  description = "ARN of the RC ZOA Boundary ECS cluster. Used to scope StopTask/DescribeTasks (tasks lack Component=zoa; see worker reaper in zoa-lambda)."
  type        = string
}

variable "boundary_ecs_exec_command" {
  description = "Interactive ecs:ExecuteCommand shell for boundary join (must match zoa-boundary module ecs_exec_interactive_command / task env ZOA_ECS_EXEC_COMMAND)."
  type        = string
  default     = "runuser -u sre -- /bin/bash -l"
}

variable "exec_scoped_role_arn" {
  description = "RC boundary exec-scoped IAM role ARN (from zoa-boundary module). Used as default for RC targets and EXEC_SCOPED_ROLE_ARN on the Lambda."
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources."
  type        = map(string)
  default     = {}
}
