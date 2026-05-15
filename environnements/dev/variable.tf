variable "aws_region" {
  type    = string
  default = "eu-west-3"
}

variable "environnement" {
  type = string
}

# 🔥 FIX IMPORTANT: instance safe par défaut
variable "type_instance" {
  type    = string
  default = "t3.micro"
}

variable "ip_admin" {
  type = string
}

variable "public_key" {
  type      = string
  sensitive = true
}