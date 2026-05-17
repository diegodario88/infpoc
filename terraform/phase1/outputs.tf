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

output "next_steps" {
  description = "O que fazer após o apply da phase1"
  value       = <<-EOT

    ✅ PHASE 1 CONCLUÍDA

    1. Faça o port-forward do Infisical:
       kubectl port-forward -n infisical svc/infisical-lb 3000:80 &

    2. Acesse http://localhost:3000 e configure:
       a. Crie conta admin
       b. Crie organização e projeto PKI
       c. Crie CA interna
       d. Baixe o cert.pem da CA → salve em ../certs/cert.pem
       e. Crie Machine Identity com Universal Auth
       f. Anote clientId e clientSecret
       g. Crie Certificate Template com:
          - CN: corebank.service.internal
          - SAN: corebank.corebank-namespace.svc.cluster.local
          - Max TTL: 24h

    3. Instale e configure o MetalLB:
       helm repo add metallb https://metallb.github.io/metallb
       helm repo update
       helm install metallb metallb/metallb -n metallb-system --create-namespace --wait
       kubectl apply -f ../metallb-config.yaml

    4. Configure as credenciais da phase2:
       cp ../phase2/terraform.tfvars.example ../phase2/terraform.tfvars
       # Edite com seus valores de clientId, clientSecret e caminho do cert.pem

    5. Execute a phase2:
       cd ../phase2 && terraform init && terraform apply
  EOT
}
