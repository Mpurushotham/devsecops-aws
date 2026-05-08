# DevSecOps on AWS — End-to-End Platform

A production-grade DevSecOps platform on AWS covering infrastructure as code, multi-account organization, full CI/CD security pipeline, ECS and EKS compute, automated threat detection and response, compliance automation, and observability.

## Architecture

```
Developer Commit
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│              Security Pipeline (GitHub Actions)          │
│  Secret Scan → SAST → IaC Scan → Container Scan →       │
│  Image Sign (cosign) → SBOM → Terraform Plan             │
└─────────────────────────────────────────────────────────┘
      │ All gates pass
      ▼
┌─────────────────────────────────────────────────────────┐
│                AWS Multi-Account Org                     │
│  Management ─► Security OU ─► Logging OU               │
│               Workloads OU                              │
│                 ├── Dev Account                         │
│                 ├── Staging Account                     │
│                 └── Prod Account                        │
│  SCPs: Region Lock, Encryption Required,                │
│         Security Services Protected, Deny Root          │
└─────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│                   Network Layer                          │
│  VPC (private subnets) + WAF v2 + ALB + VPC Endpoints   │
│  No public IPs on workloads, VPC Flow Logs enabled       │
└─────────────────────────────────────────────────────────┘
      │
      ├──► EKS Cluster (K8s workloads)
      │      Pod Security Standards: Restricted
      │      RBAC + IRSA + Network Policies + Default Deny
      │
      └──► ECS Fargate (container workloads)
             Read-only root FS, Non-root user, No capabilities
             Auto-scaling + Circuit Breaker + Rolling Deploy
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│               Security & Compliance                      │
│  GuardDuty ─► EventBridge ─► Lambda Auto-Remediation    │
│  Security Hub (CIS + NIST + PCI-DSS + AWS Foundational) │
│  AWS Config (13+ rules + auto-remediation)              │
│  CloudTrail (multi-region, insights, KMS encrypted)     │
│  CloudWatch Alarms (root login, no MFA, IAM changes)    │
└─────────────────────────────────────────────────────────┘
```

## Repository Structure

```
devsecops-aws/
├── .github/
│   └── workflows/
│       ├── devsecops-pipeline.yml     # Orchestrator pipeline
│       ├── security-scan.yml          # GitLeaks, Semgrep, CodeQL, Checkov, tfsec
│       ├── container-build.yml        # Build, Trivy, Grype, cosign sign, SBOM
│       ├── terraform-validate.yml     # fmt, validate, plan, apply per environment
│       ├── eks-deploy.yml             # EKS Helm deploy with smoke tests
│       ├── ecs-deploy.yml             # ECS rolling deploy with auto-rollback
│       └── compliance-report.yml      # Weekly Security Hub + Config + GuardDuty report
│
├── terraform/
│   ├── modules/
│   │   ├── kms/                       # KMS CMKs with rotation
│   │   ├── cloudtrail/                # Multi-region trail, CW Logs, insights
│   │   ├── security-hub/              # CIS v1.2 + v3.0, NIST, PCI, AWS Foundational
│   │   ├── aws-config/                # 13+ managed rules + S3 auto-remediation
│   │   ├── s3/                        # Secure bucket: encryption, versioning, access block
│   │   ├── ecr/                       # Immutable tags, KMS, lifecycle, scan on push
│   │   ├── vpc/                       # Private/public subnets, flow logs
│   │   ├── eks/                       # Private endpoint, audit logs, IRSA-ready
│   │   ├── ecs/                       # Fargate, autoscaling, circuit breaker, ALB
│   │   ├── iam/                       # Permission boundaries, OIDC CI/CD, least-privilege roles
│   │   ├── organizations/             # OUs, 4x SCPs (regions, encryption, security services, root)
│   │   ├── guardduty/                 # Detector, S3/K8s/malware sources
│   │   ├── waf/                       # Managed rules, known bad inputs, rate limiting
│   │   ├── rds/                       # Encrypted RDS
│   │   └── monitoring/                # CloudWatch alarms, dashboards, metric filters
│   └── environments/
│       ├── dev/                       # Dev: KMS + VPC + EKS + ECS + CloudTrail + Config
│       ├── staging/                   # Staging: full stack
│       └── prod/                      # Prod: full stack + PCI + max replicas
│
├── security/
│   ├── guardduty/main.tf              # GuardDuty S3/K8s/malware protection
│   ├── waf/main.tf                    # WAF v2 with 3 managed rule groups + rate limit
│   ├── iam-policies/                  # IAM policy JSON documents
│   ├── scp-policies/                  # SCP JSON documents
│   └── security-hub/                  # Security Hub findings configuration
│
├── src/
│   ├── app/
│   │   ├── app.py                     # FastAPI app with input validation, no secrets in code
│   │   ├── Dockerfile                 # Multi-stage, non-root, read-only FS, healthcheck
│   │   └── requirements.txt
│   └── lambda/
│       ├── auto-remediation/handler.py  # S3 public access, SG SSH, EBS unencrypted
│       └── guardduty-response/handler.py # Instance isolation, IP block in WAF, forensic snapshots
│
├── kubernetes/
│   ├── manifests/
│   │   ├── namespaces/namespaces.yaml   # PSS Restricted labels per namespace
│   │   ├── network-policies/            # Default deny all, allow DNS, selective ingress
│   │   ├── pod-security/                # Pod spec example: non-root, read-only, drop ALL caps
│   │   └── rbac/                        # Developer view, CI/CD deploy role, IRSA SAs
│   └── helm-charts/app/
│       ├── Chart.yaml
│       ├── values.yaml                  # PDB, topology spread, autoscaling, security contexts
│       └── templates/deployment.yaml
│
├── ecs/
│   └── task-definitions/api.json        # Prod task def: secrets, non-root, read-only FS
│
├── monitoring/
│   └── grafana/dashboards/              # Security Hub, GuardDuty, ECS/EKS metrics
│
├── docs/
│   ├── architecture/
│   │   ├── overview.md                  # Mermaid: full system, multi-account, network
│   │   ├── cicd.md                      # Mermaid: pipeline flow, Terraform flow, supply chain
│   │   └── security.md                  # Mermaid: defense-in-depth, threat response, IAM model
│   ├── runbooks/
│   │   └── incident-response.md         # P1/P2 playbooks with AWS CLI commands
│   └── compliance/
│       └── cis-benchmark.md             # CIS v3.0 control mapping
│
├── scripts/
│   ├── bootstrap.sh                     # Create S3 backend, DynamoDB lock, GitHub OIDC
│   ├── setup.sh                         # Install tools, verify AWS config, pre-commit
│   └── rotate-secrets.sh                # Trigger Secrets Manager rotation for all secrets
│
└── .pre-commit-config.yaml              # GitLeaks, Terraform fmt/validate/checkov/tfsec, Hadolint
```

## Security Tools Matrix

| Category | Tool | Where Used |
|---|---|---|
| Secret Detection | GitLeaks | CI pipeline + pre-commit |
| SAST | Semgrep, CodeQL | CI pipeline |
| IaC Scanning | Checkov, tfsec | CI pipeline + pre-commit |
| Container Scanning | Trivy, Grype | CI pipeline |
| Image Signing | cosign (keyless OIDC) | CI pipeline |
| SBOM | syft / anchore | CI pipeline |
| Dependency Scan | OWASP Dependency-Check | CI pipeline |
| K8s Scanning | Kubesec, Polaris | CI pipeline |
| Threat Detection | AWS GuardDuty | Always-on |
| CSPM | AWS Security Hub | Always-on |
| Config Compliance | AWS Config | Always-on |
| Audit Logging | AWS CloudTrail | Always-on |
| WAF | AWS WAF v2 | Edge protection |
| DDos | AWS Shield Standard | Edge protection |

## Security Controls Summary

| Layer | Control |
|---|---|
| Org | SCPs: deny root, require encryption, lock regions, protect security services |
| IAM | Permission boundaries, OIDC federation for CI/CD, MFA required, no long-lived keys |
| Network | Private subnets only, no public IPs, VPC endpoints, WAF, default-deny NACLs |
| Data | KMS CMKs everywhere, S3 deny non-TLS + unencrypted uploads, Secrets Manager |
| Compute | Non-root containers, read-only root FS, drop ALL capabilities, seccomp profiles |
| K8s | Pod Security Standards: Restricted, RBAC least-privilege, Network Policies: default deny |
| Detection | GuardDuty + CloudTrail insights + CloudWatch alarms (root, no-MFA, IAM changes, SG changes) |
| Response | Lambda auto-remediation: S3 public access, SG SSH, EC2 isolation, WAF IP blocking |
| Compliance | CIS v3.0, NIST 800-53, AWS Foundational via Security Hub; weekly automated report |

## Getting Started

### 1. Bootstrap (first time only)

```bash
./scripts/setup.sh       # Install tools
./scripts/bootstrap.sh   # Create Terraform state backends + GitHub OIDC
```

### 2. Deploy Infrastructure

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply
```

### 3. Configure kubectl for EKS

```bash
aws eks update-kubeconfig --region us-east-1 --name dev-cluster
kubectl apply -f kubernetes/manifests/namespaces/
kubectl apply -f kubernetes/manifests/rbac/
kubectl apply -f kubernetes/manifests/network-policies/
```

### 4. Deploy Application via Helm

```bash
helm upgrade --install app kubernetes/helm-charts/app \
  --namespace dev \
  --set image.repository=ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/dev/api \
  --set image.tag=latest \
  --set environment=dev
```

### 5. Configure GitHub Actions Secrets

| Secret | Description |
|---|---|
| `AWS_ACCOUNT_ID` | Dev AWS account ID |
| `AWS_ACCOUNT_ID_STAGING` | Staging AWS account ID |
| `AWS_ACCOUNT_ID_PROD` | Prod AWS account ID |
| `SEMGREP_APP_TOKEN` | Semgrep Cloud token |
| `GITLEAKS_LICENSE` | GitLeaks Enterprise license (optional) |

## Compliance

- **CIS AWS Foundations Benchmark v3.0** — 85%+ automated coverage
- **NIST 800-53** — via Security Hub standards
- **PCI-DSS v3.2.1** — via Security Hub (prod only)
- **AWS Foundational Security Best Practices** — all environments

## License

MIT
