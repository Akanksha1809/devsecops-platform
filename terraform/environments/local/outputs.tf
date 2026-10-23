output "application_names" {
  description = "Argo CD Applications bootstrapped by this configuration."
  value = [
    module.app_dev.application_name,
    module.app_staging.application_name,
    module.monitoring.application_name,
    module.vault.application_name,
  ]
}

output "grafana_admin_secret" {
  description = "Namespace/name of the Grafana admin credentials Secret (value intentionally not output)."
  value       = "${kubernetes_namespace.monitoring.metadata[0].name}/${kubernetes_secret.grafana_admin.metadata[0].name}"
}
