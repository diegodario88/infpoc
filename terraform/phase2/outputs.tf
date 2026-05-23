output "nginx_ingress_namespace" {
  description = "Namespace do Nginx Ingress Controller"
  value       = "ingress-nginx"
}

output "ca_secret_location" {
  description = "Localizacao dos secrets da CA (um por namespace com Ingress mTLS)"
  value       = "secret/infisical-ca em: ingress-nginx, apolo-apps (e qualquer novo namespace com Ingress mTLS)"
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
