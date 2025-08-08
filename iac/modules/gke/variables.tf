variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
  default = "clgcporg10-170"
}

variable "region" {
  description = "The GCP region for all resources."
  type        = string
  default     = "us-central1"
}

variable "authorized_ip_range" {
  description = "CIDR block for accessing the GKE control plane (e.g., your workstation IP)."
  type        = string
}

variable "gke_cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "secure-gke-cluster"
}

variable "gke_node_pool_name" {
  description = "Name of the GKE node pool."
  type        = string
  default     = "secure-node-pool"
}

variable "node_count" {
  description = "Number of nodes in the node pool."
  type        = number
  default     = 2
}

variable "machine_type" {
  description = "Machine type for GKE nodes."
  type        = string
  default     = "e2-medium"
}

variable "disk_size_gb" {
  description = "Disk size (GB) for each node."
  type        = number
  default     = 50
}