# ROSAENG-65234 — ZOA Lambda Observability Plan

> **Status:** Consolidated — SRE review applied (see `tmp/ROSAENG-65234-sre-review.md` for full review log). Ready for implementation approval.
>
> **Jira:** [ROSAENG-65234](https://redhat.atlassian.net/browse/ROSAENG-65234) — Zero Operator Access - Lambda Observability
>
> **Branches:**
> - `rosa-hyperfleet`: `feat/zoa-lambda-observability` (from `upstream/main`)
> - `rosa-hyperfleet-zoa`: `feat/zoa-lambda-observability` (from `feat/must-gather` / PR #83 base)
>
> **Audience:** Engineers implementing the work; secondary audience is review models/agents validating design, cost, and SRE fit before implementation.

---

## SRE Review Applied (summary)

This plan incorporates all accepted fixes from the Google SRE review (`tmp/ROSAENG-65234-sre-review.md`):

| # | Fix | Where |
|---|-----|-------|
| 1 | Recording rule `zoa:api_availability:5m` — aggregate first, then ratio | §7.2 |
| 2 | Reconciler detection — timestamp-based instead of `absent_over_time` | §7.2 |
| 3 | DLQ alert `for: 5m` — sustained DLQ messages page, transient blips filtered | §7.1, §7.2 |
| 4 | `HttpRequestDuration` — added `StatusClass` for consistency | §5.2 |
| 5 | SLO 99% (was 99.5%) — start loose, tighten with data | §0.3, §7.3 |
| 6 | Circuit breaker per-container — dashboard annotation + plan note | §3.4, §6.2 |
| 7 | Cost estimates adjusted — realistic sparse series counts | §0.6, §2.5 |
| 8 | Ephemeral env cost — ~$0.04 total, essentially free | §0.9 |
| 9 | New risks — alert detection latency, CB per-container | §10 |

**Skipped (acceptable for v1):** runbook references, SLO failure cause split, cold start signal, alert inhibition.

---

## 0. Plan purpose, context, and goals (handoff brief)

### 0.1 Purpose of this document

This plan specifies **how to make ZOA (Zero Operator Access) operable at production SRE standard** without building a ZOA web UI. ZOA is a serverless subsystem (Lambda + DynamoDB + S3) that runs Trusted Actions (TAs) for platform SREs via CLI. Today operators can *execute* TAs and *query* run history via CLI/DynamoDB, but there is **no continuous visibility** into whether ZOA is healthy, whether TAs are succeeding, or whether a specific management cluster's Lambda pipeline is broken.

This document answers: what exists, what is broken, what to build, what to alert on, what to put in Grafana, what **not** to duplicate, and what it costs. It is the single source of truth for implementation across two repositories (`rosa-hyperfleet-zoa` for EMF emission in Go; `rosa-hyperfleet` for YACE, Grafana, PrometheusRules).

**Out of scope:** ZOA web UI, approval workflow UI, changes to TA business logic, API Gateway (ZOA uses Lambda Function URL).

### 0.2 What we have today

| Layer | Status | Detail |
|-------|--------|--------|
| **ZOA runtime** | ✅ Deployed | 2 Lambdas per VPC (api + worker), Function URL (IAM auth), EventBridge reconciler/GC, SQS DLQ, DynamoDB executions + audit tables in RC |
| **TAs** | ✅ 9 registered | `delete_pod`, `describe_eks_cluster`, `describe_vpc_endpoint`, `get_resource`, `get_secret`, `list_eks_clusters`, `list_vpc_endpoints`, `must_gather`, `rollout_restart` |
| **Run forensics** | ✅ CLI + DynamoDB | `zoa runs`, `zoa audit`, CloudWatch Logs (365d) |
| **EMF metrics (Go)** | ⚠️ Partial, untested | `pkg/metrics/emf.go` emits to `ZOA` namespace; duplicated HTTP metrics; **cardinality bug** (full URL paths with UUIDs); missing TA action/status/mode dimensions |
| **Native CW Lambda/SQS metrics** | ✅ Exist in AWS | Not scraped into Prometheus |
| **YACE on RC** | ⚠️ Partial | Scrapes DynamoDB (includes `*-zoa-*` tables), RDS, ALB, API GW, EKS — **no Lambda, SQS, or `ZOA` namespace** |
| **YACE on MC** | ⚠️ Minimal | EKS control plane only — **no ZOA resources** |
| **Grafana dashboards** | ❌ None for ZOA | RDS/DynamoDB infra dashboards exist as style reference |
| **PrometheusRules for ZOA** | ❌ None | HCP SLA, ratelimit, remote-write-health patterns exist as reference |
| **promtool CI tests** | ✅ Infrastructure exists | `ci/promtool-test/*_rules_test.yaml`; no ZOA tests yet |
| **Thanos / alerting** | ✅ RC only | MC metrics remote-write to RC Thanos; all alerts evaluated on RC |

**Key gap:** Metrics are *emitted* (partially) but not *collected, visualized, or alerted on*. `docs/design/zoa-architecture.md` correctly marks CW Exporter → Prometheus and PrometheusRules as **Planned**.

### 0.3 What we want to achieve (Google SRE perspective)

ZOA is an **internal platform service** with safety-critical properties (no unaudited operator access). From the [Google SRE book/workbook](https://sre.google/workbook/alerting-on-slos/), operability requires:

| SRE principle | ZOA application |
|---------------|-----------------|
| **Define SLIs** | API availability (non-5xx), TA success rate, worker pipeline health (reconciler running), DLQ depth (= 0), execution latency percentiles |
| **Set SLOs** | Starting targets: API 99%/30d, TA success 95%/7d, DLQ depth 0 instantaneous — tune after baseline (start loose per SRE Workbook) |
| **Error budgets & burn alerts** | Multi-window burn-rate alerts (fast + slow) for API and TA failure rate — same pattern as `hcp-sla.yaml` |
| **Alert on symptoms, page on user impact** | **Page:** DLQ > 0, worker Lambda errors, reconciler not invoking. **Ticket:** elevated TA failure rate, throttles, GC errors. **Never page:** cooldown rejections, single TA failure |
| **Four golden signals** | **Latency:** `ExecutionDuration`, `HttpRequestDuration`, `aws_lambda_duration`. **Traffic:** `ExecutionCount`, `aws_lambda_invocations`. **Errors:** `ExecutionCount{status=failed}`, `aws_lambda_errors`, DLQ. **Saturation:** `aws_lambda_throttles`, `ConcurrentExecutions` |
| **Monitoring ≠ logging ≠ debugging** | **Metrics** (EMF + native CW) for SLIs/dashboards/alerts. **Logs** for request traces. **DynamoDB/CLI** for per-run forensics. Each layer has one job |
| **Cardinality discipline** | Low-cardinality dimensions only in EMF; operator/jira/execution_id stay in DynamoDB |
| **No UI required for ops** | Grafana on RC (Thanos) is the operational dashboard until a ZOA UI exists; future UI reads DynamoDB for drill-down — does not replace Grafana SLI panels |

**User-visible failure modes we must detect:**

1. SRE cannot run TAs (API Lambda 5xx / unavailable).
2. TAs accepted but never complete (worker/reconciler broken).
3. Silent message loss (DLQ depth > 0).
4. One MC's ZOA broken while others healthy (per-`cluster` alerting).
5. Elevated TA failure rate for a specific action (e.g. `must_gather`).

### 0.4 Target end state (acceptance criteria, refined)

| # | Criterion | Deliverable |
|---|-----------|-------------|
| 1 | EMF for every TA execution terminal transition | `ExecutionCount` + `ExecutionDuration` with Action, Status, Mode, Scope, Type |
| 2 | CW exporter scrapes ZOA-relevant namespaces | YACE on **RC + MC**: `AWS/Lambda`, `AWS/SQS`, custom `ZOA` namespace |
| 3 | Sustained error rate alerts | PrometheusRules with burn-rate pattern; promtool tests |
| 4 | Grafana operational view | **Two dashboards:** `Lambda` infra + `ZOA` unified service dashboard |
| 5 | DLQ depth alert | Page when `*-zoa-dlq` messages > 0 for 5m — filters transient single-tick failures |
| 6 | Per-cluster isolation | Alerts/dashboards use `cluster` label (mc01 vs mc05) |
| 7 | Cost-conscious | EMF cardinality controlled; native CW for infra; target < $30–80/region |

### 0.5 Key design decisions (summary for reviewers)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| HTTP metrics source | EMF (not API GW) | ZOA uses Function URL — no `AWS/ApiGateway` metrics |
| api vs worker infra metrics | Native `aws_lambda_*` + `tag_HandlerMode` | Free; no EMF duplication |
| Action/Scope/Type in EMF? | **Yes** (bounded cardinality) | DynamoDB CW metrics cannot expose TA dimensions; CLI is not continuous SLI |
| Action/Scope/Type in DynamoDB? | **Yes** (source of truth) | Complementary to EMF — not either/or |
| Cooldown rejection | `RejectionCount` metric, not execution terminal | No execution row created |
| Dashboard split | Infra (Lambda/SQS) + Operations (EMF business) | Avoid duplicate panels; link between dashboards |
| Alert location | RC Thanos Ruler only | MC remote-writes; alerts need `sum by (cluster)` |
| EMF vs logs billing | Custom metric series billed on publish (~$0.30/series/month) | Not free; cardinality = cost control |

### 0.6 Cost summary (1 region = 1 RC + 1 MC, 9 TAs)

| | Low (ephemeral) | Moderate (active SRE) | Worst-case cardinality |
|--|-----------------|----------------------|------------------------|
| Active EMF series | ~100–140 | ~180–240 | ~960 |
| **EMF custom metrics $/month** | **~$36** | **~$63** | **~$288** |
| Logs + YACE API | ~$2–5 | ~$5–8 | ~$10–15 |
| **Observability add-on total** | **~$38–41** | **~$68–71** | **~$300** |
| Existing ZOA infra (Lambda/DDB/S3) | ~$24 | ~$24 | ~$24 |
| **All-in per region** | **~$62–65** | **~$92–95** | **~$324** |

Native `AWS/Lambda` + `AWS/SQS` infra metrics: **$0** custom-metric charge. Optimizations can reduce EMF to **~$25–35/region** (see §2.5).

> **Note:** "Low" estimates assume most Action×Status dimension combos are sparse (7/9 TAs are sync+read, only ~2 status values active per TA). CW only bills series that received at least one datapoint. Ephemeral environments (40-min E2E) cost ~$0.04 total — billing stops ~3h after last datapoint (see §0.9).

### 0.7 Document map

| Section | Contents |
|---------|----------|
| §0 | This handoff brief |
| §1 | Executive summary (one paragraph) |
| §2 | Architecture, SRE data planes, cost, labels |
| §3 | Current state — `rosa-hyperfleet-zoa` (EMF code audit) |
| §4 | Current state — `rosa-hyperfleet` (YACE, Grafana, alerts) |
| §5 | Target metric model (EMF schema, event taxonomy, YACE config) |
| §6 | Grafana dashboards |
| §7 | Alerting rules (SRE paging policy, promtool) |
| §8 | Jira scope refinement |
| §9 | Implementation phases |
| §10 | Risks |
| §11 | File checklist |
| §12 | EMF quality assessment |

### 0.8 Repositories and dependencies

```
rosa-hyperfleet-zoa          rosa-hyperfleet
├── pkg/metrics/ (EMF)  ──►  ├── cloudwatch-exporter/values.yaml (YACE scrape)
├── pkg/api/ (HTTP/TA)       ├── grafana/dashboards/ (2 new)
├── pkg/handler/ (Lambda)    ├── alerting-rules/templates/zoa.yaml
└── pkg/scheduler/ (GC)    └── ci/promtool-test/zoa-rules_test.yaml
```

**PR order:** ZOA EMF fixes can merge independently; hyperfleet YACE/Grafana/alerts can ship first for native Lambda/SQS (panels populate immediately). EMF `ZOA` namespace panels populate after ZOA image deploy.

### 0.9 EMF billing & retention (quick reference)

| Question | Answer |
|----------|--------|
| Is EMF free if we only query via YACE? | **No.** EMF creates **custom CloudWatch metrics**; you pay **~$0.30/series/month** for each dimension combo that receives data |
| Do we pay for log lines too? | Yes, but negligible (~$0.05–0.13/region/month for EMF JSON lines) |
| EMF retention in CloudWatch? | **~15 months** (AWS default for custom metrics); stored whether or not Grafana queries it |
| What does Grafana query? | **Thanos** (90d–365d tiers) after YACE scrapes CW every 120s |
| Native Lambda metrics cost? | **$0** custom-metric charge — prefer for infra dashboard |
| What about ephemeral envs (40-min E2E)? | **~$0.04 total.** AWS bills custom metrics prorated by the hour. Billing stops ~3h after last datapoint. Data stays readable in CW for 15 months but is not billed. Ephemeral E2E environments are essentially free for EMF — cost concern applies only to persistent (24/7) environments |

### 0.10 Event taxonomy — what to emit when

| Event class | Example | DynamoDB row? | EMF metric |
|-------------|---------|---------------|------------|
| **Request complete** | `GET /health` → 200 | Audit maybe | `HttpRequestCount` + `HttpRequestDuration` |
| **Execution terminal** | `dispatched` → `succeeded` | ✅ | `ExecutionCount` + `ExecutionDuration` |
| **Rejection** | Cooldown 429, max concurrent | ❌ | `RejectionCount` — **not** execution terminal |
| **Pipeline tick** | Reconciler 60s, GC 5m | N/A | `ReconcilerDuration/Errors`, `GCDuration/Errors` |

**Terminal execution statuses** (`store.Status.IsTerminal()`): `succeeded`, `failed`, `timed_out`, `rejected`.  
**Non-terminal** (do not emit `ExecutionCount`): `dispatched`, `approved`, `pending_approval`.  
**Cooldown is a rejection**, not terminal — no execution record, emit `RejectionCount{reason=write_cooldown}`.

### 0.11 Registered TAs (current inventory)

| Action | Scope | Type | Mode | Targets |
|--------|-------|------|------|---------|
| `delete_pod` | kube-api | write | sync | RC, MC |
| `describe_eks_cluster` | aws-api | read | sync | RC, MC |
| `describe_vpc_endpoint` | aws-api | read | sync | RC, MC |
| `get_resource` | kube-api | read | sync | RC, MC |
| `get_secret` | kube-api | read | sync | RC, MC |
| `list_eks_clusters` | aws-api | read | sync | RC, MC |
| `list_vpc_endpoints` | aws-api | read | sync | RC, MC |
| `must_gather` | kube-api | read | **async** | RC, MC |
| `rollout_restart` | kube-api | write | sync | RC, MC |

---

## 1. Executive Summary

ZOA already emits **partial** CloudWatch EMF metrics from Go code, and the RC CloudWatch exporter (YACE) already scrapes **DynamoDB** tables that happen to include ZOA tables via a generic tag filter. What is **missing** is the end-to-end pipeline:

1. **Correct, low-cardinality business metrics** for TA execution (the current EMF has gaps and bugs).
2. **YACE configuration** for `AWS/Lambda`, `AWS/SQS` (DLQ), and the custom `ZOA` namespace — on **both RC and MC**.
3. **Two Grafana dashboards** following existing infra patterns (RDS/DynamoDB style).
4. **PrometheusRules** with Google SRE-style burn-rate alerts for what actually warrants paging.

Function URL (not API Gateway) means we **cannot** rely on `AWS/ApiGateway` metrics for ZOA HTTP health. Lambda native metrics + EMF cover the gap. EMF custom metrics have real cost (~$50–80/region/month at moderate traffic for 1 RC + 1 MC) — cardinality control is mandatory. There is no ZOA UI; Grafana serves as the operational dashboard until one exists; DynamoDB remains forensics source of truth.

---

## 2. Architecture Context

### 2.1 ZOA deployment topology (per region)

```
RC account                          MC account (×N)
├── DynamoDB (executions, audit)    ├── Lambda api  ({mc}-zoa-api)
├── S3 (artifacts)                  ├── Lambda worker ({mc}-zoa-worker)
├── Lambda api  ({rc}-zoa-api)      ├── SQS DLQ ({mc}-zoa-dlq)
├── Lambda worker ({rc}-zoa-worker) └── YACE → Prometheus → remote-write → RC Thanos
├── SQS DLQ ({rc}-zoa-dlq)
└── YACE → Prometheus → Thanos (local)
```

- **2 Lambdas per VPC** (api + worker), tagged `Component=zoa`, `HandlerMode=api|worker`, `Cluster={cluster_id}`.
- **Data plane** (DynamoDB, S3, KMS) lives in RC; MC Lambdas access via cross-account resource policies.
- **Metrics path:** MC Prometheus remote-writes to RC Thanos via RHOBS API Gateway. All Grafana dashboards run on RC and query Thanos with `cluster` / `cluster_type` labels.

### 2.2 Function URL vs API Gateway

| Signal | API Gateway path | ZOA Function URL path |
|--------|------------------|----------------------|
| HTTP 4xx/5xx at edge | `AWS/ApiGateway` 4XXError, 5XXError | **Not available** |
| Request count / latency at edge | `AWS/ApiGateway` Count, Latency | **Not available** |
| Invocation errors | — | `AWS/Lambda` Errors (includes unhandled exceptions, timeouts) |
| Invocation duration | — | `AWS/Lambda` Duration |
| Throttles / concurrency | — | `AWS/Lambda` Throttles, ConcurrentExecutions |
| Per-route HTTP status | — | **EMF only** (must implement correctly) |
| Per-TA business outcomes | — | **EMF only** |

**Implication:** EMF HTTP metrics are not optional polish — they are the only way to distinguish 4xx (client/cooldown) from 5xx (server) at the application layer.

### 2.3 Ephemeral Lambda and aggregation

Lambda containers are ephemeral, but **CloudWatch aggregates across all invocations** automatically. YACE pulls pre-aggregated statistics (Sum, Average, p99) from CloudWatch; Prometheus `rate()` / `increase()` over those series works across cold starts and concurrent executions.

**No special aggregation code is needed in Go** beyond emitting EMF with stable, low-cardinality dimensions. The anti-pattern to avoid is high-cardinality dimensions (execution IDs, full URL paths with UUIDs) that explode CloudWatch custom metric cost and make PromQL unusable.

### 2.4 Three observability planes — DynamoDB vs EMF vs Grafana (Google SRE)

ZOA has no UI today. Grafana fills the **operational dashboard** gap. A future UI would read **DynamoDB** for drill-down. These are complementary — not duplicates — if each layer does what it is best at.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  FUTURE ZOA UI (not in scope)                                          │
│  Source: DynamoDB executions + audit tables, S3 artifacts               │
│  Use: per-run detail, operator, jira, params, output links, search      │
└─────────────────────────────────────────────────────────────────────────┘
                                    ▲
                          drill-down from alert / dashboard
                                    │
┌───────────────────────────────────┴───────────────────────────────────┐
│  GRAFANA (RC, via Thanos) — ship now                                    │
│  Source: Prometheus metrics (YACE → CW native + EMF custom)             │
│  Use: SLIs/SLOs, trends, per-action rates, per-cluster health, alerts   │
└─────────────────────────────────────────────────────────────────────────┘
                                    ▲
                          YACE scrape (120s) + MC remote-write
                                    │
┌───────────────────────────────────┴───────────────────────────────────┐
│  EMF (ZOA namespace) + native AWS/Lambda/SQS/DynamoDB CW metrics        │
│  Emitted at: request complete, execution terminal, rejection, pipeline  │
└─────────────────────────────────────────────────────────────────────────┘
                                    ▲
                          written at event time
                                    │
┌───────────────────────────────────┴───────────────────────────────────┐
│  DYNAMODB executions table — system of record                           │
│  Fields: action, scope, type, mode, status, operator, jira, params…   │
│  CW metrics on table: throttles, latency, capacity ONLY (no TA dims)  │
└─────────────────────────────────────────────────────────────────────────┘
```

**Google SRE framing:**

| SRE concept | ZOA implementation |
|-------------|-------------------|
| **SLIs** (aggregated rates, latency percentiles) | EMF `ExecutionCount`, `ExecutionDuration`, `HttpRequestCount` + native `aws_lambda_*` |
| **SLOs & error budgets** | Prometheus recording rules + burn-rate alerts on Thanos (RC) |
| **Alerting** | PrometheusRules → Alertmanager (RC only) |
| **Debugging / audit** | DynamoDB + CloudWatch Logs + CLI (`zoa runs`, `zoa audit`) |
| **Dashboards** | Grafana now; future UI for run explorer does not replace Grafana for SRE |

**Should Action, Scope, Type be in EMF or only in DynamoDB?**

| Field | DynamoDB | EMF | DynamoDB CW metrics |
|-------|----------|-----|---------------------|
| `action`, `scope`, `type`, `mode`, `status` | ✅ source of truth per run | ✅ **yes** — as low-cardinality dimensions on `ExecutionCount` | ❌ impossible |
| `operator`, `jira`, `params`, `execution_id` | ✅ | ❌ never — unbounded cardinality | ❌ |
| Table throttles, read latency | N/A | ❌ | ✅ already scraped |

**Verdict:** Put **Action, Scope, Type, Mode, Status** in **EMF** (aggregatable SLI dimensions). DynamoDB remains the authoritative store for individual runs; Grafana shows **rates and trends** until a UI exists. When a UI ships, it queries DynamoDB for detail — Grafana panels for SLI trends remain valid (same split as any service: metrics for ops, DB for forensics).

**Not duplicate:** Grafana does not "re-read DynamoDB" — it reads time-series from Prometheus. A future UI and Grafana serve different questions ("show me run abc-123" vs "is must_gather failing more this week?").

### 2.5 Cost, cardinality & retention

#### What you pay for

| Component | Billing model | Notes |
|-----------|---------------|-------|
| **Native `AWS/Lambda`** (Errors, Duration, Invocations, Throttles) | **Included with Lambda** — not custom-metric priced | Use for infra dashboard; prefer over EMF for handler mode |
| **Native `AWS/SQS`** (DLQ depth) | Standard CW metric pricing | Cheap; essential for paging |
| **Native `AWS/DynamoDB`** (throttles, latency) | Standard CW metric pricing | Already scraped; infra only |
| **EMF → `ZOA` custom namespace** | **Custom metric charges** — each unique `(metric_name + dimension values)` = one billable series/month | Cardinality control is a cost control |
| **CloudWatch Logs** (EMF lines on stdout) | Log ingestion + storage per GB | Small for JSON EMF lines; still non-zero |
| **YACE `GetMetricData`** | Per-metric API request charges | Ongoing while scraping; not one-time |
| **Prometheus / Thanos** | Our infra (S3, compute) | After scrape, **this** is what Grafana queries — not CW directly |

**EMF is not "free except queries."** Publishing EMF creates **custom CloudWatch metrics** you pay to store (~$0.30/metric-month for first 10k, AWS pricing). YACE then pays again to **read** them via `GetMetricData`.

#### Retention — where data lives how long

| Store | Retention | Who queries it |
|-------|-----------|----------------|
| **CloudWatch custom metrics (EMF)** | **15 months** (AWS default for custom metrics) | YACE (every 120s) |
| **CloudWatch native Lambda/SQS metrics** | **15 months** | YACE |
| **CloudWatch Logs (EMF raw lines)** | 365 days (ZOA Lambda log groups, per terraform) | CW Insights / forensics |
| **Prometheus local (RC/MC)** | 14 days | — |
| **Thanos S3** | 90d raw → 180d 5m → 365d 1h downsampled | **Grafana + alerts** |

**Practical implication:** Once YACE scrapes EMF into Prometheus/Thanos, **Grafana and alerts use Thanos retention**, not CloudWatch. CW 15-month retention matters for (a) YACE backfill if scrape gap, (b) AWS Console debugging. We still minimize EMF series count because **CW bills per series regardless of whether we query it often**.

#### Cardinality budget (target)

| Dimension | Include? | Max values (order of) |
|-----------|----------|----------------------|
| `Cluster` | ✅ | 1 per Lambda deployment |
| `Action` | ✅ | ~20 TAs |
| `Scope` | ✅ | 2 |
| `Type` | ✅ | 2 |
| `Mode` | ✅ | 2 |
| `Status` | ✅ | 3 (succeeded, failed, timed_out) |
| `RouteTemplate` | ✅ | ~10 HTTP patterns |
| `StatusClass` | ✅ | 4 |
| `Reason` (rejections) | ✅ | ~5 |
| `Operator`, `Jira`, `ExecutionID`, raw URL | ❌ | unbounded |

Estimated active EMF series per cluster: low hundreds (sparse — most Action×Status combos empty). Acceptable if we fix the current `Route` UUID bug.

**Cost strategy:** Native CW for Lambda/SQS infra (free/cheap) → EMF only for business SLIs HTTP + executions + rejections + pipeline.

#### Worked example — 1 region, 1 RC + 1 MC, 9 TAs today

**Assumptions (current codebase, Mar 2026):**

- **9 registered TAs** (`delete_pod`, `describe_eks_cluster`, `describe_vpc_endpoint`, `get_resource`, `get_secret`, `list_eks_clusters`, `list_vpc_endpoints`, `must_gather`, `rollout_restart`)
- **2 ZOA deployments** per region (RC Lambda pair + MC Lambda pair) → 2 distinct `Cluster` dimension values
- **Moderate SRE usage** (not production fleet scale): ~50 TA runs/day/deployment, ~200 HTTP requests/day, reconciler/GC on schedule
- **AWS pricing (us-east-1, indicative):** custom metrics **$0.30/metric-month** (first 10k), logs **$0.50/GB** ingested, `GetMetricData` **~$0.01/1k metrics** requested
- CW only bills custom metric **series that received at least one datapoint** in the month (no charge for unused dimension combos)

**EMF metric names (plan as written):** ~12 distinct names  
(`ExecutionCount`, `ExecutionDuration`, `HttpRequestCount`, `HttpRequestDuration`, `RejectionCount`, `ReconcilerDuration`, `ReconcilerErrors`, `GCDuration`, `GCErrors`, `GCCleanedResources`, `CircuitBreakerStateChange`, plus optional `WorkerDuration`/`WorkerErrors`)

| Scenario | Active CW custom series (EMF) | EMF storage $/month | CW Logs (EMF lines) | YACE GetMetricData (2 exporters) | **EMF observability total** |
|----------|-------------------------------|---------------------|---------------------|----------------------------------|----------------------------|
| **Low traffic** (ephemeral dev) | ~50–70/deployment → **~100–140/region** | 120 × $0.30 = **~$36** | ~100 MB → **$0.05** | ~**$2–5** | **~$38–41/region** |
| **Moderate** (active SRE testing) | ~90–120/deployment → **~180–240/region** | 210 × $0.30 = **~$63** | ~250 MB → **$0.13** | ~**$5–8** | **~$68–71/region** |
| **Worst-case cardinality** (all dimension combos ever emitted) | ~480/deployment → **~960/region** | 960 × $0.30 = **$288** | (same) | ~**$10–15** | **~$300/region** |

> **Why lower than original estimates:** Most Action×Status dimension combos are sparse. 7/9 TAs are sync+read → only ~2 statuses active per TA (succeeded, failed). Most HTTP routes only see 2xx. CW only bills series that received at least one datapoint in the billing hour.

**What is NOT in that table (free or already paid):**

| Item | Cost |
|------|------|
| Native `AWS/Lambda` + `AWS/SQS` (infra dashboard) | **$0** custom-metric charge |
| DynamoDB CW metrics (already scraped) | ~$0 incremental (few tables) |
| Lambda compute, DynamoDB, S3 (existing ZOA estimate) | **< $12/VPC** per `zoa-architecture.md` → **~$24/region** for RC+MC |

**All-in observability increment (RC+MC region):** roughly **+$38–71/month** at low-to-moderate traffic on top of existing ~$24 ZOA infra — **EMF custom metrics dominate** the new cost, not YACE queries or logs.

**Ephemeral environments:** A 40-minute E2E run creating ~100 EMF series costs **~$0.04** (prorated by the hour; billing stops ~3h after last datapoint). No ongoing charges after env destruction.

**If $50+/region is too high — optimizations (same plan, smaller bill):**

| Change | Series saved | Est. new EMF $/region (moderate) |
|--------|--------------|----------------------------------|
| Drop `Scope` + `Type` from `ExecutionCount` (derivable from Action) | ~30% execution series | **~$55** |
| HTTP: `RouteTemplate` → 5 coarse buckets (`run`, `runs`, `audit`, `health`, `other`) | ~50% HTTP series | **~$45** |
| Omit `WorkerDuration`/`WorkerErrors` (use native Lambda Duration/Errors) | ~6 series/deployment | **~$42** |
| **Combined optimizations** | | **~$25–35/region** |

**Recommendation:** Ship with full dimension set in ephemeral, **measure actual series** in CW console (`ZOA` namespace → browse metrics), then trim dimensions if monthly bill exceeds budget. Target **< $30/region** for dev/ephemeral.

### 2.6 Label contract — RC, MC, and per-cluster alerts

Thanos runs **only on RC**. MC metrics arrive via Prometheus `remoteWrite` → RHOBS API Gateway → Thanos Receive.

**Prometheus external labels** (already configured):

| Cluster | `cluster` label | `cluster_type` label |
|---------|-----------------|----------------------|
| RC | `{regional_id}` e.g. `eph-abc-regional` | `regional` |
| MC | `{mc_id}` e.g. `eph-abc-mc01` | `management` |

**YACE adds** on AWS resources: `dimension_FunctionName`, `tag_HandlerMode` (`api`|`worker`), `tag_Cluster`, `tag_Component=zoa`.

**Lambda api vs worker — no EMF needed for infra:**

- `dimension_FunctionName` suffix: `*-zoa-api` vs `*-zoa-worker`
- `tag_HandlerMode`: `api` | `worker`

**Alert rule contract** — every ZOA alert that can fire per deployment MUST:

1. Use `sum by (cluster, ...)` (or equivalent) so **mc05 broken / mc01 fine** pages with `cluster=eph-abc-mc05` in labels.
2. Include `cluster` in alert labels for routing/triage.
3. Scope to ZOA resources: `tag_Component="zoa"` or `dimension_FunctionName=~".*-zoa-(api|worker)"`.

**promtool tests** — hyperfleet already has CI coverage:

| Existing test file | Covers |
|--------------------|--------|
| `ci/promtool-test/hcp-sla-rules_test.yaml` | HCP SLA burn-rate |
| `ci/promtool-test/ratelimit-rules_test.yaml` | Rate limit alerts |
| `ci/promtool-test/remote-write-health_test.yaml` | Per-MC remote-write |

Run: `make promtool-test` (included in `make pre-push`). ZOA adds `ci/promtool-test/zoa-rules_test.yaml` with synthetic series for **two clusters** (`mc-01` healthy, `mc-05` failing) to prove per-cluster alert isolation.

---

## 3. Current State — `rosa-hyperfleet-zoa`

### 3.1 EMF infrastructure (`pkg/metrics/`)

| File | Purpose |
|------|---------|
| `emf.go` | JSON EMF to stdout; namespace `ZOA`; helpers `Count`, `Milliseconds`, `Seconds`, `Bytes` |
| `middleware.go` | `HTTPMetrics()` middleware — **exists but is not wired anywhere** |

No unit tests for EMF output format or dimension cardinality.

### 3.2 EMF emission points today

| Location | Trigger | Metrics | Dimensions | Issues |
|----------|---------|---------|------------|--------|
| `handler.handleHTTPEvent` | Every Function URL request | RequestDuration, RequestCount, ServerErrors (5xx) | Cluster, HandlerMode=api, Method | **Duplicates** router metrics; Method-only is OK |
| `api.Handler.ServeHTTP` (router) | Every HTTP handler request | RequestDuration, RequestCount, ErrorCount (≥400) | Cluster, **Route=full path** | **Cardinality bomb** (`Route` includes execution UUIDs). **Double-counts** with handler layer |
| `scheduler.Run` (reconciler) | EventBridge 1min tick | ReconcilerDuration, ReconcilerErrors | Cluster, HandlerMode=reconciler | Good; errors also surface as Lambda Errors |
| `scheduler.RunGC` | EventBridge 5min tick | GCDuration, GCErrors | Cluster, HandlerMode=gc | Good; missing **items cleaned count** |
| `handler.handleScheduledEvent` | Worker scheduled routes | WorkerDuration, WorkerErrors | Cluster, HandlerMode=worker, Route | Good |
| `handler.handleExecutionEvent` | Worker self-invoke TA exec | ExecutionDuration, ExecutionErrors | Cluster, HandlerMode=worker, Route=execute | Missing **Action, Status, Mode** dimensions |

### 3.3 What is NOT instrumented

| Event | Why it matters |
|-------|----------------|
| TA dispatch (`handleCreate`) success/failure | Core SLI — Jira AC #1 |
| TA terminal status by action/mode | Per-action SLO, dashboard breakdown |
| Write cooldown rejection (429) | Operational signal (not page-worthy) |
| Max concurrent rejection (429) | Capacity signal |
| Circuit breaker open/half-open | Fast-fail protection — page if sustained |
| GC items cleaned (Jobs, SAs, pods) | Pipeline health |
| Async dispatch failures | Silent failures before worker picks up |
| Reconciler phase breakdown (dispatch, poll, timeout, gc) | Debug slow reconciler ticks |

### 3.4 Circuit breaker (`pkg/executor/circuit_breaker.go`)

- In-process only; trips after 3 EKS failures in 30s; opens for 60s.
- **No metric emission** today — cannot alert or dashboard.
- State is per Lambda container (not shared across concurrent executions). Acceptable for alerting on "this target's Lambda is fast-failing" but not global fleet state.

**Per-container behavior (important for dashboard interpretation):** Lambda auto-scales by spinning up multiple containers concurrently. Each container has its own independent circuit breaker (`sync.Mutex`). They don't share state:

```
Container A:  EKS call fails → fails → fails 3rd time → breaker OPENS → emits state=open
Container B:  (concurrent) EKS calls succeeding → breaker CLOSED → TAs work fine
Container C:  (new cold start) fresh breaker → CLOSED → TAs work fine
```

In Grafana you may see `CircuitBreakerStateChange{state=open}` at the same time as successful `ExecutionCount{status=succeeded}`. This is not contradictory — different containers. The metric still tells you "at least one container is having trouble reaching EKS." Dashboard panel should note this.

### 3.5 DynamoDB as observability source

Executions table is queryable via CLI (`zoa runs --status failed`). Useful for forensics, **not** a substitute for metrics (no continuous SLI, no alerting integration).

---

## 4. Current State — `rosa-hyperfleet`

### 4.1 CloudWatch Exporter (YACE)

**RC** (`argocd/config/regional-cluster/cloudwatch-exporter/values.yaml`):

| Namespace | Scraped? | ZOA relevance |
|-----------|----------|---------------|
| `AWS/EKS` | ✅ static | EKS health (host cluster, not ZOA-specific) |
| `AWS/ApiGateway` | ✅ discovery | Platform API / RHOBS — **not ZOA** |
| `AWS/RDS` | ✅ discovery | hyperfleet-db |
| `AWS/ApplicationELB` | ✅ discovery | API ALB |
| `AWS/DynamoDB` | ✅ discovery (`Name: ^{cluster}-`) | **Includes ZOA tables** (`{regional_id}-zoa-executions`, `{regional_id}-zoa-audit-log`) if `regional_id == cluster_name` |
| `AWS/CertificateManager` | ✅ discovery | API cert |
| `AWS/Lambda` | ❌ | **Needed** |
| `AWS/SQS` | ❌ | **Needed** (DLQ) |
| `ZOA` (EMF custom) | ❌ | **Needed** |

**MC** (`argocd/config/management-cluster/cloudwatch-exporter/values.yaml`):

- Only `AWS/EKS` static metrics. **No Lambda, SQS, or ZOA namespace.**

### 4.2 IAM for YACE (`terraform/modules/cloudwatch-exporter/iam.tf`)

Current permissions: CloudWatch read, tag discovery, API Gateway, RDS, ELB, IAM aliases.

**Missing for Lambda/SQS discovery** (YACE needs these for tag-based auto-discovery):

- `lambda:ListFunctions`, `lambda:ListTags`
- `sqs:ListQueues`, `sqs:ListQueueTags` (or `sqs:GetQueueAttributes` via tag API)

### 4.3 Grafana dashboards

Existing infra dashboards (pattern to follow):

- `grafana/dashboards/infrastructure/rds.json` — stat rows + time series, `$datasource` + resource variable
- `grafana/dashboards/infrastructure/dynamodb.json` — health stats (throttles, errors), capacity, latency

**No Lambda or ZOA dashboards exist.**

ZOA DynamoDB metrics may appear in the generic DynamoDB dashboard (table variable includes `*-zoa-*` tables) but there is no ZOA-specific view.

### 4.4 Alerting rules

Existing patterns:

- `hcp-sla.yaml` — multi-window burn rate (Google SRE workbook)
- `ratelimit.yaml` — ratio-based warnings
- `remote-write-health.yaml` — MC metrics pipeline health

**No ZOA rules.** `docs/adding-alerting-rules.md` documents promtool unit tests in `ci/promtool-test/`.

### 4.5 Documentation accuracy

`docs/design/zoa-architecture.md` Monitoring table marks business metrics as "Available" and CW Exporter as "**Planned**" — accurate. The Jira ticket description is largely aligned but was written as a placeholder; this plan refines scope (see §8).

---

## 5. Target Metric Model

### 5.1 Metric layers (avoid duplication)

```
┌─────────────────────────────────────────────────────────────┐
│  ZOA Dashboard (unified service / SRE)                       │
│  - TA success rate, duration by action                      │
│  - Cooldown/concurrency rejections                          │
│  - Reconciler/GC pipeline health                            │
│  - Links to infra dashboard panels (not re-query)           │
└──────────────────────────┬──────────────────────────────────┘
                           │ references
┌──────────────────────────▼──────────────────────────────────┐
│  Lambda Infrastructure Dashboard (AWS service health)       │
│  - aws_lambda_* (Errors, Throttles, Duration, Invocations)  │
│  - aws_sqs_* (DLQ depth, message age)                       │
│  - Filtered: Component=zoa or *-zoa-{api,worker}              │
│  - Variables: cluster, function_name, handler_mode            │
└─────────────────────────────────────────────────────────────┘
```

**Rule:** Lambda/SQS/DynamoDB **infra metrics** live in the infra dashboard only. The ZOA dashboard uses **EMF `ZOA` namespace** for business metrics and **dashboard links** or **shared template variables** for infra context — not duplicate panels.

### 5.2 Proposed EMF metrics (namespace `ZOA`)

#### HTTP layer (API Lambda only)

Emit **once** per request (remove duplicate handler+router emission):

| Metric | Unit | Dimensions | Notes |
|--------|------|------------|-------|
| `HttpRequestCount` | Count | Cluster, HandlerMode, Method, RouteTemplate, StatusClass | StatusClass = `2xx\|3xx\|4xx\|5xx` |
| `HttpRequestDuration` | Milliseconds | Cluster, HandlerMode, Method, RouteTemplate, StatusClass | StatusClass included for consistency — allows querying "p99 latency of 5xx vs 2xx" |

**Route normalization** (replace path params):

| Raw path | RouteTemplate |
|----------|---------------|
| `POST /api/v0/trusted-actions/get_pods/run` | `POST /api/v0/trusted-actions/{action}/run` |
| `GET /api/v0/trusted-actions/runs/abc-123` | `GET /api/v0/trusted-actions/runs/{id}` |
| `GET /health` | `GET /health` |

Implement via a small `NormalizeRoute(method, path) string` using the mux patterns or a static map.

#### Event taxonomy — what to emit when

Three distinct event classes. **Do not conflate them.**

| Class | Definition | DynamoDB record? | When to emit EMF | Example |
|-------|------------|------------------|------------------|---------|
| **Request complete** | HTTP response sent | May exist (audit) | End of `router.ServeHTTP` | `GET /health` → 200 |
| **Execution terminal** | Execution reached final status in store | ✅ always | On transition to terminal status | `dispatched` → `succeeded` |
| **Rejection** | Request denied before/during dispatch; no terminal execution | ❌ usually none | Immediately at reject | Cooldown 429 |

**Execution terminal statuses** (`store.Status.IsTerminal()`):

| Status | Terminal? | Emit `ExecutionCount`? | Notes |
|--------|-----------|------------------------|-------|
| `succeeded` | ✅ | ✅ status=succeeded | Happy path |
| `failed` | ✅ | ✅ status=failed | TA or infra error |
| `timed_out` | ✅ | ✅ status=timed_out | Deadline exceeded |
| `rejected` | ✅ | ✅ status=rejected | Approval workflow (future) |
| `dispatched` | ❌ | ❌ | In-flight; async waiting for worker |
| `approved` | ❌ | ❌ | Waiting for reconciler |
| `pending_approval` | ❌ | ❌ | Future approval flow |

**Cooldown rejection is NOT terminal.** No execution row is created (or request fails before `Create`). It is a **rejection** → emit `RejectionCount{reason=write_cooldown}` + `HttpRequestCount{statusclass=4xx}`. Same for `max_concurrent`, `validation_failed`, `circuit_breaker_open`.

**Async path:** emit `ExecutionCount` when worker transitions `dispatched` → `succeeded|failed|timed_out` in `runDispatchedExecution`. Sync path: emit in `executeSyncAndRespond` after transition.

**Dispatch accepted (async):** optional `ExecutionDispatchCount{result=accepted}` when record created and async resources dispatched — low volume, useful for "accepted but not yet finished" gap. Not required for v1.

#### TA execution (core business metrics)

Emit on **execution terminal transition** only (see table above):

| Metric | Unit | Dimensions | Notes |
|--------|------|------------|-------|
| `ExecutionCount` | Count | Cluster, Action, Status, Mode, Scope, Type | Status = succeeded\|failed\|timed_out\|rejected |
| `ExecutionDuration` | Milliseconds | Cluster, Action, Status, Mode | TA work duration; omit on instant failures with 0ms if not meaningful |

**Scope and Type come from `store.Execution` / action metadata** — duplicated in DynamoDB as source of truth, **re-emitted in EMF** for time-series aggregation (see §2.4).

#### Rejections (not execution terminal)

| Metric | Unit | Dimensions |
|--------|------|------------|
| `RejectionCount` | Count | Cluster, Reason |

Reason values: `write_cooldown`, `max_concurrent`, `validation_failed`, `circuit_breaker_open`, `action_not_found`.

#### Worker pipeline

| Metric | Unit | Dimensions | Notes |
|--------|------|------------|-------|
| `ReconcilerDuration` | Milliseconds | Cluster | Keep existing |
| `ReconcilerErrors` | Count | Cluster | Keep existing |
| `GCDuration` | Milliseconds | Cluster | Keep existing |
| `GCErrors` | Count | Cluster | Keep existing |
| `GCCleanedResources` | Count | Cluster, ResourceType | ResourceType = job\|sa\|role\|pod |
| `CircuitBreakerStateChange` | Count | Cluster, State | State = open\|half_open\|closed |

#### Deprecate / remove

| Current | Action |
|---------|--------|
| `handler.handleHTTPEvent` EMF block | Remove — router is authoritative |
| `RequestCount` / `ErrorCount` / `ServerErrors` (old names) | Replace with `HttpRequestCount` + StatusClass |
| `Route` dimension with raw path | **Remove** — replaced by RouteTemplate |
| `HTTPMetrics` middleware | Either wire it (replacing router emission) or delete dead code |
| `ExecutionErrors` (worker only, no action dim) | Replace with `ExecutionCount{status=failed}` |
| `ExecutionDispatchCount` | **Defer to v2** — optional; not needed for initial SLIs |

### 5.3 Lambda native metrics — api vs worker (no EMF duplication)

YACE discovers Lambdas with `Component=zoa`. Infra dashboard and alerts use:

| Signal | Source | Label to split api/worker |
|--------|--------|---------------------------|
| Errors, Duration, Throttles, Invocations | `aws_lambda_*` | `tag_HandlerMode` or `dimension_FunctionName=~".*-zoa-api"` |
| DLQ depth | `aws_sqs_*` | Queue name `*-zoa-dlq` (shared per deployment, not per handler) |

Do **not** emit `HandlerMode` in EMF for signals already available on `aws_lambda_*`.

### 5.4 YACE — CloudWatch namespaces to add

#### Discovery job: `AWS/Lambda`

```yaml
- type: lambda
  regions: [<aws_region>]
  searchTags:
    - key: Component
      value: zoa
  period: 120
  length: 120
  delay: 120
  metrics:
    - name: Invocations
      statistics: [Sum]
    - name: Errors
      statistics: [Sum]
    - name: Throttles
      statistics: [Sum]
    - name: Duration
      statistics: [Average, p99]
    - name: ConcurrentExecutions
      statistics: [Maximum]
```

Prometheus names (YACE convention): `aws_lambda_invocations_sum`, `aws_lambda_errors_sum`, `aws_lambda_duration_p99`, etc.
Dimension: `dimension_FunctionName` → `{cluster}-zoa-api`, `{cluster}-zoa-worker`.

#### Discovery job: `AWS/SQS` (DLQ only)

```yaml
- type: sqs
  regions: [<aws_region>]
  searchTags:
    - key: Component
      value: zoa
  period: 120
  length: 120
  delay: 120
  metrics:
    - name: ApproximateNumberOfMessagesVisible
      statistics: [Maximum]
    - name: ApproximateAgeOfOldestMessage
      statistics: [Maximum]
```

Filter to `*-dlq` queues in Grafana if other SQS resources ever get `Component=zoa`.

#### Discovery job: custom namespace `ZOA`

```yaml
- type: customNamespace
  namespace: ZOA
  regions: [<aws_region>]
  period: 120
  length: 120
  delay: 120
  metrics:
    - name: ExecutionCount
      statistics: [Sum]
    - name: ExecutionDuration
      statistics: [Average, p99]
    - name: HttpRequestCount
      statistics: [Sum]
    - name: HttpRequestDuration
      statistics: [Average, p99]
    - name: RejectionCount
      statistics: [Sum]
    - name: ReconcilerErrors
      statistics: [Sum]
    - name: GCErrors
      statistics: [Sum]
    - name: GCCleanedResources
      statistics: [Sum]
    - name: CircuitBreakerStateChange
      statistics: [Sum]
```

YACE discovers dimension combinations via `ListMetrics`. After EMF ships with stable dimensions, verify actual Prometheus metric names in a dev environment before finalizing dashboard queries.

**RC and MC:** identical discovery blocks; each YACE instance only sees resources in its AWS account. MC metrics arrive in Thanos via remote-write with `cluster={mc_id}` label.

#### DynamoDB — no change required

ZOA tables are already scraped if table `Name` tag matches `^{cluster_name}-`. Add a **filtered row** in the ZOA dashboard (not a new scrape config) for `dimension_TableName=~".*zoa.*"`.

---

## 6. Grafana Dashboards

### 6.1 Dashboard: `Lambda` — infrastructure

**File:** `argocd/config/regional-cluster/grafana/dashboards/infrastructure/lambda-zoa.json`
**Template:** `grafana/templates/dashboards/dashboard-lambda-zoa.yaml`
**Sidecar folder:** `Infrastructure` (alongside RDS, DynamoDB)

**Variables:**

| Variable | Source |
|----------|--------|
| `datasource` | Prometheus/Thanos |
| `cluster` | `label_values(aws_lambda_invocations_sum{tag_Component="zoa"}, tag_Cluster)` or `dimension_FunctionName` prefix |
| `function` | api / worker |

**Panel groups (match RDS/DynamoDB style):**

1. **Health overview** (stat row, red thresholds)
   - Error rate: `sum(rate(aws_lambda_errors_sum{...}[5m])) / sum(rate(aws_lambda_invocations_sum{...}[5m]))`
   - Throttles (sum)
   - DLQ depth: `aws_sqs_approximate_number_of_messages_visible_maximum{name=~".*-zoa-dlq"}`
   - DLQ oldest message age

2. **Invocations & errors** (time series)
   - Invocations by function
   - Errors by function

3. **Latency** (time series)
   - Duration p99 by function
   - Duration avg by function

4. **Concurrency** (time series)
   - ConcurrentExecutions max

5. **DLQ detail** (time series + stat)
   - Messages visible, age of oldest

**Scope:** RC + MC (Thanos global query). MC series distinguished by `cluster` external label.

### 6.2 Dashboard: `ZOA` — unified service dashboard

**File:** `argocd/config/regional-cluster/grafana/dashboards/zoa/zoa-operations.json`
**Template:** `grafana/templates/dashboards/dashboard-zoa-operations.yaml`
**Sidecar folder:** `ZOA` (new folder — keeps business view separate from infra)

**Variables:** `datasource`, `cluster`, `action` (from EMF Action dimension)

**Panel groups:**

1. **SLO overview** (stat row)
   - TA success rate (5m): `sum(rate(zoa_execution_count_sum{status="succeeded"}[5m])) / sum(rate(zoa_execution_count_sum[5m]))`
   - Executions/min
   - P99 execution duration
   - Active rejections/min (cooldown + concurrent)

2. **Executions** (time series)
   - Rate by action, stacked by status
   - P99 duration by action

3. **HTTP API health** (time series) — replaces missing API GW metrics
   - Request rate by RouteTemplate
   - 5xx rate
   - 4xx rate (includes cooldown — annotate as expected)
   - P99 HttpRequestDuration

4. **Worker pipeline** (time series)
   - Reconciler duration / errors
   - GC duration / errors / cleaned resources
   - Circuit breaker opens (panel tooltip: "Circuit breaker is per Lambda container, not global. Multiple concurrent containers may show mixed state — open in one, closed in another. A single state=open event means at least one container is having trouble reaching EKS.")

5. **Data layer** (time series, filtered DynamoDB)
   - ZOA table throttles, latency, consumed capacity
   - Link: "View in DynamoDB dashboard" (Grafana dashboard link)

6. **Infrastructure context** (row with dashboard links)
   - Link to `Lambda` dashboard with cluster variable passed
   - Do **not** duplicate Lambda panels here

---

## 7. Alerting Rules (Google SRE perspective)

### 7.1 What warrants paging vs ticket

| Alert | Severity | Rationale |
|-------|----------|-----------|
| DLQ messages > 0 for 5m | **critical** | Dead-lettered invocations = lost reconciler/execution work; 5m `for` filters transient single-tick failures (e.g., one reconciler tick dropped) — only pages when messages persist |
| Worker Lambda error rate > 1% for 10m | **critical** | Reconciler/GC/execution pipeline broken; TAs stall |
| No worker invocations for 5m (reconciler schedule) | **critical** | EventBridge or Lambda failure; silent pipeline stop |
| API Lambda 5xx rate > 5% for 10m (fast burn) | **warning** | SRE cannot execute TAs via CLI |
| TA failure rate > 10% for 30m (slow burn) | **warning** | Elevated operational failures — may be target cluster issue |
| Lambda throttles > 0 for 10m | **warning** | Concurrency saturation |
| DynamoDB throttles on zoa tables | **warning** | Data layer pressure |
| GC errors > 0 for 15m | **warning** | Resource leak risk |
| Circuit breaker open events | **warning** | EKS API unreachable from ZOA |
| Cooldown rejections | **none** | Expected safety behavior |
| Single TA failure | **none** | Noise — use logs/CLI |

### 7.2 Proposed PrometheusRule groups

**File:** `argocd/config/regional-cluster/alerting-rules/templates/zoa.yaml`

#### Recording rules (SLI prep)

```promql
# TA success rate — per cluster and action (mc05 vs mc01, must_gather vs get_pods)
zoa:ta_success_rate:5m =
  sum by (cluster, action) (rate(zoa_execution_count_sum{status="succeeded"}[5m]))
  / sum by (cluster, action) (rate(zoa_execution_count_sum[5m]))

# API availability SLI (5m rate, 5xx only — Function URL has no API GW)
# Aggregate FIRST (sum 5xx, sum total), THEN compute ratio — standard SRE Workbook SLI pattern
zoa:api_availability:5m =
  1 - (
    sum by (cluster) (rate(zoa_http_request_count_sum{statusclass="5xx"}[5m]))
    / sum by (cluster) (rate(zoa_http_request_count_sum[5m]))
  )

# Worker Lambda error rate — per cluster
zoa:worker_error_rate:5m =
  sum by (cluster) (rate(aws_lambda_errors_sum{dimension_FunctionName=~".*-zoa-worker", tag_Component="zoa"}[5m]))
  / sum by (cluster) (rate(aws_lambda_invocations_sum{dimension_FunctionName=~".*-zoa-worker", tag_Component="zoa"}[5m]))

# Reconciler last-seen timestamp — per cluster (for absent detection)
# timestamp() records when the metric was last updated; if gap > 300s → reconciler stopped
zoa:worker_last_invocation_timestamp =
  max by (cluster) (
    timestamp(aws_lambda_invocations_sum{dimension_FunctionName=~".*-zoa-worker", tag_Component="zoa"})
  )
```

#### Alerts

All alerts evaluated on **RC Thanos Ruler**; labels must include `cluster` for MC isolation.

| Alert | Expr sketch | `for` |
|-------|-------------|-------|
| `ZOADLQMessagesVisible` | `sum by (cluster) (aws_sqs_approximate_number_of_messages_visible_maximum{name=~".*-zoa-dlq"}) > 0` | 5m |
| `ZOAWorkerLambdaErrorRateHigh` | `zoa:worker_error_rate:5m > 0.01` | 10m |
| `ZOAReconcilerNotRunning` | `(time() - zoa:worker_last_invocation_timestamp) > 300` | 5m |
| `ZOAApiErrorBudgetFastBurn` | Multi-window on `zoa:api_availability:5m` (14.4× burn) | 5m |
| `ZOATAFailureRateHigh` | `zoa:ta_success_rate:5m < 0.90` | 30m |
| `ZOALambdaThrottled` | `increase(aws_lambda_throttles_sum{...}[10m]) > 0` | 10m |
| `ZOADynamoDBThrottled` | `increase(aws_dynamodb_throttled_requests_sum{dimension_TableName=~".*zoa.*"}[10m]) > 0` | 5m |
| `ZOAGCErrors` | `increase(zoa_gc_errors_sum[15m]) > 0` | 15m |

**MC coverage:** All rate/error alerts use `sum by (cluster, ...)`. Alert template includes `{{ $labels.cluster }}` in description. For envs without MC ZOA, only series with `tag_Component="zoa"` exist — no false positives on empty label sets.

#### promtool tests

Add `ci/promtool-test/zoa-rules_test.yaml` (matches existing `*_rules_test.yaml` convention):

- **DLQ alert:** series with `cluster=mc-05`, messages > 0 sustained for 5m → alert fires for mc-05 only
- **Worker error rate:** mc-05 errors elevated, mc-01 healthy → alert labels `cluster=mc-05`
- **Reconciler not running:** mc-05 last invocation > 300s ago, mc-01 recent → fires for mc-05 only
- **TA success rate:** `action=must_gather` failures → warning fires
- **Recording rules:** verify `zoa:ta_success_rate:5m`, `zoa:api_availability:5m` (aggregate-then-ratio), `zoa:worker_last_invocation_timestamp`

Runs in CI via `make promtool-test` / `make pre-push`.

### 7.3 SLO targets (proposed starting points — tune after baseline)

| SLI | Target | Window |
|-----|--------|--------|
| API availability (non-5xx) | 99% | 30d |
| TA success rate (excl. target failures) | 95% | 7d |
| Sync TA p99 latency | < 60s | — |
| DLQ depth | 0 | instantaneous |

---

## 8. Scope Refinement vs Jira ROSAENG-65234

| Jira item | Verdict | Notes |
|-----------|---------|-------|
| EMF for every TA execution | **Keep, refine** | Terminal-state emission with Action/Status/Mode dims |
| CW exporter scrapes ZOA namespace | **Keep** | Plus Lambda + SQS; RC **and** MC |
| Alert on sustained error rate | **Keep** | Split API vs worker vs TA; use burn-rate pattern |
| Grafana dashboard | **Keep, split into two** | Infra + Operations (Jira implied one) |
| DLQ depth alert | **Keep** | High-confidence page |
| Duration percentiles in EMF | **Partial** | CloudWatch computes p99 from EMF values; emit raw durations, let CW/YACE aggregate |
| "Cooldown rejections" metric | **Keep** | Ticket not page |
| "GC cleanup counts" | **Keep** | |
| API Gateway metrics | **Drop** | ZOA uses Function URL |
| "Circuit breaker state" in Jira | **Keep** | Not in original AC list but valuable |
| "Reconciler not firing" | **Keep** | Via Lambda invocation absent + EventBridge |
| Formal SLO/error budget docs | **Defer** | Recording rules + alerts first; document SLOs in `monitoring-platform.md` after baseline week |

---

## 9. Implementation Plan (ordered)

### Phase 1 — ZOA repo (`rosa-hyperfleet-zoa`)

1. Add `pkg/metrics/routes.go` — route normalization.
2. Refactor HTTP metrics: single emission point in `router.ServeHTTP`; remove `handler.handleHTTPEvent` duplicate.
3. Add `emitExecution(ctx, exec, status, durationMs)` helper; call from:
   - `dispatch.executeSyncAndRespond`
   - `handler.runDispatchedExecution` (worker)
   - Async failure paths in `handleCreate`
4. Add `RejectionCount` emissions in `dispatch.go` (cooldown, max_concurrent).
5. Add `GCCleanedResources` counter in `gc.go` (increment per cleaned resource).
6. Add circuit breaker EMF in `circuit_breaker.go` on state transitions.
7. Delete or wire `HTTPMetrics` middleware (prefer delete if router handles it).
8. **Unit tests (required for all Go changes)** — every new or modified Go file in Phase 1 must have matching `_test.go` coverage:
   - `pkg/metrics/routes_test.go` — `NormalizeRoute`, `StatusClass` table tests (UUID paths, action params, static routes)
   - `pkg/metrics/emf_test.go` — sorted dimension keys, valid EMF JSON structure, metric names/units
   - `pkg/metrics/execution_test.go` — `EmitExecution`, `EmitRejection`, `EmitHTTPRequest` dimension cardinality
   - `pkg/executor/circuit_breaker_test.go` — extend existing tests for state-change metric emission (capture stdout)
   - Update `pkg/api/dispatch_test.go` / `pkg/handler/handler_test.go` if metric side effects affect existing flows
   - Run `make test` before handoff; all tests use `"When ... it should ..."` naming

### Phase 2 — Hyperfleet repo (`rosa-hyperfleet`)

1. **IAM:** Add Lambda + SQS list/tag permissions to `cloudwatch-exporter` module.
2. **YACE RC:** Add Lambda, SQS, customNamespace `ZOA` jobs to `regional-cluster/cloudwatch-exporter/values.yaml`.
3. **YACE MC:** Same jobs in `management-cluster/cloudwatch-exporter/values.yaml`.
4. **Grafana:** Create `lambda-zoa.json` + `zoa-operations.json` + Helm templates.
5. **Alerting:** Create `alerting-rules/templates/zoa.yaml` + `ci/promtool-test/zoa-rules_test.yaml`.
6. **Docs:** Update `monitoring-platform.md` dashboard table; trim "Planned" from `zoa-architecture.md` monitoring section after ship.

### Phase 3 — Validation

1. Deploy to ephemeral RC (+ MC if available).
2. Run representative TAs (sync read, sync write, async, forced cooldown rejection).
3. Verify in CloudWatch Metrics console: `ZOA` namespace dimensions look correct.
4. Verify YACE `/metrics` endpoint exposes expected series.
5. Verify Grafana panels populate (allow 4–6 min for YACE scrape delay).
6. Fire promtool tests; optionally trigger DLQ alert in dev with a synthetic message.

### Phase 4 — PR strategy

| PR | Repo | Depends on |
|----|------|------------|
| EMF metrics fix + new emissions | `rosa-hyperfleet-zoa` | — |
| CW exporter + dashboards + alerts | `rosa-hyperfleet` | ZOA image deployed with new EMF (can merge hyperfleet first for Lambda/SQS; ZOA namespace panels populate after zoa deploy) |

---

## 10. Risks and Open Questions

| # | Risk / question | Mitigation |
|---|-----------------|------------|
| 1 | YACE `customNamespace` metric naming may differ from assumptions | Validate in dev before dashboard JSON is finalized |
| 2 | EMF dimension key order is unstable (`dimKeys` iterates map) | Sort dimension keys before emit (deterministic EMF) |
| 3 | High-cardinality `Action` dimension (~20 TAs) | Acceptable; do not add `Operator` or `ExecutionID` |
| 4 | MC ZOA not deployed in all envs | Alerts use `or vector(0)` / optional MC labels; no false pages |
| 5 | `feat/must-gather` branch diverged from origin | ZOA branch created from local `feat/must-gather`; rebase on PR #83 before final merge |
| 6 | Reconciler "not running" vs "no work" | Use timestamp-based recording rule (`zoa:worker_last_invocation_timestamp`); reconciler runs every 60s regardless — gap > 300s triggers alert with correct `cluster` label |
| 7 | Function URL streaming responses | Duration metric includes full stream time — correct for SLI |
| 8 | EMF custom metric cost at scale | Cardinality budget in §2.5; review CW bill after 2 weeks in ephemeral |
| 9 | Future ZOA UI overlaps Grafana | UI = DynamoDB drill-down; Grafana = SLI trends — keep both (§2.4) |
| 10 | Alert detection latency | 7–14 minutes end-to-end (YACE 120s + CW aggregation + Thanos eval). Acceptable for internal tooling. Same behavior as all other YACE-backed alerts. Can lower scrape to 60s if needed — config change, not architecture change |
| 11 | Circuit breaker per-container state | EMF shows events from independent containers; `state=open` from one + successful executions from another is normal. Dashboard annotation explains this. No code change needed |

---

## 11. Files to Touch (checklist)

### rosa-hyperfleet-zoa

- [ ] `pkg/metrics/emf.go` — sort dimension keys
- [ ] `pkg/metrics/routes.go` — new
- [ ] `pkg/metrics/middleware.go` — delete or wire
- [ ] `pkg/api/router.go` — HTTP metrics refactor
- [ ] `pkg/handler/handler.go` — remove duplicate HTTP EMF; enhance execution EMF
- [ ] `pkg/api/dispatch.go` — execution + rejection metrics
- [ ] `pkg/scheduler/gc.go` — cleaned resource counter
- [ ] `pkg/executor/circuit_breaker.go` — state change metric
- [ ] `pkg/metrics/routes_test.go` — NormalizeRoute + StatusClass
- [ ] `pkg/metrics/emf_test.go` — EMF JSON structure + sorted keys
- [ ] `pkg/metrics/execution_test.go` — execution/rejection/HTTP emit helpers

### rosa-hyperfleet

- [ ] `terraform/modules/cloudwatch-exporter/iam.tf`
- [ ] `argocd/config/regional-cluster/cloudwatch-exporter/values.yaml`
- [ ] `argocd/config/management-cluster/cloudwatch-exporter/values.yaml`
- [ ] `argocd/config/regional-cluster/grafana/dashboards/infrastructure/lambda-zoa.json`
- [ ] `argocd/config/regional-cluster/grafana/dashboards/zoa/zoa-operations.json`
- [ ] `argocd/config/regional-cluster/grafana/templates/dashboards/dashboard-lambda-zoa.yaml`
- [ ] `argocd/config/regional-cluster/grafana/templates/dashboards/dashboard-zoa-operations.yaml`
- [ ] `argocd/config/regional-cluster/alerting-rules/templates/zoa.yaml`
- [ ] `argocd/config/regional-cluster/alerting-rules/values.yaml` (SLO thresholds)
- [ ] `ci/promtool-test/zoa-rules_test.yaml`
- [ ] `docs/design/monitoring-platform.md` (post-implementation)

---

## 12. EMF Quality Assessment (existing code)

| Aspect | Grade | Detail |
|--------|-------|--------|
| Mechanism (stdout EMF) | ✅ Good | Standard AWS pattern; works with CW Logs → Metrics |
| Namespace choice (`ZOA`) | ✅ Good | Clear separation from `AWS/*` |
| Dimension design | ❌ Poor | Raw URL paths; duplicate HTTP layers |
| Business coverage | ⚠️ Partial | Worker execution timed/errors only; no action/status |
| Test coverage | ❌ None | Never validated in CloudWatch |
| Dead code | ⚠️ | `HTTPMetrics` middleware unused |
| Alignment with SRE goals | ⚠️ | Infra signals (Lambda Errors) used via return errors — clever but undocumented |

**Bottom line:** The EMF **plumbing is sound** but the **metric schema needs a breaking cleanup** before enabling YACE scrape and dashboards. Ship metric changes in ZOA **before** or **with** the first hyperfleet deploy.
