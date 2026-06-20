# =============================================================================
# Hermes Agent bootstrap — appended to the EC2 user_data and run on first boot.
#
# This script reads ALL configuration from the ENVIRONMENT. Terraform prepends
# an `export` block (built from variables in main.tf) ahead of this file, so do
# NOT hard-code any config or secrets here.
#
# SECURITY NOTE: the exported values become part of the rendered user_data,
# which Terraform persists in STATE and EC2 exposes via the Instance Metadata
# Service. The hardened alternative is to store provider_api_key and
# telegram_bot_token in AWS SSM Parameter Store / Secrets Manager and grant the
# instance an IAM role to fetch them here at boot, instead of passing them as
# Terraform variables. We implement the variable-based approach for now.
#
# UNVERIFIED: the `hermes` binary path (~/.local/bin), the config key names
# (model.provider / model.default) and the gateway subcommands below come from
# the Hermes docs and are NOT verified against a pinned release. Confirm with
# `hermes config --help` and `hermes gateway --help` before relying on them.
# =============================================================================

set -euo pipefail

log() { echo "[hermes-startup] $*"; }

# --- Validate required configuration -----------------------------------------
: "${HERMES_USER:?HERMES_USER must be set}"
: "${MODEL_PROVIDER:?MODEL_PROVIDER must be set}"
: "${MODEL_NAME:?MODEL_NAME must be set}"
: "${PROVIDER_API_KEY:?PROVIDER_API_KEY must be set}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN must be set}"

# TELEGRAM_ALLOWED_USERS is MANDATORY: an empty value makes the gateway deny
# every user by default, which presents as "bot online but silent".
if [[ -z "${TELEGRAM_ALLOWED_USERS:-}" ]]; then
  log "ERROR: TELEGRAM_ALLOWED_USERS is empty — the gateway would deny all users. Aborting."
  exit 1
fi

HERMES_INSTALL_COMMAND="${HERMES_INSTALL_COMMAND:-curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash}"

# --- Map the provider to its API-key + base-URL env var names and default ----
# Terraform pre-resolves these from the provider catalogue in providers.tf and
# passes them as PROVIDER_KEY_ENV_VAR / PROVIDER_BASE_ENV_VAR / MODEL_BASE_URL.
# NOTE: Hermes does not read per-provider base-URL env vars (NVIDIA_BASE_URL etc.),
# so MODEL_BASE_URL is applied authoritatively via `hermes config set model.base_url`
# further below; the PROVIDER_BASE_ENV_VAR line in .env is kept only for
# OPENAI_BASE_URL-style compatibility and is otherwise inert.
: "${PROVIDER_KEY_ENV_VAR:?PROVIDER_KEY_ENV_VAR must be set}"
: "${PROVIDER_BASE_ENV_VAR:?PROVIDER_BASE_ENV_VAR must be set}"
: "${MODEL_BASE_URL:?MODEL_BASE_URL must be set}"
BASE_URL="$MODEL_BASE_URL"

# --- Install OS dependencies (detect apt vs dnf/yum) -------------------------
log "installing OS dependencies"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates git python3 python3-pip python3-yaml nodejs npm
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl ca-certificates git python3 python3-pip python3-pyyaml nodejs npm
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl ca-certificates git python3 python3-pip python3-pyyaml nodejs npm
else
  log "ERROR: no supported package manager (apt/dnf/yum) found"; exit 1
fi

# --- Create the dedicated non-root hermes user if missing --------------------
if ! id -u "$HERMES_USER" >/dev/null 2>&1; then
  log "creating user $HERMES_USER"
  useradd --create-home --shell /bin/bash "$HERMES_USER"
fi
HERMES_HOME="$(getent passwd "$HERMES_USER" | cut -d: -f6)"
HERMES_UID="$(id -u "$HERMES_USER")"

# Enable lingering so the user's systemd instance runs without an active login.
# Required for the `systemctl --user` gateway service to start at boot and
# survive reboots. Also make sure the user manager + runtime dir are up before
# we try to talk to it.
log "enabling linger for $HERMES_USER"
loginctl enable-linger "$HERMES_USER"
systemctl start "user@$HERMES_UID.service" || true
for _ in $(seq 1 30); do
  [[ -d "/run/user/$HERMES_UID" ]] && break
  sleep 1
done

# Run a command as the hermes user in a login shell, with ~/.local/bin on PATH,
# the per-user systemd bus reachable, and ~/.hermes/.env loaded if present.
run_as_hermes() {
  sudo -u "$HERMES_USER" -H bash -lc "
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    export XDG_RUNTIME_DIR=\"/run/user/$HERMES_UID\"
    if [ -f \"\$HOME/.hermes/.env\" ]; then set -a; . \"\$HOME/.hermes/.env\"; set +a; fi
    $*
  "
}

# --- Install the Hermes CLI as the hermes user (NEVER as root) ----------------
log "installing Hermes CLI as $HERMES_USER"
run_as_hermes "$HERMES_INSTALL_COMMAND"

# --- Optional: authenticate the GitHub CLI with the provided PAT ---------------
# When GITHUB_TOKEN is set (non-empty), install the gh CLI, authenticate it,
# and configure git credential-helper so the Hermes agent can push/open PRs.
# When empty, this entire block is skipped — no GitHub auth on the VM.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
 log "installing GitHub CLI (gh)"
 GH_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | sed 's|.*/v||')
 curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 -o /tmp/gh.tar.gz
 tar -xzf /tmp/gh.tar.gz -C /tmp
 cp "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" "$HERMES_HOME/.local/bin/gh"
 rm -rf "/tmp/gh_${GH_VERSION}_linux_amd64" /tmp/gh.tar.gz

 log "authenticating gh CLI as $HERMES_USER"
 run_as_hermes "echo '$GITHUB_TOKEN' | gh auth login --with-token"
 run_as_hermes "gh auth setup-git"

 # Also write GITHUB_TOKEN into .env so the Hermes agent can use it
 # (e.g. for the xurl toolset or direct API calls).
 log "GITHUB_TOKEN written to .env (see below)"
else
 log "GITHUB_TOKEN not set — skipping GitHub CLI auth"
fi

# --- Optional: install and configure AgentMail (CLI + MCP server + inbox) ------
# Follows the official AgentMail + Hermes guide:
#   https://www.agentmail.to/blog/hermes-agent-email-inbox
# When AGENTMAIL_API_KEY is set (non-empty), the startup script:
#   1. Installs the AgentMail CLI (npm install -g agentmail-cli)
#   2. Registers the AgentMail MCP server in the Hermes config
#   3. Creates a default inbox via the CLI (AGENTMAIL_INBOX_DISPLAY_NAME)
#   4. Writes AGENTMAIL_API_KEY to ~/.hermes/.env (below)
# The deploy-notification email is NOT sent from here. Once the gateway is up we
# prompt the Hermes agent to send it through its AgentMail MCP tools (see the
# notification section at the end). When empty, this block is skipped entirely.
#
# SECURITY: same caveats as other secrets — the key is in user_data which
# Terraform stores in state and EC2 exposes via IMDS. Harden by fetching
# from SSM Parameter Store / Secrets Manager instead (see top-of-file note).
if [[ -n "${AGENTMAIL_API_KEY:-}" ]]; then
 # Install the CLI globally as root so the `agentmail` binary lands on the
 # system PATH. A `npm install -g` as the hermes user would fail without a
 # user-writable npm prefix; installed system-wide it is still runnable by the
 # hermes user below (and by the agent at runtime).
 log "installing AgentMail CLI (agentmail-cli)"
 npm install -g agentmail-cli

 # Register the AgentMail MCP server in Hermes config. We merge into the
 # existing config.yaml with a yaml safe-load/dump so we don't clobber any
 # other MCP servers — this is the programmatic equivalent of the
 # `mcp_servers:` block the guide has you hand-add to config.yaml.
 log "configuring AgentMail MCP server in Hermes config"
 run_as_hermes "AGENTMAIL_API_KEY='$AGENTMAIL_API_KEY' python3 -c '
import yaml, os
cfg_path = os.path.expanduser(\"~/.hermes/config.yaml\")
with open(cfg_path, \"r\") as f:
    cfg = yaml.safe_load(f) or {}
mcp = cfg.get(\"mcp_servers\", {})
mcp[\"agentmail\"] = {
    \"command\": \"npx\",
    \"args\": [\"-y\", \"agentmail-mcp\"],
    \"env\": {\"AGENTMAIL_API_KEY\": os.environ[\"AGENTMAIL_API_KEY\"]},
}
cfg[\"mcp_servers\"] = mcp
with open(cfg_path, \"w\") as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
print(\"OK\")
'"

 # Create a default inbox via the CLI (guide step). The CLI reads
 # AGENTMAIL_API_KEY from the environment. Non-fatal: if this fails the agent
 # can still create its own inbox on demand via its MCP tools when it sends
 # the deploy email below.
 AGENTMAIL_INBOX_DISPLAY_NAME="${AGENTMAIL_INBOX_DISPLAY_NAME:-hermes-agent}"
 log "creating AgentMail inbox (display_name=$AGENTMAIL_INBOX_DISPLAY_NAME)"
 run_as_hermes "AGENTMAIL_API_KEY='$AGENTMAIL_API_KEY' agentmail inboxes create --display-name '$AGENTMAIL_INBOX_DISPLAY_NAME'" \
   || log "AgentMail inbox create failed (continuing; agent can create one on demand)"
 log "AGENTMAIL_API_KEY written to .env (see below)"
else
 log "AGENTMAIL_API_KEY not set — skipping AgentMail setup"
fi

# --- Write ~/.hermes/.env (chmod 600, owned by the hermes user) --------------
log "writing $HERMES_HOME/.hermes/.env"
install -d -m 700 -o "$HERMES_USER" -g "$HERMES_USER" "$HERMES_HOME/.hermes"
umask 077
{
cat <<EOF
$PROVIDER_KEY_ENV_VAR=$PROVIDER_API_KEY
$PROVIDER_BASE_ENV_VAR=$BASE_URL
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALLOWED_USERS=$TELEGRAM_ALLOWED_USERS
EOF
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
 echo "GITHUB_TOKEN=$GITHUB_TOKEN"
fi
if [[ -n "${AGENTMAIL_API_KEY:-}" ]]; then
 echo "AGENTMAIL_API_KEY=$AGENTMAIL_API_KEY"
fi
} >"$HERMES_HOME/.hermes/.env"
chown "$HERMES_USER:$HERMES_USER" "$HERMES_HOME/.hermes/.env"
chmod 600 "$HERMES_HOME/.hermes/.env"

# --- Configure the model provider + default model ----------------------------
# Hermes does NOT read per-provider base-URL env vars (e.g. NVIDIA_BASE_URL); the
# only base-URL it honors from the environment is OPENAI_BASE_URL. To make every
# provider in the catalogue resolve to the right endpoint we set model.base_url
# explicitly in config — when base_url is set Hermes ignores the provider and
# calls that endpoint directly, authenticating with model.api_key. Without this,
# an unrecognized provider (e.g. nvidia) silently falls back to Hermes' default
# OpenRouter endpoint.
log "configuring Hermes model provider/default"
run_as_hermes "hermes config set model.provider '$MODEL_PROVIDER'"
run_as_hermes "hermes config set model.default '$MODEL_NAME'"
run_as_hermes "hermes config set model.base_url '$BASE_URL'"
run_as_hermes "hermes config set model.api_key '$PROVIDER_API_KEY'"
run_as_hermes "hermes config check"

# --- Install + start the Telegram gateway as a persistent user service -------
# Prefer the per-user service over `--system` so $HERMES_HOME stays owned by the
# hermes user (running the gateway as root leaves root-owned files in
# $HERMES_HOME and breaks later runs).
# `hermes gateway install` is interactive on Linux/systemd: it always asks
# "Start the gateway now?" and "Start on login/boot?" via input(), and the hidden
# --start-now/--start-on-login flags are only honored on Windows. Under cloud-init
# there is no readable stdin, so the prompts abort the script. Feed "y" to both
# (the order is: start-now, then start-on-login). Answering yes installs the
# per-user service, enables it on boot (linger is set above), and starts it now —
# so no separate `hermes gateway start` is needed.
log "installing and starting the Hermes gateway"
run_as_hermes "printf 'y\ny\n' | hermes gateway install"

# Show the resulting service state in the boot log for easy verification.
run_as_hermes "hermes gateway status" || true

# --- Notify that the agent is deployed and online ----------------------------
# By this point bootstrap has succeeded, so a notification failure must NEVER
# abort the script — every call below is individually guarded.
#   * Telegram: a "deployed" message to every allowed user ID (always attempted,
#     since the gateway/token are mandatory).
#   * AgentMail: an email to NOTIFICATION_EMAIL from the inbox created above
#     (only when AgentMail is configured and a notification email is set).
log "sending deployment notifications"

# Gather instance facts from IMDSv2 (http_tokens=required) for the message body.
IMDS_TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
imds() {
  curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo "unknown"
}
PUBLIC_IP="$(imds public-ipv4)"
INSTANCE_ID="$(imds instance-id)"

# Build the message body once (a plain-text file) and reuse it for both channels.
NOTIFY_FILE="/tmp/hermes-deploy-notify.txt"
{
  echo "✅ Hermes agent deployed and online"
  echo ""
  echo "Instance : $INSTANCE_ID"
  echo "Public IP: $PUBLIC_IP"
  echo "Provider : $MODEL_PROVIDER"
  echo "Model    : $MODEL_NAME"
} >"$NOTIFY_FILE"
chmod 644 "$NOTIFY_FILE"

# Telegram: message every allowed user ID. A bot can only message users who have
# already pressed Start in its chat, so failures for IDs that never did are
# expected — we log and move on rather than aborting.
IFS=',' read -ra _NOTIFY_UIDS <<< "$TELEGRAM_ALLOWED_USERS"
for _uid in "${_NOTIFY_UIDS[@]}"; do
  [[ -z "$_uid" ]] && continue
  if curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
       --data-urlencode "chat_id=${_uid}" \
       --data-urlencode "text@${NOTIFY_FILE}" >/dev/null 2>&1; then
    log "telegram deploy notice sent to $_uid"
  else
    log "telegram deploy notice FAILED for $_uid (has the user pressed Start in the bot?)"
  fi
done

# AgentMail: rather than calling the API directly, we prompt the Hermes agent
# itself to send the deploy email through its AgentMail MCP tools — exercising
# the same typed `send_message` tool the agent uses at runtime. `hermes chat -q`
# runs a single non-interactive turn with full tool access; `--yolo` skips the
# tool-approval prompts that would otherwise hang under cloud-init (no TTY).
#
# UNVERIFIED: the `hermes chat -q` / `--yolo` flags come from the Hermes CLI
# docs and are NOT verified against a pinned release. Confirm with
# `hermes chat --help` before relying on them.
if [[ -n "${AGENTMAIL_API_KEY:-}" && -n "${NOTIFICATION_EMAIL:-}" ]]; then
  log "prompting Hermes agent to send AgentMail deploy notice to $NOTIFICATION_EMAIL"
  AGENT_PROMPT="You have just been deployed as an autonomous agent on a cloud VM. \
Using your AgentMail email tools, send a short plain-text email letting the operator know you are online. \
Send it to ${NOTIFICATION_EMAIL}. \
Use the subject line: Hermes agent deployed. \
In the body, confirm the agent is deployed and online and include these facts: instance ${INSTANCE_ID}, public IP ${PUBLIC_IP}, provider ${MODEL_PROVIDER}, model ${MODEL_NAME}. \
If you do not have an inbox yet, create one first and send from it. Do not ask for confirmation — just send the email, then reply with the inbox address you sent from."
  run_as_hermes "hermes chat --yolo -q \"$AGENT_PROMPT\"" || log "AgentMail deploy notice FAILED"
elif [[ -n "${NOTIFICATION_EMAIL:-}" ]]; then
  log "NOTIFICATION_EMAIL set but AgentMail not configured (no API key) — skipping email notice"
fi

rm -f "$NOTIFY_FILE"

log "Hermes bootstrap complete"
