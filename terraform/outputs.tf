output "instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.app.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.app.id
}

output "app_url" {
  description = "URL to access the application"
  value       = "http://${aws_eip.app.public_ip}:${var.app_port}"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i sentiment-api-key.pem ubuntu@${aws_eip.app.public_ip}"
}

output "elastic_ip" {
  description = "Static public IP of the EC2 instance"
  value       = aws_eip.app.public_ip
}