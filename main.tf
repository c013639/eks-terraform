provider "aws" {
  region = "us-east-1"
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

data "aws_availability_zones" "available" {
}

locals {
  cluster_name = var.cluster_name
}

data "aws_ami" "eks-worker-ami" {
  filter {
    name   = "name"
    values = var.worker_node_ami
  }

  most_recent = true
  owners      = var.eks_ami_account_id # Amazon EKS AMI Account ID
}



module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "17.22.0"
  cluster_enabled_log_types            = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access      = true
  cluster_name    = "${local.cluster_name}"
  cluster_version = "1.18"
  subnets         = var.vpc_subnets_private

  vpc_id          = var.vpc_id
  
  tags = {
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
  }
  worker_groups = [
    {
	  name                          = "worker-group-1"
      instance_type                 = "t3.small"
	  ami_id                        = data.aws_ami.eks-worker-ami.id
      additional_userdata           = "echo place here"
      asg_desired_capacity          = 2
      additional_security_group_ids = [aws_security_group.worker_group_mgmt_one.id]
      asg_max_size  = 3
    }
  ]	
  write_kubeconfig   = true
}

resource "aws_security_group" "worker_group_mgmt_one" {
  name_prefix = "worker_group_mgmt_one"
  vpc_id      = var.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
    ]
  }
}