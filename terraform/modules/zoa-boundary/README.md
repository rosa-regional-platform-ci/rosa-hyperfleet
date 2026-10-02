# zoa-boundary Terraform module

ECS Fargate boundary tasks for audited ZOA sessions (ECS Exec + CloudWatch).

## Logging

| Stream | Log group | Purpose |
|--------|-----------|---------|
| **Container stdout** | `/ecs/<cluster_id>/zoa-boundary` | Task startup, tool listing |
| **ECS Exec sessions** | `/ecs/<cluster_id>/zoa-boundary/ssm-sessions` | Interactive session transcripts |

Both use the regional ZOA CMK (`kms_key_arn`).

Baked files live under **`/home/sre`**: `.claude/CLAUDE.md`, `.claude/ZOA_SESSION.md` (stub in image; task startup overwrites session table).

## Claude Code (classic Amazon Bedrock)

Bedrock is enabled via task env only; Claude Code selects the model (no `ANTHROPIC_MODEL` in Terraform).

| Setting | Value |
|---------|--------|
| `CLAUDE_CODE_USE_BEDROCK` | `1` |
| `CLAUDE_CODE_USE_MANTLE` | `0` |
| `AWS_REGION` | Deployment region (from task env) |

Task IAM: `bedrock:InvokeModel`, `InvokeModelWithResponseStream`, and `ListInferenceProfiles` on `inference-profile/*` and `foundation-model/*` (all regions in the partition). Marketplace subscribe via `aws:CalledViaLast = bedrock.amazonaws.com`.

The AWS account must still complete [Anthropic use case onboarding](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html) before invokes succeed.
