# FIPS-Only Compute for EKS Auto Mode

> **Superseded.** This ADR documents the EKS Auto Mode FIPS strategy, which has been
> replaced by [OSS Karpenter Node Provisioning](./karpenter-node-provisioning.md). It is
> retained for historical context and to explain decisions that the new ADR inherits.

**Last Updated Date**: 2026-05-15

## Summary

All EKS clusters in the ROSA HyperFleet use a custom Karpenter NodePool referencing a
FIPS-validated NodeClass for platform and application workloads. The built-in EKS Auto Mode
`system` node pool is retained to provide nodes for CoreDNS and metrics-server. The built-in
`general-purpose` pool is disabled so that non-system workloads land on the FIPS NodePool rather
than on non-FIPS nodes.

## Context

FedRAMP High/Moderate authorization requires that all cryptographic operations use FIPS 140-2 or
FIPS 140-3 validated modules. On EKS, this means workload compute must run a FIPS-validated
operating system — specifically Bottlerocket with FIPS mode enabled.

- **Problem Statement**: EKS Auto Mode's built-in node pools (`system` and `general-purpose`)
  provision standard (non-FIPS) Bottlerocket AMIs. Disabling both pools with `node_pools = []`
  creates a bootstrap deadlock: EKS Auto Mode's embedded Karpenter is reactive — it only creates
  nodes in response to unschedulable pods. With no built-in pools, CoreDNS and metrics-server
  remain Pending until a FIPS NodePool exists, but the FIPS NodeClass's `InstanceProfileReady`
  condition is evaluated only at creation time and depends on `node_role_arn` being set in the
  cluster's `compute_config`. Any mismatch between cluster configuration and NodeClass creation
  order results in `UnauthorizedNodeRole`, permanently blocking node provisioning.
- **Constraints**:
  - EKS Auto Mode's built-in node pools cannot be patched to reference a custom NodeClass. AWS
    auto-reverts any modifications.
  - EKS Auto Mode manages CoreDNS and metrics-server scheduling constraints; they are not
    user-configurable.
  - The cluster bootstrap runs inside an ECS Fargate task in a private subnet with no public
    cluster API access. See [ECS Fargate Bootstrap for Fully Private EKS Clusters](./fully-private-eks-bootstrap.md).
- **Assumptions**: EKS Auto Mode is retained for operational simplicity (managed control plane,
  embedded Karpenter, automatic node lifecycle management). Self-managed Karpenter is not a
  preferred alternative.

## Alternatives Considered

1. **Keep both built-in pools enabled (`system` + `general-purpose`)**: CoreDNS and metrics-server
   provision naturally; all workloads land on non-FIPS nodes. Violates the FedRAMP cryptographic
   module requirement for platform workloads. Rejected.

2. **Disable all built-in pools (`node_pools = []`)**: All nodes come from custom FIPS NodePools.
   Creates a bootstrap deadlock: the FIPS NodeClass `InstanceProfileReady` condition is only
   evaluated at NodeClass creation time. If `node_role_arn` is absent at cluster creation (even
   temporarily), the NodeClass is permanently stuck with `UnauthorizedNodeRole` and no nodes can
   be provisioned. Operationally fragile. Rejected.

3. **Patch built-in node pools to use a FIPS NodeClass**: AWS Auto Mode auto-reverts user
   modifications to built-in pools within minutes. Not durable. Rejected.

4. **Replace EKS Auto Mode with self-managed Karpenter**: Achieves FIPS compliance but loses Auto
   Mode's managed node lifecycle and unified support. Significantly increases operational
   complexity. Rejected.

5. **Retain `system` pool, disable `general-purpose`, add FIPS workloads NodePool**: The built-in
   `system` pool provides nodes for CoreDNS and metrics-server immediately at cluster creation,
   avoiding the bootstrap deadlock. The `general-purpose` pool is disabled so workloads cannot
   land on non-FIPS nodes. A custom FIPS `*-workloads` NodePool handles all platform and
   application workloads. **Chosen.**

## Design Rationale

- **Justification**: Retaining the built-in `system` pool eliminates the bootstrap deadlock
  entirely — CoreDNS and metrics-server are Active before the ECS bootstrap task runs. Disabling
  `general-purpose` ensures that pods without explicit FIPS node selectors are not silently
  scheduled on non-FIPS nodes. All platform and application workloads land on the FIPS NodePool.

- **Evidence**: The `InstanceProfileReady` condition on a custom NodeClass is evaluated only at
  NodeClass creation time, not when cluster configuration changes. This makes the `node_pools = []`
  pattern operationally fragile: it requires that `node_role_arn` be set in `compute_config` before
  the NodeClass is first applied, and there is no mechanism to re-trigger evaluation on an existing
  NodeClass. Retaining the `system` pool removes this dependency entirely.

- **Tradeoff**: Nodes provisioned by the built-in `system` pool run non-FIPS Bottlerocket AMIs.
  These nodes host only EKS-managed system addons (CoreDNS, metrics-server). Platform and
  application workloads run exclusively on the FIPS NodePool. This is an accepted scope boundary:
  EKS-managed system infrastructure vs. customer-bearing workloads.

- **Comparison**: Alternative 2 (`node_pools = []`) is the theoretically cleanest approach but
  introduces bootstrap fragility that caused repeated failures in practice. Alternative 5 (chosen)
  achieves the same workload-level FIPS compliance with a simpler, more robust bootstrap.

## Consequences

### Positive

- Platform and application workloads run on Bottlerocket with FIPS-validated cryptographic modules,
  satisfying FedRAMP High/Moderate cryptographic requirements for customer-bearing compute.
- Bootstrap is reliable: the built-in `system` pool provisions nodes and brings up CoreDNS and
  metrics-server automatically. The bootstrap task applies the FIPS NodeClass and workloads
  NodePool, waits for both addons to become Active, then installs ArgoCD — no custom node-wait
  loop or addon creation required.
- The FIPS NodeClass and workloads NodePool are applied by the ECS bootstrap task and subsequently
  adopted by ArgoCD on first sync, making them GitOps-managed.
- Disabling `general-purpose` prevents accidental scheduling of platform workloads on non-FIPS
  nodes.

### Negative

- EKS-managed system addons (CoreDNS, metrics-server) run on non-FIPS `system` pool nodes. These
  nodes are AWS-managed infrastructure, not customer-bearing workloads, but they are not
  FIPS-validated.
- EKS Auto Mode enforces a mandatory 21-day maximum node lifetime. Stateful workloads (Thanos,
  Grafana) must have `PodDisruptionBudgets` to prevent data loss during node rotation.
- Adding a new cluster type requires updating the bootstrap script's `NODEPOOL_NAME` selection
  logic.

## Cross-Cutting Concerns

### Reliability

- **Scalability**: The FIPS `*-workloads` NodePool is large (64 CPU / 256 GiB) and handles all
  platform and application workloads. The built-in `system` pool is AWS-managed and scales
  automatically for CoreDNS and metrics-server.
- **Observability**: Karpenter NodeClaims are visible via `kubectl get nodeclaims`. CloudWatch
  logs for the ECS bootstrap task provide a full audit trail.
- **Resiliency**: The 21-day mandatory rotation means PodDisruptionBudgets are load-bearing for
  stateful workloads — their absence is a reliability risk, not just a compliance gap.

### Security

- Platform and application workload nodes run with `advancedSecurity.fips: true` and
  `kernelLockdown: Integrity`, satisfying FIPS 140-2/140-3 requirements for SC-13.
- The FIPS NodeClass selects subnets and security groups via cluster-owned tags, ensuring nodes
  land in the correct private subnets with correct network policies.
- Node IAM role (`${cluster_id}-auto-node-role`) is referenced directly in the NodeClass, scoping
  node permissions to a cluster-specific role.

### Performance

- FIPS-mode Bottlerocket has negligible performance overhead for general-purpose workloads.
- `consolidateAfter: 60s` on the workloads NodePool enables rapid scale-down of idle capacity.

### Cost

- One custom NodePool adds no direct AWS cost. Node costs are identical: on-demand EC2 instances
  running Bottlerocket.
- `WhenEmpty` consolidation reclaims idle capacity promptly, reducing EC2 spend.

### Operability

- The FIPS NodeClass and workloads NodePool are created by the ECS bootstrap task on first run and
  subsequently managed by ArgoCD. Day-2 changes are made via GitOps — no manual `kubectl apply`.
- The 21-day mandatory rotation is fully automatic. Operators need only ensure PodDisruptionBudgets
  exist for stateful workloads.
- Cluster type-specific NodePool naming (`management-workloads` vs `regional-workloads`) is
  resolved at bootstrap time via the `CLUSTER_TYPE` environment variable.
