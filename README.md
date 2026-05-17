# Infisical POC - mTLS com Kubernetes, Kind e Terraform

Prova de conceito para demonstrar o fluxo de emissão e validação de certificados mTLS
usando o Infisical como PKI (Certificate Authority), integrado ao Kubernetes via
cert-manager e infisical-pki-issuer.

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
|-- metallb-config.yaml       # IPAddressPool e L2Advertisement do MetalLB
|-- terraform/
|-- certs/
|   `-- cert.pem              # Certificado da CA (gerado manualmente no Infisical)
|   |-- phase1/               # Cluster + Infisical basico
|   |   |-- main.tf
|   |   |-- infra-poc.tf      # PostgreSQL e Redis (apenas para POC)
|   |   |-- providers.tf
|   |   |-- variables.tf
|   |   `-- outputs.tf
|   `-- phase2/               # PKI, mTLS, Nginx, cert-manager
|       |-- main.tf
|       |-- providers.tf
|       |-- variables.tf
|       |-- outputs.tf
|       |-- terraform.tfvars          # NAO commitar - credenciais
|       `-- terraform.tfvars.example  # Modelo para o tfvars
`-- README.md
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
            +-- Certificate Template   <-- nome do template disponivel
            |
            v
    MetalLB (instalacao manual via Helm + kubectl)
            |
            v
    Terraform phase2
            |
            +-- Nginx Ingress Controller (LoadBalancer via MetalLB)
            +-- cert-manager
            +-- infisical-pki-issuer   <-- depende do cert-manager
            +-- RBAC                   <-- depende do infisical-pki-issuer
            +-- Secrets (credenciais)
            +-- Issuer + Certificate   <-- depende de tudo acima
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

**9. Crie o Certificate Template:**

- Va em `PKI Manager > Certificate Templates > Add Template`
- Preencha:
  - **Name:** `corebank-client-template`
  - **Issuing CA:** a CA criada no passo 7
  - **Common Name:** `corebank.service.internal`
  - **SAN:** `corebank.corebank-namespace.svc.cluster.local`
  - **Max TTL:** `24h`
  - **Key Usage:** Digital Signature, Key Encipherment
  - **Extended Key Usage:** Client Auth
- Anote o **nome** do template

---

### Instalacao do MetalLB

Esta etapa e necessaria para que o Nginx Ingress receba um IP externo via LoadBalancer.

**11. Adicione o repositorio e instale o MetalLB:**

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait \
  --timeout 120s
```

**12. Verifique o range de IPs da rede Docker do Kind:**

```bash
docker network inspect kind | grep -A4 '"IPAM"'
```

O subnet exibido determina o range disponivel. Por padrao e `172.18.0.0/16`.
O arquivo `metallb-config.yaml` usa o range `172.18.255.200-172.18.255.250`.
Ajuste se o subnet do seu ambiente for diferente.

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
certificate_template_name = "corebank-client-template"
ca_cert_path              = "../certs/cert.pem"
```

**16. Inicialize e aplique a phase2:**

```bash
cd terraform/phase2
terraform init
terraform import kubernetes_service.infisical_lb infisical/infisical-lb
terraform apply -auto-approve
```

Isso cria:

- Nginx Ingress Controller como LoadBalancer (recebe IP do MetalLB)
- Secret `infisical-ca` com o `cert.pem` no namespace `ingress-nginx`
- cert-manager
- infisical-pki-issuer
- RBAC necessario para aprovacao automatica de CertificateRequests
- Secrets com credenciais da Machine Identity
- Issuer e Certificate para o namespace `corebank-apps`

**17. Verifique o certificado emitido:**

```bash
kubectl get certificate -n corebank-apps
kubectl get secret corebank-client-tls-secret -n corebank-apps
```

O certificado deve aparecer com `READY: True`.

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

## Resolucao de Problemas

### CertificateRequest travado sem APPROVED

O cert-manager v1.13+ nao aprova automaticamente requests de issuers externos.
O RBAC criado na phase2 resolve isso. Se o problema persistir:

```bash
kubectl get certificaterequest -n corebank-apps
kubectl describe certificaterequest <nome> -n corebank-apps
```

### Invalid credentials no infisical-pki-issuer

Verifique se o `clientSecret` no Secret do Kubernetes esta correto:

```bash
kubectl get secret infisical-operator-auth -n corebank-apps \
  -o jsonpath='{.data.clientSecret}' | base64 -d
```

Confirme as credenciais fazendo login diretamente:

```bash
curl -s -X POST http://localhost:3000/api/v1/auth/universal-auth/login \
  -H "Content-Type: application/json" \
  -d '{"clientId":"SEU-CLIENT-ID","clientSecret":"SEU-CLIENT-SECRET"}' | jq .
```

### Machine Identity bloqueada (lockout)

O infisical-pki-issuer entra em loop de retry ao receber 401, acumulando
tentativas e ativando o lockout da identity. Para resolver:

1. Escale o controller para zero para parar o loop:

```bash
kubectl scale deployment -l app.kubernetes.io/instance=infisical-pki-issuer \
  -n infisical --replicas=0
kubectl scale deployment cert-manager -n cert-manager --replicas=0
```

2. Delete os requests pendentes:

```bash
kubectl delete certificaterequest --all -n corebank-apps
```

3. Redefina o lockout no painel do Infisical:
   `Organization > Access Control > Identities > sua identity`
   `Universal Auth > Lockout Options > Reset All Lockouts`

4. Confirme que o login funciona:

```bash
curl -s -X POST http://localhost:3000/api/v1/auth/universal-auth/login \
  -H "Content-Type: application/json" \
  -d '{"clientId":"SEU-CLIENT-ID","clientSecret":"SEU-CLIENT-SECRET"}' | jq .accessToken
```

5. Suba os componentes novamente:

```bash
kubectl scale deployment cert-manager -n cert-manager --replicas=1
kubectl rollout status deployment cert-manager -n cert-manager
kubectl scale deployment -l app.kubernetes.io/instance=infisical-pki-issuer \
  -n infisical --replicas=1
```

### Rotacao da CA

Para rotacionar a CA sem impactar os pods das aplicacoes:

1. Gere a nova CA no Infisical e baixe o novo `cert.pem`
2. Substitua o arquivo `certs/cert.pem`
3. Execute `terraform apply` na phase2

Apenas o Secret `infisical-ca` no namespace `ingress-nginx` sera atualizado.
Os pods das aplicacoes nao precisam ser reiniciados.

---

## Componentes e Versoes

| Componente                 | Versao   | Namespace      |
| -------------------------- | -------- | -------------- |
| Kubernetes (Kind)          | v1.29.7  | -              |
| Infisical                  | v0.151.0 | infisical      |
| PostgreSQL                 | 15.5     | infisical      |
| Redis                      | 7.2.4    | infisical      |
| Nginx Ingress Controller   | latest   | ingress-nginx  |
| cert-manager               | v1.13.0  | cert-manager   |
| infisical-pki-issuer       | 0.1.1    | infisical      |
| infisical-secrets-operator | v0.10.33 | infisical      |
| MetalLB                    | 0.15.3   | metallb-system |
