# 0001: GitHub OIDC instead of long-lived AWS keys

**Status:** Accepted
**Date:** 2026-07-28

## Problem

The pipeline needs to push images to ECR, run Terraform, and update ECS
services. Something has to authenticate to AWS.

The repository was doing both at once. `devsecops-pipeline.yml` used
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` repository secrets, while
`terraform-validate.yml`, `container-build.yml` and the deploy workflows used
OIDC role assumption. So the account was exactly as secure as the weaker of the
two, and the stronger mechanism was providing false reassurance.

Static keys are a poor fit here specifically because:

- They do not expire, so a leak is permanent until someone notices and rotates.
- They appear in the audit trail as one principal regardless of which workflow,
  branch or commit used them.
- Rotation is manual, so in practice it does not happen.

## Decision

Every workflow authenticates through the GitHub OIDC provider and assumes a
per-environment role. The static-key path is removed, not merely deprecated.

Trust is scoped in `modules/iam`:

```hcl
Condition = {
  StringLike  = { "token.actions.githubusercontent.com:sub" = "repo:Mpurushotham/devsecops-aws:*" }
  StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
}
```

## Consequences

**Gained.** Credentials last minutes. CloudTrail shows the workflow and commit
behind each call. There is no secret to rotate or leak.

**Cost.** The OIDC provider must exist before the first run, which is why
`scripts/bootstrap.sh` creates it. Forks cannot assume the role, so
`plan-dev` is skipped on fork pull requests rather than failing.

**Sharper than it looks.** The `sub` condition uses `repo:...:*`, which trusts
*any* branch in this repository. A pull request branch can therefore assume the
dev role. That is acceptable for dev and not for production: the production
role should be narrowed to `ref:refs/heads/main` or an `environment:production`
subject before real workloads run there.
