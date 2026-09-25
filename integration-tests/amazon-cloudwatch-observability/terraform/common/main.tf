// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

resource "random_id" "testing_id" {
  byte_length = 8
}

locals {
  cwa_iam_role       = "cwa-e2e-iam-role"
  vpc_security_group = "vpc_security_group"
}

data "aws_iam_role" "cwagent_iam_role" {
  name = local.cwa_iam_role
}

data "aws_vpc" "vpc" {
  default = true
}

data "aws_subnets" "public_subnet_ids" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
}

data "aws_security_group" "security_group" {
  name = local.vpc_security_group
}
