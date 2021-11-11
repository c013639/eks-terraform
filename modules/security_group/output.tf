output "security_group_id" {
  description = "The ID of the security group"
  value =  aws_security_group.worker_group_mgmt_one.id
}