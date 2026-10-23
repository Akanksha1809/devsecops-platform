terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.5"
    }
  }

  # Local backend (the default — no backend block needed to get it, this
  # is explicit for documentation). State lives at terraform.tfstate in
  # this directory, gitignored. No remote locking, no team collaboration
  # support, acceptable for a single-developer local demo — a real team
  # would use a remote backend (S3+DynamoDB, Terraform Cloud, etc.) so two
  # people can't corrupt state by applying at once. See
  # docs/IMPLEMENTATION_PLAN.md Sec4f.
}
