resource "kind_cluster" "main" {
  name           = var.cluster_name
  node_image     = var.node_image
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
    }

    node {
      role = "worker"
    }

    node {
      role = "worker"
    }
  }
}

resource "helm_release" "nginx_ingress" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress-nginx"
  create_namespace = true

  # Configurações para funcionar bem no Kind com MetalLB
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
}

resource "kubernetes_namespace" "infisical" {
  metadata {
    name = "infisical"
  }

  depends_on = [
    kind_cluster.main
  ]
}

resource "kubernetes_deployment" "postgresql" {
  metadata {
    name      = "infisical-postgresql"
    namespace = kubernetes_namespace.infisical.metadata[0].name
    labels = {
      app = "postgresql"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "postgresql"
      }
    }
    template {
      metadata {
        labels = {
          app = "postgresql"
        }
      }
      spec {
        container {
          name  = "postgresql"
          image = "postgres:15.5"
          
          env {
            name  = "POSTGRES_DB"
            value = "infisical"
          }
          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = "infisicalpassword"
          }

          port {
            container_port = 5432
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgresql" {
  metadata {
    name      = "infisical-postgresql"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }

  spec {
    selector = {
      app = "postgresql"
    }
    port {
      port        = 5432
      target_port = 5432
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "infisical-redis-master"
    namespace = kubernetes_namespace.infisical.metadata[0].name
    labels = {
      app = "redis"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "redis"
      }
    }
    template {
      metadata {
        labels = {
          app = "redis"
        }
      }
      spec {
        container {
          name  = "redis"
          image = "redis:7.2.4"
          command = ["redis-server", "--requirepass", "redispassword"]

          port {
            container_port = 6379
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = "infisical-redis-master"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }

  spec {
    selector = {
      app = "redis"
    }
    port {
      port        = 6379
      target_port = 6379
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "infisical" {
  metadata {
    name      = "infisical-backend"
    namespace = kubernetes_namespace.infisical.metadata[0].name
    labels = {
      app = "infisical"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "infisical"
      }
    }

    template {
      metadata {
        labels = {
          app = "infisical"
        }
      }

      spec {
        container {
          name  = "infisical"
          image = "docker.io/infisical/infisical:v0.151.0"

          port {
            container_port = 8080
          }

          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "ENCRYPTION_KEY"
            value = "12345678901234567890123456789012"
          }
          env {
            name  = "JWT_SIGN_SECRET"
            value = "super-secret-jwt-sign-key"
          }
          env {
            name  = "JWT_REFRESH_SECRET"
            value = "super-secret-jwt-refresh-key"
          }
          env {
            name  = "AUTH_SECRET"
            value = "super-secret-auth-key"
          }
          env {
            name  = "DB_CONNECTION_URI"
            value = "postgresql://postgres:infisicalpassword@infisical-postgresql:5432/infisical?sslmode=disable"
          }
          env {
            name  = "REDIS_URL"
            value = "redis://:redispassword@infisical-redis-master:6379/0"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.postgresql,
    kubernetes_deployment.redis
  ]
}

resource "kubernetes_service" "infisical_lb" {
  metadata {
    name      = "infisical-lb"
    namespace = kubernetes_namespace.infisical.metadata[0].name
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

  depends_on = [
    kubernetes_deployment.infisical
  ]
}

resource "kubernetes_namespace" "apolo" {
  metadata {
    name = "apolo-apps"
  }
  depends_on = [kind_cluster.main]
}

resource "kubernetes_namespace" "corebank" {
  metadata {
    name = "corebank-apps"
  }
  depends_on = [kind_cluster.main]
}

resource "kubernetes_secret" "apolo_ca_mtls" {
  metadata {
    name      = "apolo-ca-mtls"
    namespace = kubernetes_namespace.apolo.metadata[0].name
  }

  data = {
    "ca.crt" = file("${path.module}/certs/cert.pem")
  }

  type = "Opaque"
}

resource "helm_release" "infisical_operator" {
  name       = "infisical-secrets-operator"
  repository = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart      = "secrets-operator" 
  namespace  = kubernetes_namespace.infisical.metadata[0].name

  set {
    name  = "host"
    value = "http://infisical-lb.infisical.svc.cluster.local"
  }

  depends_on = [
    kubernetes_service.infisical_lb
  ]
}

resource "kubernetes_secret" "infisical_operator_auth" {
  metadata {
    name      = "infisical-operator-auth"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }

  data = {
    "clientId"     = "23c03c93-6fd8-4522-9914-a1aa4a30f869"
    "clientSecret" = "24c02b0fb297765eb11c6990dc85b205bc9f65022aafbd66d6bf66251068db2c"
  }

  type = "Opaque"
}

resource "kubernetes_secret" "infisical_operator_auth_corebank" {
  metadata {
    name      = "infisical-operator-auth"
    namespace = kubernetes_namespace.corebank.metadata[0].name
  }

  data = {
    "clientId"     = "23c03c93-6fd8-4522-9914-a1aa4a30f869"
    "clientSecret" = "24c02b0fb297765eb11c6990dc85b205bc9f65022aafbd66d6bf66251068db2c"
  }

  type = "Opaque"
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.13.0"

  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "helm_release" "infisical_pki_issuer" {
  name       = "infisical-pki-issuer"
  repository = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart      = "infisical-pki-issuer"
  namespace  = kubernetes_namespace.infisical.metadata[0].name

  set {
    name  = "host"
    value = "http://infisical-lb.infisical.svc.cluster.local"
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "apolo_pki_issuer" {
  manifest = {
    apiVersion = "infisical-issuer.infisical.com/v1alpha1"
    kind       = "Issuer"
    metadata = {
      name      = "apolo-pki-issuer"
      namespace = kubernetes_namespace.corebank.metadata[0].name
    }
    spec = {
      url                     = "http://infisical-lb.infisical.svc.cluster.local"
      projectId               = "01bb4bb3-1af3-4919-a482-8d2d99c69b6b"
      certificateTemplateName = "corebank-client-template"
      authentication = {
        universalAuth = {
          clientId = "23c03c93-6fd8-4522-9914-a1aa4a30f869"
          secretRef = {
            name = "infisical-operator-auth"
            key  = "clientSecret"
          }
        }
      }
    }
  }
  depends_on = [
    helm_release.infisical_pki_issuer,
    kubernetes_secret.infisical_operator_auth_corebank
  ]
}

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
