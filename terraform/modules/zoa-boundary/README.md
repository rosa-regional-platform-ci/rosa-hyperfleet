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

| Setting | Value |
|---------|--------|
| `CLAUDE_CODE_USE_BEDROCK` | `1` |
| `CLAUDE_CODE_USE_MANTLE` | `0` |
| `ANTHROPIC_MODEL` | `claude_bedrock_inference_profile_id` (default `us.anthropic.claude-haiku-4-5-20251001-v1:0`) |

Haiku 4.5 on Bedrock requires a **system inference profile**; application profiles sourced from the in-region foundation model are rejected by AWS. Override `claude_bedrock_inference_profile_id` per region if a different profile is approved.

Task IAM: `bedrock:InvokeModel` on the profile ARN, scoped Marketplace subscribe via `aws:CalledViaLast = bedrock.amazonaws.com`.
