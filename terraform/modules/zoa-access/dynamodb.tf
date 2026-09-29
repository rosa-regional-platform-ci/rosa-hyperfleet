# =============================================================================
# ZOA Access — Storage references
# =============================================================================
# Boundary session table is created in the zoa/ module (consolidated storage).
# This module receives the table name as a variable and only configures IAM.
#
# Target registration uses SSM Parameter Store (not DynamoDB):
#   /zoa/targets/<deployment>/<cluster> — written by each cluster's Terraform,
#   read by this Lambda via GetParametersByPath. See zoa/dynamodb.tf.
# =============================================================================
# DynamoDB tables (from zoa/ module):
#   - Sessions: var.sessions_table_name
#   - Audit:    var.audit_table_name
