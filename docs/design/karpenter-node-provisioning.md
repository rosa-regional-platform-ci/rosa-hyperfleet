# OSS Karpenter Node Provisioning Architecture

**Last Updated Date**: 2026-06-30

## Summary

ROSA HyperFleet clusters migrate from EKS Auto Mode's embedded Karpenter to self-managed OSS
Karpenter. A small AL2023 managed node group provides bootstrap capacity for the Karpenter
controller pod. All platform and application workloads run on RHEL FIPS nodes provisioned by
Karpenter via a custom `EC2NodeClass` and `NodePool`. An SQS interruption queue enables
pre-emptive draining of Spot nodes before the 2-minute termination window.

This ADR supersedes [FIPS-Only Compute for EKS Auto Mode](./fips-eks-compute.md) for the node
provisioning mechanism. The following decisions from that ADR are inherited unchanged: the
FIPS workload scoping principle (provisioning infrastructure may be non-FIPS; customer-bearing
workloads must be FIPS), the subnet and security group tag selector pattern, the `WhenEmpty`
consolidation policy, and the 64 CPU / 256 GiB NodePool limits. The following decisions are
replaced: the NodeClass type (`eks.amazonaws.com/v1 NodeClass` → `karpenter.k8s.aws/v1
EC2NodeClass`), the node operating system (Bottlerocket → RHEL FIPS), and the bootstrap
capacity mechanism (Auto Mode `system` pool → AL2023 managed node group).

## Context

EKS Auto Mode bundles Karpenter as a managed component, providing compute, storage, and load
balancing capabilities in a single configuration block. The audit in ROSAENG-60925 identified
three reasons to migrate to OSS Karpenter:

1. **FIPS enforcement gap**: Auto Mode's `advancedSecurity.fips: true` NodeClass field enforces
   FIPS at the Bottlerocket OS level. OSS Karpenter has no equivalent field. Migrating without a
   replacement FIPS enforcement mechanism breaks the FedRAMP SC-13 control.
2. **OS flexibility**: Bottlerocket is the only AMI family Auto Mode supports for workload nodes.
   OSS Karpenter with `amiFamily: Custom` allows RHEL FIPS AMIs — Red Hat's validated FIPS
   140-2/140-3 modules align naturally with ROSA's Red Hat lineage and enterprise compliance
   posture.
3. **Operational independence**: Decoupling node provisioning from Auto Mode allows independent
   upgrades of the EBS CSI driver, AWS Load Balancer Controller, and Karpenter itself without
   co-dependency on Auto Mode's release cadence.

- **Problem Statement**: EKS Auto Mode must be disabled to enable independent management of
  compute, storage, and load balancing components. Disabling `compute_config` removes the embedded
  Karpenter controller and the built-in `system` node pool, leaving no capacity for any pods until
  a replacement node provisioner and bootstrap capacity are in place. Disabling Auto Mode also
  removes the `eks.amazonaws.com/v1 NodeClass` CRD and replaces it with the OSS
  `karpenter.k8s.aws/v1 EC2NodeClass` CRD; existing NodeClass and NodePool objects referencing the
  Auto Mode API group must be deleted and recreated before ArgoCD can sync the new manifests.
- **Constraints**:
  - The cluster is fully private — the Kubernetes API endpoint is not reachable from the public
    internet. All bootstrap operations run inside an ECS Fargate task in a private subnet. See
    [ECS Fargate Bootstrap for Fully Private EKS Clusters](./fully-private-eks-bootstrap.md).
  - The cluster uses `API_AND_CONFIG_MAP` authentication mode. EKS access entries authenticate
    nodes via `system:node:{{SessionName}}` where `SessionName` is the EC2 instance ID. Kubelet
    must register using the EC2 instance ID as the node name, not the private DNS hostname.
  - RHEL FIPS AMIs are encrypted with a Red Hat-owned KMS key. Cross-account KMS grants are
    required before Karpenter can launch instances from these AMIs.
  - OSS Karpenter requires a pre-existing EC2 instance profile. Auto Mode creates this implicitly
    from `node_role_arn`; OSS Karpenter does not.
- **Assumptions**:
  - RHEL FIPS AMI IDs are stored per-region in the cluster configuration and passed to the
    `EC2NodeClass` at render time.
  - The Karpenter controller is deployed via the EKS managed addon or a Helm chart in
    `kube-system`, managed by ArgoCD after the bootstrap task completes. See
    [GitOps Cluster Configuration Architecture](./gitops-cluster-configuration.md) for the
    bootstrap-then-handoff pattern.
  - Pod Identity (not IRSA) is the preferred AWS IAM integration mechanism for new workloads on
    this platform. Karpenter controller IAM uses IRSA because Karpenter predates Pod Identity
    support and the upstream Karpenter Helm chart configures IRSA by default. The OIDC provider
    resource required for IRSA is owned per the pattern described in
    [Regional OIDC Ownership](./regional-oidc-ownership.md).

## Alternatives Considered

1. **Retain EKS Auto Mode with Bottlerocket FIPS**: Zero migration cost. `advancedSecurity.fips:
true` enforces FIPS at the OS level. However, it couples storage, networking, and compute
   lifecycle to a single AWS-managed release, prevents independent EBS CSI driver upgrades, and
   precludes use of RHEL AMIs. Rejected as the long-term target state.

2. **OSS Karpenter with Bottlerocket FIPS AMIs**: Maintains the Bottlerocket OS used today.
   Bottlerocket bootstraps via its own API (`apiclient`), not `nodeadm`. The `InstanceIdNodeName`
   option is set via Bottlerocket's `kubernetes.nodeLabels` settings — workable but requires a
   different userData format than AL2023/RHEL, adding a separate code path. Bottlerocket also has
   fewer ecosystem tools than RHEL for security hardening and compliance scanning. Not chosen but
   not excluded for future use on specific cluster types.

3. **OSS Karpenter with RHEL FIPS AMIs (chosen)**: RHEL FIPS modules are Red Hat's validated
   FIPS 140-2/140-3 implementation. `nodeadm` provides a consistent bootstrap interface across
   AL2023 and RHEL. `InstanceIdNodeName: true` is a first-class `nodeadm` config option. Aligns
   with ROSA's Red Hat lineage and enterprise compliance tooling (OpenSCAP, RHEL security
   profiles).

4. **Managed node groups only (no Karpenter)**: Eliminates Karpenter operational complexity.
   Requires manual or Terraform-driven scaling; no bin-packing or Spot interruption handling.
   Loses the existing NodePool-based scaling model that platform teams depend on. Rejected.

## Design Rationale

- **Justification**: OSS Karpenter with RHEL FIPS AMIs is the only option that satisfies all
  three requirements simultaneously: FIPS enforcement at the OS level (SC-13), independent
  lifecycle management of storage and networking addons, and operational parity with the existing
  Karpenter-based scaling model.

- **Evidence**: RHEL FIPS 140-2/140-3 validation is maintained by Red Hat and listed in the NIST
  CMVP. `nodeadm`'s `InstanceIdNodeName` option is documented by AWS as the required configuration
  for EKS access entry authentication when kubelet hostname resolution differs from the EC2
  instance ID. The SQS interruption queue pattern is the standard Karpenter Spot handling
  mechanism, reducing unplanned disruptions from the default 2-minute hard termination to a
  graceful drain.

- **Comparison**: Alternative 1 (Auto Mode) cannot provide independent addon lifecycle management.
  Alternative 2 (Bottlerocket) adds a separate userData code path and has weaker enterprise
  compliance tooling. Alternative 4 (no Karpenter) loses bin-packing and Spot support.

## Architecture

### Bootstrap Node Group

A managed node group provides two AL2023 nodes that Karpenter controller and other
`CriticalAddonsOnly`-tolerating system pods can schedule on before any RHEL workload nodes exist.

| Parameter           | Value                                |
| ------------------- | ------------------------------------ |
| AMI family          | AL2023                               |
| Instance type       | `t3.medium`                          |
| Min / Max / Desired | 2 / 2 / 2                            |
| Taint               | `CriticalAddonsOnly=true:NoSchedule` |

No custom launch template is required. EKS managed node groups on AL2023 automatically set the
IMDSv2 hop limit to 2 — sufficient for containerized workloads to reach IMDS across the VPC CNI
veth pair. Node authentication is handled automatically by EKS regardless of node name format:
managed node groups register kubelet with the EC2 instance ID as the node name by default when
the cluster uses `API_AND_CONFIG_MAP` authentication mode, satisfying the
`system:node:{{SessionName}}` access entry pattern without a supplemental `NodeConfig`.

### EC2NodeClass

The `EC2NodeClass` uses the OSS Karpenter API group (`karpenter.k8s.aws/v1`), which replaces the
EKS Auto Mode `eks.amazonaws.com/v1 NodeClass` that currently exists in the cluster. The old
`NodeClass` and `NodePool` objects referencing `eks.amazonaws.com` must be deleted prior to
applying these manifests; ArgoCD sync will fail with a CRD not found error otherwise.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: fips
spec:
  amiFamily: Custom
  amiSelectorTerms:
    - id: <rhel-fips-ami-id> # per-region, from cluster config
  role: <cluster-id>-node-role # instance profile name (must pre-exist)
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/<cluster-id>: owned
  securityGroupSelectorTerms:
    - tags:
        aws:eks:cluster-name: <cluster-id>
  metadataOptions:
    httpTokens: required # IMDSv2 only
    httpPutResponseHopLimit: 2 # explained below
  userData: |
    #!/bin/bash
    nodeadm init --config-source inline:- <<'EOF'
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: <cluster-id>
        apiServerEndpoint: <endpoint>
        certificateAuthority: <ca>
        cidr: <service-cidr>
      kubelet:
        config:
          instanceIdNodeName: true
    EOF
```

`httpPutResponseHopLimit: 2` is required for containerized workloads to reach IMDS. With the EKS
VPC CNI plugin, pods receive routable VPC IPs — there is no NAT between pod and host. However,
IMDS requests from a pod traverse the veth pair between the pod network namespace and the host
network stack, which counts as one hop. With the default `hopLimit: 1`, the TTL is exhausted
before the packet reaches the IMDS endpoint at `169.254.169.254`. Setting `hopLimit: 2` allows
exactly one veth hop plus arrival at IMDS. Setting it higher than 2 is unnecessary and expands
the IMDS attack surface.

### NodePool

The `NodePool` references `karpenter.k8s.aws` as the `nodeClassRef` group, consistent with the
OSS Karpenter CRD group. This replaces the existing `eks.amazonaws.com` group in the current
NodePool manifests.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: <cluster-type>-workloads # regional-workloads or management-workloads
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: fips
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [on-demand] # default; override to spot via config
        - key: kubernetes.io/arch
          operator: In
          values: [amd64]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: # m8i/m7i families, large–4xlarge
            - m8i.large
            - m8i.xlarge
            - m8i.2xlarge
            - m8i.4xlarge
            - m7i.large
            - m7i.xlarge
            - m7i.2xlarge
            - m7i.4xlarge
  limits:
    cpu: "64"
    memory: 256Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 60s
```

### SQS Interruption Queue

An SQS FIFO queue subscribes to EC2 event sources so Karpenter can drain nodes before the
2-minute termination window:

| Event source                          | Purpose                                        |
| ------------------------------------- | ---------------------------------------------- |
| EC2 Spot Instance Interruption        | 2-minute warning before Spot reclaim           |
| EC2 Instance Rebalance Recommendation | Early warning signal for proactive replacement |
| EC2 Scheduled Change (AWS Health)     | Planned maintenance, retirement, stop events   |

The queue ARN is passed to the Karpenter controller via `--interruption-queue-name`. EventBridge
rules forward these events from the default event bus to the SQS queue.

### IAM Architecture

**Karpenter controller role (IRSA)**

| Element         | Value                                                                                                                                                                                                                                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Trust principal | `system:serviceaccount:kube-system:karpenter`                                                                                                                                                                                                                                                                             |
| OIDC condition  | `oidc.eks.<region>.amazonaws.com/id/<oidc-id>:sub = system:serviceaccount:kube-system:karpenter`                                                                                                                                                                                                                          |
| Permissions     | EC2 fleet (CreateFleet, TerminateInstances, DescribeInstances, DescribeSubnets, DescribeSecurityGroups, DescribeLaunchTemplates, CreateLaunchTemplate, DeleteLaunchTemplate), SQS (ReceiveMessage, DeleteMessage, GetQueueAttributes, GetQueueUrl), EKS (DescribeCluster), IAM (PassRole scoped to the node IAM role ARN) |

**Node instance profile**

Auto Mode creates an EC2 instance profile implicitly from `compute_config.node_role_arn`. OSS
Karpenter requires an `aws_iam_instance_profile` resource that wraps the node IAM role. The
`EC2NodeClass` `role` field references the **instance profile name** (not the role ARN). The
Karpenter controller's `iam:PassRole` permission must be scoped to the underlying **IAM role ARN**
(e.g., `arn:aws:iam::<account>:role/<cluster-id>-node-role`), because `PassRole` is a permission
on roles, not on instance profiles.

Node role managed policies:

- `AmazonEKSWorkerNodePolicy` — core kubelet/node check-in permissions. The Auto Mode node role
  used `AmazonEKSWorkerNodeMinimalPolicy`, which is a reduced-permission variant designed
  specifically for Auto Mode's managed lifecycle model. OSS Karpenter nodes require the full
  standard policy.
- `AmazonEC2ContainerRegistryPullOnly` — minimal ECR image pull permissions.
- `AmazonEKS_CNI_Policy` — required for the `aws-node` VPC CNI daemonset to manage ENIs and
  assign secondary private IP addresses to pods. By default, `aws-node` derives these permissions
  from the host node's instance profile. This policy may be omitted only if `aws-node` is given a
  dedicated IAM role via IRSA or EKS Pod Identity — a future improvement aligned with this
  platform's Pod Identity preference, but not the current state.
- `AmazonSSMManagedInstanceCore` — enables SSM Session Manager for node access without a bastion.
  Required for break-glass access to Karpenter-provisioned nodes.

**Cross-account KMS grants**

RHEL FIPS AMIs distributed by Red Hat have their root EBS snapshot encrypted with a Red Hat
AWS account KMS key. Two grants are required on the Red Hat KMS key:

1. Grant to the node instance profile role — allows EC2 to decrypt the EBS volume when launching
   an instance from the AMI.
2. Grant to the Karpenter controller role — allows Karpenter to describe and validate the AMI's
   encryption configuration when selecting candidates.

Both grants are managed via `aws_kms_grant` resources in this repository's Terraform, targeting
the Red Hat KMS key ARN. The Red Hat key ARN must be provided as a Terraform input variable; it
is stable per Red Hat AWS account and region. Grants are applied before the ECS bootstrap task
runs, so no manual pre-arrangement with Red Hat is required.

## Consequences

### Positive

- FIPS 140-2/140-3 compliance (SC-13) is enforced via the RHEL OS rather than a NodeClass field,
  making FIPS enforcement durable across Karpenter version upgrades.
- EBS CSI driver, AWS Load Balancer Controller, and Karpenter can each be upgraded independently
  on their own cadence.
- The existing IMDSv2 enforcement TODO (`terraform/modules/eks-cluster/main.tf`) can be closed —
  `EC2NodeClass.spec.metadataOptions.httpTokens: required` provides the equivalent enforcement
  that was unavailable in Auto Mode.
- Spot interruption handling via SQS reduces unplanned workload disruptions compared to Auto Mode's
  default hard-termination behavior.
- The 21-day mandatory node rotation constraint imposed by Auto Mode is removed.
- `scripts/verify-fips.sh` already contains RHEL host-level FIPS checks (`/etc/system-fips`,
  `update-crypto-policies`, `fips-mode-setup --check`) that will activate automatically on RHEL
  nodes. The `advancedSecurity` NodeClass field checks will emit a SKIP (as designed at line 157)
  when upstream Karpenter CRDs are detected, which is the correct behaviour and requires no
  script changes.

### Negative

- The bootstrap node group (AL2023) is not FIPS-validated. Karpenter controller and
  `CriticalAddonsOnly`-tolerating system pods run on non-FIPS nodes. This is an accepted scope
  boundary: provisioning infrastructure vs. customer-bearing workloads (consistent with the
  inherited scoping principle from `fips-eks-compute.md`).
- Cross-account KMS grants for RHEL AMIs are managed via `aws_kms_grant` Terraform resources in
  this repository. The Red Hat KMS key ARN must be supplied as a Terraform input variable. A
  missing or incorrect ARN silently blocks all node launches.
- The migration from `eks.amazonaws.com/v1 NodeClass` to `karpenter.k8s.aws/v1 EC2NodeClass`
  requires deleting the existing NodeClass and NodePool objects before applying new ones. ArgoCD
  cannot perform an in-place sync because the CRD group changes. This must be coordinated as a
  controlled outage window or handled via the ECS bootstrap task before ArgoCD assumes ownership.
- Karpenter controller IRSA adds an OIDC provider resource to Terraform that must be bootstrapped
  before the ECS bootstrap task can apply the NodeClass.

## Cross-Cutting Concerns

### Reliability

- **Scalability**: The `<cluster-type>-workloads` NodePool is capped at 64 CPU / 256 GiB
  (matching the existing Auto Mode NodePool limits). This is intentional — hard limits prevent
  runaway provisioning.
- **Observability**: Karpenter emits Prometheus metrics (`karpenter_nodes_created_total`,
  `karpenter_nodepool_usage`, `karpenter_voluntary_disruption_decisions_total`) already consumed
  by the existing Grafana dashboards in `rc-health.json` and `mc-health.json`. Metric names are
  compatible between Auto Mode Karpenter and OSS Karpenter v1.
- **Resiliency**: The bootstrap node group runs 2 fixed nodes — no Karpenter dependency for the
  Karpenter controller itself. The SQS queue provides at-least-once delivery; Karpenter is
  idempotent on duplicate interruption events.

### Security

- RHEL FIPS 140-2/140-3 validated cryptographic modules satisfy FedRAMP SC-13 for
  customer-bearing workloads.
- IMDSv2 is enforced on all Karpenter-managed nodes via
  `EC2NodeClass.spec.metadataOptions.httpTokens: required`, closing the existing open TODO.
- `httpPutResponseHopLimit: 2` is the minimum value that allows pods to reach IMDS via the VPC
  CNI veth hop. Setting it to 1 blocks AWS SDK calls from any non-host-network pod; setting it
  above 2 is unnecessary and expands the IMDS attack surface.
- Karpenter controller IAM is scoped by OIDC condition to the `kube-system/karpenter` service
  account, preventing privilege escalation from other service accounts.
- Node IAM `PassRole` is scoped to the specific node IAM role ARN, not `*`.

### Performance

- RHEL FIPS mode activates the kernel's software FIPS enforcement layer in addition to Red Hat's
  validated crypto modules. For general-purpose compute, the overhead is negligible. For
  cryptography-intensive workloads (TLS termination at high throughput), benchmark against
  Bottlerocket FIPS if performance regression is a concern.
- RHEL node boot time is longer than Bottlerocket's due to a larger init process and service
  manager. Cold-start latency for new Karpenter-provisioned nodes will increase relative to
  Bottlerocket. For workloads sensitive to scale-out latency, pre-provisioning via `spec.limits`
  warm pools may be warranted.

### Cost

- AL2023 bootstrap nodes (t3.medium × 2) add approximately $60/month per cluster at on-demand
  pricing. This is fixed overhead independent of workload scale.
- Spot capacity type support (configurable via `eksNodePool.capacityType`) enables cost reduction
  for non-critical workloads at the cost of interruption exposure.
- The SQS queue and EventBridge rules have negligible cost at the event volumes this platform
  generates.

### Operability

- The EC2NodeClass and NodePool are applied by the ECS bootstrap task on first run and subsequently
  managed by ArgoCD, maintaining the existing GitOps ownership model described in
  [GitOps Cluster Configuration Architecture](./gitops-cluster-configuration.md).
- RHEL AMI IDs are region-specific and must be updated in cluster config as new RHEL FIPS AMI
  versions are released. AMI updates trigger rolling node replacement via Karpenter's drift
  detection.
- The bootstrap node group is a fixed-size managed node group (no autoscaling). Capacity changes
  require a Terraform apply.
- Karpenter controller upgrades are independent of EKS cluster version upgrades — no Auto Mode
  release coupling.
- The migration from Auto Mode requires a sequenced cutover: (1) disable `compute_config`, (2)
  install OSS Karpenter CRDs, (3) delete old `eks.amazonaws.com` NodeClass and NodePool objects,
  (4) apply new `karpenter.k8s.aws` EC2NodeClass and NodePool, (5) verify ArgoCD sync. Steps 1–4
  must occur within a single change window before any workloads become unschedulable.
