provider "google" {
  project = var.project_id
  region  = var.region
}

# Create a dedicated VPC for the GKE cluster for network isolation
resource "google_compute_network" "gke_vpc" {
  name                    = "gke-secure-vpc"
  auto_create_subnetworks = false
}

# Create a subnet for the GKE cluster
resource "google_compute_subnetwork" "gke_subnet" {
  name          = "gke-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.gke_vpc.id

  # Define secondary ranges for Pods and Services for a VPC-native cluster
  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Create a Cloud Router for the NAT Gateway
resource "google_compute_router" "gke_router" {
  name    = "gke-nat-router"
  network = google_compute_network.gke_vpc.id
  region  = google_compute_subnetwork.gke_subnet.region
}

# Create a Cloud NAT to allow outbound internet access for private nodes
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

# Create a dedicated service account for GKE nodes to follow least privilege
resource "google_service_account" "gke_node_sa" {
  account_id   = "gke-node-sa"
  display_name = "GKE Node Service Account"
}

# Assign minimal necessary roles to the node service account
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
  role    = "roles/artifactregistry.reader" # For pulling images from GCR/Artifact Registry
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# --- Secure GKE Cluster Resource ---
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

  # Restrict control plane access to your IP
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.authorized_ip_range
      display_name = "My-Workstation"
    }
  }

  # Enable VPC-native traffic routing
  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.gke_subnet.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.gke_subnet.secondary_ip_range[1].range_name
  }

  # Enable Workload Identity for secure access to other GCP services
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Enable Network Policy enforcement (e.g., Calico) to control pod-to-pod traffic
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Enable Shielded Nodes for verifiable node integrity
  enable_shielded_nodes = true

  # Disable legacy features
  enable_legacy_abac = false

  # Use standard GKE logging and monitoring
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  # Disable basic authentication and client certificate for improved security
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Disable the Kubernetes dashboard addon
  addons_config {
    kubernetes_dashboard {
      disabled = true
    }
  }
}

# --- Secure GKE Node Pool ---
resource "google_container_node_pool" "secure_node_pool" {
  name       = "secure-node-pool"
  location   = var.region
  cluster    = google_container_cluster.secure_gke_cluster.name
  node_count = 2

  node_config {
    # Use Google's hardened Container-Optimized OS
    image_type   = "COS_CONTAINERD"
    machine_type = "e2-medium"
    disk_size_gb = 50

    # Use the dedicated, least-privilege service account
    service_account = google_service_account.gke_node_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    # Enable Shielded GKE Node features
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Use metadata concealment to protect node metadata
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  # Enable auto-repair and auto-upgrade for node security and stability
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}