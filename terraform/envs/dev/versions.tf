terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  /**
   * Remote state in GCS.
   *
   * Local state is a single point of failure and cannot be shared: two engineers
   * applying at once would silently overwrite each other's resources. The GCS backend
   * also gives object-level locking, which is what actually prevents that.
   *
   * The bucket has to exist before `terraform init`, which is the one chicken-and-egg
   * in the setup. terraform/bootstrap-state/ creates it.
   */
  backend "gcs" {
    # Set with: terraform init -backend-config=backend.hcl
    # bucket = "my-project-sequifi-tfstate"
    prefix = "envs/dev"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14"
    }
  }
}
