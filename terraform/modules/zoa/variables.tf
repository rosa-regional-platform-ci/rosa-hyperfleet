variable "regional_id" {
  description = "Regional identifier prefix for resource naming"
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the RC EKS cluster"
  type        = string
}

variable "environment" {
  description = "Deployment environment name (e.g. 'ephemeral', 'integration', 'production'). Controls DynamoDB protection settings and S3 force_destroy behavior."
  type        = string
}

variable "billing_mode" {
  description = "DynamoDB billing mode"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "mc_ou_path" {
  description = "AWS Organizations OU path for Management Cluster accounts (used in cross-account S3/KMS policies)"
  type        = string

  validation {
    condition     = length(var.mc_ou_path) > 10 && startswith(var.mc_ou_path, "o-")
    error_message = "mc_ou_path must be a valid AWS Organizations path starting with 'o-' (e.g., 'o-abc123/r-root/ou-xxxx-yyyy/')"
  }
}

variable "output_retention_days" {
  description = "Days to retain TA outputs in S3"
  type        = number
  default     = 365
}

# --- Container images (mirrored from source registry → ECR) ---

variable "zoa_lambda_source_image" {
  description = "Source registry image for ZOA Lambda (mirrored to ECR at deploy time)"
  type        = string
  default     = "quay.io/redhat-user-workloads/rosa-tenant/zoa-lambda"
}

variable "zoa_runner_source_image" {
  description = "Source registry image for ZOA Runner (K8s pulls directly, no ECR mirror)"
  type        = string
  default     = "quay.io/redhat-user-workloads/rosa-tenant/zoa-runner"
}

variable "zoa_image_tag" {
  description = "Immutable image tag (git SHA). Used for source→ECR mirroring and runner image ref. Defaults to the Konflux zoa-lambda/zoa-runner on-push build tag for the pinned rosa-hyperfleet-zoa main commit; override to test another commit/PR build (e.g. an `on-pr-<sha>` Konflux tag)."
  type        = string
  default     = "8af92e65fd57562f898515c70148fe9aa75a52b1"
}

