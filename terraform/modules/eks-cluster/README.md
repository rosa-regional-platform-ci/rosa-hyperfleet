# EKS Cluster Module

Creates private EKS clusters with security-first configuration and standardized naming/tagging.

## Features

- **Deterministic Resource Naming**: Uses `cluster_id` for all resource names (e.g., `regional`, `mc01`)
- **Provider-Level Tagging**: Enforces required organizational tags via AWS provider default_tags
- **Fully Private Clusters**: EKS control plane with private endpoint only, no public API access
- **GitOps Bootstrap**: Automated Karpenter and ArgoCD installation via ECS Fargate task
- **Security Hardening**: KMS encryption, IMDSv2 enforcement, and network segmentation
- **High Availability**: Multi-AZ NAT Gateways for fault-tolerant egress connectivity
- **OSS Karpenter**: Self-managed Karpenter with AL2023 bootstrap node group, SQS interruption
  queue, and EventBridge rules (enabled by default via `enable_karpenter`)

## Compute Modes

The module supports two mutually exclusive compute modes selected by `enable_karpenter`:

### OSS Karpenter (default, `enable_karpenter = true`)

- EKS Auto Mode `compute_config`, `storage_config`, and `kubernetes_network_config` blocks are
  absent — Auto Mode is fully disabled
- An AL2023 managed node group (`t3.medium × 2`, `CriticalAddonsOnly:NoSchedule` taint) provides
  fixed bootstrap capacity for the Karpenter controller and other `CriticalAddonsOnly` system pods
- The Karpenter controller IAM role uses IRSA (OIDC provider resource created by the module)
- An EC2 instance profile for Karpenter-provisioned nodes is pre-created (`<cluster_id>-karpenter-node-role`)
- An SQS FIFO queue and four EventBridge rules receive Spot interruption, rebalance, state-change,
  and AWS Health events for graceful node draining
- Explicit EKS addons: `vpc-cni`, `kube-proxy`, `aws-ebs-csi-driver` (Pod Identity-backed),
  `coredns`, `metrics-server`, `eks-pod-identity-agent`, `aws-secrets-store-csi-driver-provider`

See [Karpenter Node Provisioning ADR](../../../docs/design/karpenter-node-provisioning.md) for
architecture rationale.

### EKS Auto Mode (`enable_karpenter = false`)

- `compute_config.node_pools = ["system"]` retains the built-in system pool for CoreDNS and
  metrics-server, while `general-purpose` is excluded so workload pods land on the FIPS NodePool
- Auto Mode manages storage and load balancing via `storage_config` and `kubernetes_network_config`

See [FIPS-Only EKS Compute ADR](../../../docs/design/fips-eks-compute.md) for the Auto Mode
strategy (superseded by OSS Karpenter as of this module version).

## Naming Convention

All resources are named using the `cluster_id` variable (e.g., `regional`, `mc01`, or `xg4y-regional`
in CI). Resource names are deterministic — no random suffixes.

**Examples:**

- EKS Cluster: `mc01`
- VPC: `mc01-vpc`
- IAM Roles: `mc01-cluster-role`, `mc01-karpenter-node-role`, `mc01-karpenter-controller`, `mc01-ebs-csi-role`
- SQS Queue: `mc01-karpenter`

## Required Provider Configuration

```hcl
provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = {
      app-code      = "APP001"      # CMDB Application ID (required)
      service-phase = "development" # development, staging, or production (required)
      cost-center   = "123"         # 3-digit cost center code (required)
    }
  }
}
```

## Usage

### Management Cluster

```hcl
module "management_cluster" {
  source = "./terraform/modules/eks-cluster"

  cluster_id    = var.management_id
  cluster_type  = "management-cluster"
  vpc_id        = module.vpc.vpc_id
  vpc_cidr      = module.vpc.vpc_cidr
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_security_group_id       = module.vpc.cluster_security_group_id
  vpc_endpoints_security_group_id = module.vpc.vpc_endpoints_security_group_id
}
```

### Regional Cluster

```hcl
module "regional_cluster" {
  source = "./terraform/modules/eks-cluster"

  cluster_id    = var.regional_id
  cluster_type  = "regional-cluster"
  vpc_id        = module.vpc.vpc_id
  vpc_cidr      = module.vpc.vpc_cidr
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_security_group_id       = module.vpc.cluster_security_group_id
  vpc_endpoints_security_group_id = module.vpc.vpc_endpoints_security_group_id
}
```

## Variables

| Name                              | Description                                                                                                    | Type           | Default  | Required |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------- | -------- | -------- |
| `cluster_id`                      | Deterministic cluster identifier for resource naming (e.g., `regional`, `mc01`)                                | `string`       | n/a      | yes      |
| `cluster_type`                    | Type of cluster: `regional-cluster` or `management-cluster`                                                    | `string`       | n/a      | yes      |
| `vpc_id`                          | VPC ID where the EKS cluster will be deployed                                                                  | `string`       | n/a      | yes      |
| `vpc_cidr`                        | VPC CIDR block (used for security group rules)                                                                 | `string`       | n/a      | yes      |
| `private_subnet_ids`              | Private subnet IDs for EKS worker nodes                                                                        | `list(string)` | n/a      | yes      |
| `cluster_security_group_id`       | Pre-created security group ID for EKS cluster control plane                                                    | `string`       | n/a      | yes      |
| `vpc_endpoints_security_group_id` | Pre-created security group ID for VPC endpoints                                                                | `string`       | n/a      | yes      |
| `cluster_version`                 | Kubernetes version                                                                                             | `string`       | `"1.34"` | no       |
| `enable_pod_security_standards`   | Enable Kubernetes Pod Security Standards                                                                       | `bool`         | `true`   | no       |
| `enable_karpenter`                | Enable OSS Karpenter instead of EKS Auto Mode. Mutually exclusive with Auto Mode.                              | `bool`         | `true`   | no       |
| `ami_kms_key_arn`                 | ARN of the Red Hat KMS key for RHEL FIPS AMI EBS snapshot decryption. Leave empty to skip KMS policy creation. | `string`       | `""`     | no       |

## Outputs

| Name                                   | Description                                                                                                               |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `cluster_name`                         | EKS cluster name (same as `cluster_id`)                                                                                   |
| `cluster_arn`                          | ARN of the EKS cluster                                                                                                    |
| `cluster_endpoint`                     | EKS cluster API endpoint                                                                                                  |
| `cluster_version`                      | Kubernetes version of the EKS cluster                                                                                     |
| `cluster_certificate_authority_data`   | Base64 encoded certificate data for kubectl (sensitive)                                                                   |
| `cluster_security_group_id`            | Security group ID attached to the EKS cluster (pass-through)                                                              |
| `vpc_endpoints_security_group_id`      | Security group ID for VPC endpoints (pass-through)                                                                        |
| `node_security_group_id`               | EKS-managed node security group ID                                                                                        |
| `kms_key_arn`                          | ARN of the KMS key used for EKS secrets encryption                                                                        |
| `kms_key_alias`                        | Alias of the KMS key used for EKS secrets encryption                                                                      |
| `vpc_id`                               | VPC ID (pass-through)                                                                                                     |
| `private_subnet_ids`                   | Private subnet IDs (pass-through)                                                                                         |
| `cluster_iam_role_arn`                 | IAM role ARN of the EKS cluster service role                                                                              |
| `node_iam_role_arn`                    | IAM role ARN for cluster nodes (Karpenter node role or Auto Mode node role, depending on `enable_karpenter`)              |
| `karpenter_controller_role_arn`        | IAM role ARN for the Karpenter controller (IRSA). `null` when `enable_karpenter = false`.                                 |
| `karpenter_queue_url`                  | SQS queue URL for Karpenter interruption handling. `null` when `enable_karpenter = false`.                                |
| `karpenter_node_instance_profile_name` | EC2 instance profile name for Karpenter nodes (matches `EC2NodeClass.spec.role`). `null` when `enable_karpenter = false`. |

## Bootstrap Functionality

The ECS bootstrap task (managed by the `ecs-bootstrap` module) runs inside the cluster VPC and:

1. Waits for CoreDNS and metrics-server addons to become Active (using the AL2023 bootstrap node group)
2. Installs Karpenter via Helm from `public.ecr.aws/karpenter/karpenter`
3. Applies the `EC2NodeClass` and `NodePool` from `argocd/config/<cluster-type>/eks-nodepool/`
4. Runs a prewarm pod to validate Karpenter can provision a node before proceeding
5. Installs ArgoCD via Helm and creates the root Application of Applications

See [ECS Fargate Bootstrap ADR](../../../docs/design/fully-private-eks-bootstrap.md) for the
bootstrap architecture and [Karpenter Node Provisioning ADR](../../../docs/design/karpenter-node-provisioning.md)
for the node provisioning strategy.

## Requirements

- Terraform >= 1.14.3
- AWS Provider >= 6.0
- Required provider `default_tags` configuration
