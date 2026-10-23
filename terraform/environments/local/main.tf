module "app_dev" {
  source = "../../modules/argocd-application"

  name                  = "devsecops-app-dev"
  repo_url              = var.repo_url
  target_revision       = var.target_revision
  source_path           = "helm/devsecops-app"
  source_type           = "helm"
  helm_values_file      = "values-dev.yaml"
  destination_namespace = "devsecops-dev"
  automated_sync        = true
}

module "app_staging" {
  source = "../../modules/argocd-application"

  name                  = "devsecops-app-staging"
  repo_url              = var.repo_url
  target_revision       = var.target_revision
  source_path           = "helm/devsecops-app"
  source_type           = "helm"
  helm_values_file      = "values-staging.yaml"
  destination_namespace = "devsecops-staging"
  # No automated sync -- promoting to staging is a deliberate
  # `argocd app sync devsecops-app-staging`, this project's promotion
  # gate from dev to staging (see docs/IMPLEMENTATION_PLAN.md Sec4c).
  automated_sync = false
}

module "monitoring" {
  source = "../../modules/argocd-application"

  name                  = "monitoring"
  repo_url              = var.repo_url
  target_revision       = var.target_revision
  source_path           = "monitoring"
  source_type           = "directory"
  destination_namespace = "monitoring"
  automated_sync        = true
}

# Terraform owns this namespace specifically (not left to the monitoring
# Application's CreateNamespace=true, which only ensures a namespace
# exists, not who manages it) because the Grafana secret below must exist
# in it, and that ordering needs to be explicit rather than racing
# Argo CD's own sync.
#
# Real friction discovered by actually running `terraform plan` after
# `apply`: Argo CD's CreateNamespace=true reaches further than "ensure it
# exists" -- it also stamps an argocd.argoproj.io/tracking-id annotation
# onto the namespace, which Terraform (owning this resource) would then
# perpetually want to remove on every plan, and Argo CD would just
# re-add on its next sync. Neither tool is wrong; they're both legitimately
# touching the same object. ignore_changes on annotations is the standard
# fix for this exact "co-managed namespace" pattern -- see
# docs/IMPLEMENTATION_PLAN.md Sec4f.
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

# Replaces the one-off `openssl rand | kubectl create secret` step from
# Phase 6 with a Terraform-managed equivalent. Known tradeoff, documented
# rather than ignored: this password is stored in Terraform state in
# plaintext (state isn't encrypted by the local backend) -- acceptable
# for a local demo credential with no real-world consequence, not
# acceptable practice for a real secret. See
# docs/IMPLEMENTATION_PLAN.md Sec4f and Phase 8 (Vault) for the contrast.
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "admin-password" = random_password.grafana_admin.result
  }
}
