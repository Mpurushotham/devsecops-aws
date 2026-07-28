variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes control plane version"
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the cluster"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the control plane ENIs and worker nodes"
  type        = list(string)
}

variable "vpc_cidr_block" {
  description = "CIDR of the VPC, used to scope node egress to interface endpoints instead of the internet"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used for envelope encryption of Kubernetes secrets and the log group"
  type        = string
}

variable "endpoint_public_access" {
  description = <<-EOT
    Expose the Kubernetes API endpoint publicly. Keep false for production.
    When false, anything talking to the API (CI runners, kubectl, ArgoCD outside
    the VPC) must reach it over VPN, Direct Connect, or a bastion.
  EOT
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public endpoint. Only meaningful when endpoint_public_access is true."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the Kubernetes API to 0.0.0.0/0. List the specific egress CIDRs instead."
  }
}

variable "node_instance_types" {
  description = "Instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired worker node count"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum worker node count"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum worker node count"
  type        = number
  default     = 4
}

variable "log_retention_days" {
  description = "CloudWatch retention for control plane logs"
  type        = number
  default     = 90
}

data "aws_partition" "current" {}

locals {
  cluster_name = "${var.environment}-cluster"
  iam_prefix   = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

# --- Control plane ---

# The log group is created explicitly so retention and KMS encryption are
# controlled here. EKS would otherwise create it with never-expire retention.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  # Envelope-encrypt Kubernetes secrets with a customer-managed key rather than
  # the AWS-managed default.
  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # API is the modern replacement for the aws-auth ConfigMap and lets access be
  # granted through aws_eks_access_entry instead of in-cluster YAML.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = { Environment = var.environment }
}

resource "aws_security_group" "cluster" {
  name        = "${local.cluster_name}-control-plane"
  description = "EKS control plane ENIs for ${local.cluster_name}"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.cluster_name}-control-plane" }
}

# Scoped to the node group rather than 0.0.0.0/0: the control plane only ever
# needs to reach kubelets and extension API servers running on the nodes.
resource "aws_vpc_security_group_egress_rule" "cluster_to_nodes" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Control plane to kubelet and extension API servers"
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 1025
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cluster_to_nodes_https" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Control plane to webhooks served over 443 on nodes"
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Kubernetes API from worker nodes"
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# --- IRSA ---
# Without this OIDC provider no service account can assume an IAM role, which
# breaks the ALB controller, ArgoCD, and every workload that talks to AWS.

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]

  tags = { Name = "${local.cluster_name}-irsa" }
}

# --- Cluster IAM role ---

resource "aws_iam_role" "cluster" {
  name = "${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "${local.iam_prefix}/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# --- Worker nodes ---

resource "aws_security_group" "node" {
  name        = "${local.cluster_name}-nodes"
  description = "EKS worker nodes for ${local.cluster_name}"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.cluster_name}-nodes" }
}

resource "aws_vpc_security_group_egress_rule" "node_https_vpc" {
  security_group_id = aws_security_group.node.id
  description       = "HTTPS to VPC interface endpoints for ECR, STS, logs and the EKS API"
  cidr_ipv4         = var.vpc_cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "node_dns_udp" {
  security_group_id = aws_security_group.node.id
  description       = "DNS resolution inside the VPC"
  cidr_ipv4         = var.vpc_cidr_block
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "node_dns_tcp" {
  security_group_id = aws_security_group.node.id
  description       = "DNS resolution inside the VPC over TCP"
  cidr_ipv4         = var.vpc_cidr_block
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}

# trivy:ignore:AWS-0104
# Kept deliberately, and narrowed to 443. Nodes pull from registries AWS does
# not front with an endpoint (upstream Helm charts, ghcr.io, quay.io, Docker
# Hub) and reach the OIDC and Sigstore endpoints used to verify signatures.
# Removing this would require mirroring every third-party image into ECR first,
# which is the right end state but is not the topology this platform describes.
resource "aws_vpc_security_group_egress_rule" "node_https_internet" {
  security_group_id = aws_security_group.node.id
  description       = "HTTPS to third-party registries and Sigstore, via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster" {
  security_group_id            = aws_security_group.node.id
  description                  = "Kubelet and extension API traffic from the control plane"
  referenced_security_group_id = aws_security_group.cluster.id
  from_port                    = 1025
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_node" {
  security_group_id            = aws_security_group.node.id
  description                  = "Pod to pod traffic between nodes"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
}

# A launch template lets us require IMDSv2 and force a hop limit of 1, which
# stops pods from reaching the instance metadata service to steal node creds.
resource "aws_launch_template" "node" {
  name_prefix = "${local.cluster_name}-node-"

  vpc_security_group_ids = [aws_security_group.node.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 50
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = var.kms_key_arn
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.cluster_name}-node"
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.environment}-node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_iam_role_policy_attachment.cni_policy,
    aws_iam_role_policy_attachment.ecr_policy,
  ]

  # desired_size drifts once the cluster autoscaler or Karpenter starts scaling.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = { Environment = var.environment }
}

resource "aws_iam_role" "node" {
  name = "${var.environment}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  policy_arn = "${local.iam_prefix}/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  policy_arn = "${local.iam_prefix}/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "ecr_policy" {
  policy_arn = "${local.iam_prefix}/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  policy_arn = "${local.iam_prefix}/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node.name
}

# --- Managed addons ---
# Addons are created after the node group so the CNI and CoreDNS have somewhere
# to schedule.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.environment}-eks-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.cluster.arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "${local.iam_prefix}/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

locals {
  oidc_host = replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")
}

# --- Outputs ---

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the API server, needed to build a kubeconfig"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group attached to the control plane ENIs"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Security group attached to worker nodes"
  value       = aws_security_group.node.id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN, used to build IRSA trust policies"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL without the https:// scheme, for IRSA conditions"
  value       = local.oidc_host
}

output "node_role_arn" {
  description = "IAM role ARN assumed by worker nodes"
  value       = aws_iam_role.node.arn
}
