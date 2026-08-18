# GUIA — Replicar a POC (mTLS com Infisical + cert-manager no Kubernetes)

Passo-a-passo completo e linear para reproduzir a POC do zero: cluster Kind +
Infisical, emissão de certificado via **cert-manager + Infisical PKI Issuer**,
rotação automática com **Stakater Reloader** e teste **mTLS** end-to-end no
Nginx Ingress. Para a visão geral/arquitetura, veja o [README](README.md).

Validado com **Infisical v0.160.9**, Kubernetes (Kind) **v1.29.7**,
cert-manager **v1.21.1**, **infisical-pki-issuer chart 0.1.1 + imagem
`v0.2.0`**, ingress-nginx **4.15.1**, reloader **2.2.16**, secrets-operator
**0.11.8** e MetalLB **0.14.9**.

> **Fixe as versões — inclusive a da imagem.** Todos os comandos `helm` deste
> guia passam `--version`, e o PKI Issuer fixa também a **tag da imagem**. O
> chart 0.1.1 traz `image.tag: latest` como default, e `latest` hoje serve o
> binário **1.0.0**, que espera um `Issuer` de schema diferente do que este
> repo usa. Sem fixar a tag, o Passo 7 falha. Ver o troubleshooting no fim.

> **Convenção:** todos os comandos rodam da raiz do repo. Valores entre
> `<...>` você substitui pelos seus (anotados no Passo 3).

---

## Pré-requisitos

Docker, Terraform >= 1.0, kubectl, Helm >= 3, `jq`, `openssl`, `curl` e (para
forçar renovação no teste) o binário `cmctl`
([releases](https://github.com/cert-manager/cmctl/releases)). Em Windows, use WSL2.
O Kind é gerenciado pelo provider Terraform — não precisa instalar o binário.

---

## Passo 1 — Infraestrutura (Terraform)

Cria o cluster Kind (1 control-plane + 2 workers), os namespaces (`infisical`,
`corebank-apps`, `apolo-apps`), PostgreSQL, Redis e o Infisical (v0.160.9) com
o Service `infisical-lb`.

```bash
cd terraform
terraform init
terraform apply -auto-approve
cd ..
kubectl get pods -n infisical -w   # aguarde tudo Running; Ctrl-C
```

---

## Passo 2 — MetalLB (LoadBalancer para o Ingress)

```bash
helm repo add metallb https://metallb.github.io/metallb && helm repo update
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system --create-namespace --version 0.14.9 --wait

# A subnet docker do Kind VARIA por máquina/instalação. Descubra a sua:
docker network inspect kind | grep -i subnet     # ex.: 172.18.0.0/16

# EDITE metallb-config.yaml para um range DENTRO dessa subnet, ex.:
#   addresses: [ 172.18.255.200-172.18.255.250 ]
kubectl apply -f metallb-config.yaml
kubectl get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses}'; echo
```

> Use a versão **0.14.9** (versões >= 0.15 quebram com `nil pointer ...
> prometheus.serviceMonitor` no subchart frr-k8s). **Sem aplicar o
> `metallb-config.yaml`** o IP do Ingress fica `<pending>` para sempre. E se o
> range estiver **fora da subnet docker**, o IP atribuído não é roteável (o
> teste mTLS falha na conexão) — por isso confira/edite o range acima.

---

## Passo 3 — Configuração no painel do Infisical

```bash
kubectl port-forward -n infisical svc/infisical-lb 3000:80 &
# Acesse http://localhost:3000, crie a conta admin.
```

Na v0.160 a organização já vem com os produtos prontos no `Overview`. Entre em
**Certificate Manager** e crie um **projeto** (ex.: `gzbank-pki`).

1. **CA interna** — no projeto: `Settings > Internal Certificate Authorities >
   Create`. Tipo **Root**, Key Algorithm **RSA 2048**, preencha CN/Org/etc. A
   Root já nasce ativa (botão "Renew CA"; não há passo "Install"). **Anote o CA ID.**
   - O menu **Signers** é de *code signing*, NÃO é a CA de TLS — não confunda.
2. **Machine Identity ORG-LEVEL** — crie em `Organization > Access Control >
   Identities` (NÃO dentro de um projeto — na v0.160 a identity criada dentro de
   um projeto fica restrita a ele). Método **Universal Auth**. **Anote o Client
   ID e gere o Client Secret** (mostrado uma única vez). Depois **adicione essa
   identity ao projeto** Cert Manager (`projeto > Access Control > Machine
   Identities > Add`, role **Admin**). A MESMA identity será reutilizada no
   fluxo 2 (Passo 11) — uma identity para os dois flows.
3. **Project ID** — descubra via API (usado pelo Issuer):
   ```bash
   TOKEN=$(curl -s -X POST http://localhost:3000/api/v1/auth/universal-auth/login \
     -H "Content-Type: application/json" \
     -d '{"clientId":"<CLIENT_ID>","clientSecret":"<CLIENT_SECRET>"}' | jq -r .accessToken)
   curl -s -H "Authorization: Bearer $TOKEN" http://localhost:3000/api/v1/workspace \
     | jq '.workspaces[] | select(.type=="cert-manager") | {id,name}'
   ```

Exporte os valores para os próximos passos:

```bash
export INF=http://localhost:3000
export CLIENT_ID="<CLIENT_ID>"
export CLIENT_SECRET="<CLIENT_SECRET>"
export CM_PROJECT_ID="<PROJECT_ID>"
export CA_ID="<CA_ID>"
```

---

## Passo 4 — Charts da fase 2 (Helm)

```bash
# cert-manager (com CRDs)
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.21.1 --set crds.enabled=true --wait

# Infisical PKI Issuer (mesmo repo Helm do secrets-operator)
helm repo add infisical-helm-charts \
  'https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/' && helm repo update
helm upgrade --install infisical-pki-issuer infisical-helm-charts/infisical-pki-issuer \
  --namespace infisical-pki-issuer --create-namespace \
  --version 0.1.1 --set controllerManager.manager.image.tag=v0.2.0 --wait

# Ingress Nginx (LoadBalancer via MetalLB)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --version 4.15.1 \
  --set controller.service.type=LoadBalancer --wait --timeout 5m

# Stakater Reloader (rollout quando o Secret muda)
helm repo add stakater https://stakater.github.io/stakater-charts && helm repo update
helm upgrade --install reloader stakater/reloader \
  --namespace reloader --create-namespace --version 2.2.16 --wait
```

> **Se o `ingress-nginx` der timeout no `--wait`:** o controller pode ter
> subido mas o Job de admission não populou o caBundle do webhook (você verá
> `x509: certificate signed by unknown authority` ao criar Ingress). Conserte:
> ```bash
> CAB=$(kubectl get secret ingress-nginx-admission -n ingress-nginx -o jsonpath='{.data.ca}')
> kubectl patch validatingwebhookconfiguration ingress-nginx-admission --type='json' \
>   -p="[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"$CAB\"}]"
> ```

---

## Passo 5 — Secret de autenticação (compartilhado)

Um único Secret `infisical-operator-auth` (com `clientId` + `clientSecret` da
identity org-level) serve **os dois fluxos**: o Issuer lê a chave `clientSecret`
dele, e o `InfisicalSecret` (fluxo 2) usa o mesmo Secret via `credentialsRef`.

```bash
kubectl create secret generic infisical-operator-auth \
  --from-literal=clientId="${CLIENT_ID}" \
  --from-literal=clientSecret="${CLIENT_SECRET}" -n corebank-apps
```

> O `clientId` também vai inline no `pki-issuer-stack.yaml` (campo `clientId`)
> — edite com o seu. O `secretRef` do Issuer aponta para este Secret.

---

## Passo 6 — Certificate template (via API)

O `infisical-pki-issuer` (chart 0.1.1, imagem `v0.2.0`) assina via
`POST /api/v2/pki/certificate-templates/{nome}/sign-certificate` — ou seja,
exige um **certificate template** (por nome). A UI da v0.160 só mostra
"Certificate Profiles", mas os templates continuam na API:

```bash
TOKEN=$(curl -s -X POST $INF/api/v1/auth/universal-auth/login \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"${CLIENT_ID}\",\"clientSecret\":\"${CLIENT_SECRET}\"}" | jq -r .accessToken)

curl -s -X POST $INF/api/v1/pki/certificate-templates \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d "{
    \"projectId\": \"${CM_PROJECT_ID}\",
    \"name\": \"corebank-mtls\",
    \"caId\": \"${CA_ID}\",
    \"commonName\": \".*\",
    \"subjectAlternativeName\": \".*\",
    \"ttl\": \"2d\",
    \"keyUsages\": [\"digitalSignature\", \"keyEncipherment\"],
    \"extendedKeyUsages\": [\"clientAuth\"]
  }" | jq .
# Esperado: HTTP 200 com id/name. Enums são case-sensitive (clientAuth).
```

---

## Passo 7 — Emitir o certificado (cert-manager + Issuer)

Edite `manifests/pki-issuer-stack.yaml` com os SEUS `projectId`, `clientId` e
(se mudou) o nome do template; depois aplique:

```bash
kubectl apply -f manifests/pki-issuer-stack.yaml
```

Valide a emissão:

```bash
# use o nome COMPLETO do CRD: "kubectl get issuer" resolve para o do
# cert-manager e responde "No resources found", escondendo o Issuer real.
kubectl get issuers.infisical-issuer.infisical.com -n corebank-apps   # Ready=True
kubectl describe certificate corebank-mtls -n corebank-apps   # Ready=True
kubectl get certificaterequest -n corebank-apps               # APPROVED + READY
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -issuer -dates -ext extendedKeyUsage,subjectAltName
# Esperado: issuer = sua CA, EKU TLS Web Client Authentication, SANs do corebank
```

> Se o CertificateRequest ficar **pending**, falta o RBAC de `approve` (está no
> `pki-issuer-stack.yaml` — confirme que foi aplicado e que o `resourceName`
> casa com o namespace/nome do Issuer).

---

## Passo 8 — CA no Ingress + apps de demonstração

O Nginx valida o cert do cliente contra o Secret `infisical-ca` (mesmo
namespace do Ingress). A CA já está no `ca.crt` que o cert-manager gravou no
Secret emitido — crie o `infisical-ca` direto dele (não precisa baixar nada do
painel nem manter arquivo):

```bash
kubectl create secret generic infisical-ca -n apolo-apps \
  --from-literal=ca.crt="$(kubectl get secret corebank-client-tls-secret \
    -n corebank-apps -o jsonpath='{.data.ca\.crt}' | base64 -d)"
```

O `httpbin-corebank` usa `corebank-app-env` via `envFrom`. Para o demo de
cert/mTLS, crie um **stub** (o fluxo real é o Passo 11):

```bash
kubectl create secret generic corebank-app-env \
  --from-literal=DB_URL="stub://placeholder" -n corebank-apps

kubectl apply -f manifests/apps.yaml
kubectl wait --for=condition=Ready pod -l app=httpbin-corebank -n corebank-apps --timeout=90s
```

---

## Passo 9 — Teste mTLS end-to-end

```bash
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# SEM cert → 400 (Nginx rejeita)
kubectl exec -n corebank-apps deploy/httpbin-corebank -c curl-client -- \
  curl -sk -o /dev/null -w "sem cert: %{http_code}\n" \
  --resolve apolo.service.internal:443:$INGRESS_IP https://apolo.service.internal/get

# COM cert → 200
kubectl exec -n corebank-apps deploy/httpbin-corebank -c curl-client -- \
  curl -sk -o /dev/null -w "com cert: %{http_code}\n" \
  --resolve apolo.service.internal:443:$INGRESS_IP \
  --cert /etc/certs/tls.crt --key /etc/certs/tls.key https://apolo.service.internal/get
```

---

## Passo 10 — Teste de rotação automática (o ponto crucial)

Renovação → Secret atualizado → Reloader → rolling restart → pod novo já com o
cert novo, tudo automático.

**1. Anote o serial atual** (é a referência da comparação):

```bash
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial -dates
```

**2. Abra o watch ANTES de disparar.** O ciclo renew → Secret → Reloader →
rollout leva poucos segundos, e `-w` só mostra o que muda depois de conectar:
se você renovar primeiro, vai encontrar a troca já em andamento. Use dois
terminais —

```bash
# terminal A — deixe rodando primeiro
kubectl get pods -n corebank-apps -l app=httpbin-corebank -w

# terminal B — dispara a renovação, sem esperar o renewBefore
cmctl renew corebank-mtls -n corebank-apps
```

— ou um só, jogando o watch para segundo plano (`--watch-only` omite a
listagem inicial, então tudo que aparecer é mudança de verdade):

```bash
kubectl get pods -n corebank-apps -l app=httpbin-corebank --watch-only &
cmctl renew corebank-mtls -n corebank-apps
```

**3. Confirme.** Nada aqui depende de timing — todas as evidências ficam
registradas, então dá para conferir com calma depois:

```bash
# quem disparou o rollout, e por qual Secret (o deploy é "reloader-reloader",
# com o prefixo do release Helm — não "reloader"):
kubectl logs -n reloader deploy/reloader-reloader --tail=50 | grep -i "changes detected"
# esperado: Changes detected in 'corebank-client-tls-secret' of type 'SECRET'
#   ... updated 'httpbin-corebank' of type 'Deployment'

# serial e notBefore novos no Secret:
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial -dates

# e o serial montado no pod NOVO é o mesmo — a prova de que o pod pegou o cert
# renovado, sem ninguém tocar no Deployment:
kubectl exec -n corebank-apps deploy/httpbin-corebank -c curl-client -- \
  cat /etc/certs/tls.crt | openssl x509 -noout -serial
```

> **Como o Reloader dispara o rollout:** ele injeta no container uma variável
> de ambiente com o *hash* do conteúdo do Secret
> (`STAKATER_COREBANK_CLIENT_TLS_SECRET_SECRET`). Quando o Secret muda, o hash
> muda, o pod template muda — e o Deployment faz rollout pela mecânica normal
> do Kubernetes. O Reloader não reinicia pod nenhum; só reescreve esse valor.
> Para ver a marca:
> ```bash
> kubectl get deploy httpbin-corebank -n corebank-apps \
>   -o jsonpath='{.spec.template.spec.containers[0].env}'; echo
> ```

> **Só aparece um CertificateRequest?** Depois da renovação, `kubectl get
> certificaterequest -n corebank-apps` mostra apenas o `corebank-mtls-2`. O
> `-1` não falhou: o `Certificate` tem `revisionHistoryLimit` 1 por padrão, e o
> cert-manager descarta o request anterior a cada emissão.

---

## Passo 11 — Fluxo 2: secrets de aplicação (InfisicalSecret)

Sincroniza secrets de um projeto de **Secrets Management** para o Secret K8s
`corebank-app-env` (consumido pelo `httpbin-corebank` via `envFrom`); quando um
secret muda, o Reloader reinicia o pod. Modelo recomendado: **1 projeto
Infisical por app** (do GitLab), variáveis na **raiz** (`/`) do environment.

**No painel:** crie o projeto de Secrets Management, **adicione a MESMA identity
org-level do Passo 3** (role Admin) e cadastre as variáveis na raiz do env
Development. Anote o **project slug**. O Secret K8s de auth
(`infisical-operator-auth`) já foi criado no Passo 5 — é o mesmo para os dois
fluxos, não precisa recriar.

```bash
# 1. Operator
helm upgrade --install infisical-secrets-operator infisical-helm-charts/secrets-operator \
  --namespace infisical --version 0.11.8 \
  --set host=http://infisical-lb.infisical.svc.cluster.local --wait

# 2. Ajuste manifests/infisicalsecret.yaml: projectSlug, envSlug (dev),
#    secretsPath ("/"). Atenção: resyncInterval é STRING ("1m") no operator novo.
#    (o credentialsRef já aponta para infisical-operator-auth, criado no Passo 5)
kubectl delete secret corebank-app-env -n corebank-apps --ignore-not-found  # remove o stub
kubectl apply -f manifests/infisicalsecret.yaml

# 3. Como o app já estava rodando com o stub, force 1 rollout para carregar o
#    secret real (a transição stub->real é delete+create e o Reloader não a pega;
#    mudanças POSTERIORES são update in-place e disparam o Reloader sozinhas).
kubectl rollout restart deploy/httpbin-corebank -n corebank-apps
```

Validação:

```bash
kubectl get infisicalsecret -n corebank-apps   # synced N secrets
kubectl get secret corebank-app-env -n corebank-apps \
  -o jsonpath='{.data}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)),"chaves")'
kubectl exec -n corebank-apps deploy/httpbin-corebank -c httpbin -- env | grep <UMA_CHAVE>
```

**Teste de propagação** (o que prova o fluxo 2): no painel, adicione/edite uma
variável no env Development. Em até `resyncInterval` (1m) o operator atualiza o
Secret K8s **in-place**, o Reloader detecta e reinicia o pod, e o valor novo
aparece dentro do container:

```bash
# abra o watch ANTES de editar a variável no painel (mesmo motivo do Passo 10)
kubectl get pods -n corebank-apps -l app=httpbin-corebank --watch-only &

# o log do Reloader confirma o gatilho (deploy "reloader-reloader"):
kubectl logs -n reloader deploy/reloader-reloader --tail=50 | grep -i "changes detected"
# esperado: Changes detected in 'corebank-app-env' ... updated 'httpbin-corebank'
#   of type 'Deployment'

kubectl exec -n corebank-apps deploy/httpbin-corebank -c httpbin -- env | grep <CHAVE_ALTERADA>
```

> O reload é feito pelo **Stakater Reloader** (anotação no Deployment), não pela
> auto-reload nativa do operator (que usa outra anotação,
> `secrets.infisical.com/auto-reload`). Por isso o status do operator pode dizer
> "found 0 deployments ... auto redeployed" — é esperado.

---

## Limpeza

```bash
kubectl delete -f manifests/apps.yaml --ignore-not-found
kubectl delete -f manifests/pki-issuer-stack.yaml --ignore-not-found
kubectl delete clusterrole infisical-issuer-approver --ignore-not-found
kubectl delete clusterrolebinding infisical-issuer-approver-binding --ignore-not-found
helm uninstall infisical-pki-issuer -n infisical-pki-issuer
helm uninstall cert-manager -n cert-manager
helm uninstall ingress-nginx -n ingress-nginx
helm uninstall reloader -n reloader
helm uninstall metallb -n metallb-system
# destruir tudo:
cd terraform && terraform destroy -auto-approve && cd ..
```

---

## Troubleshooting

- **`unknown field "spec.projectId"` (e `certificateTemplateName`,
  `authentication.universalAuth`) no `kubectl apply` do Passo 7** — o chart
  instalado é o **1.0.0**, que reescreveu o CRD do `Issuer` (passou a usar
  `application` + `profile`). Confira com `helm list -n infisical-pki-issuer`.
  Como o Helm **não** atualiza CRDs em upgrade/downgrade, voltar para a 0.1.1
  exige apagá-los:
  ```bash
  helm uninstall infisical-pki-issuer -n infisical-pki-issuer
  kubectl delete crd issuers.infisical-issuer.infisical.com \
                    clusterissuers.infisical-issuer.infisical.com
  # reinstale com o comando do Passo 4 (com --version e --set da imagem)
  ```
- **`unsupported authentication method: ""` no status do Issuer** — CRD 0.1.1
  com binário 1.0.0. Acontece quando o chart é fixado mas a imagem não: o
  código novo procura `spec.authentication.method`, campo que o CRD 0.1.1 nem
  tem. Corrija a tag da imagem (`--set controllerManager.manager.image.tag=v0.2.0`).
- **`Observed a panic ... nil pointer dereference` em `signer.go` nos logs do
  issuer** — imagem **v0.1.1** com o CRD 0.1.1. Aquele binário assina por
  `caId` no endpoint `/api/v1/pki/certificates/sign-certificate` e não conhece
  `certificateTemplateName`; a API responde erro, o código não checa o status
  HTTP e estoura. A imagem que casa com este repo é a **v0.2.0**, que usa
  `POST /api/v2/pki/certificate-templates/{nome}/sign-certificate`. Confirme
  com:
  ```bash
  kubectl get deploy -n infisical-pki-issuer \
    -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'
  # esperado: docker.io/infisical/pki-issuer:v0.2.0
  ```
- **CertificateRequest preso em `pending`** — falta o RBAC `approve` (no
  `pki-issuer-stack.yaml`); confira `kubectl get clusterrole infisical-issuer-approver`
  e se o `resourceName` casa com `corebank-apps.infisical-pki-issuer`.
- **Certificate não fica Ready** — veja `kubectl describe certificate corebank-mtls -n corebank-apps`
  e os logs: `kubectl logs -n infisical-pki-issuer deploy/infisical-pki-issuer-controller-manager` e
  `kubectl logs -n cert-manager deploy/cert-manager`. Causas: `projectId`/template
  errado, "Certificate template ... not found", identity sem permissão de emitir.
- **Ingress: `x509: certificate signed by unknown authority`** — caBundle do
  webhook vazio; aplique o patch do Passo 4.
- **EXTERNAL-IP `<pending>`** — `metallb-config.yaml` não aplicado ou range fora
  da subnet docker (`docker network inspect kind`).
- **Login 401 / identity em lockout** — confira o `clientSecret`; reset em
  `Organization > Access Control > Identities > ... > Universal Auth > Reset Lockouts`.
