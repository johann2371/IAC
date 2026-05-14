variable "aws_region" {
  default = "eu-west-3"
}

variable "environnement" {
  type = string
}

variable "type_instance" {
  default = "t2.micro"
}

variable "ip_admin" {
  type = string
}

variable "public_key" {
  type = string
}