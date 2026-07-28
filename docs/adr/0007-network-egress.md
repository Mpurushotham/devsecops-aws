# 0007: Egress scoped to VPC endpoints, with one documented exception

**Status:** Accepted
**Date:** 2026-07-28

## Problem

Every workload security group allowed egress to `0.0.0.0/0`, in several cases on
all protocols and ports. Trivy reported nine instances of AWS-0104.

Unrestricted egress is how data leaves after a compromise. A container that can
reach any host on the internet can exfiltrate to any host on the internet.

## Decision

Add interface VPC endpoints for the AWS services these workloads actually call:
`ecr.api`, `ecr.dkr`, `logs`, `secretsmanager`, `sts`, `ssm`, `ssmmessages`,
`ec2messages`, `elasticloadbalancing` and `eks`. S3 and DynamoDB already had
gateway endpoints.

With those in place, scope egress to what each component needs:

| Component | Egress |
|---|---|
| ECS tasks | 443 to the VPC CIDR, plus the S3 prefix list |
| EKS control plane | to the node security group only |
| EKS nodes | 443 and 53 to the VPC CIDR, **plus 443 to 0.0.0.0/0** |

## The exception

EKS nodes keep 443 to the internet, recorded in `.trivyignore.yaml`.

Nodes pull from registries AWS does not front with an endpoint: upstream Helm
charts, `ghcr.io`, `quay.io`, Docker Hub, plus Sigstore and the OIDC endpoints
used to verify signatures. Removing this rule requires mirroring every
third-party image into ECR first.

That is the correct end state. It is not implemented here, and the suppression
says so rather than pretending the rule is unnecessary.

## Consequences

**Gained.** Traffic to AWS APIs stays on the AWS network. ECS tasks have no
route to the open internet at all. NAT charges drop, since ECR layer pulls are
S3-backed and now take the gateway endpoint.

**Cost.** Interface endpoints are roughly $7/month each per AZ. With ten
endpoints across two AZs that is material, and it is the single largest line
item this decision adds.

**Trap.** Adding a new AWS service call from a workload will now fail with a
timeout rather than working transparently, because there is no NAT path to fall
back on. The fix is to add the endpoint, not to widen the security group.
