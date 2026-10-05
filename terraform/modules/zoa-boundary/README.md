# zoa-boundary Terraform module

ECS Fargate boundary tasks for audited ZOA sessions (ECS Exec + CloudWatch).

## Logging

| Stream                | Log group                                     | Purpose                         |
| --------------------- | --------------------------------------------- | ------------------------------- |
| **Container stdout**  | `/ecs/<cluster_id>/zoa-boundary`              | Task startup, tool listing      |
| **ECS Exec sessions** | `/ecs/<cluster_id>/zoa-boundary/ssm-sessions` | Interactive session transcripts |

Both use the regional ZOA CMK (`kms_key_arn`).

Baked files live under **`/home/sre`**: `.claude/CLAUDE.md`, `.bashrc.d/` (two-line PS1), `.claude/ZOA_SESSION.md` and **`.claude/ZOA_ACTIONS.md`** (regenerated at task start). Access Lambda injects **`ZOA_SESSION_ID`** and **`ZOA_OPERATOR`** at `RunTask`; Terraform sets deployment/target/API URL on the task definition.

Task bootstrap (banner, tool checks, keep-alive) lives in the **zoa-boundary image** entrypoint; Terraform only sets **environment**, IAM, and logging.

## Claude Code (classic Amazon Bedrock)

Boundary tasks set **`ANTHROPIC_MODEL=us.anthropic.claude-sonnet-5`** (same Bedrock ID saved by **`/model` → Sonnet** in boundary sessions), not picker **Default** (Sonnet 4.5).

| Setting                   | Value                                                                        |
| ------------------------- | ---------------------------------------------------------------------------- |
| `CLAUDE_CODE_USE_BEDROCK` | `1`                                                                          |
| `AWS_REGION`              | Deployment region (from task env)                                            |
| `ANTHROPIC_MODEL`         | `claude_code_bedrock_primary_model` (default `us.anthropic.claude-sonnet-5`) |

Task IAM: `bedrock:InvokeModel`, `InvokeModelWithResponseStream`, `ListInferenceProfiles`, and `GetInferenceProfile` (regional inference/application profiles) on the usual Bedrock ARNs. Marketplace subscribe via `aws:CalledViaLast = bedrock.amazonaws.com`.

Account-level Bedrock agreements, cost budget, and optional invocation logging are **not** in this module. Use [`../bedrock`](../bedrock) from the regional/management cluster stack (or future per-account bootstrap Terraform).
