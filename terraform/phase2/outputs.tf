output "nginx_ingress_namespace" {
  description = "Namespace do Nginx Ingress Controller"
  value       = "ingress-nginx"
}

output "ca_secret_location" {
  description = "Localizacao dos secrets da CA (um por namespace com Ingress mTLS)"
  value       = "secret/infisical-ca em: ingress-nginx, apolo-apps"
}

output "next_steps" {
  description = "Proximos passos apos phase2"
  value       = <<-EOT

    PHASE 2 CONCLUIDA

    1. Dispare manualmente o primeiro sync do subscriber:
       kubectl create job --from=cronjob/subscriber-sync \
         -n corebank-apps subscriber-sync-bootstrap
       kubectl logs -n corebank-apps -l job-name=subscriber-sync-bootstrap -f

    2. Confirme que o Secret foi criado com o cert vindo do subscriber:
       kubectl get secret corebank-client-tls-secret -n corebank-apps
       kubectl get secret corebank-client-tls-secret -n corebank-apps \
         -o jsonpath='{.metadata.annotations.infisical\.com/serial}'; echo

    3. Confirme o IP externo do Nginx (vindo do MetalLB):
       kubectl get svc -n ingress-nginx

    Forcar rotacao no painel: PKI > Subscribers > corebank-mtls > Issue Certificate
  EOT
}
