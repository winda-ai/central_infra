variable "environment" {
  description = "The environment to deploy into"
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "winda"
}

variable "region" {
  description = "The AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}

variable "repository" {
  description = "The repository URL"
  type        = string
  default     = "central_infra"
}

variable "commit_hash" {
  description = "The commit hash of the deployment"
  type        = string
  default     = "local"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDR blocks (must span at least 2 AZs)"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDR blocks (must span at least 2 AZs)"
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]
}

