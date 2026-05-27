# Fluxos e Troubleshooting

Detalhes operacionais dos dois fluxos que a POC implementa, e como diagnosticar
problemas comuns. Para o setup inicial veja o [README](../README.md).

## Sumario

- [Fluxo 1 — Rotacao do certificado mTLS (PKI Subscriber)](#fluxo-1--rotacao-do-certificado-mtls-pki-subscriber)
- [Fluxo 2 — Gerenciamento de secrets de aplicacao (InfisicalSecret)](#fluxo-2--gerenciamento-de-secrets-de-aplicacao-infisicalsecret)
- [Teste end-to-end de mTLS](#teste-end-to-end-de-mtls)
- [Troubleshooting](#troubleshooting)

---

## Fluxo 1 — Rotacao do certificado mTLS (PKI Subscriber)

A POC usa o **PKI Subscriber** do Infisical como fonte de verdade unica para
a rotacao do certificado mTLS. Toda a politica (TTL, auto-renewal) vive no
painel; o cluster apenas consome.

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

### Verificando o ciclo

```bash
# CronJob agendado
kubectl get cronjob -n corebank-apps

# Execucao manual sem esperar o agendamento
kubectl create job --from=cronjob/subscriber-sync \
  -n corebank-apps subscriber-sync-manual

kubectl logs -n corebank-apps -l job-name=subscriber-sync-manual -f

# Serial atual gravado no Secret
kubectl get secret corebank-client-tls-secret -n corebank-apps \
  -o jsonpath='{.metadata.annotations.infisical\.com/serial}'; echo

# Rolling restart do pod quando o serial mudar
kubectl get pods -n corebank-apps -w
```

### Forcando rotacao para teste

No painel: `PKI > Subscribers > corebank-mtls > Issue Certificate`. Isso
emite um novo cert imediatamente; na proxima execucao do CronJob o Secret
e atualizado e o Reloader dispara rollout do pod. Tambem da pra forcar o
sync manual com o `kubectl create job --from=cronjob/...` acima.

### Por que o `mtls-test` pod nao reinicia

O `mtls-test.yaml` monta o Secret como **volume** (nao subPath), e o processo
principal e apenas `sleep infinity`. O kubelet atualiza o conteudo do volume
in-place em ~60s quando o Secret muda, e o `curl` le o arquivo a cada chamada,
sempre pegando o cert atual. Por isso esse pod nao precisa do Reloader.

Ja o `httpbin-corebank` tem um processo persistente que carrega o cert na
memoria no startup. Para esse caso o Reloader e necessario — daí a annotation
`secret.reloader.stakater.com/reload` no Deployment.

---

## Fluxo 2 — Gerenciamento de secrets de aplicacao (InfisicalSecret)

O `infisical-secrets-operator` mantem um Secret nativo do Kubernetes em
sincronia com um escopo do Infisical (projeto + environment + path).

```
Painel Infisical (Secret Management > gzbank-secret > /corebank)
    | valor do DB_URL editado
    v
InfisicalSecret CR (corebank-app-secrets, namespace corebank-apps)
    | resyncInterval = 60s, login com a mesma Machine Identity
    | GET /api/v3/secrets/raw?workspaceSlug=...&environment=dev&secretPath=/corebank
    v
Secret nativo K8s (corebank-app-env) atualizado in-place
    v
Stakater Reloader observa o Secret pela annotation no Deployment
    v
Rolling restart do httpbin-corebank com a env var nova
```

### Manifesto

Arquivo: `corebank-secrets.yaml`

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: corebank-app-secrets
  namespace: corebank-apps
spec:
  hostAPI: http://infisical-lb.infisical.svc.cluster.local/api
  syncConfig:
    resyncInterval: 60
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: "gzbank-secret-b-gc-o"
        envSlug: "dev"
        secretsPath: "/corebank"
      credentialsRef:
        secretName: infisical-operator-auth
        secretNamespace: corebank-apps
  managedKubeSecretReferences:
    - secretName: corebank-app-env
      secretNamespace: corebank-apps
      creationPolicy: "Owner"
```

Pre-requisitos no painel:

1. Projeto `gzbank-secret` criado em Secret Management
2. Machine Identity adicionada em `Project Access > Identities` com role
   que inclui `secrets:read` no environment `dev` (a role `Admin` resolve
   sem precisar configurar policy granular)
3. Pasta `/corebank` criada no environment Development com pelo menos uma
   chave (ex: `DB_URL`)

### Consumo no Deployment

O `httpbin-corebank.yaml` ja faz `envFrom` do Secret materializado e tem
a annotation do Reloader cobrindo ambos os secrets (cert + app env):

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "corebank-client-tls-secret,corebank-app-env"
spec:
  template:
    spec:
      containers:
        - name: httpbin
          envFrom:
            - secretRef:
                name: corebank-app-env
```

### Verificando o ciclo

```bash
kubectl get infisicalsecret -n corebank-apps
kubectl get secret corebank-app-env -n corebank-apps
kubectl get secret corebank-app-env -n corebank-apps \
  -o jsonpath='{.data.DB_URL}' | base64 -d; echo

# Forca reconcile imediato (em vez de esperar 60s)
kubectl annotate infisicalsecret corebank-app-secrets -n corebank-apps \
  force-resync=$(date +%s) --overwrite
```

### Forcando uma atualizacao para teste

1. No painel, muda o valor de `DB_URL` em `/corebank` (env Development)
2. Aguarda ate 60s (resyncInterval) ou forca com o `annotate` acima
3. Confirma o novo valor no Secret K8s
4. O Reloader detecta o hash diferente e faz rolling restart do
   `httpbin-corebank`
5. Confere a env var no pod novo:

```bash
POD=$(kubectl get pod -n corebank-apps -l app=httpbin-corebank -o name | head -1)
kubectl exec -n corebank-apps $POD -- env | grep DB_URL
```

---

## Teste end-to-end de mTLS

Demonstra que o cert emitido pelo subscriber autentica corretamente contra
o Nginx Ingress com `auth-tls-verify-client: on`.

```bash
kubectl apply -f httpbin-apolo.yaml
kubectl apply -f mtls-test.yaml
kubectl wait pod/mtls-test -n corebank-apps --for=condition=Ready --timeout=30s

INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Sem cert — esperado 400
kubectl exec -n corebank-apps mtls-test -- \
  curl -sk -o /dev/null -w "sem cert: %{http_code}\n" \
  --resolve apolo.service.internal:443:$INGRESS_IP \
  https://apolo.service.internal/get

# Com cert — esperado 200
kubectl exec -n corebank-apps mtls-test -- \
  curl -sk -o /dev/null -w "com cert: %{http_code}\n" \
  --resolve apolo.service.internal:443:$INGRESS_IP \
  --cert /etc/certs/tls.crt --key /etc/certs/tls.key \
  https://apolo.service.internal/get

# Limpeza
kubectl delete -f mtls-test.yaml
```

---

## Troubleshooting

### CronJob falha com "bundle vazio"

Acontece quando o subscriber foi criado no painel mas nenhum certificado
foi emitido ainda. Va em `PKI > Subscribers > corebank-mtls` e clique em
`Issue Certificate` uma vez. A partir dai o auto-renewal mantem o bundle
sempre populado.

### CronJob/operator retorna "Successfully synced 0 secrets"

Auth funcionou mas o escopo nao retornou nada. Causas comuns:

1. **secretsPath errado** — o secret esta em uma subpasta diferente da
   declarada no `secretsPath`. Verifique no painel em qual pasta esta o
   secret.
2. **envSlug errado** — confira em `Project Settings > Secrets Management`
   a coluna "Slug" dos environments (geralmente `dev`, `staging`, `prod`).
3. **Role da identity sem permissao no env** — a role `Developer` em
   algumas versoes do Infisical exige policy explicita por environment.
   Para POC, atribua `Admin` em `Project Access > Identities`.

Debug rapido via API:

```bash
kubectl port-forward -n infisical svc/infisical-lb 3000:80 &

CLIENT_ID=$(kubectl get secret infisical-operator-auth -n corebank-apps \
  -o jsonpath='{.data.clientId}' | base64 -d)
CLIENT_SECRET=$(kubectl get secret infisical-operator-auth -n corebank-apps \
  -o jsonpath='{.data.clientSecret}' | base64 -d)

TOKEN=$(curl -s -X POST http://localhost:3000/api/v1/auth/universal-auth/login \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"$CLIENT_ID\",\"clientSecret\":\"$CLIENT_SECRET\"}" \
  | jq -r .accessToken)

# Testa o escopo exato do InfisicalSecret
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:3000/api/v3/secrets/raw?workspaceSlug=gzbank-secret-b-gc-o&environment=dev&secretPath=/corebank" \
  | jq .
```

### Invalid credentials (401 do login Universal Auth)

Verifica se o `clientSecret` no Secret do Kubernetes esta correto:

```bash
kubectl get secret infisical-operator-auth -n corebank-apps \
  -o jsonpath='{.data.clientSecret}' | base64 -d
```

Confirma fazendo login direto:

```bash
curl -s -X POST http://localhost:3000/api/v1/auth/universal-auth/login \
  -H "Content-Type: application/json" \
  -d '{"clientId":"SEU-CLIENT-ID","clientSecret":"SEU-CLIENT-SECRET"}' | jq .
```

### Machine Identity bloqueada (lockout)

Se o CronJob recebeu varios 401 seguidos, a identity pode entrar em lockout.

1. Reset no painel:
   `Organization > Access Control > Identities > sua identity > Universal Auth > Lockout Options > Reset All Lockouts`

2. Confirma que o login funciona:

```bash
curl -s -X POST http://localhost:3000/api/v1/auth/universal-auth/login \
  -H "Content-Type: application/json" \
  -d '{"clientId":"SEU-CLIENT-ID","clientSecret":"SEU-CLIENT-SECRET"}' | jq .accessToken
```

3. Dispara uma rodada manual do CronJob:

```bash
kubectl create job --from=cronjob/subscriber-sync \
  -n corebank-apps subscriber-sync-retry
```

### MetalLB falha com "nil pointer evaluating .Values.prometheus.serviceMonitor"

Bug do chart MetalLB >= 0.15 quando o subchart `frr-k8s` esta habilitado
sem os values de prometheus populados. Como a POC usa L2 mode, frr-k8s nao
e necessario. Use a versao 0.14.9 (ja referenciada no README):

```bash
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --version 0.14.9 \
  --wait
```

### Rotacao da CA

A POC parte do principio de que a CA nao roda — ela e criada uma unica vez
no painel. Caso precise trocar:

1. Gera a nova CA no Infisical e baixa o novo `cert.pem`
2. Substitui `terraform/certs/cert.pem`
3. `terraform apply` na phase2

Apenas os Secrets `infisical-ca` (em `ingress-nginx` e `apolo-apps`) sao
atualizados. Os pods das aplicacoes nao precisam ser reiniciados — eles
nao conhecem a CA, so o Nginx Ingress conhece.
