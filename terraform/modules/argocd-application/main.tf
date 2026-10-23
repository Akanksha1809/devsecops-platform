# Terraform's job stops at creating this Application object — once it
# exists, Argo CD's own reconciliation loop (not Terraform) is what keeps
# the actual Kubernetes resources it describes in sync with Git. This is
# the boundary documented in docs/IMPLEMENTATION_PLAN.md Sec4f: Terraform
# owns the bootstrap (Application CRs + the Grafana secret), Argo CD owns
# everything an Application points it at. Neither side re-applies or
# fights over the other's resources.
#
# Two separate resources (picked via count), not one resource with a
# ternary between a "helm" source and a "directory" source — Terraform's
# object type system requires both branches of a conditional to have the
# same shape, and a Helm source and a directory source genuinely don't.

locals {
  sync_policy = merge(
    {
      syncOptions = ["CreateNamespace=true"]
    },
    var.automated_sync ? {
      automated = {
        prune    = true
        selfHeal = true
      }
    } : {}
  )
}

resource "kubernetes_manifest" "application_helm" {
  count = var.source_type == "helm" ? 1 : 0

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = var.name
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.repo_url
        targetRevision = var.target_revision
        path           = var.source_path
        helm = {
          valueFiles = var.helm_values_file != null ? [var.helm_values_file] : []
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.destination_namespace
      }
      syncPolicy = local.sync_policy
    }
  }
}

resource "kubernetes_manifest" "application_directory" {
  count = var.source_type == "directory" ? 1 : 0

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = var.name
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.repo_url
        targetRevision = var.target_revision
        path           = var.source_path
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.destination_namespace
      }
      syncPolicy = local.sync_policy
    }
  }
}
