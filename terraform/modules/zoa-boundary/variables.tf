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

variable "breakglass_role_arns" {
  description = "IAM role ARNs the boundary task role may assume for break-glass access. Empty by default — populated by the break-glass epic."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
