# Infisical POC — mTLS com Kubernetes e cert-manager

Prova de conceito de emissão, **rotação automática** e validação de
certificados **mTLS** usando o **Infisical** como CA, **cert-manager** com o
**Infisical PKI Issuer** para gerir o ciclo de vida dos certificados, e o
**Stakater Reloader** para reiniciar os pods quando o certificado renova.

➡️ **Passo-a-passo completo para replicar: [GUIA.md](GUIA.md).**

## Arquitetura

```
                 emite/renova (auto)
Infisical PKI  <───────────────────────  cert-manager + Infisical PKI Issuer
(CA interna)                                      │ grava no Secret
                                                  v
                                       corebank-client-tls-secret (tls.crt/key + ca.crt)
                                                  │ muda no rollover
                                                  v
                                       Stakater Reloader ──> rolling restart do pod
                                                  │
   cliente mTLS (httpbin-corebank) ──────────────┘ monta o cert e chama:
        │ apresenta o cert
        v
   Nginx Ingress (auth-tls-verify-client: on, valida contra a CA)
        │
        v
   httpbin-apolo (servidor)
```

Fluxo: o recurso `Certificate` declara o cert desejado; o cert-manager emite
via Infisical PKI Issuer, grava no Secret e renova automaticamente; o Reloader
faz rolling restart para o pod pegar o cert novo; o Nginx Ingress exige e valida
o certificado do cliente (mTLS).

## Estrutura do repositório

```
.
├── README.md                      # este arquivo (visão geral)
├── GUIA.md                        # passo-a-passo completo + troubleshooting
├── metallb-config.yaml            # IPAddressPool + L2Advertisement do MetalLB
├── manifests/
│   ├── pki-issuer-stack.yaml      # Issuer + Certificate + RBAC de aprovação
│   ├── apps.yaml                  # httpbin-apolo (servidor) + httpbin-corebank (cliente)
│   └── infisicalsecret.yaml       # fluxo 2 (secrets de app) — opcional
└── terraform/                     # cluster Kind + Infisical + Postgres + Redis
    ├── main.tf, infra-poc.tf, providers.tf, variables.tf, outputs.tf
    └── certs/cert.pem             # certificado da CA (não versionado)
```

## Componentes e versões

| Componente               | Versão   | Namespace            |
| ------------------------ | -------- | -------------------- |
| Kubernetes (Kind)        | v1.29.7  | -                    |
| Infisical                | v0.160.9 | infisical            |
| PostgreSQL               | 15.5     | infisical            |
| Redis                    | 7.2.4    | infisical            |
| cert-manager             | latest   | cert-manager         |
| Infisical PKI Issuer     | 0.1.1    | infisical-pki-issuer |
| Nginx Ingress Controller | latest   | ingress-nginx        |
| Stakater Reloader        | latest   | reloader             |
| MetalLB                  | 0.14.9   | metallb-system       |

## Notas importantes

- O menu **Signers** do Certificate Manager (v0.160) é de *code signing*, não é
  a CA de TLS — a CA interna fica em `Settings > Internal Certificate Authorities`.
- O PKI Issuer 0.1.1 assina via um **certificate template** (criado por API; a UI
  só expõe "Certificate Profiles") — detalhes no [GUIA.md](GUIA.md).
- `terraform/certs/cert.pem` não deve ser commitado (já no `.gitignore`).
