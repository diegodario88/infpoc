variable "cluster_name" {
  description = "Name of the Kind cluster (must match phase1)"
  type        = string
  default     = "apache"
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "client_id" {
  description = "Infisical Machine Identity Client ID"
  type        = string
  sensitive   = true
}

variable "client_secret" {
  description = "Infisical Machine Identity Client Secret"
  type        = string
  sensitive   = true
}

variable "project_id" {
  description = "Infisical Project UUID"
  type        = string
}

variable "ca_cert_path" {
  description = "Path to the CA certificate PEM file (downloaded from Infisical)"
  type        = string
  default     = "../certs/cert.pem"
}

variable "infisical_url" {
  description = "Internal URL of the Infisical service"
  type        = string
  default     = "http://infisical-lb.infisical.svc.cluster.local"
}

variable "subscriber_name" {
  description = "Nome do PKI Subscriber cadastrado no painel do Infisical (com auto-renewal habilitado)"
  type        = string
  default     = "corebank-mtls"
}

variable "subscriber_sync_schedule" {
  description = "Cron schedule do CronJob que sincroniza o bundle do subscriber para o Secret"
  type        = string
  default     = "*/15 * * * *"
}
