output "ip_publique_serveur" {
  value = aws_instance.agricam_serveur.public_ip
}

output "nom_bucket_s3" {
  value = aws_s3_bucket.agricam_stockage.bucket
}

output "vpc_id" {
  value = aws_vpc.agricam_vpc.id
}

output "url" {
  value = "http://${aws_instance.agricam_serveur.public_ip}"
}