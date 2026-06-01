# GUIA — Replicar a POC (mTLS com Infisical + cert-manager no Kubernetes)

Passo-a-passo completo e linear para reproduzir a POC do zero: cluster Kind +
Infisical, emissão de certificado via **cert-manager + Infisical PKI Issuer**,
rotação automática com **Stakater Reloader** e teste **mTLS** end-to-end no
Nginx Ingress. Para a visão geral/arquitetura, veja o [README](README.md).

Validado com **Infisical v0.160.9**, Kubernetes (Kind) **v1.29.7**,
cert-manager (jetstack), **infisical-pki-issuer 0.1.1**, ingress-nginx,
reloader e MetalLB 0.14.9.

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

# Confirme que o range em metallb-config.yaml bate com a subnet docker do Kind:
docker network inspect kind | grep -i subnet     # ex.: 172.22.0.0/16
kubectl apply -f metallb-config.yaml
```

> Use a versão **0.14.9** (versões >= 0.15 quebram com `nil pointer ...
> prometheus.serviceMonitor` no subchart frr-k8s). **Sem aplicar o
> `metallb-config.yaml`** o IP do Ingress fica `<pending>` para sempre.

---

## Passo 3 — Configuração no painel do Infisical

```bash
kubectl port-forward -n infisical svc/infisical-lb 3000:80 &
# Acesse http://localhost:3000, crie a conta admin.
```

Na v0.160 a organização já vem com os produtos prontos no `Overview`. Entre em
**Certificate Manager** e crie um **projeto** (ex.: `gzbank-pki`). Dentro dele:

1. **CA interna** — `Settings > Internal Certificate Authorities > Create`.
   Tipo **Root**, Key Algorithm **RSA 2048**, preencha CN/Org/etc. A Root já
   nasce ativa (botão "Renew CA"; não há passo "Install"). **Anote o CA ID.**
   - O menu **Signers** é de *code signing*, NÃO é a CA de TLS — não confunda.
2. **Machine Identity** — `Access Control > Machine Identities > Add`, método
   **Universal Auth**, Role **Admin** no projeto. **Anote o Client ID e gere o
   Client Secret** (mostrado uma única vez).
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
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait

# Infisical PKI Issuer (mesmo repo Helm do secrets-operator)
helm repo add infisical-helm-charts \
  'https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/' && helm repo update
helm upgrade --install infisical-pki-issuer infisical-helm-charts/infisical-pki-issuer \
  --namespace infisical-pki-issuer --create-namespace --wait

# Ingress Nginx (LoadBalancer via MetalLB)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer --wait --timeout 5m

# Stakater Reloader (rollout quando o Secret muda)
helm repo add stakater https://stakater.github.io/stakater-charts && helm repo update
helm upgrade --install reloader stakater/reloader \
  --namespace reloader --create-namespace --wait
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

## Passo 5 — Secret de autenticação do Issuer

O Issuer lê o `clientSecret` deste Secret (o `clientId` vai inline no
manifest). Identity do projeto de **Certificate Manager**:

```bash
kubectl create secret generic pki-issuer-auth \
  --from-literal=clientSecret="${CLIENT_SECRET}" -n corebank-apps
```

---

## Passo 6 — Certificate template (via API)

O `infisical-pki-issuer` 0.1.1 assina via
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
namespace do Ingress). Pegue a CA do `ca.crt` que o cert-manager já gravou:

```bash
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > terraform/certs/cert.pem
openssl x509 -in terraform/certs/cert.pem -noout -subject   # confere a CA

kubectl create secret generic infisical-ca \
  --from-file=ca.crt=terraform/certs/cert.pem -n apolo-apps
```

> O download da CA pelo painel às vezes vem vazio (`undefined`). Extrair do
> `ca.crt` do Secret (acima) é o jeito confiável.

O `httpbin-corebank` usa `corebank-app-env` via `envFrom`. Para o demo de
cert/mTLS, crie um **stub** (o fluxo real é o opcional Passo 12):

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

```bash
# serial antes
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial

# força renovação (sem esperar renewBefore)
cmctl renew corebank-mtls -n corebank-apps

# Reloader loga "Changes detected in 'corebank-client-tls-secret' ... updated
# 'httpbin-corebank' Deployment" e o pod é recriado:
kubectl get pods -n corebank-apps -l app=httpbin-corebank -w   # rollout; Ctrl-C

# serial montado no pod NOVO já é o renovado:
kubectl exec -n corebank-apps deploy/httpbin-corebank -c curl-client -- \
  cat /etc/certs/tls.crt | openssl x509 -noout -serial
```

---

## Passo 11 (opcional) — Fluxo 2: secrets de aplicação (InfisicalSecret)

Substitui o stub `corebank-app-env` por sincronização real de um projeto de
**Secrets Management**. Requer o `secrets-operator` e o projeto configurados.

```bash
helm upgrade --install infisical-secrets-operator infisical-helm-charts/secrets-operator \
  --namespace infisical --set host=http://infisical-lb.infisical.svc.cluster.local

kubectl create secret generic infisical-operator-auth \
  --from-literal=clientId="<SM_CLIENT_ID>" \
  --from-literal=clientSecret="<SM_CLIENT_SECRET>" -n corebank-apps

kubectl delete secret corebank-app-env -n corebank-apps   # remove o stub
# ajuste projectSlug/envSlug/secretsPath em manifests/infisicalsecret.yaml
kubectl apply -f manifests/infisicalsecret.yaml
```

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

- **CertificateRequest preso em `pending`** — falta o RBAC `approve` (no
  `pki-issuer-stack.yaml`); confira `kubectl get clusterrole infisical-issuer-approver`
  e se o `resourceName` casa com `corebank-apps.infisical-pki-issuer`.
- **Certificate não fica Ready** — veja `kubectl describe certificate corebank-mtls -n corebank-apps`
  e os logs: `kubectl logs -n infisical-pki-issuer deploy/infisical-pki-issuer` e
  `kubectl logs -n cert-manager deploy/cert-manager`. Causas: `projectId`/template
  errado, "Certificate template ... not found", identity sem permissão de emitir.
- **Ingress: `x509: certificate signed by unknown authority`** — caBundle do
  webhook vazio; aplique o patch do Passo 4.
- **EXTERNAL-IP `<pending>`** — `metallb-config.yaml` não aplicado ou range fora
  da subnet docker (`docker network inspect kind`).
- **`cert.pem` vazio/`undefined`** — extraia do `ca.crt` do Secret (Passo 8).
- **Login 401 / identity em lockout** — confira o `clientSecret`; reset em
  `Organization > Access Control > Identities > ... > Universal Auth > Reset Lockouts`.
