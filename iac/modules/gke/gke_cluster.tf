provider "google" {
  project = var.project_id
  region  = var.region
}

# Private VPC
resource "google_compute_network" "gke_vpc" {
  name                    = "gke-secure-vpc"
  auto_create_subnetworks = false
}

# Subnet for Cluster
resource "google_compute_subnetwork" "gke_subnet" {
  name          = "gke-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.gke_vpc.id

  # Pod and Service Range
  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Nat Gateway for externernal access
resource "google_compute_router" "gke_router" {
  name    = "gke-nat-router"
  network = google_compute_network.gke_vpc.id
  region  = google_compute_subnetwork.gke_subnet.region
}

# Nat Gateway for external access
resource "google_compute_router_nat" "gke_nat" {
  name                               = "gke-nat-gateway"
  router                             = google_compute_router.gke_router.name
  region                             = google_compute_router.gke_router.region
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

  subnetwork {
    name                    = google_compute_subnetwork.gke_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# Dedicated Service account
resource "google_service_account" "gke_node_sa" {
  account_id   = "gke-node-sa"
  display_name = "GKE Node Service Account"
}

# Role Assignmnet 
resource "google_project_iam_member" "gke_node_sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "gke_node_sa_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "gke_node_sa_artifacts" {
  project = var.project_id
  role    = "roles/artifactregistry.reader" 
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# GKE cluster Config-
resource "google_container_cluster" "secure_gke_cluster" {
  name                     = "secure-gke-cluster"
  location                 = var.region
  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = google_compute_network.gke_vpc.id
  subnetwork               = google_compute_subnetwork.gke_subnet.id

  # Use a stable release channel for automatic security patches and upgrades
  release_channel {
    channel = "STABLE"
  }

  # Make the cluster private
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # IP Allocation
  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.gke_subnet.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.gke_subnet.secondary_ip_range[1].range_name
  }

  # Enable Workload Identity 
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Enable Network Policy
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Enable Shielded Nodes
  enable_shielded_nodes = true

  # Disable legacy features
  enable_legacy_abac = false

  # Enable Log and Monitoring
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  # Disable basic authentication
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

}

# Node Pool config
resource "google_container_node_pool" "secure_node_pool" {
  name       = "secure-node-pool"
  location   = var.region
  cluster    = google_container_cluster.secure_gke_cluster.name
  node_count = 2

  node_config {
    image_type   = "COS_CONTAINERD"
    machine_type = "e2-medium"
    disk_size_gb = 50

    service_account = google_service_account.gke_node_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Use metadata concealment to protect node metadata
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}