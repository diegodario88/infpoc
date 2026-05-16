terraform {
  required_version = ">= 1.0"
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    time = { 
      source = "hashicorp/time" 
    }
  }
}

provider "kind" {}

provider "kubernetes" {
  host                   = replace(kind_cluster.main.endpoint, "0.0.0.0", "127.0.0.1")
  client_certificate     = kind_cluster.main.client_certificate
  client_key             = kind_cluster.main.client_key
  cluster_ca_certificate = kind_cluster.main.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = replace(kind_cluster.main.endpoint, "0.0.0.0", "127.0.0.1")
    client_certificate     = kind_cluster.main.client_certificate
    client_key             = kind_cluster.main.client_key
    cluster_ca_certificate = kind_cluster.main.cluster_ca_certificate
  }
}

