variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the hermes agent."
  type        = string
  default     = "t3.medium"
}

variable "availability_zone" {
  description = "Availability zone to place the instance in (e.g. 'us-east-1a'). Must have a subnet in the default VPC. Empty string uses the first subnet in the VPC."
  type        = string
  default     = "us-east-1d"
}

variable "name" {
  description = "Base name used for the instance and related resources."
  type        = string
  default     = "hermes"
}

variable "hermes_install_command" {
  description = "Shell command run (as the hermes user) to install the Hermes CLI."
  type        = string
  default     = "curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
}

# --- Hermes Agent configuration (injected into the VM startup script) ---------

variable "hermes_user" {
  description = "Dedicated non-root OS user that owns and runs the Hermes Agent."
  type        = string
  default     = "hermes"
}

variable "model_provider" {
  description = "Model provider for Hermes. Choose one and the default model + base URL are auto-filled from the provider catalogue in providers.tf."
  type        = string
  default     = "openrouter"

  validation {
    condition     = contains(["openrouter", "anthropic", "openai", "nvidia"], var.model_provider)
    error_message = "model_provider must be one of: openrouter, anthropic, openai, nvidia."
  }
}

variable "model_name" {
  description = "Override the default model for the chosen provider (empty = use the provider catalogue default, e.g. openrouter → anthropic/claude-sonnet-4)."
  type        = string
  default     = ""
}

variable "provider_base_url" {
  description = "Override the provider API base URL (empty = use the provider catalogue default)."
  type        = string
  default     = ""
}

variable "provider_api_key" {
  description = "API key for the chosen model_provider. Sensitive — ends up in Terraform state (see startup script for the SSM/Secrets Manager hardening note)."
  type        = string
  sensitive   = true
}

variable "telegram_bot_token" {
  description = "Telegram bot token for the gateway. One running gateway per token (Telegram rejects concurrent polling). Sensitive — ends up in Terraform state."
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub personal access token for the Hermes agent (optional). When set, the startup script authenticates the gh CLI and configures git credential-helper so the agent can push/open PRs. When empty, GitHub auth is skipped entirely."
  type        = string
  default     = ""
  sensitive   = true
}

variable "telegram_allowed_users" {
  description = "MANDATORY comma-separated list of NUMERIC Telegram user IDs allowed to use the bot. Empty makes the gateway deny everyone ('online but silent')."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+(,[0-9]+)*$", var.telegram_allowed_users))
    error_message = "telegram_allowed_users must be a non-empty comma-separated list of numeric Telegram user IDs (e.g. \"123456789,987654321\")."
  }
}

variable "allowed_ports" {
  description = "List of inbound TCP ports to open on the instance (e.g. [3000, 8080, 5173] for web prototyping). All ports are open to 0.0.0.0/0 — only use on trusted, non-production accounts."
  type        = list(number)
  default     = [3000, 4000, 5000, 5173, 8000, 8080, 8443, 8888]
}

variable "root_volume_size" {
  description = "Size (GiB) of the root gp3 EBS volume."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags applied to all resources via the provider's default_tags."
  type        = map(string)
  default = {
    Project = "hermes"
  }
}
