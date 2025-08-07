variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources into."
  type        = string
  default     = "us-central1"
}

variable "authorized_ip_range" {
  description = "The IP range authorized to access the GKE control plane. Should be your workstation's public IP in CIDR format (e.g., 'x.x.x.x/32')."
  type        = string
}