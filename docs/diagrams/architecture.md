# Architecture

## Platform overview

```mermaid
flowchart TB
    subgraph GH["GitHub"]
        REPO[Repository]
        ACT[Actions<br/>OIDC, no static keys]
        GITOPS[gitops/<br/>desired state]
    end

    subgraph AWS["AWS Account"]
        subgraph SEC["Security & Governance"]
            CT[CloudTrail<br/>multi-region, log validation]
            CFG[AWS Config]
            SH[Security Hub<br/>CIS / NIST / PCI]
            GD[GuardDuty]
            KMS[KMS CMK<br/>rotation enabled]
        end

        ECR[(ECR<br/>IMMUTABLE tags<br/>scan on push)]

        subgraph VPC["VPC"]
            subgraph PUB["Public subnets"]
                NAT[NAT Gateway]
                IGW[Internet Gateway]
            end

            subgraph PRIV["Private subnets"]
                ALB[Internal ALB<br/>TLS 1.3, WAF attached]
                ECS[ECS Fargate<br/>first-party API]
                EKS[EKS<br/>IRSA, private endpoint]
                ARGO[ArgoCD]
                VPCE[Interface endpoints<br/>ECR, STS, logs, SM]
            end
        end

        subgraph OBS["Observability"]
            CW[CloudWatch<br/>dashboards + CIS alarms]
            SNS[SNS<br/>CMK encrypted]
        end

        S3L[(S3 log archive<br/>Object Lock in prod)]
    end

    REPO --> ACT
    ACT -->|assume role via OIDC| ECR
    ACT -->|deploy| ECS
    ACT -->|update tag| GITOPS
    GITOPS -->|poll / webhook| ARGO
    ARGO -->|reconcile| EKS
    ECS --> VPCE
    EKS --> VPCE
    VPCE --> ECR
    NAT --> IGW
    EKS -.->|443 only, third-party registries| NAT
    ALB --> ECS
    CT --> S3L
    CFG --> S3L
    ALB --> S3L
    GD --> SH
    CFG --> SH
    SH --> SNS
    CW --> SNS
    KMS -.->|encrypts| S3L
    KMS -.->|encrypts| ECR
    KMS -.->|encrypts| EKS
```

## Network topology

Private subnets carry every workload. Public subnets carry only the NAT
gateways. Nothing is placed in a public subnet with a public IP.

```mermaid
flowchart LR
    subgraph AZ_A["AZ a"]
        PUBA["Public 10.0.128.0/20<br/>NAT"]
        PRIA["Private 10.0.0.0/20<br/>workloads"]
    end
    subgraph AZ_B["AZ b"]
        PUBB["Public 10.0.144.0/20<br/>NAT"]
        PRIB["Private 10.0.16.0/20<br/>workloads"]
    end

    IGW((Internet Gateway))
    PUBA --> IGW
    PUBB --> IGW
    PRIA -->|per-AZ route table| PUBA
    PRIB -->|per-AZ route table| PUBB

    S3E[S3 / DynamoDB<br/>gateway endpoints]
    PRIA --- S3E
    PRIB --- S3E
```

Each private subnet routes through the NAT in its own AZ, so a single-AZ
failure does not take out the other zone's egress, and cross-AZ transfer
charges are avoided. `single_nat_gateway = true` collapses this to one NAT in
dev, trading that resilience for roughly $32/month.

## Delivery paths

```mermaid
flowchart TD
    PUSH[git push] --> TEST[app-test<br/>ruff, bandit, pytest]
    TEST --> BUILD[build image]
    BUILD --> SCAN{Trivy + Grype<br/>CRITICAL/HIGH?}
    SCAN -->|found| STOP[fail — nothing published]
    SCAN -->|clean| PUSHECR[push to ECR<br/>cosign sign digest<br/>SBOM attestation]

    PUSHECR --> BRANCH{branch}
    BRANCH -->|develop| DEV[ECS dev<br/>Actions push model]
    BRANCH -->|main| PRODECS[ECS prod<br/>Actions push model]
    PUSHECR --> TAG[update gitops/ tag]
    TAG --> ARGOCD[ArgoCD]
    ARGOCD -->|auto-sync| K8SDEV[EKS dev / staging]
    ARGOCD -->|manual sync<br/>release tag only| K8SPROD[EKS prod]
```

The asymmetry is deliberate: ECS uses a push model because there is no
in-cluster reconciler for it, while Kubernetes state is reconciled from git.
See [ADR 0003](../adr/0003-gitops-with-argocd.md).

## Control coverage

```mermaid
flowchart LR
    subgraph Prevent
        P1[Permission boundary<br/>+ explicit audit-tamper deny]
        P2[SCPs]
        P3[IMMUTABLE ECR tags]
        P4[Pod Security Standards]
        P5[NetworkPolicy<br/>IMDS blocked]
        P6[Mandatory TLS]
    end
    subgraph Detect
        D1[GuardDuty]
        D2[AWS Config]
        D3[Security Hub]
        D4[CloudTrail + CIS alarms]
        D5[VPC flow logs]
    end
    subgraph Respond
        R1[Auto-remediation Lambda]
        R2[GuardDuty response Lambda]
        R3[SNS to on-call]
        R4[Deployment circuit breaker]
    end

    Prevent --> Detect --> Respond
    R1 -.->|restores| Prevent
```
