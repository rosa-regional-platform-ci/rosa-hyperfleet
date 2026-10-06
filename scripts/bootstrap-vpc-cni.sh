#!/usr/bin/env bash
set -euo pipefail

echo "Installing self-managed AWS VPC CNI..."

VPC_CNI_IMAGE_REGISTRY=$(aws ssm get-parameter \
  --name /argocd/vpc-cni/image-registry \
  --query 'Parameter.Value' \
  --output text \
  --region "$AWS_REGION")
VPC_CNI_IMAGE_REGISTRY="${VPC_CNI_IMAGE_REGISTRY%/}"

if [[ "$VPC_CNI_IMAGE_REGISTRY" == "None" || ! "$VPC_CNI_IMAGE_REGISTRY" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  echo "ERROR: /argocd/vpc-cni/image-registry must contain only a registry hostname" >&2
  exit 1
fi

CLUSTER_ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.endpoint' \
  --output text)

helm repo add aws-eks https://aws.github.io/eks-charts
helm dependency build "$REPO_DIR/argocd/config/shared/kube-system"

VPC_CNI_VALUES=/tmp/vpc-cni-bootstrap-values.yaml
cat > "$VPC_CNI_VALUES" <<EOF
aws-vpc-cni:
  image:
    overrideRepository: ${VPC_CNI_IMAGE_REGISTRY}/amazon-k8s-cni
  init:
    image:
      overrideRepository: ${VPC_CNI_IMAGE_REGISTRY}/amazon-k8s-cni-init
  nodeAgent:
    image:
      overrideRepository: ${VPC_CNI_IMAGE_REGISTRY}/amazon/aws-network-policy-agent
  extraEnv:
    - name: CLUSTER_ENDPOINT
      value: ${CLUSTER_ENDPOINT}
    - name: CLUSTER_NAME
      value: ${CLUSTER_NAME}
    - name: VPC_ID
      value: ${VPC_ID}
EOF

helm template kube-system \
  "$REPO_DIR/argocd/config/shared/kube-system" \
  --namespace kube-system \
  -f "$VPC_CNI_VALUES" \
  | kubectl apply --server-side -f -

echo "Self-managed AWS VPC CNI resources applied"
