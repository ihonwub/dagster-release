provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Applied to every taggable resource this provider creates.
  default_tags {
    tags = {
      project    = var.project
      owner      = var.owner_email
      env        = var.env
      managed-by = "terraform"
    }
  }
}
