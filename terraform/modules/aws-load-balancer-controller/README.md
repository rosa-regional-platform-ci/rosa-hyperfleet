# AWS Load Balancer Controller Module

Creates the IAM role and EKS Pod Identity association for the AWS Load Balancer Controller (LBC).
This module is used in OSS Karpenter mode, where Auto Mode's built-in load balancing capability
is disabled and the LBC must be managed independently.

## Overview

The module creates:

- **IAM Role**: Pod Identity-backed role with the upstream recommended LBC policy
- **Pod Identity Association**: Binds the role to the LBC service account in the configured namespace

The LBC itself is deployed via the ArgoCD Helm wrapper at
`argocd/config/regional-cluster/aws-load-balancer-controller/`.

## Usage

```hcl
module "aws_load_balancer_controller" {
  source       = "../../../modules/aws-load-balancer-controller"
  cluster_name = module.eks_cluster.cluster_name
}
```

## Inputs

| Name              | Description                                    | Type          | Default                          | Required |
| ----------------- | ---------------------------------------------- | ------------- | -------------------------------- | :------: |
| `cluster_name`    | Name of the EKS cluster                        | `string`      | n/a                              |   yes    |
| `namespace`       | Kubernetes namespace where the LBC is deployed | `string`      | `"aws-load-balancer-controller"` |    no    |
| `service_account` | Kubernetes service account name for the LBC    | `string`      | `"aws-load-balancer-controller"` |    no    |
| `tags`            | Additional tags to apply to resources          | `map(string)` | `{}`                             |    no    |

## Outputs

| Name                          | Description                                        |
| ----------------------------- | -------------------------------------------------- |
| `role_name`                   | IAM role name for the AWS Load Balancer Controller |
| `role_arn`                    | IAM role ARN for the AWS Load Balancer Controller  |
| `pod_identity_association_id` | EKS Pod Identity association ID                    |

## IAM Policy

The inline IAM policy is derived from the upstream LBC recommended policy. It uses Pod Identity
(`pods.eks.amazonaws.com` principal) rather than IRSA, consistent with this platform's Pod Identity
preference for new workloads. Describe-only EC2 and ELB actions use `Resource: "*"` as required
by AWS; mutating actions are scoped by resource tags (`elbv2.k8s.aws/cluster`) where supported.

## Requirements

| Name      | Version   |
| --------- | --------- |
| terraform | >= 1.14.3 |
| aws       | >= 5.0    |
