variable "name" {
  description = "Name of the Argo CD Application resource."
  type        = string
}

variable "repo_url" {
  description = "Git repository Argo CD syncs this Application from."
  type        = string
}

variable "target_revision" {
  description = "Git branch/tag/commit to track."
  type        = string
  default     = "main"
}

variable "source_path" {
  description = "Path within the repo this Application's source comes from."
  type        = string
}

variable "source_type" {
  description = "\"helm\" (renders a Helm chart with an optional values file) or \"directory\" (applies plain Kubernetes manifests, recursing into subdirectories)."
  type        = string
  validation {
    condition     = contains(["helm", "directory"], var.source_type)
    error_message = "source_type must be \"helm\" or \"directory\"."
  }
}

variable "helm_values_file" {
  description = "Values file name (relative to source_path) to pass to Helm. Only used when source_type = \"helm\"."
  type        = string
  default     = null
}

variable "destination_namespace" {
  description = "Namespace this Application's resources are deployed into."
  type        = string
}

variable "automated_sync" {
  description = "If true, Argo CD auto-syncs with selfHeal+prune on every Git change. If false, this Application requires an explicit `argocd app sync` -- this project's promotion-gate pattern (see devsecops-app-staging)."
  type        = bool
  default     = true
}
