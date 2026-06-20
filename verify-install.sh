#!/usr/bin/env bash
# =============================================================================
# verify-install.sh — check that the Hermes VM bootstrapped correctly.
#
# Runs the README "Verify the installation via SSM" checks remotely and
# NON-interactively via `aws ssm send-command`, then prints a PASS/FAIL report.
# No SSH key needed — uses the same SSM access the deploy relies on.
#
# Usage:
#   source ./secrets.sh         # for AWS credentials
#   ./verify-install.sh         # auto-discovers instance + region from tfstate
#
# Overrides (optional):
#   INSTANCE_ID=i-0123... REGION=us-east-1 ./verify-install.sh
#
# Prereqs: terraform, aws CLI. (The Session Manager plugin is NOT required —
# send-command does not open a session.)
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")"

# --- Resolve instance + region (CLI env overrides, else Terraform outputs) ----
INSTANCE_ID="${INSTANCE_ID:-$(terraform output -raw instance_id 2>/dev/null)}"
if [[ -z "${INSTANCE_ID:-}" ]]; then
  echo "ERROR: could not determine INSTANCE_ID (set it explicitly or run from the terraform dir)" >&2
  exit 1
fi
# The ssm_session_command output embeds the region: "... --region <region>".
SESSION_CMD="$(terraform output -raw ssm_session_command 2>/dev/null || true)"
REGION="${REGION:-$(sed -n 's/.*--region \([^ ]*\).*/\1/p' <<<"$SESSION_CMD")}"
REGION="${REGION:-us-east-1}"

echo "Instance : $INSTANCE_ID"
echo "Region   : $REGION"
echo

# --- Wait until the instance is registered + Online in SSM --------------------
echo "Waiting for the instance to be Online in SSM..."
for _ in $(seq 1 30); do
  ping="$(aws ssm describe-instance-information \
            --region "$REGION" \
            --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text 2>/dev/null || true)"
  [[ "$ping" == "Online" ]] && break
  sleep 10
done
if [[ "${ping:-}" != "Online" ]]; then
  echo "ERROR: instance never reported Online in SSM (PingStatus=${ping:-none})." >&2
  echo "       Give it a minute or two after 'terraform apply' and retry." >&2
  exit 1
fi
echo "SSM: Online"
echo

# --- The checks that run ON the VM (as root, via send-command) ----------------
# Heredoc is quoted so nothing expands locally; it is base64'd and piped to bash
# on the box to avoid all the SSM parameter-quoting pitfalls.
read -r -d '' REMOTE_SCRIPT <<'REMOTE'
set -uo pipefail
HERMES_USER="hermes"
ENV_FILE="/home/$HERMES_USER/.hermes/.env"
CFG_FILE="/home/$HERMES_USER/.hermes/config.yaml"
fail=0
pass(){ echo "  PASS: $*"; }
bad(){  echo "  FAIL: $*"; fail=1; }
info(){ echo "  INFO: $*"; }

# Run a command as the hermes user with the per-user systemd bus reachable.
as_hermes(){ sudo -u "$HERMES_USER" -H bash -lc "export XDG_RUNTIME_DIR=/run/user/\$(id -u $HERMES_USER); $*"; }

echo "== 1. cloud-init / bootstrap =="
ci="$(cloud-init status 2>/dev/null || true)"
echo "  cloud-init: ${ci:-unknown}"
if grep -q '\[hermes-startup\] Hermes bootstrap complete' /var/log/cloud-init-output.log 2>/dev/null; then
  pass "bootstrap reached 'Hermes bootstrap complete'"
else
  bad "bootstrap-complete marker missing — last [hermes-startup] lines:"
  grep '\[hermes-startup\]' /var/log/cloud-init-output.log 2>/dev/null | tail -n 12 | sed 's/^/    /'
fi

echo "== 2. CLI / config / secrets =="
if v="$(as_hermes 'hermes --version' 2>&1)"; then pass "hermes CLI: $v"; else bad "hermes --version failed: $v"; fi
if [[ -f "$ENV_FILE" ]]; then
  perm="$(stat -c '%a %U:%G' "$ENV_FILE")"
  [[ "${perm%% *}" == "600" ]] && pass ".env present ($perm)" || bad ".env present but perms not 600 ($perm)"
else
  bad ".env missing ($ENV_FILE)"
fi
if out="$(as_hermes 'hermes config check' 2>&1)"; then pass "hermes config check OK"; else bad "hermes config check failed:"; echo "$out" | sed 's/^/    /'; fi

echo "== 3. Telegram gateway =="
gw="$(as_hermes "systemctl --user status 'hermes*' --no-pager" 2>&1)"
if grep -q 'active (running)' <<<"$gw"; then
  pass "gateway active (running)"
else
  bad "gateway not running:"
  echo "$gw" | head -n 15 | sed 's/^/    /'
fi

echo "== 4. Model configuration & inference =="
# Read back what the bootstrap set with `hermes config set model.{provider,default}`.
# There is no `hermes config get`, so read config.yaml directly (yaml.safe_load).
readcfg(){ as_hermes "python3 -c 'import yaml,os; c=yaml.safe_load(open(os.path.expanduser(\"~/.hermes/config.yaml\"))) or {}; print((c.get(\"model\") or {}).get(\"$1\",\"\"))'" 2>/dev/null | tr -d '[:space:]'; }
prov="$(readcfg provider)"
mdl="$(readcfg default)"
url="$(readcfg base_url)"
[[ -n "$prov" ]] && pass "model.provider = $prov" || bad "model.provider not set in config.yaml"
[[ -n "$mdl"  ]] && pass "model.default = $mdl"   || bad "model.default not set in config.yaml"
[[ -n "$url"  ]] && info "model.base_url = $url"
# One-shot inference: ask for a fixed sentinel and confirm it comes back. This
# actually calls the provider API, so it validates the key + base URL end-to-end.
# (Flag `hermes -q '<prompt>'` per the Hermes docs; adjust if your build differs.)
info "running a one-shot inference (calls the provider API; may take ~30s)..."
ans="$(as_hermes "hermes -q 'Reply with exactly the word PONG and nothing else.'" 2>&1)"
if grep -qi 'PONG' <<<"$ans"; then
  pass "inference OK — model returned a response"
else
  bad "inference did not return the expected response:"
  echo "$ans" | tail -n 15 | sed 's/^/    /'
fi

echo "== 5. AgentMail (optional) =="
if grep -q '^AGENTMAIL_API_KEY=' "$ENV_FILE" 2>/dev/null; then
  info "AGENTMAIL_API_KEY present in .env"
  as_hermes "python3 -c 'import yaml,os; c=yaml.safe_load(open(os.path.expanduser(\"~/.hermes/config.yaml\"))) or {}; print(\"  \"+(\"PASS: agentmail MCP server in config.yaml\" if \"agentmail\" in (c.get(\"mcp_servers\") or {}) else \"FAIL: agentmail MCP server NOT in config.yaml\"))'" 2>&1
  if as_hermes 'pip3 show agentmail >/dev/null 2>&1'; then pass "agentmail Python SDK installed"; else info "agentmail Python SDK not installed (only needed for boot-time inbox/email)"; fi
else
  info "not configured — skipped"
fi

echo "== 6. GitHub (optional) =="
if grep -q '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null; then
  st="$(as_hermes 'gh auth status' 2>&1 | head -n 3)"
  grep -q 'Logged in' <<<"$st" && pass "gh authenticated" || { bad "gh not authenticated:"; echo "$st" | sed 's/^/    /'; }
else
  info "not configured — skipped"
fi

echo
[[ $fail -eq 0 ]] && echo "RESULT: all required checks PASSED" || echo "RESULT: one or more required checks FAILED"
exit $fail
REMOTE

B64="$(base64 -w0 <<<"$REMOTE_SCRIPT")"

# --- Dispatch the command and wait for it to finish ---------------------------
echo "Running verification checks on the VM..."
CID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "hermes install verification" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d | bash\"]}" \
  --query 'Command.CommandId' --output text)"
if [[ -z "${CID:-}" ]]; then
  echo "ERROR: failed to dispatch SSM command." >&2
  exit 1
fi

# Poll until the invocation reaches a terminal state (allow ~5 min for the
# inference round-trip on top of the other checks).
status="Pending"
for _ in $(seq 1 100); do
  status="$(aws ssm get-command-invocation \
              --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" \
              --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$status" in Success|Failed|Cancelled|TimedOut) break;; esac
  sleep 3
done

echo
echo "================= verification output ================="
aws ssm get-command-invocation \
  --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text
err="$(aws ssm get-command-invocation \
        --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" \
        --query 'StandardErrorContent' --output text 2>/dev/null || true)"
[[ -n "${err// /}" && "$err" != "None" ]] && { echo "----- stderr -----"; echo "$err"; }
echo "======================================================="
echo "SSM command status: $status"

# Exit non-zero if the remote checks failed (or the command itself did).
[[ "$status" == "Success" ]] || exit 1
