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
# AMI
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
# KMS (FIX POLICY)
# =========================
resource "aws_kms_key" "agricam_kms" {
  description             = "KMS AgriCam"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "Enable IAM User Permissions"
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action   = "kms:*"
      Resource = "*"
    }]
  })
}

resource "aws_kms_alias" "agricam_kms_alias" {
  name          = "alias/agricam-${var.environnement}-${random_id.suffix.hex}"
  target_key_id = aws_kms_key.agricam_kms.key_id
}

# =========================
# VPC + FLOW LOGS
# =========================
resource "aws_vpc" "agricam_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "agricam-vpc"
  }
}

resource "aws_flow_log" "vpc_flow" {
  vpc_id               = aws_vpc.agricam_vpc.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/agricam/vpc-flowlogs"
  retention_in_days = 7
}

# =========================
# SUBNET (FIX SECURITY POLICY)
# =========================
resource "aws_subnet" "agricam_subnet" {
  vpc_id                  = aws_vpc.agricam_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = false
}

# =========================
# INTERNET GATEWAY
# =========================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.agricam_vpc.id
}

# =========================
# ROUTE TABLE
# =========================
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.agricam_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.agricam_subnet.id
  route_table_id = aws_route_table.rt.id
}

# =========================
# SECURITY GROUP (FIX CHECKOV)
# =========================
resource "aws_security_group" "agricam_sg" {
  name        = "agricam-sg-${random_id.suffix.hex}"
  vpc_id      = aws_vpc.agricam_vpc.id
  description = "AgriCam SG"

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
    description = "Outbound HTTPS only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================
# IAM ROLE (IMPORTANT FIX)
# =========================
resource "aws_iam_role" "ec2_role" {
  name = "agricam-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "agricam-profile"
  role = aws_iam_role.ec2_role.name
}

# =========================
# KEYPAIR
# =========================
resource "aws_key_pair" "agricam_keypair" {
  key_name   = "agricam-${var.environnement}-${random_id.suffix.hex}"
  public_key = var.public_key
}

# =========================
# EC2 (FIX CHECKOV)
# =========================
resource "aws_instance" "agricam_serveur" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.type_instance

  subnet_id              = aws_subnet.agricam_subnet.id
  vpc_security_group_ids = [aws_security_group.agricam_sg.id]
  key_name               = aws_key_pair.agricam_keypair.key_name

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

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
}

# =========================
# S3 BUCKETS (FULL FIX)
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

resource "aws_s3_bucket_server_side_encryption_configuration" "storage_enc" {
  bucket = aws_s3_bucket.agricam_stockage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
      kms_master_key_id = aws_kms_key.agricam_kms.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "storage_block" {
  bucket = aws_s3_bucket.agricam_stockage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "storage_lifecycle" {
  bucket = aws_s3_bucket.agricam_stockage.id

  rule {
    id     = "cleanup"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

# LOG BUCKET
resource "aws_s3_bucket" "logs_cloudtrail" {
  bucket = "agricam-${var.environnement}-logs-${random_id.suffix.hex}"
}