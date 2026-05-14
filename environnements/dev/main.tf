terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# =========================
# RANDOM
# =========================
resource "random_id" "suffix" {
  byte_length = 4
}

# =========================
# AMI UBUNTU
# =========================
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  owners = ["099720109477"]
}

# =========================
# KMS (AVEC POLICY OBLIGATOIRE)
# =========================
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "agricam_kms" {
  description             = "KMS AgriCam"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "agricam_kms_alias" {
  name          = "alias/agricam-${var.environnement}-${random_id.suffix.hex}"
  target_key_id = aws_kms_key.agricam_kms.key_id
}

# =========================
# VPC + FLOW LOGS (FIX PRISMA)
# =========================
resource "aws_vpc" "agricam_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "agricam-vpc"
  }
}

resource "aws_flow_log" "vpc_flow_log" {
  vpc_id               = aws_vpc.agricam_vpc.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_group_name       = "/aws/vpc/agricam"
  iam_role_arn         = aws_iam_role.flowlog_role.arn
}

resource "aws_iam_role" "flowlog_role" {
  name = "agricam-flowlog-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

# =========================
# SUBNET (FIX PRISMA: NO AUTO PUBLIC IP DEFAULT)
# =========================
resource "aws_subnet" "agricam_subnet" {
  vpc_id     = aws_vpc.agricam_vpc.id
  cidr_block = "10.0.1.0/24"

  map_public_ip_on_launch = false

  tags = {
    Name = "agricam-subnet"
  }
}

# =========================
# IGW + ROUTE
# =========================
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
# SECURITY GROUP (FIX PRISMA RULES)
# =========================
resource "aws_security_group" "agricam_sg" {
  name   = "agricam-sg-${random_id.suffix.hex}"
  vpc_id = aws_vpc.agricam_vpc.id
  description = "Security group for AgriCam EC2"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================
# KEY PAIR
# =========================
resource "aws_key_pair" "agricam_keypair" {
  key_name   = "agricam-${var.environnement}-${random_id.suffix.hex}"
  public_key = var.public_key
}

# =========================
# EC2 (SECURE + FIX PRISMA)
# =========================
resource "aws_instance" "agricam_serveur" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.type_instance

  subnet_id                   = aws_subnet.agricam_subnet.id
  vpc_security_group_ids     = [aws_security_group.agricam_sg.id]
  key_name                   = aws_key_pair.agricam_keypair.key_name

  associate_public_ip_address = false
  monitoring                  = true

  root_block_device {
    encrypted = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = <<-EOF
              #!/bin/bash
              apt update -y
              apt install -y nginx
              systemctl enable nginx
              systemctl start nginx
              EOF

  tags = {
    Name = "agricam-server"
  }
}

# =========================
# S3 STORAGE (FULL SECURITY FIX)
# =========================
resource "aws_s3_bucket" "agricam_stockage" {
  bucket = "agricam-${var.environnement}-storage-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_public_access_block" "storage_block" {
  bucket = aws_s3_bucket.agricam_stockage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "storage_versioning" {
  bucket = aws_s3_bucket.agricam_stockage.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage_sse" {
  bucket = aws_s3_bucket.agricam_stockage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_logging" "storage_logging" {
  bucket        = aws_s3_bucket.agricam_stockage.id
  target_bucket = aws_s3_bucket.logs_cloudtrail.id
  target_prefix = "log/"
}

# =========================
# LOG BUCKET
# =========================
resource "aws_s3_bucket" "logs_cloudtrail" {
  bucket = "agricam-${var.environnement}-logs-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_public_access_block" "logs_block" {
  bucket = aws_s3_bucket.logs_cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}