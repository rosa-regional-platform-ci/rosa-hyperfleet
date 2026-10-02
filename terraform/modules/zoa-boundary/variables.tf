variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster in this VPC"
  type        = string
}

variable "cluster_security_group_id" {
  description = "Security group ID of the EKS cluster control plane"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the boundary will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs where the boundary task can run"
  type        = list(string)
}

variable "deployment_name" {
  description = "ZOA deployment name (e.g., us-east-1, us-east-1-eph-abc123). Injected into boundary container."
  type        = string
}

variable "boundary_image" {
  description = "Container image for the boundary task (from Konflux/ECR)"
  type        = string
}

variable "zoa_function_url" {
  description = "Per-VPC Lambda Function URL for the ZOA API"
  type        = string
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs. In US regions, 365 days is enforced for FedRAMP AU-11 compliance regardless of this value."
  type        = number
  default     = 30
}

variable "cpu" {
  description = "CPU units for the Fargate task (256, 512, 1024, 2048, 4096)"
  type        = string
  default     = "512"
}

variable "memory" {
  description = "Memory (MB) for the Fargate task"
  type        = string
  default     = "1024"
}

variable "zoa_lambda_function_arn" {
  description = "ARN of the per-VPC ZOA Lambda function. Used in task role IAM to allow lambda:InvokeFunctionUrl."
  type        = string
}

variable "ecs_exec_interactive_command" {
  description = "Shell command passed to ecs:ExecuteCommand for boundary sessions. ECS Exec always starts as root; this command drops to the container user (see AWS ECS Exec docs). Returned by ZOA Access session/join API — clients must not hardcode a different command."
  type        = string
  default     = "runuser -u sre -- /bin/bash -l"
}

variable "enable_bedrock_logging" {
  description = "Enable Bedrock model invocation logging to CloudWatch (metadata only — token counts, model ID, identity. No payload capture)."
  type        = bool
  default     = false
}

variable "claude_code_bedrock_primary_model" {
  description = "Claude Code primary model (ANTHROPIC_MODEL). Default matches /model → Sonnet on Bedrock in boundary (us.anthropic.claude-sonnet-5), not picker Default (Sonnet 4.5)."
  type        = string
  default     = "us.anthropic.claude-sonnet-5"
}

variable "enable_bedrock_model_agreements" {
  description = "Manage aws_bedrock_foundation_model_agreement for each non-empty entry in bedrock_model_agreements."
  type        = bool
  default     = true
}

variable "bedrock_model_agreements" {
  description = "Foundation model ID to Bedrock PUBLIC offer ID. Must match offers available in this account/Region at apply time. Empty offer ID skips that model. Changing an offer ID replaces the agreement (see bedrock-model-agreements.tf)."
  type        = map(string)
  default = {
    "anthropic.claude-sonnet-5"                = "offer-2ykemehpsyf7g"
    "anthropic.claude-haiku-4-5-20251001-v1:0" = "offer-fudwqbphlos64"
  }
}

variable "enable_bedrock_cost_budget" {
  description = "Create an account-wide monthly Amazon Bedrock cost budget with ACTUAL spend email alerts at 50%, 80%, and 100% of bedrock_monthly_budget_usd."
  type        = bool
  default     = true
}

variable "bedrock_monthly_budget_usd" {
  description = "Monthly Bedrock spend limit (USD) for budget alerts only."
  type        = number
  default     = 1000

  validation {
    condition     = var.bedrock_monthly_budget_usd >= 1
    error_message = "bedrock_monthly_budget_usd must be at least 1."
  }
}

variable "bedrock_budget_notification_email" {
  description = "Email recipient for Bedrock budget ACTUAL spend notifications."
  type        = string
  default     = "rosa-hyperfleet@redhat.com"

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.bedrock_budget_notification_email))
    error_message = "bedrock_budget_notification_email must be a valid email address."
  }
}

variable "breakglass_role_arns" {
  description = "IAM role ARNs the boundary task role may assume for break-glass access. Empty by default — populated by the break-glass epic."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Regional ZOA CMK (module.zoa.kms_key_arn from the RC account) for ECS Exec and boundary CloudWatch logs. MC boundary uses the same RC key; key policy grants are in module.zoa."
  type        = string

  validation {
    condition     = var.kms_key_arn != ""
    error_message = "kms_key_arn is required; boundary does not create a dedicated KMS key."
  }
}

variable "access_lambda_role_arn" {
  description = "ARN of the RC ZOA Access Lambda execution role allowed to assume boundary-access and exec-scoped roles in this account."
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
