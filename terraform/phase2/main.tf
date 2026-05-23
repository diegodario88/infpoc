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
# Para rotacionar a CA: substitua o cert.pem e rode terraform apply.
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

# ── CERT-MANAGER ──────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.13.0"
  wait             = true
  timeout          = 120

  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "time_sleep" "wait_for_cert_manager" {
  depends_on      = [helm_release.cert_manager]
  create_duration = "30s"
}

# ── INFISICAL PKI ISSUER ──────────────────────────────────────────────────────
resource "helm_release" "infisical_pki_issuer" {
  name       = "infisical-pki-issuer"
  repository = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart      = "infisical-pki-issuer"
  namespace  = "infisical"
  wait       = true
  timeout    = 120

  set {
    name  = "host"
    value = var.infisical_url
  }

  depends_on = [time_sleep.wait_for_cert_manager]
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

# ── RBAC ──────────────────────────────────────────────────────────────────────

# Permite ao cert-manager aprovar CertificateRequests do infisical-issuer
resource "kubernetes_cluster_role" "infisical_issuer_approver" {
  metadata {
    name = "infisical-issuer-approver"
  }
  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["certificaterequests"]
    verbs      = ["get", "list", "watch", "update"]
  }
  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["certificaterequests/approval"]
    verbs      = ["update"]
  }
  rule {
    api_groups     = ["cert-manager.io"]
    resources      = ["signers"]
    verbs          = ["approve"]
    resource_names = ["issuers.infisical-issuer.infisical.com/*"]
  }
  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_cluster_role_binding" "infisical_issuer_approver" {
  metadata {
    name = "infisical-issuer-approver"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.infisical_issuer_approver.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "cert-manager"
    namespace = "cert-manager"
  }
  depends_on = [kubernetes_cluster_role.infisical_issuer_approver]
}

# Permissões adicionais para o controller do infisical-pki-issuer
resource "kubernetes_cluster_role" "infisical_pki_issuer_fix" {
  metadata {
    name = "infisical-pki-issuer-fix"
  }
  rule {
    api_groups = ["infisical-issuer.infisical.com"]
    resources  = ["issuers", "clusterissuers", "issuers/status", "clusterissuers/status"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["certificaterequests", "certificaterequests/status"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch", "update"]
  }
  depends_on = [helm_release.infisical_pki_issuer]
}

resource "kubernetes_cluster_role_binding" "infisical_pki_issuer_fix" {
  metadata {
    name = "infisical-pki-issuer-fix-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.infisical_pki_issuer_fix.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "infisical-pki-issuer-controller-manager"
    namespace = "infisical"
  }
  depends_on = [kubernetes_cluster_role.infisical_pki_issuer_fix]
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

# ── ISSUER + CERTIFICATE (via null_resource para evitar problema de CRD) ──────
resource "time_sleep" "wait_for_pki_issuer" {
  depends_on      = [helm_release.infisical_pki_issuer]
  create_duration = "30s"
}

resource "null_resource" "corebank_pki_config" {
  depends_on = [
    time_sleep.wait_for_pki_issuer,
    kubernetes_secret.infisical_operator_auth_corebank,
    kubernetes_cluster_role_binding.infisical_issuer_approver,
    kubernetes_cluster_role_binding.infisical_pki_issuer_fix,
  ]

  triggers = {
    client_id     = var.client_id
    project_id    = var.project_id
    template      = var.certificate_template_name
    infisical_url = var.infisical_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<EOF
      apiVersion: infisical-issuer.infisical.com/v1alpha1
      kind: Issuer
      metadata:
        name: apolo-pki-issuer
        namespace: corebank-apps
      spec:
        url: ${var.infisical_url}
        projectId: "${var.project_id}"
        certificateTemplateName: "${var.certificate_template_name}"
        authentication:
          universalAuth:
            clientId: "${var.client_id}"
            secretRef:
              name: infisical-operator-auth
              key: clientSecret
      ---
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: corebank-mtls-identity
        namespace: corebank-apps
      spec:
        secretName: corebank-client-tls-secret
        commonName: corebank.service.internal
        dnsNames:
          - corebank.corebank-namespace.svc.cluster.local
        duration: 24h
        renewBefore: 6h
        issuerRef:
          name: apolo-pki-issuer
          kind: Issuer
          group: infisical-issuer.infisical.com
      EOF
    EOT
  }
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
