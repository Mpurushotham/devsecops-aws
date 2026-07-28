# 0005: Trivy replaces the end-of-life tfsec

**Status:** Accepted
**Date:** 2026-07-28

## Problem

`aquasecurity/tfsec-action@v1.0.0` failed on every run. tfsec has been end of
life since its scanning engine was folded into Trivy, and the action no longer
executes.

This mattered more than one red job: `Security Scanning / IaC Scan (tfsec)` is a
**required status check** on `main`. A permanently failing required check means
no pull request can merge, including Dependabot's security updates. The
repository had two open PRs blocked by exactly this, one of which was a fix for
a known CVE in `python-multipart`.

## Decision

Replace it with `aquasecurity/trivy-action` in `config` scan mode, split across
two steps:

1. Scan at `CRITICAL,HIGH,MEDIUM`, emit SARIF, `exit-code: 0`.
2. Re-scan at `CRITICAL,HIGH`, `exit-code: 1`.

The gate is separate from the report so that a failing gate still publishes its
findings to code scanning. A single step with `exit-code: 1` skips the SARIF
upload on the run where the findings actually matter.

## Consequences

**Gained.** IaC scanning runs again. Checkov and Trivy now cover the same tree
with different rule sets, and disagreements between them are informative.

**Required action.** The branch protection contexts must be updated: the old
`IaC Scan (tfsec)` context will never report again, and the new
`IaC Scan (Trivy)` context is not yet required. Until that is changed, merges
stay blocked. This cannot be fixed from inside the repository's files.

**Suppressions.** One finding is accepted in `.trivyignore.yaml` with a written
justification. The file exists so that accepted risk is reviewable, rather than
being hidden by lowering the severity threshold.
