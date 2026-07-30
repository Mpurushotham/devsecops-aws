# Problem statement

What this platform is for, and which problems it solves.

## The situation it addresses

A team is shipping containerised services to AWS. Security review happens late,
manually, and inconsistently. The recurring failures are these:

1. **Credentials outlive their purpose.** CI holds static AWS keys that never
   expire and are attributed to one principal regardless of who used them.
2. **Findings are reported, not enforced.** Scanners run, produce a dashboard,
   and the build ships anyway.
3. **Nobody knows what is actually deployed.** Cluster state is whatever the
   last successful job did, and manual changes are invisible.
4. **Misconfiguration is found by an auditor, months later.** A public bucket
   or a disabled trail sits undetected.
5. **Controls are switched on but not wired together.** GuardDuty and Config
   are enabled; nothing acts on what they find.

## Use cases

### UC-1: Ship a change without handling a credential

A developer merges to `develop`. The pipeline authenticates by OIDC, builds,
scans, signs and deploys. No human sees an AWS key, and CloudTrail attributes
every call to the workflow and commit that made it.

*Solved by:* per-environment OIDC roles ([ADR 0001](adr/0001-oidc-over-static-keys.md)).

### UC-2: Stop a vulnerable image reaching a cluster

A dependency picks up a CVE. Trivy and Grype fail the job **before** the push
step, so the image is never published and there is nothing to deploy. ECR
`IMMUTABLE` tags mean a scanned tag cannot later be replaced with different
bytes.

*Solved by:* the ordering in `container-build.yml`, demonstrated in
[scenario 3](scenarios/03-supply-chain-gate.md).

### UC-3: Know what is running, and revert it

Cluster state is a directory in git. `git log` is the deployment history,
`git revert` is the rollback, and ArgoCD's `selfHeal` undoes manual drift in
non-production.

*Solved by:* ArgoCD app-of-apps ([ADR 0003](adr/0003-gitops-with-argocd.md)).

### UC-4: Close a misconfiguration in seconds

A bucket loses its public access block. Config detects it, EventBridge invokes
the remediation Lambda, the block is restored, and a Security Hub finding
records the cause. Separately, the permission boundary denies the API call
outright for roles under it.

*Solved by:* Config rules plus `src/lambda/auto-remediation`, demonstrated in
[scenario 4](scenarios/04-auto-remediation.md).

### UC-5: Produce evidence for an audit

CloudTrail is multi-region with log file validation, delivered to a bucket with
Object Lock in production, and the permission boundary explicitly denies
`cloudtrail:StopLogging` and `cloudtrail:DeleteTrail`. The weekly compliance
workflow exports Security Hub, Config and GuardDuty state as a retained
artifact.

*Solved by:* the `cloudtrail`, `s3` and `iam` modules, plus
`compliance-report.yml`.

### UC-6: Contain a compromised container

A pod cannot reach the instance metadata service, so it cannot steal the node's
IAM credentials. It runs non-root with a read-only root filesystem and all
capabilities dropped. Egress is restricted to VPC endpoints. IMDSv2 is required
with a hop limit of 1, so even a proxy on the node cannot be used to reach IMDS
from a pod.

*Solved by:* the NetworkPolicy, pod security context, and the EKS launch
template ([ADR 0007](adr/0007-network-egress.md)).

## What this platform does not solve

Stating these plainly, because a reference platform that implies completeness is
worse than one that does not:

- **No multi-account separation in practice.** The `organizations` module
  exists, but all three environments target one account. Real isolation means
  separate accounts per environment.
- **No secrets management workflow.** Secrets Manager is referenced; rotation
  is a stub script.
- **No DR or backup strategy.** No cross-region replication, no tested restore.
- **No runtime threat detection in-cluster.** GuardDuty covers the AWS control
  plane and EKS audit logs; there is no Falco-equivalent watching syscalls.
- **Not load-tested.** The controls are demonstrated, not proven under load.
- **Production OIDC trust is too broad.** The role trusts any branch in the
  repository; production should be narrowed before real workloads run there.
  This is called out in [ADR 0001](adr/0001-oidc-over-static-keys.md).
