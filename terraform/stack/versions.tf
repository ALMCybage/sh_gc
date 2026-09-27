terraform {
  # Pinned rather than ">=": a provider minor release changing a default is a
  # surprise you want at the moment you choose to upgrade, not on an unrelated apply.
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.14"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Applied to resources that support it and have no explicit labels.
  default_labels = {
    managed_by = "terraform"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
