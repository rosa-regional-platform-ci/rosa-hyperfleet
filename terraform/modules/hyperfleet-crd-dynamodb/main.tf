# =============================================================================
# hyperfleet-crd-dynamodb Module
#
# Provisions DynamoDB tables that replace the Aurora PostgreSQL hyperfleet-db
# cluster as the backing store for the hyperfleet operator CRDs.
#
# Each table stores one CRD kind:
#   {table_prefix}clusters            — Cluster CRs
#   {table_prefix}nodepools           — NodePool CRs
#   {table_prefix}placements          — Placement CRs
#   {table_prefix}manifests           — Manifest CRs
#   {table_prefix}managementclusters  — ManagementCluster CRs
#
# Schema:
#   PK  = name      (S)   — object name
#   SK  = namespace (S)   — "" for cluster-scoped
#
# GSI (updateTime-index):
#   PK  = gsiShard  (S)   — crc32(namespace) % 8 → "0"–"7"
#   SK  = updateTime (S)  — RFC3339Nano; used by poll-watcher ListSince scans
#   Projection = ALL
#
# TTL attribute: ttl (N, Unix epoch) — set on tombstone items; DynamoDB removes
# them automatically within 48 h after expiry.
#
# The poll-watcher queries the GSI for items updated since the last poll
# interval (15 s). The full consistent re-list scans the base table every 5 min.
# =============================================================================

locals {
  crd_tables = toset([
    "${var.table_prefix}clusters",
    "${var.table_prefix}nodepools",
    "${var.table_prefix}placements",
    "${var.table_prefix}manifests",
    "${var.table_prefix}managementclusters",
  ])

  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Module    = "hyperfleet-crd-dynamodb"
    }
  )
}

resource "aws_dynamodb_table" "crd" {
  for_each = local.crd_tables

  name         = each.key
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "name"
  range_key    = "namespace"

  attribute {
    name = "name"
    type = "S"
  }

  attribute {
    name = "namespace"
    type = "S"
  }

  attribute {
    name = "gsiShard"
    type = "S"
  }

  attribute {
    name = "updateTime"
    type = "S"
  }

  global_secondary_index {
    name            = "updateTime-index"
    hash_key        = "gsiShard"
    range_key       = "updateTime"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  tags = merge(
    local.common_tags,
    {
      Name = each.key
    }
  )
}
