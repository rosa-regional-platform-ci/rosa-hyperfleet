variable "github_repository" {
  type        = string
  description = "GitHub Repository in owner/name format (e.g., 'octocat/hello-world')"
  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in 'owner/name' format"
  }
}

variable "github_branch" {
  type        = string
  description = "GitHub Branch to track"
  default     = "main"
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection"
}

variable "region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-1"
}

# Optional variables for manual/single-target deployment
variable "target_account_id" {
  type        = string
  description = "Target AWS Account ID (Optional override)"
  default     = ""
}

variable "target_region" {
  type        = string
  description = "Target AWS Region (Optional override)"
  default     = ""
}

variable "target_environment" {
  type        = string
  description = "Target environment (integration, staging, prod)"
  default     = "integration"
}

variable "child_admin_role_name" {
  type        = string
  description = "IAM role name assumed in the target (child) account for infra apply and ArgoCD bootstrap. Defaults to the AWS Organizations role; override per environment."
  default     = "OrganizationAccountAccessRole"
}

variable "repository_url" {
  type        = string
  description = "Git repository URL for cluster configuration"
}

variable "repository_branch" {
  type        = string
  description = "Git branch to use for cluster configuration"
  default     = "main"
}

variable "management_id" {
  type        = string
  description = "Management cluster identifier for resource naming (e.g., 'mc01')"
}

variable "codebuild_image" {
  type        = string
  description = "ECR image URI for CodeBuild projects (platform image with pre-installed tools)"
}

variable "mc_codebuild_role_arn" {
  type        = string
  description = "ARN of the shared IAM role used by MC CodeBuild projects (created in central-account-bootstrap). If empty, creates a per-MC role (default behavior)."
  default     = ""
}

# =============================================================================
# Notifications Configuration
# =============================================================================

variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (only required for staging, production, integration environments)"
  default     = "/rosa-regional/slack/webhook-url"
}
