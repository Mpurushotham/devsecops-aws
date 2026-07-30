# 0009: Pin GitHub Actions by commit SHA

**Status:** Accepted
**Date:** 2026-07-28

## Problem

Every action was referenced by a moving tag: `actions/checkout@v5`,
`aws-actions/configure-aws-credentials@v6`, and so on. Semgrep flagged 66
instances.

A tag is a pointer the upstream owner can move. These workflows assume an AWS
role with permission to push images and run Terraform, so whatever code a tag
resolves to at run time executes with that role. The chain looks like:

1. An action's repository or maintainer account is compromised.
2. The attacker force-pushes `v5` to point at their own commit.
3. Our next run fetches it, and it executes holding our OIDC credentials.

Nothing in this repository would have changed, and nothing in a diff would show
it. This is not hypothetical: it is the mechanism behind the `tj-actions`
compromise, where a moved tag exposed secrets across thousands of repositories.

## Decision

All 66 references are pinned to full 40-character commit SHAs, with the
human-readable tag kept as a trailing comment:

```yaml
uses: actions/checkout@fbc6f3992d24a9b0b1c1b0e4bc38e6a1e1c1e01c # v5
```

The comment is not decoration. Dependabot parses it to know which version the
pin represents, so updates still arrive as reviewable pull requests.

A SHA cannot be repointed. Changing which code runs now requires a commit here,
which is reviewable and attributable.

## Consequences

**Gained.** The code executing with this repository's AWS role is fixed at a
known commit. Supply-chain movement upstream is visible as a diff rather than
silent.

**Cost.** The workflows are less readable, and every update is a 40-character
change. The trailing comment recovers most of the readability.

**Requires.** `scripts/verify-action-refs.sh` was updated to resolve SHA pins as
commits rather than refs, and runs in CI. Without it, a mistyped SHA fails
during "Set up job" with no useful message.

**Paired with.** A 7-day Dependabot cooldown, 14 days for majors. Pinning stops
a tag moving underneath us; the cooldown stops us adopting a freshly published
release before the ecosystem has had a chance to notice it is malicious. Neither
control substitutes for the other.

## Rejected

**Pinning to major tags only.** That is what was already happening, and it is
precisely what fails.

**Vendoring the actions.** Complete control, but every action becomes ours to
maintain and security-patch. The cost is not justified for a platform of this
size.
