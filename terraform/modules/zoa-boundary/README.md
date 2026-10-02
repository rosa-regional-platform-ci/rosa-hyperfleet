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

Task IAM: `bedrock:InvokeModel`, `InvokeModelWithResponseStream`, and `ListInferenceProfiles` on `inference-profile/*` and `foundation-model/*` (all regions in the partition). Marketplace subscribe via `aws:CalledViaLast = bedrock.amazonaws.com`.

Anthropic **use case** and **model access** in the AWS account are account-level prerequisites ([Bedrock model access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)); this module does not submit those forms.
