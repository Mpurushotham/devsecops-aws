# 0008: Vendor the AWS sample app rather than submodule it

**Status:** Accepted
**Date:** 2026-07-28

## Problem

The platform needed a workload realistic enough to prove the pipeline works.
`src/app` is a single FastAPI service, which exercises almost none of the
multi-service, multi-language, stateful-dependency behaviour the platform
claims to support.

## Decision

Vendor `aws-containers/retail-store-sample-app` at tag `v1.6.2` into `app/`,
excluding its `.git`. Provenance is recorded in `app/VENDOR.md`.

## Why vendored, not a submodule

A submodule keeps the tree ~27 MB smaller, but a clone is then not
self-contained, CI has to recurse, and the exact bytes deployed depend on a
pointer resolved elsewhere. For a directory whose purpose is to be a
reproducible deployment target, having the reviewed bytes committed is worth
the size.

## Scanner scope

Third-party code does not gate this repository's CI:

- `.semgrepignore` excludes `app/`.
- `pip-audit` is scoped to `src/`.
- CodeQL analyses Python only, and the sample is Java, Go and Node.

It is still scanned where it matters: any image built from it goes through the
same Trivy and Grype gates as first-party code, because that is what actually
reaches a cluster.

## Consequences

**Gained.** Five services in four languages, with MySQL, DynamoDB, Redis and
RabbitMQ dependencies, which forced the network policy, security group and IRSA
work to be correct rather than theoretical.

**Cost.** 27 MB in the repository, and a refresh is a manual step. Upstream
security fixes arrive only when someone bumps the version.

**Risk accepted.** Excluding `app/` from the SAST gate means a vulnerability
introduced upstream will not fail a build here. The mitigation is the image
scan, which does gate. If the vendored copy ever becomes something we modify
rather than consume, this decision needs revisiting.
