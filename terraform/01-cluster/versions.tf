# Stage 01 is PURE AWS -- no kubernetes/helm providers here. That is deliberate:
# it lets this stage plan/apply without a running cluster, sidestepping the
# provider chicken-egg. The in-cluster resources live in 02-bootstrap.
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state for now. To move to a shared/remote backend later, uncomment and
  # `terraform init -migrate-state` (bootstrap the bucket + lock table first):
  # backend "s3" {
  #   bucket         = "dagster-platform-tfstate"
  #   key            = "01-cluster/terraform.tfstate"
  #   region         = "us-west-2"
  #   dynamodb_table = "dagster-platform-tflock"
  #   encrypt        = true
  # }
}
