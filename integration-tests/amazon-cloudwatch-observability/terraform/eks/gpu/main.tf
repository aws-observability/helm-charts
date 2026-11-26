// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

// DCGM Exporter on a real GPU: one g4dn.xlarge node on the EKS AL2023 NVIDIA AMI, the NVIDIA device
// plugin, the chart with the same values as ../main.tf, and the EKS validator built with the gpu tag,
// so TestDcgmExporterHealthy fails if dcgm-exporter is not Ready, restarts, or serves no DCGM_FI_ series.

module "common" {
  source = "../../common"
}

locals {
  aws_eks      = "aws eks --region ${var.region}"
  cluster_name = var.cluster_name != "" ? var.cluster_name : "cwagent-helm-chart-integ-gpu"
}

resource "aws_eks_cluster" "this" {
  name     = "${local.cluster_name}-${module.common.testing_id}"
  role_arn = module.common.role_arn
  version  = var.k8s_version
  vpc_config {
    subnet_ids         = module.common.public_subnet_ids
    security_group_ids = [module.common.security_group]
  }
}

# EKS Node Groups
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.cluster_name}-node"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = module.common.public_subnet_ids

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  # The NVIDIA AMI has the driver and container toolkit, but not the device plugin.
  ami_type      = "AL2023_x86_64_NVIDIA"
  capacity_type = "ON_DEMAND"
  # shortcut: 50 GiB is a guess for the NVIDIA AMI plus the DCGM image; raise it if image pulls fail.
  disk_size      = 50
  instance_types = [var.instance_type]

  # The device plugin chart only schedules on nodes NFD marks as NVIDIA, or with this label. There is no NFD here.
  labels = {
    "nvidia.com/gpu.present" = "true"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_CloudWatchAgentServerPolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy
  ]
}

# EKS Node IAM Role
resource "aws_iam_role" "node_role" {
  name = "${local.cluster_name}-Worker-Role-${module.common.testing_id}"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_CloudWatchAgentServerPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.node_role.name
}

resource "null_resource" "kubectl" {
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this
  ]
  provisioner "local-exec" {
    command = <<-EOT
      ${local.aws_eks} update-kubeconfig --name ${aws_eks_cluster.this.name}
      ${local.aws_eks} list-clusters --output text
      ${local.aws_eks} describe-cluster --name ${aws_eks_cluster.this.name} --output text
    EOT
  }
}

resource "helm_release" "nvidia_device_plugin" {
  depends_on = [
    null_resource.kubectl
  ]
  name       = "nvidia-device-plugin"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = var.nvidia_device_plugin_version
  wait       = true
}

resource "helm_release" "this" {
  depends_on = [
    helm_release.nvidia_device_plugin
  ]
  name             = "amazon-cloudwatch-observability"
  namespace        = "amazon-cloudwatch"
  create_namespace = true
  chart            = var.helm_dir
  set = concat([
    {
      name  = "region"
      value = var.region
    },
    {
      name  = "clusterName"
      value = aws_eks_cluster.this.name
    },
    {
      name  = "otelContainerInsights.enabled"
      value = "true"
    }
    ],
    var.operator_image_tag == "" ? [] : [{ name = "manager.image.tag", value = var.operator_image_tag }],
  )
}

resource "null_resource" "validator" {
  depends_on = [
    helm_release.this
  ]
  provisioner "local-exec" {
    command = "go test ${var.test_dir} -v --tags=linuxonly,gpu -timeout 20m"
  }
}
