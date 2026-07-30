# Deployment scenarios

Each scenario is an end-to-end path through the platform, written so it can be
followed start to finish and so the failure modes are stated rather than
discovered.

| # | Scenario | Target | Delivery | Doc |
|---|---|---|---|---|
| 1 | First-party API to ECS Fargate | ECS | GitHub Actions push | [01-ecs-fargate.md](01-ecs-fargate.md) |
| 2 | Retail store sample to EKS via GitOps | EKS | ArgoCD | [02-eks-gitops.md](02-eks-gitops.md) |
| 3 | A vulnerable image is blocked | either | pipeline gate | [03-supply-chain-gate.md](03-supply-chain-gate.md) |
| 4 | A public S3 bucket is auto-remediated | n/a | Config + Lambda | [04-auto-remediation.md](04-auto-remediation.md) |

## Prerequisites common to all scenarios

The bootstrap is deliberately outside Terraform, because Terraform cannot
create the bucket that stores its own state:

```bash
export AWS_REGION=us-east-1
./scripts/bootstrap.sh          # state bucket, lock table, GitHub OIDC provider
```

Then, per environment:

```bash
cd terraform/environments/dev
terraform init
terraform apply -var="certificate_arn=arn:aws:acm:us-east-1:<account>:certificate/<id>"
```

`certificate_arn` has no default on purpose. The ECS module has no plaintext
listener, so there is no configuration in which the load balancer silently
serves HTTP. If the environment has no domain yet, import a self-signed
certificate into ACM rather than weakening the module.

## What each scenario is meant to prove

These are not a feature tour. Each one exists because something in the platform
is only trustworthy if it has been observed working:

1. **ECS Fargate** proves the OIDC trust chain, the ECR push path, and that a
   rollback restores the previous task definition rather than redeploying the
   broken one.
2. **EKS GitOps** proves IRSA works end to end, that the cluster converges from
   git alone, and that production does not move without a release tag.
3. **Supply chain gate** proves the pipeline actually refuses to publish, rather
   than reporting and continuing.
4. **Auto-remediation** proves the detective and responsive controls are wired
   to each other, not just both switched on.
