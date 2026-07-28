# 0004: State bucket created outside Terraform

**Status:** Accepted
**Date:** 2026-07-28

## Problem

Each environment declared an S3 backend in a bucket that the same configuration
also created:

```hcl
backend "s3" { bucket = "devsecops-aws-tfstate-dev" ... }
module "s3_tfstate" { bucket_name = "devsecops-aws-tfstate-dev" ... }
```

Terraform initialises the backend before evaluating resources, so the first
`terraform init` failed against a bucket that did not exist. And once
`scripts/bootstrap.sh` had created it, `terraform apply` failed the other way:
`BucketAlreadyExists` for a bucket it believed it owned.

## Decision

The state bucket and lock table are created by `scripts/bootstrap.sh` and are
not Terraform-managed. The `s3_tfstate` module block is removed from every
environment, and the backend block carries a comment saying why.

## Alternatives rejected

**A separate bootstrap Terraform configuration with a local backend.** Cleaner
in principle, but it moves the problem: the local state file then has to be
committed or stored somewhere, and it is the one piece of state nobody can
afford to lose.

**`terraform init -backend=false` then migrate.** Works once, by hand, and
nobody remembers the sequence six months later.

## Consequences

**Gained.** `terraform init` works on a clean checkout. No resource is
described in two places.

**Cost.** The state bucket's configuration is enforced by a shell script rather
than by a plan, so drift on it is not detected. Given that its contents are
versioned and access is blocked at the account level, that is an acceptable
trade for the bootstrap path being reliable.

**Note.** The script is idempotent and safe to re-run; it checks for existence
before creating.
