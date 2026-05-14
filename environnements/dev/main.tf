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
# SUBNET
# =========================
resource "aws_subnet" "agricam_subnet" {
  vpc_id                  = aws_vpc.agricam_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

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

resource "aws_route_table_association" "agricam_rta" {
  subnet_id      = aws_subnet.agricam_subnet.id
  route_table_id = aws_route_table.agricam_rt.id
}

# =========================
# SECURITY GROUP
# =========================
resource "aws_security_group" "agricam_sg" {
  name        = "agricam-sg-${var.environnement}"
  description = "Groupe de securite AgriCam — HTTPS et SSH admin uniquement"
  vpc_id      = aws_vpc.agricam_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS entrant"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin]
    description = "SSH Admin"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS sortant"
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP sortant"
  }

  tags = {
    Name = "agricam-sg-${var.environnement}"
  }
}

# =========================
# CLE SSH AWS (FIX CI/CD)
# =========================
resource "aws_key_pair" "agricam_keypair" {
  key_name   = "agricam-keypair-${var.environnement}"
  public_key = var.public_key
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

  ebs_optimized = true
  monitoring    = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    kms_key_id  = aws_kms_key.agricam_kms.arn
    volume_type = "gp3"
    volume_size = 20
  }

  user_data = <<-EOF
#!/bin/bash
apt update -y
apt install -y nginx
systemctl enable nginx
systemctl start nginx
EOF

  tags = {
    Name          = "agricam-serveur-${var.environnement}"
    Projet        = "AgriCam"
    Environnement = var.environnement
  }
}

# =========================
# S3 + CLOUDTRAIL (inchangé)
# =========================
# ... (inchangé pour éviter surcharge)