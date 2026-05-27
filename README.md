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
|-- metallb-config.yaml       # IPAddressPool e L2Advertisement do MetalLB
|-- terraform/
|   |`-- certs/
|       `-- cert.pem          # Certificado da CA (gerado manualmente no Infisical)
|   |-- phase1/               # Cluster + Infisical basico
|   |   |-- main.tf
|   |   |-- infra-poc.tf      # PostgreSQL e Redis (apenas para POC)
|   |   |-- providers.tf
|   |   |-- variables.tf
|   |   `-- outputs.tf
|   `-- phase2/               # Nginx Ingress, Reloader, Subscriber sync
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

## Resolucao de Problemas

### CronJob falha com "bundle vazio"

Acontece quando o subscriber foi criado no painel mas nenhum certificado
foi emitido ainda. Va em `PKI > Subscribers > corebank-mtls` e clique em
`Issue Certificate` uma vez. A partir dai o auto-renewal mantem o bundle
sempre populado.

### Invalid credentials no CronJob (401 do login Universal Auth)

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

Se o CronJob recebeu varios 401 seguidos, a identity pode entrar em lockout.

1. Redefina o lockout no painel do Infisical:
   `Organization > Access Control > Identities > sua identity`
   `Universal Auth > Lockout Options > Reset All Lockouts`

2. Confirme que o login funciona:

```bash
curl -s -X POST http://localhost:3000/api/v1/auth/universal-auth/login \
  -H "Content-Type: application/json" \
  -d '{"clientId":"SEU-CLIENT-ID","clientSecret":"SEU-CLIENT-SECRET"}' | jq .accessToken
```

3. Dispare manualmente uma rodada do CronJob para confirmar:

```bash
kubectl create job --from=cronjob/subscriber-sync \
  -n corebank-apps subscriber-sync-retry
```

### Rotacao da CA

Para rotacionar a CA sem impactar os pods das aplicacoes:

1. Gere a nova CA no Infisical e baixe o novo `cert.pem`
2. Substitua o arquivo `certs/cert.pem`
3. Execute `terraform apply` na phase2

Apenas o Secret `infisical-ca` no namespace `ingress-nginx` sera atualizado.
Os pods das aplicacoes nao precisam ser reiniciados.

---

## Fluxo do Subscriber (rotacao governada pelo painel)

A POC usa o **PKI Subscriber** do Infisical como fonte de verdade unica
para a rotacao do certificado mTLS. Toda a politica (TTL, auto-renewal)
vive no painel; o cluster apenas consome:

```
Painel Infisical (PKI > Subscribers > corebank-mtls)
    | TTL + Auto-Renewal habilitado
    v
Infisical emite/renova o cert internamente
    |
    v
CronJob subscriber-sync (a cada 15 min, namespace corebank-apps)
    | 1. login Universal Auth (Machine Identity)
    | 2. GET /api/v1/pki/subscribers/{name}/latest-certificate-bundle
    | 3. compara serial com a annotation infisical.com/serial no Secret
    | 4. se mudou, kubectl apply no Secret corebank-client-tls-secret
    v
Stakater Reloader (namespace reloader)
    | observa o Secret anotado no Deployment
    v
Rolling restart do httpbin-corebank com o cert novo
```

### Verificando o ciclo completo

```bash
# Veja o CronJob agendado
kubectl get cronjob -n corebank-apps

# Force uma execucao manual sem esperar o agendamento
kubectl create job --from=cronjob/subscriber-sync \
  -n corebank-apps subscriber-sync-manual

# Acompanhe o log
kubectl logs -n corebank-apps -l job-name=subscriber-sync-manual -f

# Confira o serial atual gravado no Secret
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.metadata.annotations.infisical\.com/serial}'; echo

# Observe o rolling restart do pod (deve acontecer quando o serial muda)
kubectl get pods -n corebank-apps -w
```

### Forcando uma rotacao para teste

No painel: `PKI > Subscribers > corebank-mtls > Issue Certificate`. Isso
emite um novo cert imediatamente; na proxima execucao do CronJob o Secret
e atualizado e o Reloader faz rollout do pod. Tambem da pra disparar
manualmente o sync com o `kubectl create job --from=cronjob/...` acima.

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
