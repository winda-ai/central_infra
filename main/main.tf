
locals {
  # Sanitize commit hash - only use if it's not empty and is valid
  safe_commit_hash = var.commit_hash != "" && var.commit_hash != null ? substr(replace(var.commit_hash, "/[^a-zA-Z0-9-]/", ""), 0, 7) : "local"

  common_tags = merge({
    Application = "winda-central-infra"
    Environment = var.environment
    Repository  = var.repository
    CommitHash  = local.safe_commit_hash
  }, var.tags)
  name_prefix = "${var.name_prefix}-${var.environment}-${var.region}"

  # Regional FQDN for multi-region deployment
  # Examples: useast1.dev.winda.ai, uswest2.dev.winda.ai, euwest1.dev.winda.ai
  regional_fqdn = "${replace(var.region, "-", "")}.${var.environment}.winda.ai"

  # Global FQDN (for Route53 geolocation/latency routing)
  # Example: dev.winda.ai (routes to nearest region)
  global_fqdn = "${var.environment}.winda.ai"
}

///////////////////////////////////////////////
// Data Sources
///////////////////////////////////////////////

# Fetch manually created Route53 hosted zone
data "aws_route53_zone" "selected" {
  name         = var.route53_zone_name
  private_zone = false
}

///////////////////////////////////////////////
// Networking: VPC, Subnets, Routing, SGs
///////////////////////////////////////////////

# Fetch available AZs (limit to 2 for cost) 
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${local.name_prefix}-vpc" })
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-igw" })
}

# Public Subnets
resource "aws_subnet" "public" {
  for_each                = { for idx, cidr in var.public_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = local.azs[tonumber(each.key)]
  map_public_ip_on_launch = true
  tags                    = merge(local.common_tags, { Name = "${local.name_prefix}-public-${each.key}", Tier = "public" })
}

# Private Subnets
resource "aws_subnet" "private" {
  for_each          = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = local.azs[tonumber(each.key)]
  tags              = merge(local.common_tags, { Name = "${local.name_prefix}-private-${each.key}", Tier = "private" })
}

# Elastic IP for NAT
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-nat-eip" })
}

# NAT Gateway in first public subnet
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id
  tags          = merge(local.common_tags, { Name = "${local.name_prefix}-nat" })
  depends_on    = [aws_internet_gateway.igw]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.common_tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-private-rt" })
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}


# ============================================================
# ECS Cluster
# ============================================================
resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ecs-cluster"
  })
}

# Attach AWS-managed Fargate capacity providers to the cluster
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  # Use AWS-managed capacity providers (no need to create them)
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 100
    base              = 0
  }
}

///////////////////////////////////////////////
// ACM Certificate
///////////////////////////////////////////////


resource "aws_acm_certificate" "this" {
  domain_name       = local.regional_fqdn
  validation_method = "DNS"

  # Include global domain and wildcard subdomains as Subject Alternative Names
  # This supports:
  # - dev.winda.ai (global routing)
  # - *.dev.winda.ai (single-level: corrosion-engineer.dev.winda.ai)
  # - *.*.dev.winda.ai (two-level: api.corrosion-engineer.dev.winda.ai)
  subject_alternative_names = [
    local.global_fqdn,
    "*.${local.global_fqdn}",
    "*.*.${local.global_fqdn}"
  ]

  lifecycle {
    create_before_destroy = true
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-acm-cert" })
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn = aws_acm_certificate.this.arn
  timeouts {
    create = "10m"
  }
}

resource "time_sleep" "wait_30_seconds_for_certification_validation" {
  depends_on      = [aws_acm_certificate.this]
  create_duration = "30s"
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.selected.zone_id
}

# ============================================================
# AWS ALB
# ============================================================
resource "aws_security_group" "alb_sg" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb-sg" })
}

resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = values(aws_subnet.public)[*].id
  idle_timeout       = 60

  enable_deletion_protection       = false
  enable_http2                     = true
  enable_cross_zone_load_balancing = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb" })
}

# Default Target Group (required for listeners, will be unused)
# Services in their own repos will create their own target groups
resource "aws_lb_target_group" "default" {
  name     = "${local.name_prefix}-default-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-299"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  deregistration_delay = 30

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-default-tg" })
}

# HTTP Listener - Redirect to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-http-listener" })
}

# HTTPS Listener - Default action returns 404
# Services will add their own listener rules
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Service not found"
      status_code  = "404"
    }
  }

  depends_on = [aws_acm_certificate_validation.this]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-https-listener" })
}

# Regional Route53 A Record for ALB
# This is the direct regional endpoint (e.g., dev-useast1.winda.ai)
resource "aws_route53_record" "alb_regional" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.regional_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# Global Route53 A Record with Latency-Based Routing
# This routes traffic to the nearest region (e.g., dev.winda.ai)
resource "aws_route53_record" "alb_global" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.global_fqdn
  type    = "A"

  # Latency-based routing to nearest region
  set_identifier = var.region
  latency_routing_policy {
    region = var.region
  }

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# ============================================================
# Security Group for ECS Services
# ============================================================
resource "aws_security_group" "ecs_service_sg" {
  name        = "${local.name_prefix}-ecs-service-sg"
  description = "Security group for ECS services to receive traffic from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow traffic from ALB"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ecs-service-sg" })
}


