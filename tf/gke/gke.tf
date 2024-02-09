data "google_compute_zones" "available" {
  for_each = toset([for fleet in var.fleets : fleet.region])
  project  = var.project_id
  region   = each.value
}

data "google_project" "project" {
  project_id = var.project_id
}

resource "random_pet" "gke" {
  for_each = { for cluster in local.gke_clusters : cluster.cluster_num => cluster }
  keepers = {
    gke = each.key
  }
}

locals {
  subnets = module.vpc.subnets
  zones   = data.google_compute_zones.available
  gke_clusters = flatten([[
    for fleet in var.fleets : [
      for num in range(fleet.num_clusters) : {
        zone              = local.zones[fleet.region].names[num % length(local.zones[fleet.region].names)]
        env               = fleet.env
        region            = fleet.region
        subnetwork        = local.subnets["${fleet.region}/${fleet.region}"].name
        ip_range_pods     = "${fleet.region}-pod-cidr"
        ip_range_services = "${fleet.region}-svc-cidr-${num}"
        network           = module.vpc.network_name
        cluster_num       = "gke-${fleet.region}-${num}"
        name              = ""
      }
    ]
    ], [
    {
      zone              = var.gke_config.zone
      env               = var.gke_config.env
      region            = var.gke_config.region
      subnetwork        = var.gke_config.subnet.name
      ip_range_pods     = var.gke_config.subnet.ip_range_pods_name
      ip_range_services = var.gke_config.subnet.ip_range_svcs_name
      network           = module.vpc.network_name
      cluster_num       = var.gke_config.name
      name              = var.gke_config.name
    }
    ]
  ])
}

module "gke" {
  source                    = "terraform-google-modules/kubernetes-engine/google"
  for_each                  = { for cluster in local.gke_clusters : cluster.cluster_num => cluster }
  project_id                = module.vpc.project_id
  name                      = each.value.name != "" ? "${each.value.name}-${random_pet.gke[each.key].id}" : "gke-${each.value.zone}-${random_pet.gke[each.key].id}"
  regional                  = false
  region                    = each.value.region
  zones                     = [each.value.zone]
  release_channel           = "UNSPECIFIED"
  maintenance_start_time    = "08:00"
  network                   = each.value.network
  subnetwork                = each.value.subnetwork
  ip_range_pods             = each.value.ip_range_pods
  ip_range_services         = each.value.ip_range_services
  gateway_api_channel       = "CHANNEL_STANDARD"
  default_max_pods_per_node = 64
  network_policy            = true
  deletion_protection       = false
  cluster_resource_labels   = { "mesh_id" : "proj-${data.google_project.project.number}", "env" : "${each.value.env}", "infra" : "gcp" }
  node_pools = [
    {
      name         = "node-pool-01"
      autoscaling  = true
      auto_upgrade = false
      min_count    = 1
      max_count    = 5
      node_count   = 2
      machine_type = "e2-standard-4"
    },
  ]
}

resource "google_gke_hub_membership" "membership" {
  for_each      = { for cluster in local.gke_clusters : cluster.cluster_num => cluster }
  membership_id = each.key
  project       = var.project_id
  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${module.gke[each.key].cluster_id}"
    }
  }
  # provider   = google-beta
  depends_on = [module.gke]
}


