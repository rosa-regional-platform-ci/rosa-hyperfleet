# =============================================================================
# RDS FleetStore Module Variables
# =============================================================================

variable "cluster_id" {
  description = "Regional cluster identifier for resource naming (e.g. 'regional')"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where RDS will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS subnet group (Multi-AZ requires >= 2 AZs)"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR block — allowed to connect to the RDS instance"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.r6g.large"
}

variable "allocated_storage" {
  description = "Initial storage allocation in GiB"
  type        = number
  default     = 100
}

variable "max_allocated_storage" {
  description = "Maximum storage for autoscaling in GiB (0 disables autoscaling)"
  type        = number
  default     = 500
}

variable "engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.9"
}

variable "database_name" {
  description = "Name of the database to create"
  type        = string
  default     = "fleetstore"
}

variable "backup_retention_period" {
  description = "Days to retain automated backups (PITR window)"
  type        = number
  default     = 14
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot when destroying (set true for ephemeral only)"
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights"
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (0 to disable)"
  type        = number
  default     = 60
}
