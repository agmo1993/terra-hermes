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
# Hermes resolves the endpoint from a per-provider <PROVIDER>_BASE_URL env var,
# which "always wins" over the built-in default. We write it into .env so the
# agent always talks to the right endpoint (e.g. NVIDIA NIM instead of the
# global OpenRouter fallback). DEFAULT_BASE_URL values are the providers'
# registry defaults; override per-deploy with var.provider_base_url.
case "$MODEL_PROVIDER" in
  openrouter)
    PROVIDER_KEY_VAR="OPENROUTER_API_KEY"; PROVIDER_BASE_URL_VAR="OPENROUTER_BASE_URL"
    DEFAULT_BASE_URL="https://openrouter.ai/api/v1" ;;
  anthropic)
    PROVIDER_KEY_VAR="ANTHROPIC_API_KEY"; PROVIDER_BASE_URL_VAR="ANTHROPIC_BASE_URL"
    DEFAULT_BASE_URL="https://api.anthropic.com" ;;
  openai)
    PROVIDER_KEY_VAR="OPENAI_API_KEY"; PROVIDER_BASE_URL_VAR="OPENAI_BASE_URL"
    DEFAULT_BASE_URL="https://api.openai.com/v1" ;;
  nvidia)
    PROVIDER_KEY_VAR="NVIDIA_API_KEY"; PROVIDER_BASE_URL_VAR="NVIDIA_BASE_URL"
    DEFAULT_BASE_URL="https://integrate.api.nvidia.com/v1" ;;
  *) log "ERROR: unsupported MODEL_PROVIDER='$MODEL_PROVIDER'"; exit 1 ;;
esac

# Optional Terraform override (MODEL_BASE_URL); otherwise the provider default.
BASE_URL="${MODEL_BASE_URL:-$DEFAULT_BASE_URL}"

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

# --- Write ~/.hermes/.env (chmod 600, owned by the hermes user) --------------
log "writing $HERMES_HOME/.hermes/.env"
install -d -m 700 -o "$HERMES_USER" -g "$HERMES_USER" "$HERMES_HOME/.hermes"
umask 077
cat >"$HERMES_HOME/.hermes/.env" <<EOF
$PROVIDER_KEY_VAR=$PROVIDER_API_KEY
$PROVIDER_BASE_URL_VAR=$BASE_URL
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALLOWED_USERS=$TELEGRAM_ALLOWED_USERS
EOF
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
