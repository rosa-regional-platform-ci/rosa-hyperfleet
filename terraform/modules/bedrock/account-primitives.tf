# --- Foundation model agreements ---------------------------------------------

data "external" "bedrock_agreement_exists" {
  for_each = local.bedrock_agreement_entries

  program = local.account_primitive_check_program

  query = {
    check    = "agreement"
    model_id = each.value.model_id
    region   = data.aws_region.current.name
  }
}

locals {
  bedrock_agreement_entries_to_create = {
    for key, entry in local.bedrock_agreement_entries :
    key => entry
    if try(data.external.bedrock_agreement_exists[key].result.exists, "false") != "true"
  }
}

# --- Bedrock cost budget (one name per account) ------------------------------

data "external" "bedrock_budget_exists" {
  count = var.enable_cost_budget ? 1 : 0

  program = local.account_primitive_check_program

  query = {
    check       = "budget"
    account_id  = data.aws_caller_identity.current.account_id
    budget_name = var.budget_name
  }
}

locals {
  bedrock_budget_already_exists = length(data.external.bedrock_budget_exists) > 0 && (
    data.external.bedrock_budget_exists[0].result.exists == "true"
  )
  create_bedrock_cost_budget = var.enable_cost_budget && !local.bedrock_budget_already_exists
}

# --- Bedrock model invocation logging (account singleton when enabled) ---------

data "external" "bedrock_invocation_logging_exists" {
  count = var.enable_invocation_logging ? 1 : 0

  program = local.account_primitive_check_program

  query = {
    check  = "invocation_logging"
    region = data.aws_region.current.name
  }
}

locals {
  bedrock_invocation_logging_already_exists = length(data.external.bedrock_invocation_logging_exists) > 0 && (
    data.external.bedrock_invocation_logging_exists[0].result.exists == "true"
  )
  create_bedrock_invocation_logging = var.enable_invocation_logging && !local.bedrock_invocation_logging_already_exists
}
