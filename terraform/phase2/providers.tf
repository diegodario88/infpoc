terraform {
  required_version = ">= 1.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = "kind-${var.cluster_name}"
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = "kind-${var.cluster_name}"
  }
}
