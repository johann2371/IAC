# Fichier : outputs.tf 
output "ip_publique_serveur" { 
description = "Adresse IP publique du serveur AgriCam" 
value       = aws_instance.agricam_serveur.public_ip 
} 
output "nom_bucket_s3" { 
description = "Nom du bucket S3 de stockage" 
value       = aws_s3_bucket.agricam_stockage.bucket 
} 
output "id_vpc" { 
description = "Identifiant du VPC cree" 
value       = aws_vpc.agricam_vpc.id 
} 
output "url_application" { 
description = "URL de l'application AgriCam (HTTP)" 
value       = "http://${aws_instance.agricam_serveur.public_ip}" 
} 