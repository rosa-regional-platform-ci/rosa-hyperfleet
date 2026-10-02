# zoa-boundary Terraform module

ECS Fargate cluster and task definition for ZOA Boundary sessions (ECS Exec + ZOA CLI in the target VPC).

## CloudWatch log groups (single KMS CMK)

Both groups use the regional ZOA CMK (`kms_key_arn` = RC `module.zoa.kms_key_arn`), including MC deployments via cross-account key policy in `module.zoa`.

| Purpose | Log group | Stream prefix / pattern | Written by |
| -------- | --------- | ------------------------ | ---------- |
| **Container stdout** | `/ecs/<cluster_id>/zoa-boundary` | `container/zoa-boundary/<task-id>` | ECS `awslogs` driver (task execution role) |
| **ECS Exec sessions** | `/ecs/<cluster_id>/zoa-boundary/ssm-sessions` | `ecs-execute-command-<session-id>` | ECS Exec OVERRIDE (task role) |

`<cluster_id>` is `regional_id` on the RC and `management_id` on each MC.

FedRAMP session accountability (AU-09) uses the **exec** group. Use `aws logs tail` on `.../ssm-sessions` for investigations; use the container group only for task bootstrap failures.

Requirements: `util-linux` (`script`) in the boundary image, `initProcessEnabled`, cluster `executeCommandConfiguration.logging = OVERRIDE`, task `EnableExecuteCommand`.

See [rosa-hyperfleet-zoa `docs/design/boundary-session-logging.md`](https://github.com/openshift-online/rosa-hyperfleet-zoa/blob/main/docs/design/boundary-session-logging.md).

**ECS Exec user:** AWS runs `ecs:ExecuteCommand` as **root** regardless of the task definition `user` field ([ECS Exec docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html)). The task runs its main process as UID **1000** (`sre`); interactive sessions use **`ecs_exec_interactive_command`** (default `runuser -u sre -- /bin/bash -l`), set in Terraform on the boundary task (`ZOA_ECS_EXEC_COMMAND`) and returned by **ZOA Access** `session/join` as `exec_command`. Clients must pass that command to ExecuteCommand — do not hardcode a different shell in the CLI alone.

Baked files live under **`/home/sre`** (use `ls -la`): `.claude/CLAUDE.md`, `.claude/ZOA_SESSION.md` (stub in image; task startup script overwrites session table).

## Claude Code (Bedrock Mantle, in-region)

Terraform sets on the ECS task (override image defaults):

| Env var | Value |
| -------- | ----- |
| `AWS_REGION` | Deployment region (pins Mantle endpoint) |
| `CLAUDE_CODE_USE_MANTLE` | `1` |
| `CLAUDE_CODE_USE_BEDROCK` | `0` |
| `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `claude_mantle_model_id` (default `anthropic.claude-haiku-4-5`) |

Task IAM: `bedrock-mantle:*` scoped with `aws:RequestedRegion` = deployment region. No classic `bedrock:InvokeModel` or geo inference profiles.

## Outputs

| Output | Description |
| ------ | ----------- |
| `log_group_name` | Container stdout log group |
| `exec_log_group_name` | ECS Exec session log group |
| `ecs_cluster_name` | Boundary ECS cluster |
