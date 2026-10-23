variable "kubeconfig_path" {
  description = "Path to the kubeconfig file to use."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to target. Defaults to this project's kind cluster -- change deliberately if pointing at a different cluster."
  type        = string
  default     = "kind-devsecops-platform"
}

variable "repo_url" {
  description = "Git repository every Argo CD Application in this environment syncs from."
  type        = string
  default     = "https://github.com/Akanksha1809/devsecops-platform.git"
}

variable "target_revision" {
  description = "Git branch/tag/commit every Application tracks."
  type        = string
  default     = "main"
}
