variable "project_id" {}

variable "network_name" {
  type = string
  default = "vpc"
}

variable "fleets" {
    type = list(object({
        region = string
        env    = string
        num_clusters  = number
        subnet = object({
            name = string
            cidr = string
        })
    }))
    default = [
        {
            region        = "us-west2"
            env           = "prod"
            num_clusters  = 2
            subnet = {
                name = "us-west2"
                cidr = "10.1.0.0/17"
            }
        },
        {
            region        = "us-central1"
            env           = "prod"
            num_clusters  = 2
            subnet = {
                name = "us-central1"
                cidr = "10.2.0.0/17"
            }
        },
        {
            region        = "us-east4"
            env           = "prod"
            num_clusters  = 0
            subnet = {
                name = "us-east4"
                cidr = "10.3.0.0/17"
            }
        }
    ]
}

# GKE Config (config cluster for ingress etc.)
variable "gke_config" {
  type = object({
    name    = string
    region  = string
    zone    = string
    env     = string
    network = string
    subnet = object({
      name               = string
      ip_range           = string
      ip_range_pods_name = string
      ip_range_pods      = string
      ip_range_svcs_name = string
      ip_range_svcs      = string
    })
  })
  default = {
    name    = "gke-config"
    region  = "us-central1"
    zone    = "us-central1-a"
    env     = "config"
    network = "vpc-prod"
    subnet = {
      name               = "us-central1-config"
      ip_range           = "10.10.0.0/20"
      ip_range_pods_name = "us-central1-config-pods"
      ip_range_pods      = "10.11.0.0/18"
      ip_range_svcs_name = "us-central1-config-svcs"
      ip_range_svcs      = "10.12.0.0/24"
    }
  }
}


