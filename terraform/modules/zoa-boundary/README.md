# zoa-boundary Terraform module

ECS Fargate boundary tasks for audited ZOA sessions (ECS Exec + CloudWatch).

## Logging

| Stream | Log group | Purpose |
|--------|-----------|---------|
| **Container stdout** | `/ecs/<cluster_id>/zoa-boundary` | Task startup, tool listing |
| **ECS Exec sessions** | `/ecs/<cluster_id>/zoa-boundary/ssm-sessions` | Interactive session transcripts |

Both use the regional ZOA CMK (`kms_key_arn`).

Baked files live under **`/home/sre`** (use `ls -la`): `.claude/CLAUDE.md`, `.claude/ZOA_SESSION.md` (stub in image; task startup script overwrites session table).

## Claude Code (classic Amazon Bedrock, in-region)

Claude Code uses the **Bedrock Invoke API** (`bedrock-runtime`), not Mantle.

| Setting | Value |
|---------|--------|
| `AWS_REGION` | Deployment region |
| `CLAUDE_CODE_USE_BEDROCK` | `1` |
| `CLAUDE_CODE_USE_MANTLE` | `0` |
| `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Application inference profile ID (single-region Haiku 4.5) |

Terraform creates `aws_bedrock_inference_profile` with `model_source.copy_from` = the in-region foundation model ARN (`claude_bedrock_foundation_model_id`). That is **not** a `us.anthropic.*` geo profile — requests stay in the cluster region.

Task IAM: `bedrock:InvokeModel` on the foundation model + application profile ARNs, scoped `aws-marketplace:Subscribe` with `aws:CalledViaLast = bedrock.amazonaws.com` for first-time model access.
