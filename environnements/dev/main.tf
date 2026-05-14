# Fichier : agricam-infra/environnements/dev/main.tf
# Infrastructure AgriCam — Environnement de developpement
# CamTech Solutions — Douala, Cameroun

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# =========================
# KMS KEY (CloudTrail + EBS)
# =========================
resource "aws_kms_key" "agricam_kms" {
  description             = "Cle KMS AgriCam pour chiffrement EBS et CloudTrail"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Projet        = "AgriCam"
    Environnement = var.environnement
  }
}

resource "aws_kms_alias" "agricam_kms_alias" {
  name          = "alias/agricam-${var.environnement}"
  target_key_id = aws_kms_key.agricam_kms.key_id
}

# =========================
# SNS TOPIC (CloudTrail)
# =========================
resource "aws_sns_topic" "cloudtrail_alerts" {
  name              = "agricam-cloudtrail-alerts-${var.environnement}"
  kms_master_key_id = aws_kms_key.agricam_kms.id

  tags = {
    Projet        = "AgriCam"
    Environnement = var.environnement
  }
}

# =========================
# VPC
# =========================
resource "aws_vpc" "agricam_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name          = "agricam-vpc-${var.environnement}"
    Projet        = "AgriCam"
    Entreprise    = "CamTech Solutions"
    Environnement = var.environnement
  }
}

# =========================
# SUBNET — Pas d'IP publique automatique (CKV_AWS_130)
# =========================
resource "aws_subnet" "agricam_subnet" {
  vpc_id                  = aws_vpc.agricam_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false # FIX CKV_AWS_130

  tags = {
    Name = "agricam-subnet-${var.environnement}"
  }
}

# =========================
# INTERNET GATEWAY
# =========================
resource "aws_internet_gateway" "agricam_igw" {
  vpc_id = aws_vpc.agricam_vpc.id

  tags = {
    Name = "agricam-igw-${var.environnement}"
  }
}

# =========================
# ROUTE TABLE
# =========================
resource "aws_route_table" "agricam_rt" {
  vpc_id = aws_vpc.agricam_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.agricam_igw.id
  }

  tags = {
    Name = "agricam-rt-${var.environnement}"
  }
}

# =========================
# ASSOCIATION ROUTE TABLE
# =========================
resource "aws_route_table_association" "agricam_rta" {
  subnet_id      = aws_subnet.agricam_subnet.id
  route_table_id = aws_route_table.agricam_rt.id
}

# =========================
# SECURITY GROUP
# FIX CKV_AWS_260 : plus de port 80 ouvert à 0.0.0.0/0
# FIX CKV_AWS_382 : egress restreint
# FIX CKV_AWS_23  : description sur chaque règle
# =========================
resource "aws_security_group" "agricam_sg" {
  name        = "agricam-sg-${var.environnement}"
  description = "Groupe de securite AgriCam — acces HTTPS et SSH admin uniquement"
  vpc_id      = aws_vpc.agricam_vpc.id

  # HTTPS uniquement (plus de port 80 public — FIX CKV_AWS_260)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS entrant depuis internet"
  }

  # SSH — IP admin uniquement
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin]
    description = "SSH Admin uniquement"
  }

  # SORTANT — restreint HTTPS + HTTP seulement (FIX CKV_AWS_382)
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS sortant vers internet"
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP sortant pour mises a jour apt"
  }

  tags = {
    Name = "agricam-sg-${var.environnement}"
  }
}

# =========================
# CLE SSH AWS
# =========================
resource "aws_key_pair" "agricam_keypair" {
  key_name   = "agricam-keypair-${var.environnement}"
  public_key = file("~/.ssh/agricam_key.pub")
}

# =========================
# INSTANCE EC2
# FIX CKV_AWS_79  : IMDSv2 obligatoire
# FIX CKV_AWS_8   : EBS chiffré avec KMS
# FIX CKV_AWS_126 : monitoring détaillé activé
# FIX CKV_AWS_135 : EBS optimisé activé
# =========================
resource "aws_instance" "agricam_serveur" {
  ami                    = var.ami_id
  instance_type          = var.type_instance
  subnet_id              = aws_subnet.agricam_subnet.id
  vpc_security_group_ids = [aws_security_group.agricam_sg.id]
  key_name               = aws_key_pair.agricam_keypair.key_name
  ebs_optimized          = true # FIX CKV_AWS_135
  monitoring             = true # FIX CKV_AWS_126

  # FIX CKV_AWS_79 : IMDSv2 uniquement (désactive IMDSv1)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Force IMDSv2
    http_put_response_hop_limit = 1
  }

  # FIX CKV_AWS_8 : EBS racine chiffré avec KMS
  root_block_device {
    encrypted   = true
    kms_key_id  = aws_kms_key.agricam_kms.arn
    volume_type = "gp3"
    volume_size = 20
  }

  user_data = <<-EOF
#!/bin/bash
set -e

apt update -y
apt install -y nginx

systemctl start nginx
systemctl enable nginx

cat <<HTML > /var/www/html/index.html
<h1>AgriCam - ${var.environnement}</h1>
<p>Serveur operationnel</p>
HTML

EOF

  tags = {
    Name          = "agricam-serveur-${var.environnement}"
    Projet        = "AgriCam"
    Environnement = var.environnement
  }
}

# =========================
# BUCKET S3 PRINCIPAL
# =========================
resource "aws_s3_bucket" "agricam_stockage" {
  bucket = "agricam-${var.environnement}-stockage-camtech-2026"

  tags = {
    Name          = "agricam-stockage-${var.environnement}"
    Environnement = var.environnement
  }
}

resource "aws_s3_bucket_public_access_block" "agricam_s3_pab" {
  bucket = aws_s3_bucket.agricam_stockage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "agricam_chiffrement" {
  bucket = aws_s3_bucket.agricam_stockage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.agricam_kms.arn
    }
  }
}

resource "aws_s3_bucket_versioning" "agricam_versioning" {
  bucket = aws_s3_bucket.agricam_stockage.id

  versioning_configuration {
    status = "Enabled"
  }
}

# =========================
# BUCKET CLOUDTRAIL
# =========================
resource "aws_s3_bucket" "logs_cloudtrail" {
  bucket = "agricam-cloudtrail-logs-${var.environnement}-2026"

  tags = {
    Projet = "AgriCam"
    Type   = "Logs"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_pab" {
  bucket = aws_s3_bucket.logs_cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_chiffrement" {
  bucket = aws_s3_bucket.logs_cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.agricam_kms.arn
    }
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail_versioning" {
  bucket = aws_s3_bucket.logs_cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# =========================
# POLICY CLOUDTRAIL
# =========================
resource "aws_s3_bucket_policy" "cloudtrail_policy" {
  bucket = aws_s3_bucket.logs_cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.logs_cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs_cloudtrail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# =========================
# CLOUDTRAIL
# FIX CKV_AWS_252 : SNS Topic ajouté
# FIX CKV_AWS_35  : chiffrement KMS ajouté
# =========================
resource "aws_cloudtrail" "agricam_audit" {
  name                          = "agricam-trail-${var.environnement}"
  s3_bucket_name                = aws_s3_bucket.logs_cloudtrail.id
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  include_global_service_events = true
  kms_key_id                    = aws_kms_key.agricam_kms.arn         # FIX CKV_AWS_35
  sns_topic_name                = aws_sns_topic.cloudtrail_alerts.arn # FIX CKV_AWS_252

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_policy
  ]

  tags = {
    Projet = "AgriCam"
    Type   = "Securite"
  }
}
