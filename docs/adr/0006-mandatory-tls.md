# 0006: No plaintext listener in any environment

**Status:** Accepted
**Date:** 2026-07-28

## Problem

The ECS module declared an HTTPS listener with no `certificate_arn`, which the
ELB API rejects outright, so the module could not be applied at all.

The obvious repair was to make the certificate optional and fall back to HTTP
when unset. That was implemented first, and it was wrong: a variable with an
empty default means the listener silently degrades to plaintext in exactly the
environments where nobody is looking. Trivy flagged it (AWS-0054) in all three
environments, including production.

## Decision

`certificate_arn` is required and validated as an ACM ARN. There is no
configuration in which the load balancer serves plaintext.

Port 80 exists, but only as a redirect to 443. A client connecting in plaintext
is told to come back over TLS rather than being served.

TLS policy is `ELBSecurityPolicy-TLS13-1-2-2021-06`, and the bucket policies
additionally deny any S3 request below TLS 1.2.

## Consequences

**Gained.** No environment can be plaintext by omission. The failure is a
`terraform plan` error with a clear message, at the earliest possible moment.

**Cost.** Every environment needs a certificate before it can be applied,
including throwaway ones. For an environment with no domain, import a
self-signed certificate into ACM. That is friction, and it is the point: the
friction is visible, whereas a silent downgrade is not.

**Rejected.** Keeping the fallback with a `#trivy:ignore`. A suppression would
have hidden a real weakness rather than accepting a known one.
