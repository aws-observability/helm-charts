// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

// Java profiling with Application Signals: the chart with java.profiling on and its default-on OTLP endpoint
// (otlp.http.port), a Java workload with ADOT, and a validator that checks each signal reaches its own receiver
// (traces and Application Signals metrics on 4316, profiles on the OTLP HTTP endpoint) and lands in CloudWatch. Needs operator and agent images with Java profiling (agent v1.300075.0 or
// later); the image variables override the chart defaults.

module "common" {
  source = "../../common"
}

locals {
  aws_eks      = "aws eks --region ${var.region}"
  cluster_name = var.cluster_name != "" ? var.cluster_name : "cwagent-helm-chart-integ"
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

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  disk_size      = 20
  instance_types = [var.instance_type]

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

resource "helm_release" "this" {
  depends_on = [
    null_resource.kubectl
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
    }
    ],
    var.operator_image_domain == "" ? [] : [{ name = "manager.image.repositoryDomainMap.public", value = var.operator_image_domain }],
    var.operator_image_tag == "" ? [] : [{ name = "manager.image.tag", value = var.operator_image_tag }],
    var.agent_image_domain == "" ? [] : [{ name = "agent.image.repositoryDomainMap.public", value = var.agent_image_domain }],
    var.agent_image_repository == "" ? [] : [{ name = "agent.image.repository", value = var.agent_image_repository }],
    var.agent_image_tag == "" ? [] : [{ name = "agent.image.tag", value = var.agent_image_tag }],
    [
      { name = "manager.autoInstrumentationConfiguration.java.profiling.enabled", value = "true", type = "string" },
      { name = "otlp.profiles.enabled", value = "true" },
      { name = "otlp.http.port", value = var.otlp_http_port },
    ],
  )
}

resource "null_resource" "validator" {
  depends_on = [
    helm_release.this
  ]
  provisioner "local-exec" {
    command = "bash ${var.test_dir}/java_profiling_e2e.sh ${var.region} java-profiling-it-${module.common.testing_id} ${var.test_dir}/java-profiling-app.yaml ${var.otlp_http_port}"
  }
}
