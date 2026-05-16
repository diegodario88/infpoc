variable "cluster_name" {
  description = "Name of the Kind cluster"
  type        = string
  default     = "apache"
}

variable "node_image" {
  description = "Docker image to use for Kind nodes"
  type        = string
  default     = "kindest/node:v1.29.7"
}

variable "infisical_namespace" {
  description = "Kubernetes namespace for Infisical"
  type        = string
  default     = "infisical"
}

