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
  description = <<-EOT
    ACM certificate for the ALB HTTPS listener. Production must set this: an
    empty value drops the load balancer back to a plaintext HTTP listener.
  EOT
  type        = string
  default     = ""
}
