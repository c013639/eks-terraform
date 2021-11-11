data "aws_region" "current" {} 

locals {
  aws_account_id = var.aws_account_id != "" ? var.aws_account_id : data.aws_caller_identity.current.account_id
  # clean URLs of https:// prefix
  urls = [
    for url in compact(distinct(concat(var.provider_urls, [var.provider_url]))) :
    replace(url, "https://", "")
  ]
  number_of_role_policy_arns = coalesce(var.number_of_role_policy_arns, length([aws_iam_policy.cluster_autoscaler.arn]))
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "assume_role_with_oidc" {
  count = var.create_role ? 1 : 0

  dynamic "statement" {
    for_each = local.urls

    content {
      effect = "Allow"

      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type = "Federated"

        identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.aws_account_id}:oidc-provider/${statement.value}"]
      }

      dynamic "condition" {
        for_each = length(var.oidc_fully_qualified_subjects) > 0 ? local.urls : []

        content {
          test     = "StringEquals"
          variable = "${statement.value}:sub"
          values   = var.oidc_fully_qualified_subjects
        }
      }

      dynamic "condition" {
        for_each = length(var.oidc_subjects_with_wildcards) > 0 ? local.urls : []

        content {
          test     = "StringLike"
          variable = "${statement.value}:sub"
          values   = var.oidc_subjects_with_wildcards
        }
      }

      dynamic "condition" {
        for_each = length(var.oidc_fully_qualified_audiences) > 0 ? local.urls : []

        content {
          test     = "StringLike"
          variable = "${statement.value}:aud"
          values   = var.oidc_fully_qualified_audiences
        }
      }
    }
  }
}

resource "helm_release" "cluster-autoscaler" {
  
  name             = "cluster-autoscaler"
  namespace        = local.k8s_service_account_namespace
  repository       = "https://kubernetes.github.io/autoscaler"
  chart            = "cluster-autoscaler"
  version          = "9.10.7"
  create_namespace = false

  set {
    name  = "awsRegion"
    value = data.aws_region.current.name
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = local.k8s_service_account_name
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = element(concat(aws_iam_role.this.*.arn, [""]), 0)
    type  = "string"
  }
  set {
    name  = "autoDiscovery.clusterName"
    value = local.name
  }
  set {
    name  = "autoDiscovery.enabled"
    value = "true"
  }
  set {
    name  = "rbac.create"
    value = "true"
  }
}

locals {
  name            = var.cluster_name
  k8s_service_account_namespace = "kube-system"
  k8s_service_account_name      = "cluster-autoscaler-aws"
}

resource "aws_iam_role" "this" {
  count = var.create_role ? 1 : 0

  name                 = var.role_name
  name_prefix          = var.role_name_prefix
  description          = var.role_description
  path                 = var.role_path
  max_session_duration = var.max_session_duration

  force_detach_policies = var.force_detach_policies
  permissions_boundary  = var.role_permissions_boundary_arn

  assume_role_policy = join("", data.aws_iam_policy_document.assume_role_with_oidc.*.json)

  tags = var.tags
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "clusterAutoscalerAll"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "ec2:DescribeLaunchTemplateVersions",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "clusterAutoscalerOwn"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_id}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name_prefix = "cluster-autoscaler"
  description = "EKS cluster-autoscaler policy for cluster var.cluster_id"
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json
} 

resource "aws_iam_role_policy_attachment" "custom" {
  count = var.create_role ? local.number_of_role_policy_arns : 0
  role       = join("", aws_iam_role.this.*.name)
  policy_arn = [aws_iam_policy.cluster_autoscaler.arn][count.index]
}


