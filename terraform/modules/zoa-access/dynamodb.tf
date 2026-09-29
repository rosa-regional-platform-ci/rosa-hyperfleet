# =============================================================================
# ZOA Access — DynamoDB table references
# =============================================================================
# Boundary session and target tables are created in the zoa/ module
# (consolidated storage). This module receives table names as variables
# and only configures IAM access to them.
# =============================================================================
# Tables:
#   - Sessions: var.sessions_table_name (from zoa/ module)
#   - Targets:  var.targets_table_name  (from zoa/ module)
#   - Audit:    var.audit_table_name    (from zoa/ module)
