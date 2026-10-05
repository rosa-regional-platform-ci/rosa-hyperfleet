variable "regional_id" {
  description = "Regional cluster ID (e.g. eph-xxx-regional)."
  type        = string
}

variable "tags" {
  description = "Additional tags for the execution role."
  type        = map(string)
  default     = {}
}
