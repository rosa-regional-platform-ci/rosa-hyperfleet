#!/usr/bin/env bash
# Query Karpenter provisioning metrics from a cluster.
# Usage: ./scripts/query-karpenter-metrics.sh <cluster-type> <cluster-id>
set -euo pipefail

CLUSTER_TYPE="${1:-}"
CLUSTER_ID="${2:-}"

if [[ -z "$CLUSTER_TYPE" || -z "$CLUSTER_ID" ]]; then
    echo "Usage: $0 <cluster-type> <cluster-id>" >&2
    echo "  cluster-type: regional-cluster | management-cluster" >&2
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Karpenter Provisioning Metrics: ${CLUSTER_TYPE}/${CLUSTER_ID}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Update kubeconfig
aws eks update-kubeconfig --name "${CLUSTER_ID}" --region "${AWS_REGION:-us-east-1}" >/dev/null 2>&1

# Check if Karpenter is deployed
if ! kubectl get deployment -n kube-system karpenter >/dev/null 2>&1; then
    echo "⚠️  Karpenter not deployed yet - skipping metrics"
    exit 0
fi

# Check if Karpenter is ready
READY_REPLICAS=$(kubectl get deployment -n kube-system karpenter -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$READY_REPLICAS" == "0" ]]; then
    echo "⚠️  Karpenter not ready yet - skipping metrics"
    exit 0
fi

echo ""
echo "📊 Node Creation Metrics"
echo "────────────────────────────────────────────────────────────────────"

# Query Karpenter metrics endpoint
KARPENTER_METRICS=$(kubectl get --raw /api/v1/namespaces/kube-system/services/karpenter:8080/proxy/metrics 2>/dev/null || echo "")

if [[ -z "$KARPENTER_METRICS" ]]; then
    echo "⚠️  Unable to fetch Karpenter metrics endpoint"
    exit 0
fi

# Extract key metrics
echo "$KARPENTER_METRICS" | grep -E '^karpenter_nodeclaims_created_total' | while read -r line; do
    # Parse: karpenter_nodeclaims_created_total{nodepool="default",reason="provisioning"} 5.0
    METRIC=$(echo "$line" | awk '{print $1}')
    VALUE=$(echo "$line" | awk '{print $NF}')
    echo "  ${METRIC} = ${VALUE}"
done

echo ""
echo "📊 Pod Provisioning Duration (p50, p90, p99)"
echo "────────────────────────────────────────────────────────────────────"

# Pod provisioning startup duration quantiles
echo "$KARPENTER_METRICS" | grep '^karpenter_pods_provisioning_startup_duration_seconds{quantile=' | while read -r line; do
    QUANTILE=$(echo "$line" | sed -E 's/.*quantile="([^"]+)".*/\1/')
    VALUE=$(echo "$line" | awk '{print $NF}')
    printf "  p%-3s = %6.2f seconds\n" "${QUANTILE}" "${VALUE}"
done

echo ""
echo "📊 Node Lifetime"
echo "────────────────────────────────────────────────────────────────────"

# Node lifetime quantiles (how long nodes have been running)
echo "$KARPENTER_METRICS" | grep '^karpenter_nodes_lifetime_duration_seconds{quantile=' | while read -r line; do
    QUANTILE=$(echo "$line" | sed -E 's/.*quantile="([^"]+)".*/\1/')
    VALUE=$(echo "$line" | awk '{print $NF}')
    MINUTES=$(awk "BEGIN {printf \"%.1f\", ${VALUE}/60}")
    printf "  p%-3s = %6.2f seconds (%6.1f minutes)\n" "${QUANTILE}" "${VALUE}" "${MINUTES}"
done

echo ""
echo "📊 Recent NodeClaim Events"
echo "────────────────────────────────────────────────────────────────────"

# Show recent nodeclaim creations (last 5 minutes)
kubectl get events -n kube-system --sort-by='.lastTimestamp' \
    --field-selector involvedObject.kind=NodeClaim 2>/dev/null | tail -10 || echo "  (no recent events)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Metrics collection complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
