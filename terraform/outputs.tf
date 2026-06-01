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
  description = "O que fazer após o apply do terraform"
  value       = <<-EOT

    ✅ INFRA CRIADA (cluster + Infisical + Postgres + Redis)

    Continue pelo passo-a-passo em GUIA.md (na raiz do repo):
      - Passo 2: MetalLB
      - Passo 3: configuração no painel do Infisical (CA, identity, template)
      - Passos 4+: cert-manager, PKI Issuer, manifests e testes

    Acesso rápido ao painel:
      kubectl port-forward -n infisical svc/infisical-lb 3000:80 &
      # http://localhost:3000
  EOT
}
