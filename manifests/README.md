# Phase 2 — versao manifestos K8s

Phase 2 da POC — Nginx Ingress, Reloader, Secrets Operator e o pipeline de
sincronizacao do PKI Subscriber. Tudo via `helm install` e `kubectl apply`,
comando por comando.

Pre-requisito: cluster Kind ja criado (phase1) com Infisical, MetalLB e os
namespaces `infisical`, `corebank-apps`, `apolo-apps`. CA, Machine Identity
e PKI Subscriber ja cadastrados no painel do Infisical.

## Visao geral do que sera aplicado

| # | Recurso | Como |
| - | ------- | ---- |
| 1 | Nginx Ingress Controller | `helm install` |
| 2 | Stakater Reloader | `helm install` |
| 3 | Infisical Secrets Operator | `helm install` |
| 4 | Secret `infisical-ca` (ingress-nginx + apolo-apps) | `kubectl create secret` |
| 5 | Secret `infisical-operator-auth` (infisical + corebank-apps) | `kubectl create secret` |
| 6 | ConfigMap `subscriber-sync-config` | `01-subscriber-sync-config.yaml` |
| 7 | ConfigMap `subscriber-sync-script` | `02-subscriber-sync-script.yaml` |
| 8 | RBAC do CronJob | `03-subscriber-sync-rbac.yaml` |
| 9 | CronJob `subscriber-sync` | `04-subscriber-sync-cronjob.yaml` |
| 10 | Service LoadBalancer do Infisical | `05-infisical-lb-service.yaml` |

## Variaveis usadas nos comandos

Antes de comecar, exporta os valores que voce anotou no painel do Infisical:

```bash
export CLIENT_ID="..."           # Machine Identity
export CLIENT_SECRET="..."       # Machine Identity
export CA_CERT_PATH="../terraform/certs/cert.pem"
```

O `PROJECT_ID` e o `SUBSCRIBER_NAME` ja estao hardcoded em
`01-subscriber-sync-config.yaml` — edita esse arquivo se forem diferentes.

---

## 1. Nginx Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 2m
```

Confirma que recebeu IP do MetalLB:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP deve sair do range configurado em metallb-config.yaml
```

## 2. Stakater Reloader

```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update

helm upgrade --install reloader stakater/reloader \
  --namespace reloader \
  --create-namespace \
  --wait --timeout 2m
```

## 3. Infisical Secrets Operator

```bash
helm repo add infisical-helm-charts https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
helm repo update

helm upgrade --install infisical-secrets-operator infisical-helm-charts/secrets-operator \
  --namespace infisical \
  --set host=http://infisical-lb.infisical.svc.cluster.local
```

## 4. Secret com a CA (consumido pelo Nginx Ingress)

O Nginx exige que o Secret esteja no mesmo namespace do Ingress. Cria nos
dois namespaces onde existem Ingress com `auth-tls` (ingress-nginx para o
proprio controller, apolo-apps para o `httpbin-apolo-ingress`):

```bash
kubectl create secret generic infisical-ca \
  --from-file=ca.crt="${CA_CERT_PATH}" \
  -n ingress-nginx

kubectl create secret generic infisical-ca \
  --from-file=ca.crt="${CA_CERT_PATH}" \
  -n apolo-apps
```

## 5. Secret com as credenciais da Machine Identity

Consumido pelo CronJob de sync e pelo `InfisicalSecret` (corebank-secrets.yaml).
Cria em ambos os namespaces porque cada um tem um consumer diferente:

```bash
kubectl create secret generic infisical-operator-auth \
  --from-literal=clientId="${CLIENT_ID}" \
  --from-literal=clientSecret="${CLIENT_SECRET}" \
  -n infisical

kubectl create secret generic infisical-operator-auth \
  --from-literal=clientId="${CLIENT_ID}" \
  --from-literal=clientSecret="${CLIENT_SECRET}" \
  -n corebank-apps
```

## 6 a 10. Manifestos YAML versionados

Aplica em ordem (os prefixos numericos preservam a sequencia):

```bash
kubectl apply -f manifests/01-subscriber-sync-config.yaml
kubectl apply -f manifests/02-subscriber-sync-script.yaml
kubectl apply -f manifests/03-subscriber-sync-rbac.yaml
kubectl apply -f manifests/04-subscriber-sync-cronjob.yaml
kubectl apply -f manifests/05-infisical-lb-service.yaml
```

Ou tudo de uma vez:

```bash
kubectl apply -f manifests/
```

## 11. Bootstrap do primeiro sync

O CronJob roda a cada 15 minutos. Para nao esperar, dispara manualmente:

```bash
kubectl create job --from=cronjob/subscriber-sync \
  -n corebank-apps subscriber-sync-bootstrap

kubectl logs -n corebank-apps -l job-name=subscriber-sync-bootstrap -f
```

Esperado:

```
[sync] login Universal Auth
[sync] buscando latest-certificate-bundle do subscriber corebank-mtls
[sync] serial recebido: <hex>
[sync] atualizando Secret corebank-client-tls-secret
[sync] ok
```

## 12. Validacao

```bash
# Secret materializado pelo sync
kubectl get secret corebank-client-tls-secret -n corebank-apps

# Serial bate com o cert atual do subscriber no painel
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.metadata.annotations.infisical\.com/serial}'; echo

# Inspecao do cert
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates \
    -ext subjectAltName,extendedKeyUsage
```

A partir daqui o fluxo e o mesmo da versao terraform. Para os fluxos
detalhados de rotacao e troubleshooting, ver
[../docs/fluxos.md](../docs/fluxos.md).

---

## Limpeza

Ordem inversa (helm uninstall primeiro, kubectl delete depois):

```bash
helm uninstall infisical-secrets-operator -n infisical
helm uninstall reloader -n reloader
helm uninstall ingress-nginx -n ingress-nginx

kubectl delete -f manifests/
kubectl delete secret infisical-ca -n ingress-nginx
kubectl delete secret infisical-ca -n apolo-apps
kubectl delete secret infisical-operator-auth -n infisical
kubectl delete secret infisical-operator-auth -n corebank-apps
```
