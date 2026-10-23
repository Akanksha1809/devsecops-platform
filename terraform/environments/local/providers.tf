provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

# address/token are deliberately not set here -- VAULT_ADDR and
# VAULT_TOKEN env vars, set fresh from this cluster's own dev-mode logs
# on every `terraform apply` (the root token is regenerated on every
# Vault pod restart and is never written to a file in this repo). See
# docs/IMPLEMENTATION_PLAN.md Sec4g.
provider "vault" {}
