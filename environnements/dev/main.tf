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
# RANDOM SUFFIX
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
# KMS
# =========================
resource "aws_kms_key" "agricam_kms" {
  description             = "KMS AgriCam"
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_kms_alias" "agricam_kms_alias" {
  name          = "alias/agricam-${var.environnement}-${random_id.suffix.hex}"
  target_key_id = aws_kms_key.agricam_kms.key_id
}

# =========================
# VPC
# =========================
resource "aws_vpc" "agricam_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "agricam-vpc"
  }
}

# Default security group locked (Checkov fix)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.agricam_vpc.id
}

# =========================
# SUBNET (PRIVATE MODE FIX)
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
# INTERNET GATEWAY
# =========================
resource "aws_internet_gateway" "agricam_igw" {
  vpc_id = aws_vpc.agricam_vpc.id
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
}

resource "aws_route_table_association" "agricam_rta" {
  subnet_id      = aws_subnet.agricam_subnet.id
  route_table_id = aws_route_table.agricam_rt.id
}

# =========================
# SECURITY GROUP (CLEAN)
# =========================
resource "aws_security_group" "agricam_sg" {
  name        = "agricam-sg-${random_id.suffix.hex}"
  description = "Security group for AgriCam"
  vpc_id      = aws_vpc.agricam_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin]
  }

  ingress {
    description = "HTTP restricted"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin]
  }

  egress {
    description = "Outbound limited"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
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
# EC2 INSTANCE (SECURE)
# =========================
resource "aws_instance" "agricam_serveur" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.type_instance

  subnet_id              = aws_subnet.agricam_subnet.id
  vpc_security_group_ids = [aws_security_group.agricam_sg.id]
  key_name               = aws_key_pair.agricam_keypair.key_name

  associate_public_ip_address = false

  monitoring     = true
  ebs_optimized   = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
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
# S3 STORAGE (SECURE)
# =========================
resource "aws_s3_bucket" "agricam_stockage" {
  bucket = "agricam-${var.environnement}-storage-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "storage_versioning" {
  bucket = aws_s3_bucket.agricam_stockage.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage_encryption" {
  bucket = aws_s3_bucket.agricam_stockage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "storage_pab" {
  bucket = aws_s3_bucket.agricam_stockage.id

  block_public_acls      = true
  block_public_policy    = true
  ignore_public_acls     = true
  restrict_public_buckets = true
}

# =========================
# S3 LOGS
# =========================
resource "aws_s3_bucket" "logs_cloudtrail" {
  bucket = "agricam-${var.environnement}-logs-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "logs_versioning" {
  bucket = aws_s3_bucket.logs_cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "logs_pab" {
  bucket = aws_s3_bucket.logs_cloudtrail.id

  block_public_acls      = true
  block_public_policy    = true
  ignore_public_acls     = true
  restrict_public_buckets = true
}

# =========================
# FLOW LOGS VPC
# =========================
resource "aws_flow_log" "agricam_flow" {
  vpc_id               = aws_vpc.agricam_vpc.id
  traffic_type         = "ALL"
  log_destination_type  = "s3"
  log_destination       = aws_s3_bucket.logs_cloudtrail.arn
}