# Scenario 4: A public S3 bucket is auto-remediated

Demonstrates that the detective and responsive controls are wired to each
other, rather than merely both being enabled.

## What this proves

- AWS Config detects the drift.
- The remediation Lambda acts on it without a human.
- CloudTrail records both the drift and the correction.

## Flow

```mermaid
sequenceDiagram
    participant Actor
    participant S3
    participant Config as AWS Config
    participant EB as EventBridge
    participant L as Lambda
    participant SH as Security Hub

    Actor->>S3: disable public access block
    S3->>Config: configuration item
    Config->>Config: rule s3-bucket-public-read-prohibited
    Config->>EB: NON_COMPLIANT
    EB->>L: invoke auto-remediation
    L->>S3: re-apply public access block
    L->>SH: record finding + action taken
    Note over S3: window of exposure is seconds, not days
```

## Reproduce

In a non-production account only:

```bash
aws s3api delete-public-access-block --bucket devsecops-aws-logs-dev
```

## Expected outcome

```bash
# Within a few minutes, the block is restored:
aws s3api get-public-access-block --bucket devsecops-aws-logs-dev

# And the action is recorded:
aws logs tail /aws/lambda/dev-auto-remediation --follow
```

## Why this is not sufficient on its own

Auto-remediation closes the window; it does not explain it. The same event
raises a Security Hub finding so the cause is investigated, because a bucket
that keeps going public is a signal about the process, not about the bucket.

The permission boundary in `modules/iam` also carries an explicit deny on
`s3:PutBucketPolicy`, `s3:DeleteBucket` and the CloudTrail and Config
tampering calls, so a role under that boundary cannot make this change at all.
Detection is the backstop for identities outside the boundary, not the primary
control.
