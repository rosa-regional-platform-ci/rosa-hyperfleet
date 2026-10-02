# Monthly Bedrock cost alerts for this AWS account (all Bedrock callers, not only boundary).
# Notifications do not cap or stop inference.

resource "aws_budgets_budget" "bedrock" {
  count = var.enable_bedrock_cost_budget ? 1 : 0

  name         = "${var.cluster_id}-bedrock-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.bedrock_monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Bedrock"]
  }

  dynamic "notification" {
    for_each = [50, 80, 100]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.bedrock_budget_notification_email]
    }
  }

  tags = local.common_tags
}
