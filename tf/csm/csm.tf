
resource "google_gke_hub_feature_membership" "gke_west2_a" {
  project   = var.project_id
  location   = "global"
  feature    = "projects/${var.project_id}/locations/global/features/servicemesh"
  membership = var.gke_west2_a_cluster_membership
  mesh {
    management = "MANAGEMENT_AUTOMATIC"
  }
}

resource "google_gke_hub_feature_membership" "gke_west2_b" {
  project   = var.project_id
  location   = "global"
  feature    = "projects/${var.project_id}/locations/global/features/servicemesh"
  membership = var.gke_west2_b_cluster_membership
  mesh {
    management = "MANAGEMENT_AUTOMATIC"
  }
}
