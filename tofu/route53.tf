data "aws_route53_zone" "main" {
  name         = var.root_dns_zone_name
  provider = aws.us
}

resource "aws_route53_zone" "demo" {
  name = var.demo_dns_zone_name
  provider = aws.us
}

resource "aws_route53_record" "demo_ns" {
  name    = var.demo_dns_zone_name
  provider = aws.us
  zone_id = data.aws_route53_zone.main.zone_id
  type    = "NS"
  ttl     = "30"
  records = aws_route53_zone.demo.name_servers
}

output "demo_zone_id" {
  description = "Zone ID for Route53"
  value       = aws_route53_zone.demo.zone_id
}

output "demo_zone_name" {
  description = "Zone name for Route53"
  value       = aws_route53_zone.demo.name
}
