output "instance_id" {
  description = "ID of the hermes EC2 instance."
  value       = aws_instance.hermes.id
}

output "public_ip" {
  description = "Public IP of the hermes instance."
  value       = aws_instance.hermes.public_ip
}

output "private_ip" {
  description = "Private IP of the hermes instance."
  value       = aws_instance.hermes.private_ip
}

output "availability_zone" {
  description = "Availability zone the instance was placed in."
  value       = aws_instance.hermes.availability_zone
}

output "ssm_session_command" {
  description = "Command to open an interactive shell on the instance via SSM."
  value       = "aws ssm start-session --target ${aws_instance.hermes.id} --region ${var.region}"
}
