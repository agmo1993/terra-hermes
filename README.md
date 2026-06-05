# terra-hermes

Quick Terraform to deploy a single EC2 instance running the **hermes agent**.

It provisions:

- One `t3.medium` **Ubuntu 24.04 LTS** (amd64) instance in the default VPC
- The **Hermes Agent**, installed at first boot as a dedicated non-root user
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
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"                        # optional; matches var.region

# Hermes secrets (consumed as Terraform variables)
export TF_VAR_provider_api_key="nvapi-..."           # key for your model_provider
export TF_VAR_telegram_bot_token="123456789:ABC..."  # from @BotFather

# Optional: keep this here too instead of in terraform.tfvars
export TF_VAR_telegram_allowed_users="123456789,987654321"
```

- The IAM user behind those keys needs permissions for EC2, IAM (role +
  instance profile), and security groups, plus `ssm:StartSession` to connect.
  Prefer an IAM user over root keys.
- Keep it out of git — this repo already ignores `secrets.sh` — and
  `chmod 600 secrets.sh`.
- `source` it in the same shell before any Terraform/AWS command:

  ```sh
  cp secrets.sh.example secrets.sh   # then edit in your values
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
   # edit terraform.tfvars: model_provider, model_name, telegram_allowed_users, ...

   source ./secrets.sh   # AWS keys + TF_VAR_provider_api_key + TF_VAR_telegram_bot_token
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
   cloud-init status --long                          # want: status: done
   sudo grep '\[hermes-startup\]' /var/log/cloud-init-output.log
   ```

   The last marker should read `[hermes-startup] Hermes bootstrap complete`. If
   not, the step after the final marker is where it failed.

3. **Confirm the CLI, config, and endpoint:**

   ```sh
   sudo -u hermes -H bash -lc 'hermes --version'      # CLI installed
   sudo ls -l /home/hermes/.hermes/.env               # secrets file (600, hermes-owned)
   sudo -u hermes -H bash -lc 'hermes config check'   # provider + API key + base URL reachable
   ```

4. **Confirm the Telegram gateway is running** (persistent per-user service):

   ```sh
   sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) \
     systemctl --user status 'hermes*'                # want: active (running)
   # live logs:
   sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) \
     journalctl --user -u 'hermes*' -f
   ```

5. **End-to-end:** message the bot from a Telegram account whose numeric ID is in
   `telegram_allowed_users`. A reply confirms the full chain. "Online but silent"
   almost always means your ID isn't in that list.

## Configuration

| Variable                 | Default                     | Description                                              |
| ------------------------ | --------------------------- | ------------------------------------------------------- |
| `provider_api_key`       | _(required, sensitive)_     | API key for the chosen `model_provider`                 |
| `telegram_bot_token`     | _(required, sensitive)_     | Telegram bot token (one running gateway per token)      |
| `telegram_allowed_users` | _(required)_                | Comma-separated NUMERIC Telegram user IDs (mandatory)   |
| `model_provider`         | `openrouter`                | `openrouter` \| `anthropic` \| `openai`                 |
| `model_name`             | `anthropic/claude-opus-4`   | Default model identifier                                |
| `hermes_user`            | `hermes`                    | Dedicated non-root user that runs Hermes                |
| `hermes_install_command` | Hermes `install.sh` via curl | Command (run as `hermes_user`) to install the CLI      |
| `region`                 | `us-east-1`                 | AWS region                                              |
| `instance_type`          | `t3.medium`                 | EC2 instance type                                       |
| `availability_zone`      | `us-east-1d`                | AZ to place the instance in (empty = first subnet)      |
| `name`                   | `hermes`                    | Base name for the instance and related resources        |
| `root_volume_size` | `20` | Root gp3 volume size (GiB) |
| `allowed_ports` | `[3000, 4000, 5000, 5173, 8000, 8080, 8443, 8888]` | Inbound TCP ports open for web prototyping (set `[]` for egress-only) |
| `tags` | `{Project=…}` | Tags applied to all resources |

## Teardown

```sh
terraform destroy
```
