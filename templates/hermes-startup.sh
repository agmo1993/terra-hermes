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

# --- Install email webhook skill (if email processing enabled) -----------------
if [[ -n "${HERMES_WEBHOOK_SECRET:-}" ]]; then
  log "installing Hermes email webhook skill"
  run_as_hermes "
    mkdir -p ~/.hermes/skills/hermes-email-webhook
    cat > ~/.hermes/skills/hermes-email-webhook/skill.py <<'PYEOF'
# ~/.hermes/skills/hermes-email-webhook/skill.py
# Hermes skill: HTTP webhook for receiving emails from AWS Lambda
from aiohttp import web
import asyncio
import json
import hmac
import hashlib
import os
import subprocess

WEBHOOK_SECRET=os.environ.get('HERMES_WEBHOOK_SECRET', '')

async def verify_request(request):
    if not WEBHOOK_SECRET:
        return True
    sig = request.headers.get('X-Hermes-Signature', '')
    body = await request.read()
    expected = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig)

async def email_webhook(request):
    if not await verify_request(request):
        return web.Response(status=401, text='Invalid signature')

    data = await request.json()

    if data.get('type') == 'email_received':
        email_data = data['email']
        receipt = data.get('receipt', {})

        print(f'📧 [webhook] Email from {email_data[\"from\"]}: {email_data[\"subject\"]}')
        print(f'   Spam: {receipt.get(\"spam\")}, Virus: {receipt.get(\"virus\")}')

        # Store in Hermes memory for later queries
        memory_entry = {
            'type': 'email',
            'message_id': email_data['message_id'],
            'from': email_data['from'],
            'to': email_data['to'],
            'subject': email_data['subject'],
            'body': email_data['text_body'][:5000],
            'received_at': email_data['received_at'],
            'spam': receipt.get('spam'),
            'virus': receipt.get('virus')
        }

        # Write to a JSONL file the agent can read
        with open(os.path.expanduser('~/.hermes/emails.jsonl'), 'a') as f:
            f.write(json.dumps(memory_entry) + '\\n')

        # Notify via Telegram if user is allowed
        allowed_users = os.environ.get('TELEGRAM_ALLOWED_USERS', '').split(',')
        bot_token = os.environ.get('TELEGRAM_BOT_TOKEN', '')
        for user_id in allowed_users:
            if user_id and bot_token:
                try:
                    subprocess.run([
                        'curl', '-s', '-X', 'POST',
                        f'https://api.telegram.org/bot{bot_token}/sendMessage',
                        '-d', f'chat_id={user_id}',
                        '-d', f'text=📧 New email from {email_data[\"from\"]}: {email_data[\"subject\"][:100]}'
                    ], timeout=5)
                except Exception:
                    pass

    return web.json_response({'status': 'ok', 'received': True})

async def health_check(request):
    return web.json_response({'status': 'healthy', 'service': 'hermes-email-webhook'})

async def start_webhook_server():
    app = web.Application()
    app.router.add_post('/webhook/email', email_webhook)
    app.router.add_get('/health', health_check)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, '0.0.0.0', 8000)
    await site.start()
    print('🌐 Hermes email webhook listening on 0.0.0.0:8000')
    return runner

# Auto-start when module loads
if __name__ != '__main__':
    import sys
    if 'run_as_hermes' in sys.modules:
        asyncio.create_task(start_webhook_server())
else:
    asyncio.run(start_webhook_server())
PYEOF
  "

  # Install aiohttp for the webhook
  run_as_hermes "~/.local/bin/pip install aiohttp --quiet"

  log "email webhook skill installed"
fi

log "Hermes bootstrap complete"
