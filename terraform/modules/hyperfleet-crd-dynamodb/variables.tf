variable "table_prefix" {
  type        = string
  description = "Prefix prepended to every CRD table name. Must end with a separator (e.g. 'rc01-'). Matches the HYPERFLEET_DB_TABLE_PREFIX env var on the operator and platform-api."
}

variable "enable_pitr" {
  type        = bool
  default     = true
  description = "Enable DynamoDB Point-in-Time Recovery on all CRD tables."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags to apply to all resources in this module."
}
