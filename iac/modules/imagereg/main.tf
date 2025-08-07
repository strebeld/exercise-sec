provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_artifact_registry_repository" "wiz_repo" {
  provider  = google
  location  = var.region
  repository_id = "wiz-images"
  description   = "Docker repository for storing container images"
  format        = "DOCKER"
}
