output "clusters" {
    value = module.gke
    sensitive = true 
}

output "memberships" {
  value = [
    for membership in google_gke_hub_membership.membership : membership.membership_id
  ]
}

