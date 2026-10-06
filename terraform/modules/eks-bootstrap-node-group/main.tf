locals {
  common_tags = {
    function  = "cluster-infra"
    module    = "eks-bootstrap-node-group"
    ManagedBy = "terraform"
  }
}

resource "aws_eks_node_group" "karpenter_bootstrap" {
  cluster_name    = var.cluster_name
  node_group_name = "${var.cluster_id}-karpenter-bootstrap"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = var.worker_node_ami_id != "" ? "CUSTOM" : "AL2023_x86_64_STANDARD"
  instance_types = ["m7i.xlarge"]

  launch_template {
    id      = var.launch_template_id
    version = var.launch_template_version
  }

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  tags = merge(local.common_tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# Core add-ons are created only after the bootstrap node group exists.
resource "aws_eks_addon" "coredns" {
  cluster_name = var.cluster_name
  addon_name   = "coredns"
  tags         = local.common_tags

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = var.cluster_name
  addon_name   = "metrics-server"
  tags         = local.common_tags

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = var.cluster_name
  addon_name   = "eks-pod-identity-agent"
  tags         = local.common_tags

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = var.cluster_name
  addon_name   = "kube-proxy"
  tags         = local.common_tags

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = var.cluster_name
  addon_name   = "aws-ebs-csi-driver"
  tags         = local.common_tags

  depends_on = [aws_eks_node_group.karpenter_bootstrap, aws_eks_addon.pod_identity]
}

resource "aws_eks_addon" "aws_secrets_store_csi_driver_provider" {
  cluster_name = var.cluster_name
  addon_name   = "aws-secrets-store-csi-driver-provider"
  tags         = local.common_tags

  configuration_values = jsonencode({
    secrets-store-csi-driver = {
      syncSecret = {
        enabled = true
      }
    }
  })

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}
