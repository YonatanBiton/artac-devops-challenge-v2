variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project, used for resource naming"
  type        = string
  default     = "sentiment-api"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "app_port" {
  description = "Port the application listens on"
  type        = number
  default     = 8080
}

variable "docker_image" {
  description = "Docker image to deploy"
  type        = string
}

variable "ssh_key_name" {
  description = "Name of the SSH key pair for EC2 access"
  type        = string
  default     = "sentiment-api-key"
}
