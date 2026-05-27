# ── NGINX INGRESS ─────────────────────────────────────────────────────────────
resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 120

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
}

# CA do Infisical — o cert.pem e distribuido para cada namespace que
# possui um Ingress com auth-tls. O Nginx exige que o secret esteja
# no mesmo namespace do recurso Ingress.
resource "kubernetes_secret" "nginx_ca_mtls_ingress_nginx" {
  metadata {
    name      = "infisical-ca"
    namespace = "ingress-nginx"
  }
  data = {
    "ca.crt" = file(var.ca_cert_path)
  }
  type       = "Opaque"
  depends_on = [helm_release.nginx_ingress]
}

resource "kubernetes_secret" "nginx_ca_mtls_apolo" {
  metadata {
    name      = "infisical-ca"
    namespace = "apolo-apps"
  }
  data = {
    "ca.crt" = file(var.ca_cert_path)
  }
  type = "Opaque"
}

# ── INFISICAL SECRETS OPERATOR ────────────────────────────────────────────────
resource "helm_release" "infisical_operator" {
  name       = "infisical-secrets-operator"
  repository = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart      = "secrets-operator"
  namespace  = "infisical"

  set {
    name  = "host"
    value = var.infisical_url
  }
}

# ── SECRETS ───────────────────────────────────────────────────────────────────

# Credenciais da Machine Identity para o namespace infisical
resource "kubernetes_secret" "infisical_operator_auth" {
  metadata {
    name      = "infisical-operator-auth"
    namespace = "infisical"
  }
  data = {
    "clientId"     = var.client_id
    "clientSecret" = var.client_secret
  }
  type = "Opaque"
}

# Credenciais da Machine Identity para o namespace corebank-apps
resource "kubernetes_secret" "infisical_operator_auth_corebank" {
  metadata {
    name      = "infisical-operator-auth"
    namespace = "corebank-apps"
  }
  data = {
    "clientId"     = var.client_id
    "clientSecret" = var.client_secret
  }
  type = "Opaque"
}

# ── RELOADER (rolling restart quando o Secret do cert muda) ───────────────────
resource "helm_release" "reloader" {
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  namespace        = "reloader"
  create_namespace = true
  wait             = true
  timeout          = 120
}

# ── SUBSCRIBER SYNC: ConfigMap com o script ───────────────────────────────────
# Script que autentica via Universal Auth, busca o bundle do subscriber
# e faz patch no Secret corebank-client-tls-secret. O Reloader detecta
# a mudanca de hash e dispara rolling restart do Deployment anotado.
resource "kubernetes_config_map" "subscriber_sync_script" {
  metadata {
    name      = "subscriber-sync-script"
    namespace = "corebank-apps"
  }

  data = {
    "sync.sh" = <<-EOT
      #!/bin/sh
      set -eu

      : "$${INFISICAL_URL:?must be set}"
      : "$${CLIENT_ID:?must be set}"
      : "$${CLIENT_SECRET:?must be set}"
      : "$${PROJECT_ID:?must be set}"
      : "$${SUBSCRIBER_NAME:?must be set}"
      : "$${SECRET_NAME:?must be set}"
      : "$${NAMESPACE:?must be set}"

      echo "[sync] login Universal Auth"
      TOKEN=$(curl -fsS -X POST "$${INFISICAL_URL}/api/v1/auth/universal-auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"clientId\":\"$${CLIENT_ID}\",\"clientSecret\":\"$${CLIENT_SECRET}\"}" \
        | jq -r .accessToken)

      if [ -z "$${TOKEN}" ] || [ "$${TOKEN}" = "null" ]; then
        echo "[sync] falha no login Universal Auth" >&2
        exit 1
      fi

      echo "[sync] buscando latest-certificate-bundle do subscriber $${SUBSCRIBER_NAME}"
      BUNDLE=$(curl -fsS \
        -H "Authorization: Bearer $${TOKEN}" \
        "$${INFISICAL_URL}/api/v1/pki/subscribers/$${SUBSCRIBER_NAME}/latest-certificate-bundle?projectId=$${PROJECT_ID}")

      CERT=$(echo "$${BUNDLE}" | jq -r .certificate)
      KEY=$(echo "$${BUNDLE}" | jq -r .privateKey)
      CHAIN=$(echo "$${BUNDLE}" | jq -r .certificateChain)

      if [ -z "$${CERT}" ] || [ "$${CERT}" = "null" ]; then
        echo "[sync] bundle vazio - subscriber ainda nao tem cert ativo?" >&2
        exit 1
      fi

      SERIAL=$(echo "$${BUNDLE}" | jq -r .serialNumber)
      echo "[sync] serial recebido: $${SERIAL}"

      # Compara serial atual no Secret. Se igual, nao mexe (evita restart desnecessario).
      CURRENT_SERIAL=$(kubectl get secret "$${SECRET_NAME}" -n "$${NAMESPACE}" \
        -o jsonpath='{.metadata.annotations.infisical\.com/serial}' 2>/dev/null || echo "")

      if [ "$${CURRENT_SERIAL}" = "$${SERIAL}" ]; then
        echo "[sync] serial inalterado, nada a fazer"
        exit 0
      fi

      echo "[sync] atualizando Secret $${SECRET_NAME}"
      TLS_CRT=$(printf '%s' "$${CERT}" | base64 -w0)
      TLS_KEY=$(printf '%s' "$${KEY}"  | base64 -w0)
      CA_CRT=$(printf '%s'  "$${CHAIN}" | base64 -w0)

      kubectl apply -f - <<EOF_INNER
      apiVersion: v1
      kind: Secret
      metadata:
        name: $${SECRET_NAME}
        namespace: $${NAMESPACE}
        annotations:
          infisical.com/serial: "$${SERIAL}"
          infisical.com/subscriber: "$${SUBSCRIBER_NAME}"
      type: kubernetes.io/tls
      data:
        tls.crt: $${TLS_CRT}
        tls.key: $${TLS_KEY}
        ca.crt:  $${CA_CRT}
      EOF_INNER

      echo "[sync] ok"
    EOT
  }
}

# ── SUBSCRIBER SYNC: RBAC ─────────────────────────────────────────────────────
resource "kubernetes_service_account" "subscriber_sync" {
  metadata {
    name      = "subscriber-sync"
    namespace = "corebank-apps"
  }
}

resource "kubernetes_role" "subscriber_sync" {
  metadata {
    name      = "subscriber-sync"
    namespace = "corebank-apps"
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "create", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "subscriber_sync" {
  metadata {
    name      = "subscriber-sync"
    namespace = "corebank-apps"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.subscriber_sync.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.subscriber_sync.metadata[0].name
    namespace = "corebank-apps"
  }
}

# ── SUBSCRIBER SYNC: CronJob ──────────────────────────────────────────────────
resource "kubernetes_cron_job_v1" "subscriber_sync" {
  metadata {
    name      = "subscriber-sync"
    namespace = "corebank-apps"
  }

  spec {
    schedule                      = var.subscriber_sync_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3

    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.subscriber_sync.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name    = "sync"
              image   = "alpine/k8s:1.29.7"
              command = ["/bin/sh", "/scripts/sync.sh"]

              env {
                name  = "INFISICAL_URL"
                value = var.infisical_url
              }
              env {
                name  = "PROJECT_ID"
                value = var.project_id
              }
              env {
                name  = "SUBSCRIBER_NAME"
                value = var.subscriber_name
              }
              env {
                name  = "SECRET_NAME"
                value = "corebank-client-tls-secret"
              }
              env {
                name  = "NAMESPACE"
                value = "corebank-apps"
              }
              env {
                name = "CLIENT_ID"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.infisical_operator_auth_corebank.metadata[0].name
                    key  = "clientId"
                  }
                }
              }
              env {
                name = "CLIENT_SECRET"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.infisical_operator_auth_corebank.metadata[0].name
                    key  = "clientSecret"
                  }
                }
              }

              volume_mount {
                name       = "script"
                mount_path = "/scripts"
              }
            }

            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map.subscriber_sync_script.metadata[0].name
                default_mode = "0755"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_role_binding.subscriber_sync,
    kubernetes_secret.infisical_operator_auth_corebank,
  ]
}

# ── INFISICAL SERVICE (muda de NodePort para LoadBalancer) ────────────────────
resource "kubernetes_service" "infisical_lb" {
  metadata {
    name      = "infisical-lb"
    namespace = "infisical"
  }
  spec {
    selector = {
      app = "infisical"
    }
    port {
      port        = 80
      target_port = 8080
    }
    type = "LoadBalancer"
  }
  depends_on = [helm_release.nginx_ingress]
}
