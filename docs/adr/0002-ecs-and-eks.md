# 0002: Run both ECS and EKS rather than choosing one

**Status:** Accepted
**Date:** 2026-07-28

## Problem

The platform provisions both an ECS cluster and an EKS cluster in every
environment. That is unusual, and duplicated cost, so it needs justifying or
removing.

## Decision

Keep both, with a stated division:

- **ECS Fargate** runs the first-party API. No node fleet to patch, no
  Kubernetes control plane to upgrade, and the task definition is the whole
  deployment unit.
- **EKS** runs the multi-service sample workload and anything needing
  Kubernetes primitives: network policies, service mesh, operators, or an
  ecosystem component that only ships as a Helm chart.

## Why not pick one

**ECS only** would mean the platform cannot demonstrate IRSA, network policies,
pod security standards, admission control or GitOps reconciliation. Those are
the controls most organisations are actually asking about.

**EKS only** would mean paying a Kubernetes upgrade cadence for a single
stateless HTTP service, and would make the simplest deployment path the most
complex one.

## Consequences

**Cost.** Roughly $73/month per EKS control plane per environment, on top of
the node fleet. Real, and the reason dev uses a single NAT gateway and
`t3.medium` nodes.

**Duplication.** Two deployment workflows, two sets of health checks, two
rollback mechanisms. Mitigated by both consuming the same container image from
the same ECR repository, scanned and signed once by the same pipeline.

**Honest limitation.** Running both means neither is exercised as hard as it
would be if it were the only target. This platform demonstrates the controls; it
is not evidence that either path has been load-tested.
