variable "cluster_id" {
  description = "Unique cluster identifier used for resource naming."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for the bootstrap nodes."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the bootstrap node group."
  type        = list(string)
}

variable "launch_template_id" {
  description = "Launch template ID for the bootstrap node group."
  type        = string
}

variable "launch_template_version" {
  description = "Launch template version for the bootstrap node group."
  type        = string
}

variable "worker_node_ami_id" {
  description = "Custom worker AMI ID, if one is configured."
  type        = string
  default     = ""
}
