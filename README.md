# terra-hermes

Quick Terraform to deploy a single EC2 instance running the **hermes agent**.

It provisions:

- One `t3.medium` **Ubuntu 24.04 LTS** (amd64) instance in the default VPC
- The **Hermes Agent**, installed at first boot as a dedicated non-root user
- A **provider catalogue** — pick a provider and the default model + base URL are auto-filled
- The model provider + API key configured non-interactively from variables
- The **Telegram gateway** running as a persistent per-user systemd service
- **Selected inbound TCP ports** open for web prototyping (default: 3000, 4000, 5000, 5173, 8000, 8080, 8443, 8888)
- **SSM Session Manager** access (IAM role) — no SSH key required
- An egress-only security group (overridable — see `allowed_ports`), encrypted gp3 root volume, IMDSv2 enforced

Region defaults to `us-east-1`; Terraform state is stored locally.

The boot logic lives in `templates/hermes-startup.sh`. It reads all configuration
from the environment; `main.tf` prepends an `export` block (built from the
variables below) ahead of it, so nothing is hand-edited on the box.

> **Secrets & state:** `provider_api_key` and `telegram_bot_token` are injected via
> `user_data`, which Terraform stores in **state** and EC2 exposes via the metadata
> service. For production, store them in SSM Parameter Store / Secrets Manager and
> fetch them at boot via an instance IAM role (noted in the startup script).

## Provider catalogue

Pick a provider via `model_provider` and the default model + base URL are resolved
automatically from the catalogue in `providers.tf`:

| Provider | Default model | Base URL |
| ---------- | ------------------------- | ---------------------------------------- |
| `openrouter` | `anthropic/claude-sonnet-4` | `https://openrouter.ai/api/v1` |
| `anthropic` | `claude-sonnet-4` | `https://api.anthropic.com` |
| `openai` | `gpt-4.1` | `https://api.openai.com/v1` |
| `nvidia` | `z-ai/glm-5.1` | `https://integrate.api.nvidia.com/v1` |

To override the default model or base URL for a provider, set `model_name` or
`provider_base_url` (empty = use the catalogue default).

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform) >= 1.5
- AWS credentials configured (e.g. `aws configure` or environment variables)
- A default VPC in the target region (standard on most accounts)
- For connecting: the AWS CLI + the
 [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

## Authentication via `secrets.sh`

Keep all credentials — both your **AWS keys** and the Hermes **secrets** — in a
local, **gitignored** `secrets.sh` that you `source` before running Terraform.
Terraform reads any `TF_VAR_<name>` env var as the value for variable `<name>`,
and the AWS provider picks up `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from
the environment.

Requirements — the file must `export` the following:

```sh
# secrets.sh — DO NOT COMMIT

# AWS credentials (used by Terraform to create/destroy resources)
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY=*** AWS_REGION="us-east-1" # optional; matches var.region

# Hermes secrets (consumed as Terraform variables)
export TF_VAR_provider_api_key="nvapi-..." # key for your model_provider
export TF_VAR_telegram_bot_token="123456789:ABC..." # from @BotFather

# Optional: keep this here too instead of in terraform.tfvars
export TF_VAR_telegram_allowed_users="123456789,987654321"

# Optional: GitHub PAT — enables gh CLI + git push on the deployed VM.
# export TF_VAR_github_token="ghp_..."
```

- The IAM user behind those keys needs permissions for EC2, IAM (role +
 instance profile), and security groups, plus `ssm:StartSession` to connect.
 Prefer an IAM user over root keys.
- Keep it out of git — this repo already ignores `secrets.sh` — and
 `chmod 600 secrets.sh`.
- `source` it in the same shell before any Terraform/AWS command:

 ```sh
 cp secrets.sh.example secrets.sh # then edit in your values
 chmod 600 secrets.sh
 source ./secrets.sh
 ```

> The Hermes secrets are still written into the instance `user_data` and therefore
> into Terraform **state**. `secrets.sh` only keeps them out of source files and
> shell history; for production-grade handling use SSM Parameter Store / Secrets
> Manager with an instance IAM role.

## Usage

1. Provide configuration. Non-secret values go in `terraform.tfvars`; credentials
 come from `secrets.sh`:

 ```sh
 cp terraform.tfvars.example terraform.tfvars
 # edit terraform.tfvars: model_provider, telegram_allowed_users, ...
 # Pick a provider — default model + base URL are auto-filled:
 #   model_provider = "openrouter"
 #   model_provider = "anthropic"
 #   model_provider = "openai"
 #   model_provider = "nvidia"

 source ./secrets.sh # AWS keys + TF_VAR_provider_api_key + TF_VAR_telegram_bot_token
 ```

2. Deploy:

 ```sh
 terraform init
 terraform plan
 terraform apply
 ```

3. Connect to the instance via SSM (no SSH key required):

 ```sh
 aws ssm start-session --target <instance_id> --region us-east-1
 ```

 The exact command is printed as the `ssm_session_command` output. The instance
 must show as **Online** in SSM Fleet Manager before you can connect (usually a
 minute or two after boot).

## Verify the installation via SSM

Wait 5 minutes after the `terraform apply` to allow time for the hermes installation to be completed

The whole agent runs under the dedicated `hermes` user. Connect, then work
through the checks below — each line tells you which stage succeeded.

1. **Open a session** (no SSH key needed; instance must be `Online` in SSM):

 ```sh
 aws ssm start-session --target $(terraform output -raw instance_id) --region us-east-1
 ```

2. **Confirm the bootstrap finished cleanly:**

 ```sh
 cloud-init status --long # want: status: done
 sudo grep '\[hermes-startup\]' /var/log/cloud-init-output.log
 ```

 The last marker should read `[hermes-startup] Hermes bootstrap complete`. If
 not, the step after the final marker is where it failed.

3. **Confirm the CLI, config, and endpoint:**

 ```sh
 sudo -u hermes -H bash -lc 'hermes --version' # CLI installed
 sudo ls -l /home/hermes/.hermes/.env # secrets file (600, hermes-owned)
 sudo -u hermes -H bash -lc 'hermes config check' # provider + API key + base URL reachable
 ```

4. **Confirm the Telegram gateway is running** (persistent per-user service):

 ```sh
 sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) \
 systemctl --user status 'hermes*' # want: active (running)
 # live logs:
 sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) \
 journalctl --user -u 'hermes*' -f
 ```

5. **End-to-end:** message the bot from a Telegram account whose numeric ID is in
 `telegram_allowed_users`. A reply confirms the full chain. "Online but silent"
 almost always means your ID isn't in that list.

## Configuration

| Variable | Default | Description |
| ------------------------ | --------------------------- | ------------------------------------------------------- |
| `model_provider` | `openrouter` | `openrouter` \| `anthropic` \| `openai` \| `nvidia` — default model + base URL auto-filled |
| `model_name` | `""` (catalogue default) | Override the default model for the chosen provider |
| `provider_base_url` | `""` (catalogue default) | Override the provider API base URL |
| `provider_api_key` | _(required, sensitive)_ | API key for the chosen `model_provider` |
| `telegram_bot_token` | _(required, sensitive)_ | Telegram bot token (one running gateway per token) |
| `telegram_allowed_users` | _(required)_ | Comma-separated NUMERIC Telegram user IDs (mandatory) |
| `github_token` | `""` (optional, sensitive) | GitHub PAT — enables gh CLI + git push on the VM (empty = skip GitHub auth) |
| `hermes_user` | `hermes` | Dedicated non-root user that runs Hermes |
| `hermes_install_command` | Hermes `install.sh` via curl | Command (run as `hermes_user`) to install the CLI |
| `region` | `us-east-1` | AWS region |
| `instance_type` | `t3.medium` | EC2 instance type |
| `availability_zone` | `us-east-1d` | AZ to place the instance in (empty = first subnet) |
| `name` | `hermes` | Base name for the instance and related resources |
| `root_volume_size` | `20` | Root gp3 volume size (GiB) |
| `allowed_ports` | `[3000, 4000, 5000, 5173, 8000, 8080, 8443, 8888]` | Inbound TCP ports open for web prototyping (set `[]` for egress-only) |
| `tags` | `{Project=…}` | Tags applied to all resources |

## Finding Your Route 53 Domains for SES

To use the SES email integration, you need a domain managed by Route 53. Here's how to find available domains:

### List All Hosted Zones (AWS CLI)

```bash
# List all hosted zones in your account
aws route53 list-hosted-zones \
  --query 'HostedZones[*].[Name,Id,Config.PrivateZone]' \
  --output table
```

**Example output:**
```
---------------------------------------------------
|          ListHostedZones                         |
+------------------+-----------------+-----------+
|  example.com.    |  Z1234567890ABC |  False    |
|  staging.example.com. | Z0987654321DEF |  False    |
|  internal.corp.  |  Z111222333444  |  True     |
+------------------+-----------------+-----------+
```

- **Name** = hosted zone name (use this for `route53_hosted_zone_name` in tfvars)
- **Id** = hosted zone ID (e.g., `Z1234567890ABC`)
- **PrivateZone** = `False` means public domain (required for SES), `True` = private/internal

### Find a Specific Domain

```bash
# Search for a specific domain
aws route53 list-hosted-zones-by-name \
  --dns-name "example.com" \
  --query 'HostedZones[0].[Name,Id]' \
  --output text
```

### List All Record Sets in a Zone (to check existing subdomains)

```bash
# Replace Z1234567890ABC with your hosted zone ID
aws route53 list-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --query 'ResourceRecordSets[?Type==`A` || Type==`CNAME`].{Name:Name,Type:Type,Value:ResourceRecords[0].Value}' \
  --output table
```

### Use a Subdomain for Hermes (Recommended)

Instead of using your root domain (`example.com`), create a dedicated subdomain for Hermes:

```bash
# 1. Get your hosted zone ID
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "example.com" --query 'HostedZones[0].Id' --output text | cut -d'/' -f3)

# 2. Create NS record delegating hermes.example.com to SES (optional, or just use as subdomain)
# Actually for SES you can just use the subdomain directly with the parent zone
```

**In your `terraform.tfvars`:**
```hcl
# Use subdomain (recommended)
ses_domain              = "hermes.example.com"
route53_hosted_zone_name = "example.com."      # Parent zone with trailing dot

# OR use root domain
ses_domain              = "example.com"
route53_hosted_zone_name = "example.com."      # With trailing dot
```

### Verify Domain Ownership

Before deploying, confirm you own the domain and it's in Route 53:

```bash
# Check domain registration status (if registered via Route 53)
aws route53domains list-domains --query 'Domains[*].[DomainName,AutoRenew,Expiry]' --output table

# Or just verify the hosted zone exists
aws route53 get-hosted-zone --id Z1234567890ABC
```

### Required DNS Records (Created Automatically by Terraform)

When you deploy with `enable_email_processing = true`, Terraform creates these records in **your existing hosted zone**:

| Record | Purpose |
|--------|---------|
| `MX @` | Routes incoming email to SES (`inbound-smtp.us-east-1.amazonaws.com`) |
| `TXT _amazonses` | Domain ownership verification token |
| `CNAME <dkim-token-1>._domainkey` | DKIM signing (3 records) |
| `TXT @` | SPF record (`v=spf1 include:amazonses.com ~all`) |
| `TXT _dmarc` | DMARC policy (`v=DMARC1; p=quarantine; rua=mailto:dmarc@...`) |

### Troubleshooting

**Domain not showing in list?**
- Ensure you're in the correct AWS account/region
- Check if domain is registered with a different registrar (not Route 53) — you can still use it but must manage DNS manually
- Private hosted zones (`PrivateZone=true`) cannot be used for SES email receiving

**Want to use a domain registered elsewhere?**
- Point your registrar's nameservers to Route 53, OR
- Manually create the above DNS records at your registrar

## Teardown

```sh
terraform destroy
```
