variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN from the EKS module, used to build IRSA trust policies"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer host without the https:// scheme"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN ArgoCD may use to decrypt sealed values"
  type        = string
}

variable "chart_version" {
  description = "argo-cd Helm chart version. Pinned so a sync never silently upgrades the control plane itself."
  type        = string
  default     = "7.7.16"
}

variable "namespace" {
  description = "Namespace ArgoCD runs in"
  type        = string
  default     = "argocd"
}

variable "gitops_repo_url" {
  description = "HTTPS URL of the repository holding the desired state"
  type        = string
  default     = "https://github.com/Mpurushotham/devsecops-aws.git"
}

variable "gitops_target_revision" {
  description = <<-EOT
    Branch, tag or commit the root application tracks. A branch means the
    cluster follows whatever lands there; a tag pins it until deliberately
    moved. Production should track a tag.
  EOT
  type        = string
  default     = "main"
}

variable "gitops_path" {
  description = "Directory in the repository holding the app-of-apps root"
  type        = string
  default     = "gitops/bootstrap"
}

variable "ingress_enabled" {
  description = "Expose the ArgoCD UI through an internal ALB ingress"
  type        = bool
  default     = false
}

variable "ingress_certificate_arn" {
  description = "ACM certificate for the ArgoCD ingress. Required when ingress_enabled is true."
  type        = string
  default     = ""

  validation {
    condition     = var.ingress_certificate_arn == "" || can(regex("^arn:aws[a-z-]*:acm:", var.ingress_certificate_arn))
    error_message = "ingress_certificate_arn must be an ACM certificate ARN."
  }
}

locals {
  # server.insecure is set because TLS terminates at the ALB. Without it the
  # server would also serve TLS behind the load balancer and the health checks
  # would fail against a certificate the ALB does not trust.
  values = {
    global = {
      domain = ""
    }

    configs = {
      params = {
        "server.insecure" = var.ingress_enabled
      }

      cm = {
        # Anonymous access off. ArgoCD holds cluster-admin on the cluster it
        # manages, so an unauthenticated UI is an unauthenticated path to it.
        "users.anonymous.enabled" = "false"
        "timeout.reconciliation"  = "180s"
      }

      rbac = {
        # Default role for any authenticated user with no explicit grant. The
        # ArgoCD default is a full-access admin policy, which is not a safe
        # default for a cluster that runs production workloads.
        "policy.default" = "role:readonly"
        "policy.csv"     = <<-CSV
          p, role:platform-admin, applications, *, */*, allow
          p, role:platform-admin, repositories, *, *, allow
          p, role:platform-admin, clusters, get, *, allow
          g, ${var.environment}-platform-admins, role:platform-admin
        CSV
      }
    }

    controller = {
      replicas = 1
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
      serviceAccount = {
        create = true
        name   = "argocd-application-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.argocd.arn
        }
      }
    }

    server = {
      replicas = 2
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
      serviceAccount = {
        create = true
        name   = "argocd-server"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.argocd.arn
        }
      }
      ingress = {
        enabled          = var.ingress_enabled
        ingressClassName = "alb"
        annotations = {
          "alb.ingress.kubernetes.io/scheme"           = "internal"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
          "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
          "alb.ingress.kubernetes.io/certificate-arn"  = var.ingress_certificate_arn
          "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
          "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
        }
      }
    }

    repoServer = {
      replicas = 2
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    applicationSet = {
      replicas = 1
    }

    redis-ha = {
      enabled = false
    }

    # Notifications and the CLI-facing gRPC service are not used here.
    notifications = {
      enabled = false
    }

    dex = {
      enabled = false
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      # ArgoCD's controllers need to run with elevated privileges relative to
      # the workload namespaces, so this namespace runs under the privileged
      # Pod Security Standard rather than restricted.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [yamlencode(local.values)]

  # ArgoCD's CRDs and controllers take a while to become ready on a cold
  # cluster, and a half-installed release leaves Applications unreconciled.
  wait    = true
  timeout = 900

  depends_on = [kubernetes_namespace.argocd]
}

# --- IRSA role ---
# ArgoCD needs AWS access to pull Helm charts from ECR OCI registries and to
# decrypt any KMS-encrypted values it renders.

resource "aws_iam_role" "argocd" {
  name = "${var.environment}-argocd-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
        # Scoped to the two service accounts that exist, rather than any
        # service account in the namespace.
        StringLike = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.namespace}:argocd-*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "argocd" {
  name = "${var.environment}-argocd-policy"
  role = aws_iam_role.argocd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PullHelmChartsFromECR"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ReadECRRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.environment}/*"
      },
      {
        Sid      = "DecryptRenderedValues"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

# --- Root application ---
# Created through the CRD the Helm release installs. Everything else ArgoCD
# manages is declared in git under gitops_path, so this is the only
# Application that Terraform owns.

resource "kubernetes_manifest" "root_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "root"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      # Without this finalizer, deleting the root Application orphans every
      # child instead of cascading the removal.
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }

    spec = {
      project = "default"

      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_target_revision
        path           = var.gitops_path
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.argocd.metadata[0].name
      }

      syncPolicy = {
        automated = {
          # prune removes resources deleted from git; selfHeal reverts manual
          # kubectl edits. Together they make git the only way to change the
          # cluster, which is the point of running this at all.
          prune      = true
          selfHeal   = true
          allowEmpty = false
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
        ]
        retry = {
          limit = 5
          backoff = {
            duration    = "10s"
            factor      = 2
            maxDuration = "5m"
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd]
}

output "namespace" {
  description = "Namespace ArgoCD is installed in"
  value       = kubernetes_namespace.argocd.metadata[0].name
}

output "iam_role_arn" {
  description = "IRSA role assumed by the ArgoCD controllers"
  value       = aws_iam_role.argocd.arn
}

output "initial_admin_secret_command" {
  description = "How to read the generated admin password, which is never placed in Terraform state"
  value       = "kubectl -n ${var.namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
