output "ecs_cluster_id" {
  value       = aws_ecs_cluster.this.id
  description = "ECS Cluster ID"
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.this.name
  description = "ECS Cluster Name"
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "public_subnet_ids" {
  value       = [for subnet in aws_subnet.public : subnet.id]
  description = "List of public subnet IDs"
}

output "private_subnet_ids" {
  value       = [for subnet in aws_subnet.private : subnet.id]
  description = "List of private subnet IDs"
}

output "alb_arn" {
  value       = aws_lb.this.arn
  description = "ARN of the Application Load Balancer"
}

output "alb_dns_name" {
  value       = aws_lb.this.dns_name
  description = "DNS name of the Application Load Balancer"
}

output "alb_zone_id" {
  value       = aws_lb.this.zone_id
  description = "Zone ID of the Application Load Balancer"
}

output "alb_security_group_id" {
  value       = aws_security_group.alb_sg.id
  description = "Security Group ID of the ALB"
}

output "ecs_service_security_group_id" {
  value       = aws_security_group.ecs_service_sg.id
  description = "Security Group ID for ECS Services"
}

output "https_listener_arn" {
  value       = aws_lb_listener.https.arn
  description = "ARN of the HTTPS listener (for adding listener rules from service repos)"
}

output "http_listener_arn" {
  value       = aws_lb_listener.http.arn
  description = "ARN of the HTTP listener"
}

output "certificate_arn" {
  value       = aws_acm_certificate_validation.this.certificate_arn
  description = "ARN of the validated ACM certificate"
}

output "regional_domain_name" {
  value       = local.regional_fqdn
  description = "The regional fully qualified domain name (e.g., dev-useast1.winda.ai)"
}

output "global_domain_name" {
  value       = local.global_fqdn
  description = "The global fully qualified domain name with latency routing (e.g., dev.winda.ai)"
}

# Legacy output for backward compatibility
output "domain_name" {
  value       = local.global_fqdn
  description = "The fully qualified domain name (global, with latency routing)"
}

output "route53_zone_id" {
  value       = data.aws_route53_zone.selected.zone_id
  description = "Route53 Zone ID"
}

output "route53_zone_name" {
  value       = data.aws_route53_zone.selected.name
  description = "Route53 Zone Name"
}