output "nginx_ingress_namespace" {
  description = "Namespace do Nginx Ingress Controller"
  value       = "ingress-nginx"
}

output "ca_secret_location" {
  description = "Localização do secret da CA (único ponto de configuração do cert.pem)"
  value       = "secret/infisical-ca no namespace ingress-nginx"
}

output "next_steps" {
  description = "Próximos passos após phase2"
  value       = <<-EOT

    ✅ PHASE 2 CONCLUÍDA

    Verifique o certificado emitido:
      kubectl get certificate -n corebank-apps
      kubectl get secret corebank-client-tls-secret -n corebank-apps

    Verifique o Nginx Ingress:
      kubectl get svc -n ingress-nginx

    Para rotacionar a CA no futuro, atualize apenas:
      secret/infisical-ca no namespace ingress-nginx
    E aplique: terraform apply
  EOT
}
