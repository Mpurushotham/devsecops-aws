# Architecture & Design Decisions

## Network Architecture

- **VPC**: Private subnets for workloads, public subnets only for load balancers
- **EKS**: Private endpoint only — no public API server access
- **NAT Gateway**: Outbound internet for private subnets
- **VPC Flow Logs**: Enabled for all traffic analysis

## Security Layers

| Layer | Control |
|---|---|
| Perimeter | AWS WAF, Shield Standard |
| Network | Security Groups, NACLs, VPC endpoints |
| Identity | IAM least-privilege, IRSA for pods |
| Data | Encryption at rest (KMS), in transit (TLS) |
| Detection | GuardDuty, Security Hub, CloudTrail |
| Response | Lambda-based auto-remediation |

## CI/CD Security Gates

All code must pass these gates before deployment:
1. Secret scanning (GitLeaks) — blocks on any detected secret
2. SAST (Semgrep) — blocks on high/critical findings
3. IaC scanning (Checkov + tfsec) — blocks on policy violations
4. Container scanning (Trivy) — blocks on critical CVEs
5. Manual approval — required for production deployments

## Compliance Mapping

| Control | AWS Service |
|---|---|
| Audit Logging | CloudTrail + S3 (encrypted, versioned) |
| Access Management | IAM + AWS SSO |
| Vulnerability Management | Inspector v2 + ECR scanning |
| Incident Response | GuardDuty + Security Hub |
| Configuration Management | AWS Config + Config Rules |
