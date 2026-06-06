# Provider catalogue: each entry bundles the default model, API base URL,
# and the env-var name Hermes expects for the API key.  Picking a provider
# via var.model_provider auto-fills everything else — only the API key
# needs to be supplied separately.

locals {
  provider_catalogue = {
    openrouter = {
      model        = "anthropic/claude-sonnet-4"
      base_url     = "https://openrouter.ai/api/v1"
      key_env_var  = "OPENROUTER_API_KEY"
      base_env_var = "OPENROUTER_BASE_URL"
    }
    anthropic = {
      model        = "claude-sonnet-4"
      base_url     = "https://api.anthropic.com"
      key_env_var  = "ANTHROPIC_API_KEY"
      base_env_var = "ANTHROPIC_BASE_URL"
    }
    openai = {
      model        = "gpt-4.1"
      base_url     = "https://api.openai.com/v1"
      key_env_var  = "OPENAI_API_KEY"
      base_env_var = "OPENAI_BASE_URL"
    }
    nvidia = {
      model        = "z-ai/glm-5.1"
      base_url     = "https://integrate.api.nvidia.com/v1"
      key_env_var  = "NVIDIA_API_KEY"
      base_env_var = "NVIDIA_BASE_URL"
    }
  }

  # Resolved provider config — looks up the catalogue entry for the
  # chosen provider.  var.model_name and var.provider_base_url can
  # override the catalogue defaults when set (non-empty).
  selected_provider    = local.provider_catalogue[var.model_provider]
  resolved_model       = var.model_name != "" ? var.model_name : local.selected_provider.model
  resolved_base_url    = var.provider_base_url != "" ? var.provider_base_url : local.selected_provider.base_url
  resolved_key_env_var = local.selected_provider.key_env_var
  resolved_base_env_var = local.selected_provider.base_env_var
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}
