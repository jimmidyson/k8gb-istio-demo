data "aws_route53_zone" "ksphere_platform" {
  name         = "dkp2demo.com."
  provider = aws.us
}

output "route53_zone_id" {
  description = "Zone ID for Route53"
  value       = data.aws_route53_zone.ksphere_platform.zone_id
}

output "route53_zone_name" {
  description = "Zone name for Route53"
  value       = data.aws_route53_zone.ksphere_platform.name
}
