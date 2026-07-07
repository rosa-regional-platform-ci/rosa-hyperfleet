# ECS Bootstrap Module

This Terraform module creates ECS Fargate infrastructure for bootstrapping private EKS clusters.
It provides secure, auditable task execution within the cluster VPC — used for Karpenter
installation, NodePool seeding, and ArgoCD setup during initial cluster provisioning.

## Overview

The module creates:

- **ECS Fargate Cluster**: Dedicated cluster for bootstrap operations
- **ECS Task Definition**: Containerized bootstrap execution
- **IAM Roles**: Separate execution and task roles with minimal required permissions
- **Security Groups**: Network isolation with controlled EKS API access
- **CloudWatch Logging**: KMS-encrypted log group for audit trail of all bootstrap operations

## Usage

```hcl
module "ecs_bootstrap" {
  source = "../../../modules/ecs-bootstrap"

  cluster_id                    = var.regional_id
  vpc_id                        = module.eks_cluster.vpc_id
  private_subnets               = module.eks_cluster.private_subnets
  eks_cluster_arn               = module.eks_cluster.cluster_arn
  eks_cluster_name              = module.eks_cluster.cluster_name
  eks_cluster_security_group_id = module.eks_cluster.cluster_security_group_id
  container_image               = "<bootstrap-image>"
  karpenter_controller_role_arn = module.eks_cluster.karpenter_controller_role_arn
  karpenter_queue_url           = module.eks_cluster.karpenter_queue_url
}
```

## Security Features

### Network Security

- **Private Execution**: Tasks run in private subnets without public IPs
- **Controlled Access**: Security groups allow only necessary EKS API access (port 443)

### IAM Security

- **EKS Access Entries**: Uses EKS access entry mechanism for Kubernetes RBAC
- **Minimal Permissions**: Task role has only required EKS, SSM, and S3 permissions

### Audit Trail

- **CloudWatch Logs**: KMS-encrypted log group retaining all bootstrap operations for 365 days
- **ECS Task Tracking**: Task execution history and status via ECS console

## Inputs

| Name                            | Description                                                                                     | Type           | Default                                                 | Required |
| ------------------------------- | ----------------------------------------------------------------------------------------------- | -------------- | ------------------------------------------------------- | :------: |
| `cluster_id`                    | Cluster identifier for resource naming (e.g., `regional`, `mc01`)                               | `string`       | n/a                                                     |   yes    |
| `vpc_id`                        | VPC ID for ECS task execution                                                                   | `string`       | n/a                                                     |   yes    |
| `private_subnets`               | Private subnet IDs for task execution                                                           | `list(string)` | n/a                                                     |   yes    |
| `eks_cluster_arn`               | EKS cluster ARN for bootstrap configuration                                                     | `string`       | n/a                                                     |   yes    |
| `eks_cluster_name`              | EKS cluster name for bootstrap configuration                                                    | `string`       | n/a                                                     |   yes    |
| `eks_cluster_security_group_id` | EKS cluster security group ID                                                                   | `string`       | n/a                                                     |   yes    |
| `container_image`               | Container image for the bootstrap task (must have aws, kubectl, helm, git, jq)                  | `string`       | n/a                                                     |   yes    |
| `repository_url`                | Git repository URL for cluster configuration                                                    | `string`       | `"https://github.com/openshift-online/rosa-hyperfleet"` |    no    |
| `repository_branch`             | Git branch to use for cluster configuration                                                     | `string`       | `"main"`                                                |    no    |
| `thanos_kms_key_arn`            | KMS key ARN for Thanos S3 encryption                                                            | `string`       | `""`                                                    |    no    |
| `loki_kms_key_arn`              | KMS key ARN for Loki S3 encryption                                                              | `string`       | `""`                                                    |    no    |
| `management_clusters`           | Comma-separated colon-delimited MC entries (e.g. `mc01:123456789012`)                           | `string`       | `""`                                                    |    no    |
| `karpenter_controller_role_arn` | IAM role ARN for the Karpenter controller (IRSA). Required when the cluster uses OSS Karpenter. | `string`       | `""`                                                    |    no    |
| `karpenter_queue_url`           | SQS queue URL for Karpenter interruption handling                                               | `string`       | `""`                                                    |    no    |
| `karpenter_version`             | Karpenter Helm chart version to install during bootstrap                                        | `string`       | `"1.13.0"`                                              |    no    |

## Outputs

| Name                          | Description                                            |
| ----------------------------- | ------------------------------------------------------ |
| `ecs_cluster_arn`             | ARN of the ECS cluster for bootstrap tasks             |
| `task_definition_arn`         | ARN of the ECS task definition for bootstrap execution |
| `log_group_name`              | CloudWatch log group name for bootstrap operations     |
| `bootstrap_security_group_id` | Security group ID for bootstrap ECS tasks              |
| `private_subnets`             | Private subnet IDs where bootstrap tasks run           |

## Requirements

| Name      | Version   |
| --------- | --------- |
| terraform | >= 1.14.3 |
| aws       | >= 5.0    |
