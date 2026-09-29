# =============================================================================
# ZOA Access DynamoDB Tables
# =============================================================================
# Session tracking and target registry tables for ZOA Boundary.
# Both tables use KMS encryption and PAY_PER_REQUEST billing.
# =============================================================================

# =============================================================================
# boundary-sessions — Session state tracking
# =============================================================================
# PK: sessionId (ECS task ID)
# GSIs for listing by operator, status, and target cluster.
# TTL: 30 days (session metadata — the audit table covers FedRAMP long-term)

resource "aws_dynamodb_table" "sessions" {
  name         = var.sessions_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sessionId"

  attribute {
    name = "sessionId"
    type = "S"
  }

  attribute {
    name = "operator"
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
    name = "createdAt"
    type = "S"
  }

  global_secondary_index {
    name            = "operator-index"
    hash_key        = "operator"
    range_key       = "createdAt"
    projection_type = "ALL"
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

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = merge(local.common_tags, {
    Name = var.sessions_table_name
  })
}

# =============================================================================
# boundary-targets — Target registry (RC, MC clusters)
# =============================================================================
# PK: targetId (e.g., rc, mc01, mc02)
# GSI for listing targets by deployment.

resource "aws_dynamodb_table" "targets" {
  name         = var.targets_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "targetId"

  attribute {
    name = "targetId"
    type = "S"
  }

  attribute {
    name = "deploymentName"
    type = "S"
  }

  attribute {
    name = "targetType"
    type = "S"
  }

  global_secondary_index {
    name            = "deployment-index"
    hash_key        = "deploymentName"
    range_key       = "targetType"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = merge(local.common_tags, {
    Name = var.targets_table_name
  })
}
