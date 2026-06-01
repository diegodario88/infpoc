resource "kubernetes_stateful_set" "postgresql" {
  metadata {
    name      = "infisical-postgresql"
    namespace = kubernetes_namespace.infisical.metadata[0].name
    labels = {
      app = "postgresql"
    }
  }

  spec {
    service_name = "infisical-postgresql"
    replicas     = 1

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

          volume_mount {
            name       = "postgresql-data"
            mount_path = "/var/lib/postgresql/data"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "postgresql-data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = "5Gi"
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

# ── REDIS ─────────────────────────────────────────────────────────────────────
resource "kubernetes_stateful_set" "redis" {
  metadata {
    name      = "infisical-redis-master"
    namespace = kubernetes_namespace.infisical.metadata[0].name
    labels = {
      app = "redis"
    }
  }

  spec {
    service_name = "infisical-redis-master"
    replicas     = 1

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
          name    = "redis"
          image   = "redis:7.2.4"
          command = ["redis-server", "--requirepass", "redispassword", "--appendonly", "yes"]

          port {
            container_port = 6379
          }

          volume_mount {
            name       = "redis-data"
            mount_path = "/data"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "redis-data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = "1Gi"
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
