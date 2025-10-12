# Environment Configuration
environment             = "dev"
region                  = "us-east-1"
name_prefix             = "winda"

# Networking
vpc_cidr                = "10.20.0.0/16"
public_subnet_cidrs     = ["10.20.1.0/24", "10.20.2.0/24"]
private_subnet_cidrs    = ["10.20.11.0/24", "10.20.12.0/24"]

# DNS
route53_zone_name       = "winda.ai"
