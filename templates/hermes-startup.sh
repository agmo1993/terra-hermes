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
# The startup script just uses them directly — no case statement needed.
: "${PROVIDER_KEY_ENV_VAR:?PROVIDER_KEY_ENV_VAR must be set}"
: "${PROVIDER_BASE_ENV_VAR:?PROVIDER_BASE_ENV_VAR must be set}"
: "${MODEL_BASE_URL:?MODEL_BASE_URL must be set}"
BASE_URL="$MODEL_BASE_URL"

# --- Install OS dependencies (detect apt vs dnf/yum) -------------------------
log "installing OS dependencies"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates git
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl ca-certificates git
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl ca-certificates git
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

# --- Optional: install and configure AgentMail (MCP + Python SDK + inbox) ------
# When AGENTMAIL_API_KEY is set (non-empty), the startup script:
#   1. Installs the AgentMail Python SDK (pip3 install agentmail)
#   2. Writes AGENTMAIL_API_KEY to ~/.hermes/.env
#   3. Adds the AgentMail MCP server to the Hermes config (via hermes config)
#   4. Creates a default inbox (using AGENTMAIL_INBOX_DISPLAY_NAME)
# When empty, this entire block is skipped — no AgentMail on the VM.
#
# SECURITY: same caveats as other secrets — the key is in user_data which
# Terraform stores in state and EC2 exposes via IMDS. Harden by fetching
# from SSM Parameter Store / Secrets Manager instead (see top-of-file note).
if [[ -n "${AGENTMAIL_API_KEY:-}" ]]; then
 log "installing AgentMail Python SDK"
 run_as_hermes "pip3 install agentmail 2>&1 | tail -1"

 # The AGENTMAIL_API_KEY will be written to .env below (in the
 # ~/.hermes/.env write block), alongside the other secrets.

 # Add the AgentMail MCP server to Hermes config using Python (yaml
 # safe-load/dump to merge into the existing config.yaml without
 # clobbering any other MCP servers the user may have added).
 log "configuring AgentMail MCP server in Hermes config"
 run_as_hermes "python3 -c '
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

 # Create a default inbox using the Python SDK.
 AGENTMAIL_INBOX_DISPLAY_NAME="${AGENTMAIL_INBOX_DISPLAY_NAME:-hermes-agent}"
 log "creating AgentMail inbox (display_name=$AGENTMAIL_INBOX_DISPLAY_NAME)"
 INBOX_JSON=$(run_as_hermes "python3 -c '
import json, sys, os
from agentmail import AgentMail
client = AgentMail()
existing = client.inboxes.list()
if existing.inboxes and len(existing.inboxes) > 0:
    inbox = existing.inboxes[0]
    print(json.dumps({\"email\": inbox.email, \"display_name\": inbox.display_name, \"existing\": True}))
    sys.exit(0)
inbox = client.inboxes.create(request={\"display_name\": \"'\"$AGENTMAIL_INBOX_DISPLAY_NAME\"'\"})
print(json.dumps({\"email\": inbox.email, \"display_name\": inbox.display_name, \"existing\": False}))
'")
 log "AgentMail inbox ready: $INBOX_JSON"
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
log "configuring Hermes model provider/default"
run_as_hermes "hermes config set model.provider '$MODEL_PROVIDER'"
run_as_hermes "hermes config set model.default '$MODEL_NAME'"
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

log "Hermes bootstrap complete"
