terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  backend "gcs" {
    # terraform init -backend-config=backend.hcl
    prefix = "envs/prod"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14"
    }
  }
}
