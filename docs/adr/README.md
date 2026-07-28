# Architecture Decision Records

Each record states the problem, the decision, and what it costs. A record
without a stated cost is usually a decision that was never really made.

| # | Decision | Status |
|---|---|---|
| [0001](0001-oidc-over-static-keys.md) | GitHub OIDC instead of long-lived AWS keys | Accepted |
| [0002](0002-ecs-and-eks.md) | Run both ECS and EKS rather than choosing one | Accepted |
| [0003](0003-gitops-with-argocd.md) | ArgoCD for Kubernetes delivery, Actions for ECS | Accepted |
| [0004](0004-state-backend-bootstrap.md) | State bucket created outside Terraform | Accepted |
| [0005](0005-trivy-replaces-tfsec.md) | Trivy replaces the end-of-life tfsec | Accepted |
| [0006](0006-mandatory-tls.md) | No plaintext listener in any environment | Accepted |
| [0007](0007-network-egress.md) | Egress scoped to VPC endpoints, one documented exception | Accepted |
| [0008](0008-vendored-sample-app.md) | Vendor the AWS sample app rather than submodule it | Accepted |
| [0009](0009-pin-actions-by-sha.md) | Pin GitHub Actions by commit SHA, not moving tags | Accepted |
