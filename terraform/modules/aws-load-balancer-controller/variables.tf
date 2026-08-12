variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string

  validation {
    # IAM role names are capped at 64 chars; the "-aws-load-balancer-controller"
    # suffix (30 chars) leaves 34 chars for cluster_name.
    condition     = length(var.cluster_name) <= 34
    error_message = "cluster_name must be 34 characters or fewer so the generated IAM role name (\"<cluster_name>-aws-load-balancer-controller\") stays within IAM's 64-character role name limit."
  }
}

variable "namespace" {
  description = "Kubernetes namespace where the LBC is deployed"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "service_account" {
  description = "Kubernetes service account name for the LBC"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
