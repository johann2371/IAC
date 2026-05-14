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
# AMI Ubuntu (stable)
# =========================
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-*"]
  }

  owners = ["099720109477"]
}

# =========================
# VPC (IMPORTANT: éviter VpcLimitExceeded)
# =========================
resource "aws_vpc" "agricam_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "agricam-${var.environnement}"
  }
}

resource "aws_subnet" "agricam_subnet" {
  vpc_id                  = aws_vpc.agricam_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "agricam-subnet-${var.environnement}"
  }
}

resource "aws_internet_gateway" "agricam_igw" {
  vpc_id = aws_vpc.agricam_vpc.id
}

resource "aws_route_table" "agricam_rt" {
  vpc_id = aws_vpc.agricam_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.agricam_igw.id
  }
}

resource "aws_route_table_association" "agricam_rta" {
  subnet_id      = aws_subnet.agricam_subnet.id
  route_table_id = aws_route_table.agricam_rt.id
}

# =========================
# SECURITY GROUP (corrigé propre)
# =========================
resource "aws_security_group" "agricam_sg" {
  name   = "agricam-sg-${var.environnement}"
  vpc_id = aws_vpc.agricam_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================
# KEYPAIR
# =========================
resource "aws_key_pair" "agricam_keypair" {
  key_name   = "agricam-${var.environnement}"
  public_key = var.public_key
}

# =========================
# EC2 (FREE TIER SAFE)
# =========================
resource "aws_instance" "agricam_serveur" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.type_instance
  subnet_id              = aws_subnet.agricam_subnet.id
  vpc_security_group_ids = [aws_security_group.agricam_sg.id]
  key_name               = aws_key_pair.agricam_keypair.key_name

  user_data = <<-EOF
#!/bin/bash
apt update -y
apt install -y nginx
systemctl enable nginx
systemctl start nginx
EOF

  tags = {
    Name = "agricam-${var.environnement}"
  }
}

# =========================
# S3 (simple)
# =========================
resource "aws_s3_bucket" "agricam_stockage" {
  bucket = "agricam-${var.environnement}-storage-2026"
}

resource "aws_s3_bucket" "logs_cloudtrail" {
  bucket = "agricam-${var.environnement}-logs-2026"
}