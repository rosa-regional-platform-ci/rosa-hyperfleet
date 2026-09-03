#!/usr/bin/env bash
# ZOA-specific image push for cross-component pre-merge e2e.
#
# Mirrors both ZOA Lambda and Runner images from the ci-operator pipeline
# registry to quay.io/rrp-dev-ci/ so the ephemeral EKS environment can pull
# them. Unlike the generic rosa-hyperfleet-image-push step (which handles
# one image), ZOA needs two images with separate repos but the same tag.
#
# Expected env vars (set by ci-operator + step-registry):
#   CI_ZOA_LAMBDA_IMAGE   — pipeline image pullspec for zoa-lambda
#   CI_ZOA_RUNNER_IMAGE   — pipeline image pullspec for zoa-runner
#   PULL_NUMBER           — PR number (set by Prow)
#   BUILD_ID              — unique build ID (set by Prow)
#
# Writes to SHARED_DIR:
#   component-image-override  — "IMAGE_REPO IMAGE_TAG" for the lambda image
#   runner-image-override     — "RUNNER_IMAGE_REPO RUNNER_IMAGE_TAG" for the runner
#
# Requires: oc CLI, quay push credentials (rosa-regional-platform-dev-ci-quay-push)

set -euo pipefail

LAMBDA_DEST_REPO="${ROSA_REGIONAL_QUAY_DEST_REPO:-quay.io/rrp-dev-ci/zoa-lambda}"
RUNNER_DEST_REPO="${ROSA_REGIONAL_QUAY_RUNNER_DEST_REPO:-quay.io/rrp-dev-ci/zoa-runner}"
IMAGE_TAG="ci-${PULL_NUMBER:-0}-${BUILD_ID:-unknown}"

echo "ZOA image push:"
echo "  Lambda: ${CI_ZOA_LAMBDA_IMAGE} → ${LAMBDA_DEST_REPO}:${IMAGE_TAG}"
echo "  Runner: ${CI_ZOA_RUNNER_IMAGE} → ${RUNNER_DEST_REPO}:${IMAGE_TAG}"

# Mirror lambda
oc image mirror \
  "${CI_ZOA_LAMBDA_IMAGE}" \
  "${LAMBDA_DEST_REPO}:${IMAGE_TAG}" \
  --keep-manifest-list=true

# Mirror runner
oc image mirror \
  "${CI_ZOA_RUNNER_IMAGE}" \
  "${RUNNER_DEST_REPO}:${IMAGE_TAG}" \
  --keep-manifest-list=true

echo "Images pushed successfully"

# Write overrides for the provision step.
# The provision step reads these to substitute IMAGE_REPO/IMAGE_TAG and
# RUNNER_IMAGE_REPO/RUNNER_IMAGE_TAG placeholders in the override YAML.
echo "${LAMBDA_DEST_REPO} ${IMAGE_TAG}" > "${SHARED_DIR}/component-image-override"
echo "${RUNNER_DEST_REPO} ${IMAGE_TAG}" > "${SHARED_DIR}/runner-image-override"

echo "Override files written to SHARED_DIR"
