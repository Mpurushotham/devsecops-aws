variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the cluster and load balancer"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for tasks and the internal ALB"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN for log encryption and secret decryption"
  type        = string
}

variable "app_image" {
  description = "Fully qualified container image for the app task"
  type        = string
}

variable "app_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Fargate task CPU units"
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 1024
}

variable "min_capacity" {
  description = "Minimum task count"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum task count"
  type        = number
  default     = 10
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate for the ALB HTTPS listener. When empty the module falls back
    to a plaintext HTTP listener, which is only acceptable for an internal ALB in
    a non-production environment that has no domain yet.
  EOT
  type        = string
  default     = ""
}

variable "access_logs_bucket" {
  description = "Bucket receiving ALB access logs"
  type        = string
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the internal ALB"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "enable_deletion_protection" {
  description = "Block accidental ALB deletion. Should be false in ephemeral environments or terraform destroy will fail."
  type        = bool
  default     = true
}

variable "db_password_secret_arn" {
  description = <<-EOT
    Full ARN of the Secrets Manager secret holding the database password.
    Leave empty to omit the secret from the task definition. A wildcard ARN is
    not valid here: ECS resolves this at task start and rejects anything that is
    not a concrete ARN.
  EOT
  type        = string
  default     = ""
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# The regional ELB service account that owns ALB access log delivery.
data "aws_elb_service_account" "current" {}

locals {
  task_secrets = var.db_password_secret_arn == "" ? [] : [
    { name = "DB_PASSWORD", valueFrom = var.db_password_secret_arn }
  ]
}

resource "aws_ecs_cluster" "main" {
  name = "${var.environment}-cluster"

  configuration {
    execute_command_configuration {
      kms_key_id = var.kms_key_arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs.name
      }
    }
  }

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Environment = var.environment }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.environment}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.environment}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([{
    name      = "app"
    image     = var.app_image
    essential = true

    portMappings = [{
      containerPort = var.app_port
      protocol      = "tcp"
    }]

    environment = [
      { name = "ENVIRONMENT", value = var.environment }
    ]

    secrets = local.task_secrets

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "app"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:${var.app_port}/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    readonlyRootFilesystem = true
    user                   = "1000:1000"

    linuxParameters = {
      capabilities = {
        drop = ["ALL"]
        add  = []
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name                              = "${var.environment}-app-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.app.arn
  desired_count                     = var.min_capacity
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  enable_execute_command            = false
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.app_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "app" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.environment}-app-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.app.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_security_group" "app" {
  name        = "${var.environment}-ecs-app-sg"
  description = "ECS app task security group"
  vpc_id      = var.vpc_id

  tags = { Environment = var.environment }
}

# The ALB and task groups reference each other, so their rules live outside the
# group definitions. Inline blocks would make the two groups mutually dependent
# and Terraform would reject the graph as a cycle.

# Without this rule the ALB has no path to the tasks, every health check fails,
# and the service never reaches a steady state.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App traffic and health checks from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS outbound for ECR pulls, Secrets Manager and CloudWatch"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_lb" "app" {
  name               = "${var.environment}-app-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true

  access_logs {
    bucket  = var.access_logs_bucket
    prefix  = "alb"
    enabled = true
  }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.environment}-app-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 30
    matcher             = "200"
    path                = "/health"
    port                = "traffic-port"
    timeout             = 5
    unhealthy_threshold = 3
  }
}

# An HTTPS listener without certificate_arn is rejected by the API, so the
# listener type follows whether a certificate was supplied.
resource "aws_lb_listener" "https" {
  count             = var.certificate_arn == "" ? 0 : 1
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http" {
  count             = var.certificate_arn == "" ? 1 : 0
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "ALB security group"
  vpc_id      = var.vpc_id

  tags = { Environment = var.environment }
}

resource "aws_vpc_security_group_ingress_rule" "alb_client" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Internal client traffic"
  cidr_ipv4         = each.value
  from_port         = var.certificate_arn == "" ? 80 : 443
  to_port           = var.certificate_arn == "" ? 80 : 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To ECS tasks"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_iam_role" "task" {
  name = "${var.environment}-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role" "execution" {
  name = "${var.environment}-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "${var.environment}-ecs-secrets-policy"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.environment}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      }
    ]
  })
}

output "cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.main.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.app.name
}

output "task_definition_family" {
  description = "Task definition family, used by the deploy workflow"
  value       = aws_ecs_task_definition.app.family
}

output "alb_dns_name" {
  description = "DNS name of the internal ALB"
  value       = aws_lb.app.dns_name
}

output "alb_arn" {
  description = "ARN of the ALB, for associating a WAF web ACL"
  value       = aws_lb.app.arn
}

output "target_group_arn" {
  description = "ARN of the app target group"
  value       = aws_lb_target_group.app.arn
}

output "elb_service_account_arn" {
  description = "ELB service account principal that must be allowed to write ALB access logs"
  value       = data.aws_elb_service_account.current.arn
}
