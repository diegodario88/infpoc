output "cluster_name" {
  description = "Kind cluster name"
  value       = kind_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes cluster endpoint"
  value       = replace(kind_cluster.main.endpoint, "0.0.0.0", "127.0.0.1")
}

output "kubeconfig_path" {
  description = "Path to kubeconfig file"
  value       = kind_cluster.main.kubeconfig_path
}

output "infisical_namespace" {
  description = "Infisical namespace"
  value       = kubernetes_namespace.infisical.metadata[0].name
}

output "infisical_service" {
  description = "Infisical service name"
  value       = kubernetes_service.infisical_lb.metadata[0].name
}

output "access_infisical" {
  description = "How to access Infisical"
  value       = "Port forward: kubectl port-forward -n infisical svc/infisical-lb 3000:80"
}

output "kubectl_config_commands" {
  description = "Commands to configure kubectl"
  value = <<-EOT
    # Set kubeconfig
    export KUBECONFIG=${kind_cluster.main.kubeconfig_path}

    # Verify cluster
    kubectl --kubeconfig=${kind_cluster.main.kubeconfig_path} cluster-info

    # Get pods
    kubectl --kubeconfig=${kind_cluster.main.kubeconfig_path} get pods -n infisical

    # Port forward to Infisical (Mapeia a porta 80 do serviço LoadBalancer para 3000 local)
    kubectl --kubeconfig=${kind_cluster.main.kubeconfig_path} port-forward -n infisical svc/infisical-lb 3000:80
  EOT
}
