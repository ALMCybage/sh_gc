/**
 * The chicken-and-egg: Terraform state lives in GCS, but the bucket has to exist
 * before `terraform init` can use it.
 *
 * This tiny root module creates the bucket with LOCAL state, and is the only thing
 * in the repo that does. Run it once per project, commit nothing, and every other
 * environment then uses the remote backend.
 *
 *   cd terraform/bootstrap-state
 *   terraform init
 *   terraform apply -var project_id=my-project
 *
 * Then, in each env:
 *   terraform init -backend-config="bucket=my-project-sequifi-tfstate"
 */

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }

variable "region" {
  type    = string
  default = "us-central1"
}

resource "google_storage_bucket" "state" {
  name     = "${var.project_id}-sequifi-tfstate"
  project  = var.project_id
  location = var.region

  uniform_bucket_level_access = true
  # State contains generated passwords and resource inventory. It must never be
  # publicly reachable, whatever the project's other policies say.
  public_access_prevention = "enforced"

  versioning {
    # State history is the recovery path when an apply goes wrong. Without versioning
    # a corrupted state file is unrecoverable and the infrastructure has to be
    # imported back by hand.
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 30
    }

    action {
      type = "Delete"
    }
  }

  lifecycle {
    # Deleting the state bucket orphans every resource Terraform manages.
    prevent_destroy = true
  }
}

output "backend_config" {
  value = <<-EOT
    Initialise each environment with:

      terraform init -backend-config="bucket=${google_storage_bucket.state.name}"

    Or write terraform/envs/<env>/backend.hcl containing:

      bucket = "${google_storage_bucket.state.name}"
  EOT
}
