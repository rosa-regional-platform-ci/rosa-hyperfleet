#!/bin/bash
# Run e2e API tests from rosa-hyperfleet-api against the provisioned environment.
#
# API URL resolution (first match wins):
#   1. BASE_URL env var            — set by local wrapper scripts (ephemeral-env.sh, int-env.sh)
#   2. CREDS_DIR/api_url file — Prow-mounted secret for the standing int environment
#   3. SHARED_DIR terraform output — written by ephemeral-provider during CI provisioning
#
# RHOBS_API_URL and ZOA_RC_API_URL/ZOA_MC_API_URL follow the same resolution
# order and are optional — their tests are skipped (not failed) when absent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

source "${SCRIPT_DIR}/setup-aws-profiles.sh"

if [[ -n "${BASE_URL:-}" ]]; then
  echo "Using BASE_URL from environment: ${BASE_URL}"
else
  if [[ -r "${CREDS_DIR}/api_url" ]]; then
    echo "Using API URL from ${CREDS_DIR}/api_url (CI pre-existing environment)"
    BASE_URL="$(cat "${CREDS_DIR}/api_url")"
  else
    echo "No ${CREDS_DIR}/api_url found, falling back to terraform outputs (ephemeral environment)"
    TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
    if [[ ! -r "${TF_OUTPUTS}" ]]; then
      echo "ERROR: ${TF_OUTPUTS} does not exist or is not readable" >&2
      exit 1
    fi
    BASE_URL="$(jq -r '.api_gateway_invoke_url.value // empty' "${TF_OUTPUTS}")"
    if [[ -z "${BASE_URL}" ]]; then
      echo "ERROR: api_gateway_invoke_url.value not found in ${TF_OUTPUTS}" >&2
      exit 1
    fi
  fi
fi
export BASE_URL
echo "Running API e2e tests against ${BASE_URL}"

# RHOBS API URL for observability E2E tests (Thanos Query read path).
# The query path is always available — uses the same invoke URL as remote-write.
if [[ -z "${RHOBS_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/rhobs_api_url" ]]; then
    RHOBS_API_URL="$(cat "${CREDS_DIR}/rhobs_api_url")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    RHOBS_API_URL="$(jq -r '.rhobs_api_url.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -n "${RHOBS_API_URL:-}" ]]; then
  export RHOBS_API_URL
  echo "RHOBS API URL: ${RHOBS_API_URL}"
else
  echo "WARNING: RHOBS_API_URL not available — observability tests will be skipped"
fi

# ZOA RC/MC API URLs, for the light "zoa"-labeled smoke tests bundled into
# test-e2e-api (rosa-hyperfleet-api/test/e2e-api/zoa_smoke_test.go). Same
# resolution order as RHOBS_API_URL above; local wrapper scripts
# (ephemeral-env.sh) already export these directly, so this is mainly for
# CI-triggered runs (Prow). MC may legitimately be absent — management
# clusters provision dynamically, so the smoke suite just runs RC-only then.
if [[ -z "${ZOA_RC_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/zoa_rc_api_url" ]]; then
    ZOA_RC_API_URL="$(cat "${CREDS_DIR}/zoa_rc_api_url")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    ZOA_RC_API_URL="$(jq -r '.zoa_api_function_url.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -z "${ZOA_MC_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/zoa_mc_api_url" ]]; then
    ZOA_MC_API_URL="$(cat "${CREDS_DIR}/zoa_mc_api_url")"
  elif [[ -n "${SHARED_DIR:-}" && -r "${SHARED_DIR}/management-terraform-outputs.json" ]]; then
    ZOA_MC_API_URL="$(jq -r '.zoa_api_function_url.value // empty' "${SHARED_DIR}/management-terraform-outputs.json")"
  fi
fi
if [[ -n "${ZOA_RC_API_URL:-}" ]]; then
  export ZOA_RC_API_URL
  echo "ZOA RC API URL: ${ZOA_RC_API_URL}"
else
  echo "ZOA_RC_API_URL not available — ZOA smoke tests will be skipped"
fi
[[ -n "${ZOA_MC_API_URL:-}" ]] && export ZOA_MC_API_URL && echo "ZOA MC API URL: ${ZOA_MC_API_URL}"

# Use the regional account profile for authenticated API calls
export AWS_PROFILE="rrp-rc"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Compute CLUSTER_PREFIX early so it's available for pre-cleanup hooks (log
# collection while HCPs still exist), not just in the post-test failure handler.
# Callers (e.g. ephemeral-env.sh) may set CLUSTER_PREFIX directly; honour it.
if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
    echo "Using caller-provided CLUSTER_PREFIX=${CLUSTER_PREFIX}"
elif [[ -r "${CREDS_DIR}/api_url" ]]; then
    export CLUSTER_PREFIX=""
elif [[ -n "${BUILD_ID:-}" ]]; then
    _hash="$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)" \
        || { echo "WARNING: sha256sum failed — CLUSTER_PREFIX not set"; _hash=""; }
    if [[ -n "$_hash" ]]; then
        export CLUSTER_PREFIX="eph-${_hash}-"
    fi
else
    echo "WARNING: no ${CREDS_DIR}/api_url and BUILD_ID not set — CLUSTER_PREFIX unset, log collection disabled" >&2
fi

E2E_REF="${E2E_REF:-main}"
E2E_REPO="${E2E_REPO:-https://github.com/openshift-online/rosa-hyperfleet-api.git}"
CLI_REF="${CLI_REF:-main}"
CLI_REPO="${CLI_REPO:-https://github.com/openshift-online/rosa-hyperfleet-cli.git}"
ZOA_REF="${ZOA_REF:-main}"
ZOA_REPO="${ZOA_REPO:-https://github.com/openshift-online/rosa-hyperfleet-zoa.git}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
echo ""
echo "=== API Tests ==="
echo "===           ==="
echo "Repo: ${E2E_REPO} - Branch: ${E2E_REF}"
echo ""
git clone --depth 1 --branch "${E2E_REF}" \
  "${E2E_REPO}" "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

echo "===           ==="
echo "working commit $(git rev-parse HEAD)"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

# Light ZOA smoke coverage (test/e2e-api/zoa_smoke_test.go, label "zoa") only
# runs if ZOA_RC_API_URL and a built zoa CLI are available — both are
# best-effort here so a zoa checkout/build hiccup never blocks the platform
# API e2e run it's bundled into. Deep ZOA validation lives in
# rosa-hyperfleet-zoa's own e2e suite (make ephemeral-zoa-e2e).
if [[ -n "${ZOA_RC_API_URL:-}" ]]; then
  if git clone --depth 1 --branch "${ZOA_REF}" "${ZOA_REPO}" "${WORK_DIR}/zoa" \
      && make -C "${WORK_DIR}/zoa" build; then
    export ZOA_BIN="${WORK_DIR}/zoa/bin/zoa"
    echo "ZOA CLI built from ${ZOA_REPO}@${ZOA_REF}: ${ZOA_BIN}"
  else
    echo "WARNING: failed to build zoa CLI from ${ZOA_REPO}@${ZOA_REF} — ZOA smoke tests will be skipped"
  fi
else
  echo "ZOA_RC_API_URL not set — ZOA smoke tests will be skipped"
fi

platform_rc=0
hcp_rc=0
monitoring_rc=0
make test-e2e-api || platform_rc=$?

# Get regional account ID for CLI tests
if [[ -z "${E2E_ACCOUNT_ID:-}" ]]; then
  export E2E_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  echo "Regional account ID: ${E2E_ACCOUNT_ID}"
fi

# --- HCP Creation E2E Tests ---
# Customer credentials are supplied via the rrp-customer AWS profile (CUSTOMER_AWS_PROFILE).
# Subprocesses use credential_process auto-refresh, avoiding the 15-minute STS TTL cliff.
# Only run if the platform API tests passed.
_have_customer_creds=false
if [[ $platform_rc -ne 0 ]]; then
  echo "Skipping HCP creation & Platform Monitoring tests — platform API tests failed (exit code: $platform_rc)"
elif aws configure export-credentials --profile rrp-customer --format process &>/dev/null; then
  export CUSTOMER_AWS_PROFILE="rrp-customer"
  echo "Customer profile rrp-customer is available"

  if [[ -z "${E2E_CUSTOMER_ACCOUNT_ID:-}" ]]; then
    export E2E_CUSTOMER_ACCOUNT_ID="$(aws sts get-caller-identity --profile rrp-customer --query Account --output text)"
    echo "Customer account ID: ${E2E_CUSTOMER_ACCOUNT_ID:0:8}..."
  fi
  _have_customer_creds=true
else
  echo "WARNING: No rrp-customer profile available — skipping HCP creation tests"
fi

if [[ "$_have_customer_creds" == "true" ]]; then
  test_hcp_creation() {
    echo ""
    echo "=== HCP Creation Tests ==="

    local HCP_CLUSTER_NAME="e2e-$(date +%s)"

    CLI_WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${CLI_WORK_DIR}"; rm -rf "${WORK_DIR}"' EXIT
    cd "${CLI_WORK_DIR}"
    git clone --depth 1 --branch "${CLI_REF}" \
      "${CLI_REPO}" "${CLI_WORK_DIR}/cli"
    cd "${CLI_WORK_DIR}/cli"

    export GOTOOLCHAIN=auto
    make build
    chmod 755 ./bin/rosactl

    export ROSACTL_BIN="${CLI_WORK_DIR}/cli/bin/rosactl"

    cd "${WORK_DIR}/api"

    "${ROSACTL_BIN}" login --url "${BASE_URL}"
    echo "Creating HCP cluster: ${HCP_CLUSTER_NAME}"

    # Collect cluster logs before HCP cleanup so the HCP namespace is captured.
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        export PRE_CLEANUP_HOOK="S3_ONLY=true ${REPO_ROOT}/scripts/dev/dump-env.sh"
    fi

    export GINKGO_NO_COLOR=TRUE
    if [[ -n "${E2E_SKIP_CLEANUP:-}" ]]; then
      echo "E2E_SKIP_CLEANUP is set — cleanup specs will be skipped"
      export E2E_LABEL_FILTER='!cleanup'
    fi
    make test-e2e-cli || return $?

    echo "HCP creation test completed for: ${HCP_CLUSTER_NAME}"
  }

  test_hcp_creation || hcp_rc=$?

  echo ""
  echo "=== Platform Monitoring Tests ==="
  echo ""
  make test-e2e-platform-monitoring || monitoring_rc=$?
fi

# HCP test failures collect logs via PRE_CLEANUP_HOOK in the test's DeferCleanup
# (before HCP deletion). Only collect here for non-HCP failures.
if [[ $platform_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]]; then
    # Logs are left in S3 rather than added to public CI artifacts because
    # they may contain sensitive data that cannot be reliably redacted.
    # The S3 URIs are printed below for manual retrieval.
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        S3_ONLY=true \
            "${REPO_ROOT}/scripts/dev/dump-env.sh" || true
    fi
fi

echo ""
echo "E2E results: platform=$platform_rc hcp=$hcp_rc monitoring=$monitoring_rc"
if [[ $platform_rc -ne 0 ]] || [[ $hcp_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]]; then
    exit 1
fi
