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

variable "claude_bedrock_model_id" {
  description = "Bedrock on-demand foundation model ID in the cluster region for Claude Code (ANTHROPIC_MODEL). Use foundation-model IDs, not cross-region inference profiles, when restricting IAM to the deployment region."
  type        = string
  default     = "anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "allowed_bedrock_models" {
  description = "Foundation-model ID patterns (Bedrock IAM) allowed for boundary tasks. Empty disables Bedrock IAM."
  type        = list(string)
  default     = ["anthropic.claude-haiku-4-5-*"]
}

variable "allowed_bedrock_inference_profiles" {
  description = "Inference profile ID suffix patterns (after inference-profile/) for Bedrock IAM. Leave empty when using on-demand foundation models in the cluster region only."
  type        = list(string)
  default     = []
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

variable "breakglass_role_arns" {
  description = "IAM role ARNs the boundary task role may assume for break-glass access. Empty by default — populated by the break-glass epic."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Optional shared ZOA CMK for ECS Exec and boundary CloudWatch logs. When set, no dedicated boundary_logs key is created (use on regional cluster). MC accounts leave empty until cross-account log encryption is defined."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
