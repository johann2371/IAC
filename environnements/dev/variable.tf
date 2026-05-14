variable "aws_region" {
  type    = string
  default = "eu-west-3"
}

variable "environnement" {
  type = string
}

variable "type_instance" {
  type    = string
  default = "t2.small"
}

variable "ip_admin" {
  type = string
}

variable "public_key" {
  type      = string
  sensitive = true
}