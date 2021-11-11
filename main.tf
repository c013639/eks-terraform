terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}
provider "aws" {
  region = "us-east-1"
}


provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
} 

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

data "aws_region" "current" {}



data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}


data "aws_availability_zones" "available" {
}

locals {
  cluster_name = var.cluster_name
}

locals {
  tf-eks-node-userdata = <<USERDATA
#!/bin/bash
set -o xtrace
/etc/eks/bootstrap.sh --apiserver-endpoint 'data.aws_eks_cluster.cluster.endpoint' --b64-cluster-ca 'data.aws_eks_cluster.cluster.certificate_authority.0.data' --kubelet-extra-args "--node-labels=env=dev --register-with-taints=env=dev:NoSchedule" '${local.cluster_name}'
USERDATA
}

data "aws_ami" "eks-worker-ami" {
  filter {
    name   = "name"
    values = var.worker_node_ami
  }

  most_recent = true
  owners      = var.eks_ami_account_id # Amazon EKS AMI Account ID
}


locals {
  name                          = var.cluster_name
  k8s_service_account_namespace = "kube-system"
  k8s_service_account_name      = "cluster-autoscaler-aws"
}

module "eks" {
  source  = "./modules/eks"
  #version = "17.22.0"
  cluster_enabled_log_types            = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access      = true
  cluster_name    = "${local.cluster_name}"
  cluster_version = "1.21"
  subnets         = var.vpc_subnets_private
  #cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  worker_create_security_group         = true
  vpc_id          = var.vpc_id
  enable_irsa = true

  
  tags = {
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
  }
  worker_groups = [
    {
	  name                          = "worker-group-1"
      instance_type                 = "t3.small"
	  ami_id                        = data.aws_ami.eks-worker-ami.id
      additional_userdata           = "$(local.tf-eks-node-userdata)"
      asg_desired_capacity          = 2
      additional_security_group_ids = [module.security_group.security_group_id]
      asg_max_size  = 4
    }
  ]	
  write_kubeconfig   = true
}

module "irsa" { 
  source                        = "./modules/irsa"
  create_role                   = true
  role_name                     = "cluster-autoscaler"
  provider_url                  = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  cluster_id                    = module.eks.cluster_id
  cluster_name                  = var.cluster_name
  oidc_fully_qualified_subjects = ["system:serviceaccount:${local.k8s_service_account_namespace}:${local.k8s_service_account_name}"]

}

module "security_group" {
  source                        = "./modules/security_group"
  vpc_id                        = var.vpc_id
}
