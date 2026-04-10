terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

provider "kubernetes" {
  config_path = ""
}

# ── Resource properties ──────────────────────────────────────────────

locals {
  resource_name  = var.context.resource.name
  namespace      = var.context.runtime.kubernetes.namespace
  normalized_name = local.resource_name

  properties      = try(var.context.resource.properties, {})
  image           = local.properties.image
  build_context   = local.properties.build.context
  dockerfile      = try(local.properties.build.dockerfile, "Dockerfile")
  registry_secret = local.properties.registry.secretName

  environment_segments = try(split("/", local.properties.environment), [])
  environment_label    = length(local.environment_segments) > 0 ? element(local.environment_segments, length(local.environment_segments) - 1) : ""

  labels = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/environment" = local.environment_label
    "radapp.io/application" = try(var.context.application.name, "")
  }
}

# ── Build Job ────────────────────────────────────────────────────────
# Mounts the source directory from the host via hostPath, then BuildKit
# builds and pushes the image to the remote registry (e.g., ghcr.io).

resource "kubernetes_job_v1" "build" {
  metadata {
    name      = "${local.normalized_name}-build"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 600

    template {
      metadata {
        labels = local.labels
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "build-and-push"
          image = "moby/buildkit:latest"

          command = [
            "buildctl-daemonless.sh",
            "build",
            "--frontend=dockerfile.v0",
            "--local=context=/workspace",
            "--local=dockerfile=/workspace",
            "--opt=filename=${local.dockerfile}",
            "--output=type=image,name=${local.image},push=true",
          ]

          volume_mount {
            name       = "source"
            mount_path = "/workspace"
            read_only  = true
          }

          volume_mount {
            name       = "docker-config"
            mount_path = "/root/.docker"
            read_only  = true
          }

          security_context {
            privileged = true
          }
        }

        volume {
          name = "source"
          host_path {
            path = local.build_context
            type = "Directory"
          }
        }

        volume {
          name = "docker-config"
          secret {
            secret_name = local.registry_secret
            items {
              key  = ".dockerconfigjson"
              path = "config.json"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }
}

# ── Outputs ──────────────────────────────────────────────────────────

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/batch/Job/${local.normalized_name}-build"
    ]
  }
}
