# ROSAENG-65234 — SRE Review of ZOA Observability Plan

> **Reviewer perspective:** Google SRE (Site Reliability Engineering) principles — SRE Book, SRE Workbook, Alerting on SLOs.
>
> **Source:** `tmp/ROSAENG-65234-zoa-observability-plan.md` (1011 lines, rev Sep 14 2026)
>
> **Verdict:** The plan is **strong** — well above average for a first observability pass on a serverless subsystem. The three-plane model (DynamoDB/EMF/Grafana), cost analysis, and cardinality discipline are exactly right. Below are issues and improvements ranked by impact.

---

## Owner decisions (post-review feedback)

| # | Finding | Decision | Notes |
|---|---------|----------|-------|
| 1 | Recording rule math bug | ✅ **Fix** | Blocking — wrong PromQL ships otherwise |
| 2 | `absent_over_time` per-cluster | ✅ **Fix** — use timestamp approach (option 1) | Simpler than Helm loop; good enough |
| 3 | No runbook references | ❌ **Skip** | Not a concern for v1 |
| 4 | SLO conflates infra vs target failures | ❌ **Skip** | Per-cluster aggregation isolates impact; infra dashboards provide complementary signal |
| 5 | Cold start latency signal | ❌ **Skip** | Not a concern |
| 6 | YACE 120s alert blind spots | ❌ **Accept** | Same behavior as all other YACE scrapes; can lower to 60s later if needed |
| 7 | DLQ alert `for: 5m` too long | ✅ **Keep `for: 5m`** | Transient single-tick failures (e.g., one reconciler tick DLQ'd) are expected; only page when messages persist |
| 8 | Circuit breaker per-container | ✅ **Note** | Add dashboard annotation explaining concurrent container behavior |
| 9 | Duration dimensions differ from Count | ✅ **Fix** — add `StatusClass` to duration | Consistency, per Google SRE practice |
| 10 | Missing `DeploymentTarget` dim | Deferred | `cluster_type` from Prometheus covers Grafana; nice-to-have |
| 11 | SLO 99.5% too tight | ✅ **Fix** — start at 99% | Loosen first, tighten with data |
| 12 | Alert inhibition/dependency | ❌ **Skip** | Not a concern for v1 |
| 13 | Cost estimate conservative | ✅ **Adjust** | See ephemeral cost clarification below |

### Ephemeral environment EMF cost (clarification)

**Q:** What happens when an ephemeral env lives 40 min for E2E then is destroyed?

**A:** AWS custom metrics are **prorated by the hour**. Billing stops ~3 hours after the last datapoint. For a 40-minute env creating ~100 EMF series:

```
100 series × 1 hour × ($0.30 / 730 hours/month) ≈ $0.04
```

After destruction, no new datapoints → **no further charges**. The metric data remains readable in CloudWatch for 15 months but is not billed. Ephemeral E2E environments are **essentially free** for EMF — cost concern applies only to persistent (24/7) environments.

---

## Findings Summary

| # | Severity | Finding | Section | Status |
|---|----------|---------|---------|--------|
| 1 | 🔴 High | Recording rule `zoa:api_availability:5m` is mathematically wrong | §7.2 | ✅ Fix |
| 2 | 🔴 High | `absent_over_time` for reconciler detection needs per-cluster scoping | §7.2 | ✅ Fix (option 1) |
| 3 | 🟡 Medium | No runbook references on alerts | §7.1–7.2 | ❌ Skip |
| 4 | 🟡 Medium | SLO on TA success rate (95%) conflates infra failures with target-cluster failures | §7.3 | ❌ Skip |
| 5 | 🟡 Medium | Missing cold start latency signal | §5.2, §6.1 | ❌ Skip |
| 6 | 🟡 Medium | YACE 120s scrape interval creates alert blind spots for short-lived conditions | §5.4, §7.2 | ❌ Accept |
| 7 | 🟢 Low | DLQ alert `for: 5m` kept — transient blips expected | §7.1 | ✅ Keep |
| 8 | 🟢 Low | Circuit breaker metric is per-container, not per-deployment | §3.4, §5.2 | ✅ Note |
| 9 | 🟢 Low | `HttpRequestDuration` dimensions differ from `HttpRequestCount` (missing `StatusClass`) | §5.2 | ✅ Fix |
| 10 | 🟢 Low | Missing `DeploymentTarget` dimension on EMF (RC vs MC scope filtering) | §5.2 | Deferred |
| 11 | ℹ️ Info | SLO 99.5% API availability may be too tight for internal tooling | §7.3 | ✅ Fix → 99% |
| 12 | ℹ️ Info | No mention of alert inhibition/dependency between critical and warning | §7.2 | ❌ Skip |
| 13 | ℹ️ Info | Cost estimate ~160 series at "low" seems conservative-high | §2.5 | ✅ Adjust |

---

## Detailed Findings

### 1. 🔴 Recording rule `zoa:api_availability:5m` is mathematically wrong — ✅ FIX

**Location:** §7.2, recording rules block

**Current:**

```promql
zoa:api_availability:5m =
  sum by (cluster) (
    1 - (
      rate(zoa_http_request_count_sum{statusclass="5xx"}[5m])
      / rate(zoa_http_request_count_sum[5m])
    )
  )
```

**Problem:** `1 - (rate_a / rate_b)` is computed per-series, then summed across series. If there are N matching series, the result is `N - sum(error_ratios)`, not a single availability number. The `sum by (cluster)` aggregates the **per-series** subtraction results.

**Fix:**

```promql
zoa:api_availability:5m =
  1 - (
    sum by (cluster) (rate(zoa_http_request_count_sum{statusclass="5xx"}[5m]))
    / sum by (cluster) (rate(zoa_http_request_count_sum[5m]))
  )
```

Aggregate first (sum all 5xx, sum all requests), **then** compute the ratio. Standard SLI pattern from the SRE Workbook.

---

### 2. 🔴 `absent_over_time` for reconciler needs per-cluster enumeration — ✅ FIX (option 1)

**Location:** §7.2, `ZOAReconcilerNotRunning` alert

**Problem:** `absent_over_time(metric{filter}[5m])` returns a single `{}` result when the **entire** metric is missing — it does **not** return per-cluster absence. If mc-01 has data but mc-05 does not, the `absent_over_time` returns nothing (the metric exists, just not for mc-05).

**Fix options:**

1. **Recording rule that enumerates known clusters**, then alert on the difference:

   ```promql
   # Recording: last invocation timestamp per cluster
   zoa:worker_last_invocation_timestamp =
     max by (cluster) (
       timestamp(aws_lambda_invocations_sum{dimension_FunctionName=~".*-zoa-worker", tag_Component="zoa"})
     )

   # Alert: cluster not seen for 5m
   - alert: ZOAReconcilerNotRunning
     expr: (time() - zoa:worker_last_invocation_timestamp) > 300
   ```

2. **Use the `up` metric** with a label match against known ZOA clusters (requires discovery).

3. **Explicit per-cluster `absent` in the Helm template** (same approach as `remote-write-health.yaml` which loops over known MCs). This is probably the most consistent with existing patterns in the repo.

**Recommendation:** Use approach (1) — timestamp-based recording rule. It's simple PromQL that works without Helm templating for cluster enumeration. The `timestamp()` function records when the metric was last seen; if the gap exceeds 300s, the alert fires with the correct `cluster` label. No infra or Helm changes needed.

> **Owner note:** Option 3 (Helm loop like `remote-write-health.yaml`) is also valid but that alert is special — requires infra knowledge beyond pure PromQL. Option 1 is simpler and good enough.

---

### 3. 🟡 No runbook references on alerts — ❌ SKIP

**Location:** §7.1–7.2

**Problem:** Every alert should have a `runbook_url` annotation pointing to a playbook. Google SRE is explicit: *"Every page should have a corresponding entry in a playbook."* Without runbooks, the alert fires and the on-call engineer has to read the plan doc to figure out response steps.

**Recommendation:** Add a `runbook_url` annotation pattern in the alert spec, even if runbooks are stubs initially:

```yaml
annotations:
  runbook_url: "https://github.com/openshift-online/rosa-hyperfleet/blob/main/docs/sop/zoa-{{ $labels.alertname | toLower }}.md"
```

Add to Phase 2 implementation: create stub SOPs in `docs/sop/` for each critical/warning alert. Minimum content: "What does this alert mean?", "First response steps", "Escalation".

---

### 4. 🟡 SLO for TA success rate (95%) conflates failure causes — ❌ SKIP

**Location:** §7.3

**Problem:** A 95% TA success rate SLO counts **all** failures equally. But many TA failures are caused by the **target cluster** (e.g., pod doesn't exist, namespace invalid, EKS unreachable because the MC itself is degraded), not by ZOA infrastructure. Alerting on "ZOA is broken" when the signal is "the target cluster has issues" produces false pages.

From Google SRE: *"Your SLI should measure the reliability of your service, not your dependencies."*

**Recommendation:**

- **Short-term (v1):** Keep the 95% target but add `unless` clauses or separate recording rules for infra-vs-target failures. The circuit breaker already distinguishes "EKS unreachable" — emit that as a separate dimension.
- **Medium-term:** Classify failures: `infra_failure` (Lambda timeout, DynamoDB error, circuit breaker) vs `target_failure` (TA returned error from target cluster). EMF `Status` could be enriched: `failed_infra` vs `failed_target`. This does not require a dimension — it can be derived from the TA result or error type in code.
- Add a note in §7.3: *"95% target is provisional. After 4 weeks of data, split the SLI into infra-caused vs target-caused failures and set independent targets."*

> **Owner note:** Per-cluster aggregation (`sum by (cluster)`) already isolates MC-specific failures. A broken target MC burns only that cluster's error budget, not the global one. Additionally, infra-level monitoring (Lambda errors, DynamoDB throttles) provides a complementary signal to distinguish ZOA infra problems from target cluster problems. Acceptable for v1.

---

### 5. 🟡 Missing cold start latency signal — ❌ SKIP

**Location:** §5.2, §6.1

**Problem:** Lambda cold starts are a real operational concern (VPC-attached Lambdas, though improved by Hyperplane, still have higher init times). The plan mentions `aws_lambda_duration` for p99 latency but does not call out **Init Duration** specifically. CloudWatch publishes `Init Duration` in the REPORT log line but **not as a native metric** in `AWS/Lambda` namespace — it requires parsing CloudWatch Logs or adding a dedicated EMF metric.

**Impact:** A creeping cold-start regression (e.g., binary size increase, VPC ENI attachment delay) would go undetected. Duration p99 would increase but without isolation of the cold-start component.

**Recommendation:**

- **Option A (low effort):** Add an EMF metric `ColdStartDuration` emitted in the Lambda handler when `AWS_LAMBDA_INITIALIZATION_TYPE` env var indicates a cold start (check `_HANDLER` or detect first invocation). One extra series per cluster.
- **Option B (deferred):** Note as a risk/future item. Lambda CloudWatch Insights can query REPORT lines for init duration ad-hoc.
- At minimum, add `ColdStartDuration` to the "Future/v2" section so it is not lost.

---

### 6. 🟡 YACE 120s scrape creates alert blind spots — ❌ ACCEPT

**Location:** §5.4, §7.2

**Problem:** YACE polls CloudWatch every 120s. CloudWatch itself aggregates EMF into 1-minute datapoints. Combined with Thanos evaluation, the effective end-to-end latency from "event happens" to "alert fires" is:

```
Event → EMF log → CW metric (~30s) → YACE scrape (0–120s) → Prometheus → Thanos Ruler eval (every 60s)
= 1.5–4 minutes before alert expression can even see the data
+ `for:` duration (5–10m in plan)
= 6.5–14 minutes total time to page
```

For the DLQ alert (`for: 5m`), a dead letter at time T would not page until T + ~7–9 minutes minimum.

**Impact:** Acceptable for most alerts (worker errors, TA failure rate). For DLQ specifically, this means a burst of dead-lettered reconciler invocations sits undetected for ~7 minutes. Since reconciler runs every 60s, that's potentially 7 lost ticks.

**Recommendation:**

- **Accept and document** the latency. For an internal SRE tool (not customer-facing), 7–9 min detection is reasonable.
- Add to §10 Risks: *"Alert detection latency: 7–14 minutes end-to-end due to YACE 120s poll + CW aggregation + Thanos eval. Acceptable for internal tooling; would need CloudWatch Alarms (direct, no Prometheus) for sub-minute detection."*
- **Do not** add CloudWatch Alarms as a parallel path — the complexity is not justified for internal tooling.

> **Owner note:** All YACE scrapes in the platform have the same 120s behavior. Acceptable. If we ever find it insufficient, lowering to 60s is a config change, not an architecture change.

---

### 7. 🟢 DLQ alert `for: 5m` — should instant-fire — ✅ FIX

**Location:** §7.1

**Problem:** A DLQ message means the Lambda invocation was dropped — reconciler missed a tick, TA execution lost. In ZOA's design, DLQ is the last-resort safety net. The 5-minute `for` duration delays pages for something that is, by definition, already a failure that bypassed all retries.

**Recommendation:** Use `for: 0m` (instant-fire). A single DLQ message is page-worthy — it means the Lambda invocation was dropped after all retries. At ZOA's low volume, this will not be noisy. The YACE 120s scrape already provides natural dampening (message must persist for at least one scrape cycle).

> **Owner note:** A single DLQ message should trigger an alert. Google SRE agrees — DLQ > 0 is a failure that bypassed all retries.

---

### 8. 🟢 Circuit breaker metric is per-container, not per-deployment — ✅ NOTE

**Location:** §3.4, §5.2

**Problem:** The plan correctly notes the circuit breaker is per Lambda container (in-process state, `sync.Mutex`). But `CircuitBreakerStateChange` EMF metrics will arrive from different containers, each with independent breaker state. If one container trips but another (concurrent) does not, the EMF will show a `state=open` event followed by successful executions from other containers.

**Impact:** Low — the metric still signals "at least one container is seeing EKS failures." The per-cluster aggregation will show the signal. But dashboard/alert interpretation needs a note: *"Circuit breaker fires per Lambda container, not globally. Multiple concurrent containers may show mixed state."*

**Recommendation:** Add a note in the ZOA Operations dashboard for the circuit breaker panel. No code change needed.

**Plain-language explanation:** Lambda auto-scales by spinning up multiple containers concurrently. Each container has its own independent circuit breaker (Go struct with `sync.Mutex`). They don't share state:

```
Container A:  EKS call fails → fails → fails 3rd time → breaker OPENS → emits state=open
Container B:  (concurrent) EKS calls succeeding → breaker CLOSED → TAs work fine
Container C:  (new cold start) fresh breaker → CLOSED → TAs work fine
```

In Grafana: you see `state=open` at 14:01 **and** successful executions at 14:01. Not contradictory — different containers. The metric still tells you "at least one container is having trouble reaching EKS." Dashboard panel tooltip should note this.

---

### 9. 🟢 `HttpRequestDuration` dimensions differ from `HttpRequestCount` — ✅ FIX

**Location:** §5.2

`HttpRequestCount` has: `Cluster, HandlerMode, Method, RouteTemplate, StatusClass`
`HttpRequestDuration` has: `Cluster, HandlerMode, Method, RouteTemplate` (no `StatusClass`)

**Problem:** Minor — but it means you cannot compute "p99 latency of successful requests only" vs "p99 latency of 5xx requests." In practice, 5xx responses from Lambda are usually fast (error returns quickly), so the overall p99 is dominated by successful requests. Acceptable.

**Recommendation:** Add `StatusClass` to `HttpRequestDuration` for consistency. Google SRE practice: count and latency metrics for the same signal should share dimensions so you can query "p99 latency of 5xx responses" if needed. The cardinality increase (~4x on duration series) is modest — ~4 status classes × existing route combos — and stays within the budget.

---

### 10. 🟢 Missing `DeploymentTarget` dimension on EMF — DEFERRED

**Location:** §5.2

**Problem:** The `Cluster` dimension identifies the deployment, but when querying Thanos across RC + MC, there is no EMF dimension to filter "show me only RC executions" vs "only MC executions." The Thanos `cluster_type` external label from Prometheus helps, but only after the YACE scrape. In CloudWatch (before Prometheus), you would need to know which `Cluster` value maps to RC vs MC.

**Impact:** Low — `cluster_type` label in Prometheus/Thanos covers the Grafana use case. CW Console debugging requires knowing cluster names.

**Recommendation:** Optional. If added, `DeploymentTarget` (rc/mc) is 2 values — negligible cardinality increase. The `ZOA_DEPLOYMENT_TARGET` env var is already set. But it is not essential — `cluster_type` from Prometheus handles it. Note as "nice to have" in Phase 1.

---

### 11. ℹ️ 99.5% API availability SLO may be too tight — ✅ FIX → 99%

**Location:** §7.3

**Context:** ZOA is an internal SRE tool, not a customer-facing API. 99.5% over 30 days = ~2.2 hours of allowed downtime. A single Lambda cold-start + VPC ENI issue lasting 3 hours would blow the budget.

**Recommendation:** Start at **99%** (7.3 hours/30d) and tighten after observing baseline. The SRE Workbook recommends starting loose and tightening once you have data, not the reverse.

---

### 12. ℹ️ No alert inhibition/dependency — ❌ SKIP

**Location:** §7.2

**Problem:** If the worker Lambda is down (`ZOAWorkerLambdaErrorRateHigh` fires), the reconciler cannot run, so `ZOAReconcilerNotRunning` also fires, and DLQ messages pile up, so `ZOADLQMessagesVisible` fires. That is 3 pages for 1 root cause.

**Recommendation:** Add inhibition rules (in Alertmanager config or via `unless` in PromQL) so:
- `ZOAWorkerLambdaErrorRateHigh` (critical) inhibits `ZOAReconcilerNotRunning` and `ZOAGCErrors`
- `ZOAReconcilerNotRunning` inhibits `ZOADLQMessagesVisible` (if reconciler is known-down, DLQ is expected)

Or at minimum, document the cascade in the runbook: *"If all three fire simultaneously, investigate worker Lambda first."*

---

### 13. ℹ️ Cost estimate sanity check — ✅ ADJUST

**Location:** §2.5

The "low traffic (ephemeral dev)" estimate of ~160 active series seems conservatively high. With 9 TAs and most only used occasionally:

- `ExecutionCount` × (9 actions × 3 statuses × 2 modes × 2 scopes × 2 types) = 216 theoretical max, but 7/9 TAs are sync+read — so only ~2 status combos (succeeded, failed) are realistic per TA. Real active: ~20–30 execution series.
- `HttpRequestCount` × (10 routes × 4 status classes) = 40 max, but most routes only see 2xx. Real: ~15–20.
- Pipeline metrics (reconciler, GC): ~10 series.
- Rejections: ~5.

**Realistic active per deployment: ~50–70**, not 80. **Per region (2 deployments): ~100–140**.

Monthly cost at ~120 series: 120 × $0.30 = **~$36/region**, not $48. Still in the same ballpark but less alarming.

**Recommendation:** Adjust the estimate or note it as "upper bound within the low scenario" to avoid sticker shock.

---

## Strengths (things done well)

| Aspect | Assessment |
|--------|------------|
| **Three-plane model** (DynamoDB / EMF / Grafana) | Exactly right; clear separation of concerns |
| **Cost-first thinking** | Exceptional for an observability plan — most skip this entirely |
| **Cardinality discipline** | Correctly excludes operator/jira/execution_id |
| **Function URL awareness** | Explicitly calls out missing API GW metrics and compensates |
| **Event taxonomy** | Clear terminal vs rejection vs request distinction |
| **Existing pattern reuse** | References hcp-sla burn-rate, RDS dashboard style, promtool conventions |
| **Per-cluster alert isolation** | `sum by (cluster)` contract is correct and tested |
| **Dashboard split** (infra vs business) | Avoids duplication; link pattern is the right approach |
| **Scope refinement vs Jira** | Honest about what to drop (API GW) and what to defer (SLO docs) |

---

## Recommended priority for fixes before implementation

1. **Fix recording rule math** (finding #1) — blocking; wrong alerts ship otherwise.
2. **Fix absent_over_time pattern** (finding #2) — use timestamp approach; blocking for per-cluster detection.
3. **DLQ alert `for: 0m`** (finding #7) — single message should page.
4. **Add `StatusClass` to `HttpRequestDuration`** (finding #9) — consistency.
5. **SLO 99.5% → 99%** (finding #11) — change one number.
6. **Add circuit breaker dashboard note** (finding #8) — tooltip/annotation.
7. **Adjust cost estimates** (finding #13) — more realistic numbers.

### Skipped (owner decision, acceptable for v1)

- Runbook references (#3)
- SLO failure cause split (#4)
- Cold start signal (#5)
- Alert inhibition (#12)
