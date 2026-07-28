variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC. Must be large enough to carve /20 subnets per AZ."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR, for example 10.0.0.0/16."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4 so the cidrsubnet layout stays within range."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Route every private subnet through one NAT gateway instead of one per AZ.
    Saves roughly $32/month per avoided AZ but makes the NAT a single point of
    failure, so it should stay false in production.
  EOT
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the flow log group"
  type        = string
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs"
  type        = number
  default     = 90
}

variable "eks_cluster_name" {
  description = <<-EOT
    EKS cluster name used for kubernetes.io/cluster/<name> subnet discovery tags.
    Leave empty when the VPC hosts no EKS cluster.
  EOT
  type        = string
  default     = ""
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  nat_gateway_count = var.single_nat_gateway ? 1 : var.az_count

  eks_discovery_tags = var.eks_cluster_name == "" ? {} : {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.environment}-vpc" }
}

# --- Subnets ---
# Private subnets take the low quarter of the address space (indices 0..3),
# public the high half (indices 8..11), leaving room to grow either side
# without renumbering existing subnets.

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index)
  availability_zone = local.azs[count.index]

  tags = merge(
    {
      Name                              = "${var.environment}-private-${count.index + 1}"
      Tier                              = "private"
      "kubernetes.io/role/internal-elb" = "1"
    },
    local.eks_discovery_tags,
  )
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.cidr_block, 4, count.index + 8)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    {
      Name                     = "${var.environment}-public-${count.index + 1}"
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"
    },
    local.eks_discovery_tags,
  )
}

# --- Internet egress ---

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.environment}-igw" }
}

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = { Name = "${var.environment}-nat-eip-${count.index + 1}" }
}

resource "aws_nat_gateway" "main" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.environment}-nat-${count.index + 1}" }

  depends_on = [aws_internet_gateway.main]
}

# --- Routing ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.environment}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so each subnet uses its zone-local NAT and
# egress never crosses an AZ boundary (which would also incur transfer cost).
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.environment}-private-rt-${count.index + 1}" }
}

resource "aws_route" "private_nat" {
  count                  = var.az_count
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- Default security group lockdown (CIS 5.4) ---

resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  # Declaring no ingress or egress blocks removes every rule from the default
  # security group, which CIS requires to restrict all traffic.
  tags = { Name = "${var.environment}-default-sg-do-not-use" }
}

# --- VPC endpoints ---
# Gateway endpoints cost nothing and keep S3/DynamoDB traffic off the NAT
# gateway. ECR layer pulls are S3-backed, so this materially cuts NAT charges.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${var.environment}-s3-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${var.environment}-dynamodb-endpoint" }
}

# --- Flow logs ---

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.environment}-flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.environment}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.environment}-vpc-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  max_aggregation_interval = 60

  tags = { Name = "${var.environment}-flow-logs" }
}

# --- Outputs ---

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private, NAT-routed subnets"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of the public, IGW-routed subnets"
  value       = aws_subnet.public[*].id
}

output "private_route_table_ids" {
  description = "IDs of the per-AZ private route tables"
  value       = aws_route_table.private[*].id
}

output "nat_gateway_ips" {
  description = "Public IPs of the NAT gateways, useful for downstream allow-lists"
  value       = aws_eip.nat[*].public_ip
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs"
  value       = aws_cloudwatch_log_group.flow_logs.name
}
