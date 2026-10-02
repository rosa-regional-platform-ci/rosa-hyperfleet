# zoa-boundary Terraform module

ECS Fargate boundary tasks for audited ZOA sessions (ECS Exec + CloudWatch).

## Logging

| Stream | Log group | Purpose |
|--------|-----------|---------|
| **Container stdout** | `/ecs/<cluster_id>/zoa-boundary` | Task startup, tool listing |
| **ECS Exec sessions** | `/ecs/<cluster_id>/zoa-boundary/ssm-sessions` | Interactive session transcripts |

Both use the regional ZOA CMK (`kms_key_arn`).

Baked files live under **`/home/sre`**: `.claude/CLAUDE.md`, `.claude/ZOA_SESSION.md` (stub in image; **`boundary/zoa-boundary-entrypoint.sh`** overwrites the session table at task start from ECS env).

Task bootstrap (banner, tool checks, keep-alive) lives in the **zoa-boundary image** entrypoint; Terraform only sets **environment**, IAM, and logging.

## Claude Code (classic Amazon Bedrock)

Boundary tasks set **`ANTHROPIC_MODEL=us.anthropic.claude-sonnet-5`** (same Bedrock ID saved by **`/model` → Sonnet** in boundary sessions), not picker **Default** (Sonnet 4.5).

| Setting | Value |
|---------|--------|
| `CLAUDE_CODE_USE_BEDROCK` | `1` |
| `AWS_REGION` | Deployment region (from task env) |
| `ANTHROPIC_MODEL` | `claude_code_bedrock_primary_model` (default `us.anthropic.claude-sonnet-5`) |

Task IAM: `bedrock:InvokeModel`, `InvokeModelWithResponseStream`, `ListInferenceProfiles`, and `GetInferenceProfile` (regional inference/application profiles) on the usual Bedrock ARNs. Marketplace subscribe via `aws:CalledViaLast = bedrock.amazonaws.com`.

### Bedrock model agreements

This module runs on **both RC and MC** Terraform applies — each AWS account gets its own agreements and budget.

When `enable_bedrock_model_agreements` is true, Terraform manages `aws_bedrock_foundation_model_agreement` for each non-empty entry in `bedrock_model_agreements`. Resource identity is **`model_id|offer_id`**: adding a model creates an agreement; **changing an offer ID destroys the old agreement and creates a new one**; removing a model from the map **destroys** its agreement. `ignore_changes = [offer_token]` only avoids churn when AWS rotates tokens for the same offer ID.

**Before production in an account/Region:** confirm PUBLIC offer IDs (CLI/console), set `bedrock_model_agreements` via module inputs (today: defaults in `variables.tf`; planned: per-env `config/`). Agreements already created manually must be **imported** or removed before first apply to avoid conflicts.

This is **not** the Anthropic use-case form; account onboarding may still be required for invoke.

### Bedrock cost budget

When `enable_bedrock_cost_budget` is true, one **account-wide** monthly **Amazon Bedrock** budget emails **ACTUAL** spend at **50%, 80%, and 100%** of `bedrock_monthly_budget_usd` (default **1000** USD). The subscriber is **`bedrock_budget_notification_email` with `+<aws_account_id>` before `@`** (default base `rosa-hyperfleet@redhat.com` → `rosa-hyperfleet+123456789012@redhat.com` per account). Alerts do not cap usage. Confirm plus addresses are accepted by your mail system; AWS Budgets may require confirming each variant the first time it is used.
