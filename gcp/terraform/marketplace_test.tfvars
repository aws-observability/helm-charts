# Marketplace validates this module with `terraform plan --var-file=marketplace_test.tfvars`.
#
# Do not include the following variables here:
# - project_id (provided by Marketplace)
#
# helm_chart_repo / helm_chart_name / helm_chart_version and all *_image_registry /
# *_image_repo / *_image_tag variables are NOT injected by Marketplace's
# "Click to Deploy" flow (confirmed: it applies the raw uploaded module zip
# as-is) — they default in variables.tf to this package's own mirrored chart
# and images, so they don't need to be (and can't rely on being) set here or
# anywhere else.

# goog_cm_deployment_name is populated by Marketplace's UI at real deploy time,
# but is NOT auto-injected during this validation plan — it must be set here
# explicitly, per Google support's confirmed root cause for EXECUTE_TERRAFORM_PLAN
# failures ("Error: No value for required variable").
goog_cm_deployment_name = "test-deployment"

# create_cluster=true here is ONLY for Marketplace's own validation plan, which
# needs to provision its own ephemeral test cluster. Real customer deployments
# never set this — see variables.tf.
create_cluster   = true
cluster_name     = "marketplace-test"
cluster_location = "us-central1"

helm_values_yaml = <<-EOT
  {
    "clusterName": "marketplace-test",
    "region": "us-east-1",
    "roleArn": "arn:aws:iam::000000000000:role/marketplace-test"
  }
EOT
