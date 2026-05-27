# Infisical POC - mTLS com Kubernetes, Kind e Terraform

Prova de conceito para demonstrar o fluxo de emissão e validação de certificados mTLS
usando o Infisical como PKI (Certificate Authority), com rotação governada pelo
**PKI Subscriber** do painel — um CronJob no cluster sincroniza o bundle ativo e
o Stakater Reloader faz rolling restart do pod quando o cert renova.

## Visão Geral da Arquitetura

```
Cliente
    |
    v
Nginx Ingress Controller (unico componente que conhece o ca.crt da CA)
    |
    | mTLS: valida o certificado do Pod usando ca.crt
    v
Pod da aplicacao (certificado emitido pelo Infisical PKI)
    |
    v
Infisical PKI (Certificate Authority)
```

O Nginx Ingress e o unico ponto que precisa conhecer o certificado da CA.
Quando a CA for rotacionada no Infisical, apenas o Secret `infisical-ca`
no namespace `ingress-nginx` precisa ser atualizado, sem impacto nos pods.

## Pre-requisitos

Ferramentas necessarias instaladas e funcionando:

- Docker
- Terraform >= 1.0
- kubectl
- Helm >= 3.0
- Git
- WSL2 (se Windows)

O Kind e gerenciado pelo provider Terraform `tehcyx/kind`, nao e necessario
instalar o binario Kind separadamente.

## Estrutura do Projeto

```
.
|-- README.md
|-- docs/
|   `-- fluxos.md             # Detalhes operacionais e troubleshooting
|-- metallb-config.yaml       # IPAddressPool e L2Advertisement do MetalLB
|-- corebank-secrets.yaml     # InfisicalSecret (sync de DB_URL etc)
|-- httpbin-corebank.yaml     # Deployment cliente mTLS, com Reloader
|-- httpbin-apolo.yaml        # Deployment + Ingress com auth-tls
|-- mtls-test.yaml            # Pod efemero com curl para validar mTLS
`-- terraform/
    |-- certs/
    |   `-- cert.pem          # Certificado da CA (download do painel)
    |-- phase1/               # Cluster + Infisical basico
    |   |-- main.tf
    |   |-- infra-poc.tf      # PostgreSQL e Redis (apenas para POC)
    |   |-- providers.tf
    |   |-- variables.tf
    |   `-- outputs.tf
    `-- phase2/               # Nginx Ingress, Reloader, Subscriber sync
        |-- main.tf
        |-- providers.tf
        |-- variables.tf
        |-- outputs.tf
        |-- terraform.tfvars          # NAO commitar - credenciais
        `-- terraform.tfvars.example  # Modelo para o tfvars
```

> **Importante:** O arquivo `certs/cert.pem` e o `terraform.tfvars` da phase2
> nao devem ser commitados no repositorio. Adicione ao `.gitignore`:
>
> ```
> certs/
> terraform/phase2/terraform.tfvars
> **/.terraform/
> *.tfstate
> *.tfstate.backup
> ```

## Dependencias entre Componentes

E fundamental entender a ordem de dependencia antes de executar qualquer passo:

```
Kind Cluster (Terraform phase1)
    |
    +-- PostgreSQL StatefulSet  <-- Infisical depende
    +-- Redis StatefulSet       <-- Infisical depende
    |
    +-- Infisical Deployment
            |
            v
    Configuracao Manual do Infisical (painel web)
            |
            +-- CA criada              <-- cert.pem disponivel para download
            +-- Machine Identity       <-- clientId e clientSecret disponiveis
            +-- PKI Subscriber         <-- corebank-mtls com auto-renewal
            |
            v
    MetalLB (instalacao manual via Helm + kubectl)
            |
            v
    Terraform phase2
            |
            +-- Nginx Ingress Controller (LoadBalancer via MetalLB)
            +-- infisical-secrets-operator
            +-- Secrets (credenciais da Machine Identity)
            +-- Stakater Reloader      <-- rollout do pod quando o Secret muda
            +-- CronJob subscriber-sync <-- puxa o bundle do PKI Subscriber
```

## Passo a Passo

### Phase 1 - Cluster e Infisical

**1. Clone o repositorio e entre no diretorio da phase1:**

```bash
cd terraform/phase1
```

**2. Inicialize e aplique o Terraform:**

```bash
terraform init
terraform apply -auto-approve
```

Isso cria:

- Cluster Kind com 1 control-plane e 2 workers
- Namespaces: `infisical`, `corebank-apps`, `apolo-apps`
- PostgreSQL como StatefulSet com PVC de 5Gi
- Redis como StatefulSet com PVC de 1Gi
- Infisical Deployment + Service (NodePort 30080)

**3. Aguarde todos os pods ficarem Running:**

```bash
kubectl get pods -n infisical -w
```

**4. Faca o port-forward para acessar o Infisical:**

```bash
kubectl port-forward -n infisical svc/infisical-lb 3000:80
```

Acesse `http://localhost:3000` no browser.

---

### Configuracao Manual do Infisical

Esta etapa e obrigatoria e deve ser feita antes da phase2.
Todos os valores obtidos aqui serao usados no `terraform.tfvars` da phase2.

**5. Crie a conta de administrador** no primeiro acesso ao painel.

**6. Crie a organizacao e o projeto PKI:**

- Anote o **Project ID** (UUID) em `Project Settings`

**7. Crie a CA interna:**

- Va em `PKI Manager > Certificate Authorities > Create`
- Tipo: Root
- Preencha os campos da CA (CN, Organization, etc)
- Apos criar, clique na CA e faca o download do certificado
- Salve o arquivo como `certs/cert.pem` na raiz do projeto

**8. Crie a Machine Identity:**

- Va em `Organization > Access Control > Identities > Create`
- Metodo de autenticacao: Universal Auth
- Anote o **Client ID** exibido na tela
- Gere um **Client Secret** e anote o valor (exibido apenas uma vez)
- Adicione a identity ao projeto PKI com role `Admin`:
  - Va em `Project > Access Control > Machine Identities > Add`

**9. Crie o PKI Subscriber:**

- Va em `PKI Manager > Subscribers > Add Subscriber`
- Preencha:
  - **Subscriber Name:** `corebank-mtls`
  - **Issuing CA:** a CA criada no passo 7
  - **Common Name:** `corebank.service.internal`
  - **SAN:** `corebank.service.internal, corebank.corebank-apps.svc.cluster.local, httpbin-corebank.corebank-apps.svc.cluster.local`
  - **TTL:** `2d` (ou `1h` se a UI permitir Hour como unidade)
  - **Key Usage:** Digital Signature, Key Encipherment
  - **Extended Key Usage:** Client Auth
- Em `Advanced`:
  - **Auto Renewal:** habilitado
  - **Renewal Before:** `1 day` (ou `15 minutes` se possivel)
- Apos criar, clique em `Issue Certificate` uma vez para gerar o primeiro cert.
  O CronJob nao emite, apenas sincroniza o bundle ja existente.

---

### Instalacao do MetalLB

Esta etapa e necessaria para que o Nginx Ingress receba um IP externo via LoadBalancer.

**11. Adicione o repositorio e instale o MetalLB:**

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --version 0.14.9 \
  --wait \
  --timeout 120s
```

> A versao 0.14.9 evita um bug do chart >= 0.15 que falha com
> `nil pointer evaluating .Values.prometheus.serviceMonitor.enabled`
> no subchart `frr-k8s`. Como a POC usa L2 mode, frr-k8s nao seria usado
> de qualquer forma.

**12. Verifique o range de IPs da rede Docker do Kind:**

```bash
docker network inspect kind | grep -A4 '"IPAM"'
```

O subnet exibido determina o range disponivel. Pode variar entre instalacoes
(ex: `172.18.0.0/16`, `172.22.0.0/16`). O arquivo `metallb-config.yaml`
ja vem com `172.22.255.200-172.22.255.250` — ajuste o primeiro octeto se o
subnet do seu Docker for diferente.

**13. Aplique a configuracao do MetalLB:**

```bash
kubectl apply -f metallb-config.yaml
```

**14. Verifique se os recursos foram criados:**

```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

---

### Phase 2 - PKI, mTLS e Nginx

**15. Configure o arquivo de variaveis:**

```bash
cp terraform/phase2/terraform.tfvars.example terraform/phase2/terraform.tfvars
```

Edite o `terraform.tfvars` com os valores obtidos nos passos anteriores:

```hcl
cluster_name              = "apache"
kubeconfig_path           = "~/.kube/config"
project_id                = "UUID-do-projeto-aqui"
client_id                 = "client-id-da-machine-identity"
client_secret             = "client-secret-da-machine-identity"
ca_cert_path              = "../certs/cert.pem"
subscriber_name           = "corebank-mtls"
subscriber_sync_schedule  = "*/15 * * * *"
```

**16. Inicialize e aplique a phase2:**

```bash
cd terraform/phase2
terraform init
terraform import kubernetes_service.infisical_lb infisical/infisical-lb
terraform apply -auto-approve

# Dispare manualmente o primeiro sync (sem esperar o cron)
kubectl create job --from=cronjob/subscriber-sync \
  -n corebank-apps subscriber-sync-bootstrap

kubectl logs -n corebank-apps -l job-name=subscriber-sync-bootstrap -f
```

Isso cria:

- Nginx Ingress Controller como LoadBalancer (recebe IP do MetalLB)
- Secret `infisical-ca` com o `cert.pem` no namespace `ingress-nginx` e `apolo-apps`
- infisical-secrets-operator
- Secrets com credenciais da Machine Identity (`infisical` e `corebank-apps`)
- Stakater Reloader (rollout do pod quando o Secret de cert muda)
- ConfigMap + RBAC + CronJob `subscriber-sync` no `corebank-apps`

**17. Verifique o Secret sincronizado pelo CronJob:**

```bash
kubectl get secret corebank-client-tls-secret -n corebank-apps
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.metadata.annotations.infisical\.com/serial}'; echo
```

O serial impresso deve casar com o cert mais recente do subscriber no painel.

**18. Inspecione o certificado:**

```bash
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -text -noout | grep -E "Subject:|Issuer:|Not After:|DNS:"
```

**19. Verifique o IP externo do Nginx:**

```bash
kubectl get svc -n ingress-nginx
```

O campo `EXTERNAL-IP` deve exibir um IP do range configurado no MetalLB.

---

## Fluxos e Troubleshooting

Os detalhes operacionais dos dois fluxos da POC (rotacao de cert via PKI
Subscriber + gerenciamento de secrets via InfisicalSecret) e o
troubleshooting comum estao em **[docs/fluxos.md](docs/fluxos.md)**.

Tambem la: como rodar o teste end-to-end de mTLS com o `mtls-test.yaml`.

---

## Componentes e Versoes

| Componente                 | Versao   | Namespace      |
| -------------------------- | -------- | -------------- |
| Kubernetes (Kind)          | v1.29.7  | -              |
| Infisical                  | v0.151.0 | infisical      |
| PostgreSQL                 | 15.5     | infisical      |
| Redis                      | 7.2.4    | infisical      |
| Nginx Ingress Controller   | latest   | ingress-nginx  |
| infisical-secrets-operator | v0.10.33 | infisical      |
| MetalLB                    | 0.14.9   | metallb-system |
| Stakater Reloader          | latest   | reloader       |
