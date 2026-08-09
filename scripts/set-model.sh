#!/usr/bin/env bash
# =============================================================================
# set-model.sh — change the default model the Hermes agent uses.
#
# Runs `hermes config set model.default <model>` on the instance over SSM (the
# box has no SSH), verifies the config, and restarts the Telegram gateway so the
# change takes effect. Mirrors how templates/hermes-startup.sh configures Hermes.
#
# Usage:
#   scripts/set-model.sh <model_name>
#   scripts/set-model.sh <model_name> --provider <provider>
#   scripts/set-model.sh <model_name> --base-url <url>
#   scripts/set-model.sh <model_name> --no-restart
#
#   INSTANCE_ID=i-0abc REGION=us-east-1 scripts/set-model.sh <model_name>
#
# Examples:
#   scripts/set-model.sh anthropic/claude-sonnet-4
#   scripts/set-model.sh gpt-4.1 --provider openai
#   scripts/set-model.sh gemini-2.5-pro --provider gemini \
#     --base-url https://generativelanguage.googleapis.com/v1beta
#
# NOTE on --provider / --base-url: these set model.provider and model.base_url
# respectively. Switching providers also needs that provider's API key in
# ~/.hermes/.env, which this script does NOT touch — change
# model_provider/provider_api_key in Terraform and re-apply for a full provider
# switch. Use --provider/--base-url only when the target provider's key is
# already configured on the box. (Pass --base-url whenever you change providers:
# model.base_url does not auto-update with model.provider, so leaving it stale
# routes requests to the previous provider's endpoint.)
#
# Exit status: 0 on success, non-zero otherwise.
# Requires: terraform (optional, for auto-detect), aws CLI, jq.
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi
pass() { echo "  ${GREEN}✔${RESET} $*"; }
fail() { echo "  ${RED}✗${RESET} $*"; }
info() { echo "  ${BOLD}·${RESET} $*"; }
section() { echo; echo "${BOLD}$*${RESET}"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "${RED}error:${RESET} '$1' is required but not installed."; exit 2; }; }
need aws
need jq

# --- parse args --------------------------------------------------------------
MODEL=""
PROVIDER=""
BASE_URL=""
DO_RESTART=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --no-restart) DO_RESTART=0; shift ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "${RED}error:${RESET} unknown flag '$1'"; exit 2 ;;
    *) if [[ -z "$MODEL" ]]; then MODEL="$1"; else echo "${RED}error:${RESET} unexpected argument '$1'"; exit 2; fi; shift ;;
  esac
done

if [[ -z "$MODEL" ]]; then
  echo "${RED}error:${RESET} no model given."
  echo "usage: scripts/set-model.sh <model_name> [--provider <provider>] [--base-url <url>] [--no-restart]"
  exit 2
fi

# Validate against a conservative charset so the value is safe to single-quote
# into a remote shell command (model ids look like 'anthropic/claude-sonnet-4').
if ! [[ "$MODEL" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
  echo "${RED}error:${RESET} model '$MODEL' contains unexpected characters."
  exit 2
fi
if [[ -n "$PROVIDER" ]] && ! [[ "$PROVIDER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "${RED}error:${RESET} provider '$PROVIDER' contains unexpected characters."
  exit 2
fi
# Restrict to characters that appear in an https URL and are safe to
# single-quote into the remote shell command (no spaces, quotes, backticks, $).
# The pattern lives in a variable so its ';' etc. don't confuse [[ =~ ]] parsing.
URL_RE='^https?://[A-Za-z0-9._~:/?#@!*+,;=%-]+$'
if [[ -n "$BASE_URL" ]] && ! [[ "$BASE_URL" =~ $URL_RE ]]; then
  echo "${RED}error:${RESET} base-url '$BASE_URL' is not a valid http(s) URL."
  exit 2
fi

HERMES_USER="${HERMES_USER:-hermes}"

# --- resolve instance id + region --------------------------------------------
REGION="${REGION:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
if [[ -z "$INSTANCE_ID" || -z "$REGION" ]]; then
  if command -v terraform >/dev/null 2>&1 && [[ -f "$REPO_DIR/terraform.tfstate" ]]; then
    tf_out="$(cd "$REPO_DIR" && terraform output -json 2>/dev/null)"
    if [[ -n "$tf_out" && "$tf_out" != "{}" ]]; then
      [[ -z "$INSTANCE_ID" ]] && INSTANCE_ID="$(jq -r '.instance_id.value // empty' <<<"$tf_out")"
      [[ -z "$REGION" ]] && REGION="$(jq -r '.ssm_session_command.value // empty' <<<"$tf_out" | sed -n 's/.*--region \([^ ]*\).*/\1/p')"
    fi
  fi
fi
REGION="${REGION:-us-east-1}"
if [[ -z "$INSTANCE_ID" ]]; then
  echo "${RED}error:${RESET} could not determine instance id (set INSTANCE_ID=... or run 'terraform apply')."
  exit 1
fi

AWS=(aws --region "$REGION" --output json)

info "instance: ${INSTANCE_ID}   region: ${REGION}   user: ${HERMES_USER}"
info "target model: ${BOLD}${MODEL}${RESET}${PROVIDER:+   provider: ${BOLD}${PROVIDER}${RESET}}${BASE_URL:+   base_url: ${BOLD}${BASE_URL}${RESET}}"
[[ "$DO_RESTART" -eq 0 ]] && info "gateway restart: skipped (--no-restart)"

# --- SSM runner --------------------------------------------------------------
SSM_STATUS=""; SSM_STDERR=""
run_ssm() {
  local script="$1" cmd_id status params inv
  params="$(jq -Rn --arg s "$script" '{commands:[$s]}')"
  cmd_id="$("${AWS[@]}" ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "terra-hermes set-model" \
    --parameters "$params" 2>/dev/null | jq -r '.Command.CommandId // empty')"
  if [[ -z "$cmd_id" ]]; then SSM_STATUS="SendFailed"; return 1; fi

  for _ in $(seq 1 45); do
    status="$("${AWS[@]}" ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null | jq -r '.Status // "Pending"')"
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 2
  done
  inv="$("${AWS[@]}" ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null)"
  SSM_STATUS="$(jq -r '.Status // "Unknown"' <<<"$inv")"
  SSM_STDERR="$(jq -r '.StandardErrorContent // ""' <<<"$inv")"
  jq -r '.StandardOutputContent // ""' <<<"$inv"
}

# --- build remote script -----------------------------------------------------
# Unquoted heredoc: ${MODEL}/${PROVIDER}/${HERMES_USER}/${DO_RESTART} expand
# here; \$ escapes vars evaluated on the box. POSIX-sh clean (SSM uses /bin/sh).
# run_as_hermes deliberately does NOT source .env — none of these commands need
# it, and it keeps output clean.
REMOTE_SCRIPT=$(cat <<REOF
set -u
HERMES_USER='${HERMES_USER}'
HERMES_UID="\$(id -u "\$HERMES_USER" 2>/dev/null || echo)"
run_as_hermes() {
  sudo -u "\$HERMES_USER" -H bash -lc "export PATH=\"\\\$HOME/.local/bin:\\\$PATH\"; export XDG_RUNTIME_DIR=\"/run/user/\$HERMES_UID\"; \$*"
}

if ! run_as_hermes "command -v hermes" >/dev/null 2>&1; then
  echo "RESULT=no-hermes"; exit 0
fi

OLD="\$(run_as_hermes "hermes config show" 2>/dev/null | grep -iE 'model' | grep -iE 'default|provider' | tr -d ' ')"
echo "OLD_CONFIG=\$OLD"

if run_as_hermes "hermes config set model.default '${MODEL}'" >/tmp/setmodel.out 2>&1; then
  echo "SET_MODEL=ok"
else
  echo "SET_MODEL=fail"; echo "SET_ERR=\$(tr '\n' '|' </tmp/setmodel.out)"
fi
REOF
)

if [[ -n "$PROVIDER" ]]; then
  REMOTE_SCRIPT+=$(cat <<REOF

if run_as_hermes "hermes config set model.provider '${PROVIDER}'" >/tmp/setprov.out 2>&1; then
  echo "SET_PROVIDER=ok"
else
  echo "SET_PROVIDER=fail"; echo "PROV_ERR=\$(tr '\n' '|' </tmp/setprov.out)"
fi
REOF
)
fi

if [[ -n "$BASE_URL" ]]; then
  REMOTE_SCRIPT+=$(cat <<REOF

if run_as_hermes "hermes config set model.base_url '${BASE_URL}'" >/tmp/setbase.out 2>&1; then
  echo "SET_BASE_URL=ok"
else
  echo "SET_BASE_URL=fail"; echo "BASE_ERR=\$(tr '\n' '|' </tmp/setbase.out)"
fi
REOF
)
fi

REMOTE_SCRIPT+=$(cat <<REOF

if run_as_hermes "hermes config check" >/dev/null 2>&1; then
  echo "CONFIG_CHECK=ok"
else
  echo "CONFIG_CHECK=fail"
fi
NEW="\$(run_as_hermes "hermes config show" 2>/dev/null | grep -iE 'model' | grep -iE 'default|provider' | tr -d ' ')"
echo "NEW_CONFIG=\$NEW"
REOF
)

if [[ "$DO_RESTART" -eq 1 ]]; then
  REMOTE_SCRIPT+=$(cat <<'REOF'

if run_as_hermes "hermes gateway restart" >/dev/null 2>&1; then
  echo "RESTART=ok"
else
  echo "RESTART=fail"
fi
GW="$(run_as_hermes "systemctl --user is-active hermes-gateway" 2>/dev/null | tail -n1)"
echo "GATEWAY=$GW"
REOF
)
fi

# --- run + report ------------------------------------------------------------
section "Applying model change (via SSM)"
info "sending remote command…"
OUT="$(run_ssm "$REMOTE_SCRIPT")"

if [[ "$SSM_STATUS" != "Success" && -z "$OUT" ]]; then
  fail "remote command failed (status: ${SSM_STATUS:-unknown})"
  [[ -n "$SSM_STDERR" ]] && echo "    stderr: ${SSM_STDERR}"
  exit 1
fi

get() { grep -m1 "^$1=" <<<"$OUT" | cut -d= -f2-; }

if [[ "$(get RESULT)" == "no-hermes" ]]; then
  fail "hermes is not installed for user '${HERMES_USER}' — run scripts/check-deployment.sh"
  exit 1
fi

OK=1
[[ -n "$(get OLD_CONFIG)" ]] && info "before: $(get OLD_CONFIG)"

if [[ "$(get SET_MODEL)" == "ok" ]]; then
  pass "model.default set to '${MODEL}'"
else
  fail "failed to set model.default"; [[ -n "$(get SET_ERR)" ]] && echo "    ${YELLOW}$(get SET_ERR)${RESET}"; OK=0
fi

if [[ -n "$PROVIDER" ]]; then
  if [[ "$(get SET_PROVIDER)" == "ok" ]]; then
    pass "model.provider set to '${PROVIDER}'"
    info "reminder: ensure ${PROVIDER}'s API key + base URL are in ~/.hermes/.env"
  else
    fail "failed to set model.provider"; [[ -n "$(get PROV_ERR)" ]] && echo "    ${YELLOW}$(get PROV_ERR)${RESET}"; OK=0
  fi
fi

if [[ -n "$BASE_URL" ]]; then
  if [[ "$(get SET_BASE_URL)" == "ok" ]]; then
    pass "model.base_url set to '${BASE_URL}'"
  else
    fail "failed to set model.base_url"; [[ -n "$(get BASE_ERR)" ]] && echo "    ${YELLOW}$(get BASE_ERR)${RESET}"; OK=0
  fi
fi

if [[ "$(get CONFIG_CHECK)" == "ok" ]]; then
  pass "'hermes config check' passed"
else
  fail "'hermes config check' failed after the change"; OK=0
fi

[[ -n "$(get NEW_CONFIG)" ]] && info "after:  $(get NEW_CONFIG)"

if [[ "$DO_RESTART" -eq 1 ]]; then
  if [[ "$(get RESTART)" == "ok" && "$(get GATEWAY)" == "active" ]]; then
    pass "gateway restarted and active"
  else
    fail "gateway did not come back active (restart: $(get RESTART), state: $(get GATEWAY))"; OK=0
  fi
else
  info "gateway not restarted — run 'hermes gateway restart' to apply, or re-run without --no-restart"
fi

echo
if [[ "$OK" -eq 1 ]]; then
  echo "${GREEN}${BOLD}OK${RESET} — Hermes model is now '${MODEL}'."
  exit 0
else
  echo "${RED}${BOLD}FAILED${RESET} — model change did not fully succeed (see above)."
  exit 1
fi
