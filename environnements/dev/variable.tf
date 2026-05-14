# Fichier : variables.tf 

variable "aws_region" {
  description = "Region AWS ou deployer les ressources"
  type        = string
  default     = "eu-west-3"
}

variable "environnement" {
  description = "Nom de l'environnement (dev, staging, prod)"
  type        = string
}

variable "type_instance" {
  description = "Type d'instance EC2"
  type        = string
  default     = "t2.micro"
}

variable "ami_id" {
  description = "ID de l'image AMI (systeme d'exploitation)"
  type        = string
}

variable "ip_admin" {
  description = "IP de l'admin autorise au SSH (format x.x.x.x/32)"
  type        = string
}

