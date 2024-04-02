// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

output "security_group" {
  value = data.aws_security_group.security_group.id
}

output "public_subnet_ids" {
  value = data.aws_subnets.public_subnet_ids.ids
}

output "role_arn" {
  value = data.aws_iam_role.cwagent_iam_role.arn
}
