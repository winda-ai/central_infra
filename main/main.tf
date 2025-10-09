
locals {
common_tags = merge({
    Application = "winda-central-infra"
    Environment = var.environment
    repository  = var.repository
    commit_hash = substr(var.commit_hash, 0, 5)
  }, var.tags)
  name_prefix = "${var.name_prefix}-${var.environment}-${var.region}"
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