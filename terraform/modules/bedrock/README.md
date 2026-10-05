# Bedrock account primitives

Generic Terraform for **per AWS account + Region** Bedrock onboarding:

- Foundation model **agreements** (PUBLIC offers)
- Monthly **cost budget** (alerts only)
- Optional **model invocation logging** (metadata to CloudWatch; dedicated KMS)

Not tied to ZOA or boundary. HyperFleet calls this module from regional and management cluster stacks today; move the same module to dedicated per-account bootstrap Terraform when that exists.

## Shared pool accounts (ephemeral / CI)

Many cluster stacks share one RC or MC AWS account. Account-scoped objects must not be owned by a single ephemeral state.

At plan time, `data.external` runs `scripts/check_account_primitive.sh`. If AWS already has the agreement, budget, or logging configuration, **create is skipped** and the object is **not imported** into this stack’s state. Destroying one ephemeral stack therefore does not delete account-wide Bedrock setup for others.

The first stack that creates a primitive **does** hold it in state until that stack is destroyed or you migrate ownership to account bootstrap TF.

## Invocation logging

When `enable_invocation_logging` is true and the account has no logging config yet, this module creates:

- KMS key `alias/bedrock-invocation-logs`
- Log group (default `/aws/bedrock/model-invocations`)
- IAM role (default `bedrock-invocation-logging`)
- `aws_bedrock_model_invocation_logging_configuration`

Workload IAM (for example boundary task `bedrock:InvokeModel`) stays in the workload module; agreements are not part of invoke policies.

## Variables

See `variables.tf`. Resource names default to account-wide fixed strings (`bedrock-monthly`, `bedrock-invocation-logging`), not cluster IDs.
