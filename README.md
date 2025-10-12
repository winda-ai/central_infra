# Central Infrastructure

**Shared AWS infrastructure for microservices across multiple regions.**

## What This Provides

This creates the foundational infrastructure that all your microservices use:

- **🌐 Multi-Region Networking** - VPC, subnets, NAT Gateway in each region
- **🔒 SSL Certificates** - Wildcard certificates (`*.dev.winda.ai`)
- **⚖️ Load Balancing** - ALB with automatic HTTPS
- **🚀 ECS Cluster** - Fargate cluster for running containers
- **🗺️ Smart DNS Routing** - Route53 directs users to nearest region
- **🔐 Security Groups** - Pre-configured for ALB ↔ ECS communication

## Architecture

### Single Region View
```
User Request → dev.winda.ai
       ↓
   [Route53] → Routes to nearest region
       ↓
   [ALB - HTTPS/TLS 1.3]
       ↓
   Listener Rules (added by services):
   ├─→ /api/service-a/* → Service A (ECS Fargate)
   ├─→ /api/service-b/* → Service B (ECS Fargate)
   └─→ subdomain.dev.winda.ai → Service C (ECS Fargate)
          ↓
   [Private Subnets + NAT Gateway]
```

### Multi-Region DNS
```
User anywhere → dev.winda.ai
                    ↓
              [Route53 Latency Routing]
        ┌──────────┼──────────┐
        ↓          ↓          ↓
   useast1    uswest2    euwest1
   ALB        ALB        ALB
   (nearest region automatically selected)
```

---

## Quick Start

### 1. Deploy Central Infrastructure

```bash
# Deploy to first region
make init ENV=dev REGION=us-east-1
make apply ENV=dev REGION=us-east-1

# Deploy to additional regions (optional)
make apply ENV=dev REGION=us-west-2
make apply ENV=dev REGION=eu-west-1
```

### 2. Get Outputs (for service teams)

```bash
make outputs ENV=dev
```

Key outputs your services need:
- `ecs_cluster_id` - Where to deploy containers
- `https_listener_arn` - Where to add routing rules
- `ecs_service_security_group_id` - Security group for your services
- `private_subnet_ids` - Where to place containers
- `vpc_id` - For creating resources

---

## How Services Use This Infrastructure

### Complete Service Example

Your microservice repository needs these files:

#### 1. Reference Central Infrastructure (`data.tf`)

```hcl
data "terraform_remote_state" "central" {
  backend = "s3"
  config = {
    bucket = "your-terraform-state-bucket"
    key    = "central-infra/${var.environment}/${var.region}/terraform.tfstate"
    region = var.region
  }
}

locals {
  # Get everything from central infra
  vpc_id                 = data.terraform_remote_state.central.outputs.vpc_id
  private_subnet_ids     = data.terraform_remote_state.central.outputs.private_subnet_ids
  ecs_cluster_id         = data.terraform_remote_state.central.outputs.ecs_cluster_id
  ecs_security_group_id  = data.terraform_remote_state.central.outputs.ecs_service_security_group_id
  https_listener_arn     = data.terraform_remote_state.central.outputs.https_listener_arn
  global_domain          = data.terraform_remote_state.central.outputs.global_domain_name
}
```

#### 2. Create Target Group (`alb.tf`)

```hcl
resource "aws_lb_target_group" "this" {
  name     = "my-service-${var.environment}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = local.vpc_id
  target_type = "ip"
  
  health_check {
    path = "/health"
    port = "traffic-port"
  }
}
```

#### 3. Add Routing Rule (choose ONE option)

**Option A: Path-Based** (simpler, recommended)
```hcl
resource "aws_lb_listener_rule" "this" {
  listener_arn = local.https_listener_arn
  priority     = 100  # Choose unique number per service
  
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
  
  condition {
    path_pattern {
      values = ["/api/my-service/*"]
    }
  }
}
# Access: https://dev.winda.ai/api/my-service/*
```

**Option B: Subdomain-Based** (more isolation)
```hcl
resource "aws_lb_listener_rule" "this" {
  listener_arn = local.https_listener_arn
  priority     = 100
  
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
  
  condition {
    host_header {
      values = ["my-service.${local.global_domain}"]
    }
  }
}

# Also create DNS record
resource "aws_route53_record" "service" {
  zone_id = data.terraform_remote_state.central.outputs.route53_zone_id
  name    = "my-service.${local.global_domain}"
  type    = "A"
  
  set_identifier = var.region
  latency_routing_policy { region = var.region }
  
  alias {
    name    = data.terraform_remote_state.central.outputs.alb_dns_name
    zone_id = data.terraform_remote_state.central.outputs.alb_zone_id
    evaluate_target_health = true
  }
}
# Access: https://my-service.dev.winda.ai/*
```

#### 4. Deploy ECS Service (`ecs.tf`)

```hcl
resource "aws_ecs_task_definition" "this" {
  family                   = "my-service-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  
  container_definitions = jsonencode([{
    name  = "my-service"
    image = "your-ecr-repo:latest"
    portMappings = [{ containerPort = 8080 }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/my-service"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  name            = "my-service-${var.environment}"
  cluster         = local.ecs_cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  
  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [local.ecs_security_group_id]
    assign_public_ip = false
  }
  
  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "my-service"
    container_port   = 8080
  }
}
```

### Deploy Your Service to Multiple Regions

```bash
# Deploy to same regions as central infra
cd my-service/terraform
make apply ENV=dev REGION=us-east-1
make apply ENV=dev REGION=us-west-2
make apply ENV=dev REGION=eu-west-1
```

Done! Your service now:
- ✅ Routes traffic from `dev.winda.ai` to nearest region
- ✅ Has automatic HTTPS/TLS encryption  
- ✅ Scales independently in each region
- ✅ Fails over automatically if one region is down

---

## Domain Structure

| Domain | Purpose | Example |
|--------|---------|---------|
| `dev.winda.ai` | Global endpoint, routes to nearest region | Main entry point |
| `useast1.dev.winda.ai` | Direct access to us-east-1 | Testing specific region |
| `service.dev.winda.ai` | Service subdomain (optional) | Service-specific domain |
| `dev.winda.ai/api/service/*` | Service path (recommended) | Path-based routing |

**Certificate Coverage**: `dev.winda.ai` + `*.dev.winda.ai` (wildcard)

---

## Multi-Region Strategy

### How It Works

1. **Deploy central infra** to each region (us-east-1, us-west-2, eu-west-1)
2. **Route53 creates latency records** - One global domain, multiple regional ALBs
3. **Deploy services** to each region - Same configuration everywhere
4. **DNS automatically routes** users to nearest healthy region

### Priority Management

Each service needs a unique listener priority:

| Service | Priority | Path/Host |
|---------|----------|-----------|
| auth | 100 | `/api/auth/*` |
| users | 200 | `/api/users/*` |
| orders | 300 | `/api/orders/*` |

**Important**: Use same priority across all regions for consistency.

---

## Repository Structure

```
central_infra/
├── main/               # Terraform code
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── workspace/          # Environment configs
│   └── dev/
│       ├── us-east-1/terraform.tfvars
│       ├── us-west-2/terraform.tfvars
│       └── eu-west-1/terraform.tfvars
├── Makefile           # Deployment commands
└── README.md          # This file
```

---

## Prerequisites

1. **Route53 Hosted Zone** for `winda.ai` (manual setup)
2. **S3 Bucket** for Terraform state
3. **AWS IAM** permissions

## Common Commands

```bash
# Deploy
make init ENV=dev REGION=us-east-1
make apply ENV=dev REGION=us-east-1

# View outputs
make outputs ENV=dev

# Validate
make validate ENV=dev REGION=us-east-1

# Destroy
make destroy ENV=dev REGION=us-east-1
```

---

## Variables

Edit `workspace/<env>/<region>/terraform.tfvars`:

```hcl
environment          = "dev"
region               = "us-east-1"
vpc_cidr             = "10.20.0.0/16"
route53_zone_name    = "winda.ai"
```

---

## Troubleshooting

**Certificate validation timeout?**
- Wait 10-30 minutes for DNS propagation
- Verify Route53 hosted zone exists

**Service unhealthy?**
- Check security groups allow traffic from ALB
- Verify container health check endpoint returns 200
- Confirm container listens on correct port

**Can't access service?**
- Test: `curl https://dev.winda.ai/api/your-service/health`
- Check listener rule priority is unique
- Verify DNS resolves: `dig dev.winda.ai`

---

## What Gets Created

**Per Region:**
- 1 VPC with public/private subnets across 2 AZs
- 1 Internet Gateway + 1 NAT Gateway
- 1 Application Load Balancer (ALB)
- 1 ECS Fargate Cluster
- 1 ACM Certificate (covers `dev.winda.ai` and `*.dev.winda.ai`)
- Route53 records (regional + global latency-based)
- Security groups for ALB and ECS

**Cost**: ~$70-90/month per region (base infrastructure, before services)

---

## License

Proprietary - Winda AI
