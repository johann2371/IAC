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
# SUBNET
# =========================
resource "aws_subnet" "agricam_subnet" {
  vpc_id                  = aws_vpc.agricam_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

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
# =========================
resource "aws_security_group" "agricam_sg" {
  name        = "agricam-sg-${var.environnement}"
  description = "Groupe de securite AgriCam"
  vpc_id      = aws_vpc.agricam_vpc.id

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin]
    description = "SSH Admin"
  }

  # SORTANT
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
# =========================
resource "aws_instance" "agricam_serveur" {
  ami                    = var.ami_id
  instance_type          = var.type_instance
  subnet_id              = aws_subnet.agricam_subnet.id
  vpc_security_group_ids = [aws_security_group.agricam_sg.id]
  key_name               = aws_key_pair.agricam_keypair.key_name

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

# =========================
# BLOCAGE ACCES PUBLIC S3
# =========================
resource "aws_s3_bucket_public_access_block" "agricam_s3_pab" {
  bucket = aws_s3_bucket.agricam_stockage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =========================
# CHIFFREMENT S3
# =========================
resource "aws_s3_bucket_server_side_encryption_configuration" "agricam_chiffrement" {
  bucket = aws_s3_bucket.agricam_stockage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# =========================
# VERSIONING S3
# =========================
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

        Action = "s3:PutObject"

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
# =========================
resource "aws_cloudtrail" "agricam_audit" {
  name                          = "agricam-trail-${var.environnement}"
  s3_bucket_name                = aws_s3_bucket.logs_cloudtrail.id
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  include_global_service_events = true

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_policy
  ]

  tags = {
    Projet = "AgriCam"
    Type   = "Securite"
  }
}