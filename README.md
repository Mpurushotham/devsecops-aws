# DevSecOps on AWS

A comprehensive DevSecOps implementation on AWS covering infrastructure as code, CI/CD pipelines, security automation, and Kubernetes workloads.

## Architecture Overview

```
devsecops-aws/
├── .github/workflows/       # GitHub Actions CI/CD pipelines
├── terraform/               # Infrastructure as Code
│   ├── modules/             # Reusable Terraform modules
│   │   ├── vpc/             # VPC, subnets, routing
│   │   ├── eks/             # EKS cluster
│   │   ├── iam/             # IAM roles and policies
│   │   └── rds/             # RDS databases
│   └── environments/        # Per-environment configs
│       ├── dev/
│       ├── staging/
│       └── prod/
├── security/                # Security configurations
│   ├── iam-policies/        # IAM policy documents
│   ├── scp-policies/        # AWS Organizations SCPs
│   ├── guardduty/           # GuardDuty threat detection
│   ├── security-hub/        # Security Hub standards
│   └── waf/                 # WAF rules
├── ci-cd/                   # Pipeline definitions
│   ├── github-actions/      # Reusable workflow templates
│   └── codepipeline/        # AWS CodePipeline configs
├── kubernetes/              # K8s workloads
│   ├── manifests/           # Raw Kubernetes manifests
│   └── helm-charts/         # Helm chart templates
├── monitoring/              # Observability stack
│   ├── cloudwatch/          # CloudWatch dashboards & alarms
│   └── prometheus-grafana/  # Prometheus & Grafana configs
├── scripts/                 # Utility and automation scripts
└── docs/                    # Architecture diagrams and runbooks
```

## Security Tools & Services

| Category | Tool/Service |
|---|---|
| SAST | Checkov, tfsec, Semgrep |
| DAST | OWASP ZAP |
| Container Scanning | Trivy, ECR image scanning |
| Secrets Detection | GitLeaks, AWS Secrets Manager |
| Threat Detection | AWS GuardDuty |
| Compliance | AWS Security Hub, AWS Config |
| WAF | AWS WAF v2 |
| Identity | AWS IAM, AWS SSO |

## CI/CD Security Pipeline

```
Code Push
   │
   ├── Secret Scanning (GitLeaks)
   ├── SAST (Semgrep / Checkov)
   ├── Terraform Plan + tfsec
   ├── Container Build + Trivy Scan
   ├── Integration Tests
   └── Deploy (with approval gates for prod)
```

## Prerequisites

- AWS CLI v2
- Terraform >= 1.5
- kubectl
- Helm 3
- GitHub Actions or AWS CodePipeline

## Getting Started

```bash
# 1. Configure AWS credentials
aws configure

# 2. Initialize Terraform for your environment
cd terraform/environments/dev
terraform init
terraform plan
terraform apply

# 3. Configure kubectl for EKS
aws eks update-kubeconfig --region us-east-1 --name <cluster-name>

# 4. Deploy workloads
kubectl apply -f kubernetes/manifests/
```

## Security Standards

- CIS AWS Foundations Benchmark
- NIST 800-53
- SOC 2 Type II controls
- PCI-DSS (where applicable)

## License

MIT
