# =============================================================================
# DynamoDB Table for ZOA Executions
# =============================================================================
# Stores Trusted Action execution metadata and status.
# PK: executionId (direct Get by ID)
#
# GSI Index Architecture (4 indexes, each serving distinct access patterns):
#
#   status-index (PK=status, SK=createdAt)
#     Consumers: reconciler, GC, CLI
#     - Reconciler polls for dispatched/running items to drive state machine (oldest first)
#     - GC finds terminal items (succeeded/failed) older than TTL for K8s resource cleanup
#     - CLI: `zoa runs --status X` lists executions filtered by status (newest first)
#
#   target-index (PK=targetCluster, SK=createdAt)
#     Consumers: CLI, cooldown check
#     - CLI: `zoa runs --target X` for cross-cluster filtered view (newest first)
#     - Write cooldown: ListByTargetAndAction checks recent writes on a target
#       to prevent accidental duplicate SRE requests (time-bounded query)
#
#   target-status-index (PK=targetCluster, SK=targetStatusKey)
#     Consumers: reconciler, GC, concurrency limiter
#     - Composite sort key format: "{status}#{timestamp}" enables begins_with queries
#     - Reconciler: find all dispatched executions for THIS target only (cluster-scoped)
#     - GC: find all terminal executions for THIS target that need cleanup
#     - Concurrency limiter: CountActiveByTarget counts dispatched+approved items
#       per target to enforce MaxConcurrentPerTarget without reading the entire table
#     - Why not use status-index + target-index separately? DynamoDB cannot join indexes.
#       Without this composite, finding "dispatched items on target X" requires reading
#       ALL dispatched items across the fleet (O(fleet)) or ALL items on a target (O(history)).
#       This index makes it O(result_set) — cost proportional to active items only.
#
#   date-bucket-index (PK=dateBucket, SK=createdAt)
#     Consumers: CLI default path
#     - CLI: `zoa runs` (no --target, no --status) for cross-cluster listing (newest first)
#     - Daily partition key (e.g. "2026-08-26") with no partition size limits at scale
#     - Iterates backwards through daily buckets from today until --since boundary
#     - CLI enforces --since 24h default, guaranteeing bounded queries
#     - Items written before this index was deployed lack dateBucket and are only
#       accessible via --target or --status filters

resource "aws_dynamodb_table" "executions" {
  name                        = local.table_name
  billing_mode                = var.billing_mode
  hash_key                    = "executionId"
  deletion_protection_enabled = var.environment != "ephemeral"

  attribute {
    name = "executionId"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "targetCluster"
    type = "S"
  }

  attribute {
    name = "targetStatusKey"
    type = "S"
  }

  attribute {
    name = "dateBucket"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "target-index"
    hash_key        = "targetCluster"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "target-status-index"
    hash_key        = "targetCluster"
    range_key       = "targetStatusKey"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "date-bucket-index"
    hash_key        = "dateBucket"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.environment != "ephemeral"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.zoa.arn
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_name
      Component = "zoa"
    }
  )
}

# Cross-account access for MC Lambda roles
resource "aws_dynamodb_resource_policy" "executions_cross_account" {
  resource_arn = aws_dynamodb_table.executions.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCrossAccountLambdaAccess"
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:DescribeTable",
      ]
      Resource = [
        aws_dynamodb_table.executions.arn,
        "${aws_dynamodb_table.executions.arn}/index/*",
      ]
      Condition = {
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
        }
        StringLike = {
          "aws:PrincipalArn" = "arn:*:iam::*:role/*-zoa-lambda"
        }
      }
    }]
  })
}

# =============================================================================
# DynamoDB Table for ZOA Audit Log
# =============================================================================
# Stores API call audit entries for compliance and observability.
# PK: accountId, SK: timestamp (per-account listing from the Lambda's own account)
# TTL: 365-day automatic expiration
#
# GSI Index Architecture (2 indexes):
#
#   target-index (PK=targetCluster, SK=timestamp)
#     Consumers: CLI
#     - CLI: `zoa audit --target X` for cross-cluster filtered view (newest first)
#     - Each Lambda writes audit entries with its own targetCluster, enabling
#       filtering by which cluster processed the request
#
#   date-bucket-index (PK=dateBucket, SK=timestamp)
#     Consumers: CLI default path
#     - CLI: `zoa audit` (no --target) for cross-cluster listing (newest first)
#     - Daily partition key (e.g. "2026-08-26") with no partition size limits at scale
#     - Iterates backwards through daily buckets from today until --since boundary
#     - CLI enforces --since 24h default, guaranteeing bounded queries

resource "aws_dynamodb_table" "audit_log" {
  name                        = local.audit_table_name
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  range_key                   = "timestamp"
  deletion_protection_enabled = var.environment != "ephemeral"

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "targetCluster"
    type = "S"
  }

  attribute {
    name = "dateBucket"
    type = "S"
  }

  global_secondary_index {
    name            = "target-index"
    hash_key        = "targetCluster"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "date-bucket-index"
    hash_key        = "dateBucket"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.zoa.arn
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.environment != "ephemeral"
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.audit_table_name
      Component = "zoa"
    }
  )
}

# Cross-account access for MC Lambda roles (audit writes + cross-cluster reads)
resource "aws_dynamodb_resource_policy" "audit_cross_account" {
  resource_arn = aws_dynamodb_table.audit_log.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCrossAccountLambdaAuditAccess"
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = [
        "dynamodb:PutItem",
        "dynamodb:Query",
      ]
      Resource = [
        aws_dynamodb_table.audit_log.arn,
        "${aws_dynamodb_table.audit_log.arn}/index/*",
      ]
      Condition = {
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
        }
        StringLike = {
          "aws:PrincipalArn" = "arn:*:iam::*:role/*-zoa-lambda"
        }
      }
    }]
  })
}
