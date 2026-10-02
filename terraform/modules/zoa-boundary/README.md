# zoa-boundary Terraform module

ECS Fargate cluster and task definition for ZOA Boundary sessions (ECS Exec + ZOA CLI in the target VPC).

## CloudWatch log groups (single KMS CMK)

Both groups use the same key: `kms_key_arn` when set (RC shared ZOA CMK), otherwise `aws_kms_key.boundary_logs` per deployment.

| Purpose | Log group | Stream prefix / pattern | Written by |
| -------- | --------- | ------------------------ | ---------- |
| **Container stdout** | `/ecs/<cluster_id>/zoa-boundary` | `container/zoa-boundary/<task-id>` | ECS `awslogs` driver (task execution role) |
| **ECS Exec sessions** | `/ecs/<cluster_id>/zoa-boundary/ssm-sessions` | `ecs-execute-command-<session-id>` | ECS Exec OVERRIDE (task role) |

`<cluster_id>` is `regional_id` on the RC and `management_id` on each MC.

FedRAMP session accountability (AU-09) uses the **exec** group. Use `aws logs tail` on `.../ssm-sessions` for investigations; use the container group only for task bootstrap failures.

Requirements: `util-linux` (`script`) in the boundary image, `initProcessEnabled`, cluster `executeCommandConfiguration.logging = OVERRIDE`, task `EnableExecuteCommand`.

See [rosa-hyperfleet-zoa `docs/design/boundary-session-logging.md`](https://github.com/openshift-online/rosa-hyperfleet-zoa/blob/main/docs/design/boundary-session-logging.md).

## Outputs

| Output | Description |
| ------ | ----------- |
| `log_group_name` | Container stdout log group |
| `exec_log_group_name` | ECS Exec session log group |
| `ecs_cluster_name` | Boundary ECS cluster |
