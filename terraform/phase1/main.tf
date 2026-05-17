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

resource "kubernetes_namespace" "infisical" {
  metadata {
    name = "infisical"
  }
  depends_on = [kind_cluster.main]
}

resource "kubernetes_namespace" "corebank" {
  metadata {
    name = "corebank-apps"
  }
  depends_on = [kind_cluster.main]
}

resource "kubernetes_namespace" "apolo" {
  metadata {
    name = "apolo-apps"
  }
  depends_on = [kind_cluster.main]
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
    kubernetes_stateful_set.postgresql,
    kubernetes_stateful_set.redis
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
      node_port   = 30080
    }

    type = "NodePort"
  }

  depends_on = [kubernetes_deployment.infisical]
}
