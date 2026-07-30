variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "eks_cluster_version" {
  description = "Kubernetes control plane version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "certificate_arn" {
  description = "ACM certificate for the ALB HTTPS listener. Required: the ECS module has no plaintext fallback."
  type        = string
}
