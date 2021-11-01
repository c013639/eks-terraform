variable "worker_node_ami" {
	type = list
}
variable "vpc_id" {}
variable "vpc_subnets_private" {
	type = list
}
variable "eks_ami_account_id" {
	type = list
}

variable "cluster_name" {}

