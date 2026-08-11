# ZOA Lambda Infrastructure

## Status

- **Phase**: Implementation
- **Modules**: `terraform/modules/zoa-lambda/`, `terraform/modules/zoa/`
- **Deployed to**: RC VPC + each MC VPC

## Architecture

ZOA uses a **2-Lambda per VPC** model:

| Lambda | Trigger | Purpose | Timeout | Concurrency |
|---|---|---|---|---|
| **API** | Function URL (IAM auth) + LWA | CLI requests, sync TA execution, streaming downloads | 300s | 50 |
| **Worker** | EventBridge Scheduler + self-invoke | Reconciler, GC, reaper, async TA execution | 300s | 10 |

Both share the same binary and IAM role. `HANDLER_MODE` env var selects the execution path.

## Terraform Module Split

```
terraform/modules/zoa/          → Data layer (DynamoDB, S3, KMS, uploader role)
                                  Lives only in RC. MC access via resource policies.

terraform/modules/zoa-lambda/   → Compute layer (Lambdas, EventBridge, SQS DLQ, CW Logs)
                                  Deployed once per VPC (RC + each MC).
```

## Tunable Parameters

All timeouts and batch sizes are **configurable without code change** via Terraform variables that map to Lambda environment variables.

### Terraform Variables (in `zoa-lambda` module)

| Variable | Default | Purpose | Safe range |
|---|---|---|---|
| `lambda_api_timeout` | 300 | API Lambda hard ceiling (seconds) | 60–900 |
| `lambda_worker_timeout` | 300 | Worker Lambda hard ceiling (seconds) | 60–900 |
| `lambda_api_concurrency` | 50 | Max concurrent API Lambda invocations | 1–1000 |
| `lambda_worker_concurrency` | 10 | Max concurrent Worker Lambda invocations | 2–100 |
| `reconciler_deadline_seconds` | 55 | Code-level deadline for reconciler/GC/reaper | < `lambda_worker_timeout` |
| `max_batch_per_tick` | 30 | Items processed per scheduled phase per tick | 1–200 |
| `lambda_memory_size` | 512 | Memory in MB (also affects CPU proportionally) | 128–10240 |
| `enable_reconciler` | true | Toggle EventBridge schedules (disable for testing) | true/false |
| `dynamodb_ttl_days` | 365 | DynamoDB record retention (FIPS compliance) | 30–3650 |

### Lambda Environment Variables

| Env Var | Set from | Controls |
|---|---|---|
| `HANDLER_MODE` | Terraform (fixed) | "api" or "worker" |
| `RECONCILER_DEADLINE_SECONDS` | `reconciler_deadline_seconds` | Code deadline for scheduled routes |
| `EXECUTION_DEADLINE_SECONDS` | `lambda_worker_timeout - 5` | Code deadline for TA execution |
| `MAX_BATCH_PER_TICK` | `max_batch_per_tick` | Batch limit per phase |
| `AWS_LAMBDA_FUNCTION_NAME` | AWS (auto-set) | Used for self-invocation |

## EventBridge Schedules

| Schedule | Rate | Target Route | State |
|---|---|---|---|
| `{cluster}-zoa-reconciler` | 1 minute | `reconciler` | Enabled |
| `{cluster}-zoa-gc` | 5 minutes | `gc` | Enabled |
| `{cluster}-zoa-reaper` | 5 minutes | `reaper` | Disabled (until rosa-boundary) |

## Self-Invocation (Fan-out)

The Worker Lambda invokes **itself** for TA execution:
- Reconciler claims approved executions → transitions to `dispatched`
- Invokes `AWS_LAMBDA_FUNCTION_NAME` with `InvocationType=Event`
- AWS Lambda queues the invocation in a separate concurrent slot
- `reserved_concurrency=10` ensures max 9 concurrent TA executions + 1 for reconciler

## Security Model

- **Function URL**: `AWS_IAM` auth only — requires valid SigV4 signature
- **VPC attachment**: Lambda runs inside the target VPC with the cluster security group
- **SQS DLQ**: SSE enabled, 14-day retention, auto-cleaned
- **KMS**: All data encrypted at rest (DynamoDB, S3, SQS)
- **Cross-account**: MC Lambdas access RC data via resource-based policies (no STS hop)

## Monitoring

| Signal | Source | How |
|---|---|---|
| Lambda errors | AWS/Lambda namespace | Auto-published by Lambda runtime |
| Duration, throttles | AWS/Lambda namespace | Auto-published by Lambda runtime |
| Business metrics | ZOA/Custom namespace | EMF logs emitted by Go code |
| Alerting | Prometheus | CW Exporter scrapes → PrometheusRules evaluate |
| Logs | CloudWatch Logs | 365-day retention, JSON structured |

## Deployment Flow

1. CodePipeline triggers CodeBuild
2. CodeBuild clones `rosa-hyperfleet-zoa` repo (branch configurable)
3. Cross-compiles `zoa-lambda` binary for `linux/arm64`
4. Packages as ZIP artifact with SHA256 hash
5. Terraform `source_code_hash` detects changes → updates Lambda

## Cost Considerations

- Lambda bills per-ms of actual execution, not per-timeout
- Reserved concurrency guarantees slots but doesn't incur idle cost
- Graviton (arm64) is ~20% cheaper than x86
- EventBridge Scheduler: free tier covers most schedules
- SQS DLQ: minimal cost (14-day retention, encrypted)
