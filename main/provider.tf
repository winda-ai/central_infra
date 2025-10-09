// Terraform and provider versions
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

// AWS provider configuration. Versions and required providers are declared in versions.tf
provider "aws" {
  region = var.region
} 