# =============================================================================
# ZOA Access Lambda Module Variables
# =============================================================================
# RC-only module — deploys the Access Lambda behind API Gateway for session
# lifecycle management and target discovery. No VPC attachment.
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

variable "targets_table_name" {
  description = "Name of the DynamoDB boundary-targets table."
  type        = string
  default     = "boundary-targets"
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

variable "custom_domain" {
  description = "Custom domain name for API Gateway (e.g., zoa-access.us-east-1.int0.rosa.devshift.net). Empty string disables custom domain."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the custom domain. Required when custom_domain is set."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the custom domain TLS. Required when custom_domain is set."
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "Enable WAF WebACL on the API Gateway (rate limiting, AWS managed rules)."
  type        = bool
  default     = false
}

variable "ssm_account_id" {
  description = "AWS account ID where the SSM /zoa/deployments parameter lives (Central Account). Empty string means same account (dev/ephemeral)."
  type        = string
  default     = ""
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
