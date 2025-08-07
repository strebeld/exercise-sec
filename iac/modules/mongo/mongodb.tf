provider "google" {
  project = "gke-project-467402"  # <-- replace with your project ID
  credentials = file("~/gcpkey/gke-project-467402-f5893750ef0c.json")
  region  = "us-central1"
  zone    = "us-central1-a"
}

# GCS Bucket for MongoDB backups
resource "google_storage_bucket" "mongodb_backups" {
  name                        = "mongodb-backups-${random_id.bucket_id.hex}"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}

# Make bucket objects publicly readable and listable
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.mongodb_backups.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "random_id" "bucket_id" {
  byte_length = 4
}

resource "google_compute_instance" "mongodb_vm" {
  name         = "mongodb-vm"
  machine_type = "e2-medium"
  zone         = "us-central1-a"

  tags = ["mongodb", "ssh"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 20
    }
  }

  network_interface {
    network       = "default"
    access_config {}
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y gnupg curl cron gzip

    # Install MongoDB
    curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list
    apt-get update
    apt-get install -y mongodb-org

    # Configure MongoDB for remote access and authentication
    sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
    echo -e "security:\n  authorization: enabled" >> /etc/mongod.conf
    systemctl enable mongod
    systemctl start mongod
    sleep 10

    # Create admin user
    mongo <<EOF
use admin
db.createUser({
  user: "admin",
  pwd: "StrongPassword123!",
  roles: [ { role: "userAdminAnyDatabase", db: "admin" }, { role: "readWriteAnyDatabase", db: "admin" } ]
})
EOF
    systemctl restart mongod

    # Install Google Cloud SDK and authenticate
    echo "Installing gcloud CLI..."
    apt-get install -y apt-transport-https ca-certificates gnupg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
    apt-get update && apt-get install -y google-cloud-sdk

    # Write backup script
    cat << 'EOF2' > /usr/local/bin/mongo_backup.sh
#!/bin/bash
DATE=$(date +%F-%H-%M)
BACKUP_NAME="mongo-backup-$DATE.gz"
mongodump --authenticationDatabase admin -u admin -p 'StrongPassword123!' --archive | gzip > /tmp/$BACKUP_NAME
gsutil cp /tmp/$BACKUP_NAME gs://${google_storage_bucket.mongodb_backups.name}/
rm /tmp/$BACKUP_NAME
EOF2

    chmod +x /usr/local/bin/mongo_backup.sh

    # Setup daily cron job
    echo "0 2 * * * root /usr/local/bin/mongo_backup.sh" > /etc/cron.d/mongo_backup

    # Ensure cron is running
    systemctl enable cron
    systemctl start cron
  EOT

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# Open SSH
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh"]
}

# Open MongoDB
resource "google_compute_firewall" "allow_mongodb" {
  name    = "allow-mongodb"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["27017"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mongodb"]
}
