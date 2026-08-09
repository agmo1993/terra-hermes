#!/usr/bin/env bash
# =============================================================================
# check-deployment.sh — health check for the terra-hermes stack.
#
# Verifies, in order:
#   1. Terraform state exists and exposes the instance outputs
#   2. The EC2 instance is running in AWS
#   3. The SSM agent on the instance is online (this is how we reach it)
#   4. Hermes is installed for the hermes user
#   5. The model provider is configured correctly (provider + default model
#      are set, the provider's API key is present, and `hermes config check` passes)
#   6. The Telegram gateway service is active
#
# The box has no SSH — all remote probes run via SSM send-command, which
# executes as root on the instance and drops to the hermes user the same way
# templates/hermes-startup.sh does.
#
# Usage:
#   scripts/check-deployment.sh                 # auto-detect from terraform output
#   INSTANCE_ID=i-0abc REGION=us-east-1 scripts/check-deployment.sh
#
# Exit status: 0 if every check passes, 1 otherwise.
# Requires: terraform (optional), aws CLI, jq.
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- pretty output -----------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

FAILED=0
pass() { echo "  ${GREEN}✔${RESET} $*"; }
fail() { echo "  ${RED}✗${RESET} $*"; FAILED=1; }
warn() { echo "  ${YELLOW}!${RESET} $*"; }
info() { echo "  ${BOLD}·${RESET} $*"; }
section() { echo; echo "${BOLD}$*${RESET}"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "${RED}error:${RESET} '$1' is required but not installed."; exit 2; }; }
need aws
need jq

# --- 1. Resolve instance id + region -----------------------------------------
section "1. Terraform state"
HERMES_USER="${HERMES_USER:-hermes}"
REGION="${REGION:-}"
INSTANCE_ID="${INSTANCE_ID:-}"

if [[ -z "$INSTANCE_ID" || -z "$REGION" ]]; then
  if command -v terraform >/dev/null 2>&1 && [[ -f "$REPO_DIR/terraform.tfstate" ]]; then
    tf_out="$(cd "$REPO_DIR" && terraform output -json 2>/dev/null)"
    if [[ -n "$tf_out" && "$tf_out" != "{}" ]]; then
      [[ -z "$INSTANCE_ID" ]] && INSTANCE_ID="$(jq -r '.instance_id.value // empty' <<<"$tf_out")"
      # ssm_session_command embeds --region <r>; pull it out if REGION unset.
      if [[ -z "$REGION" ]]; then
        REGION="$(jq -r '.ssm_session_command.value // empty' <<<"$tf_out" | sed -n 's/.*--region \([^ ]*\).*/\1/p')"
      fi
      pass "read outputs from terraform state"
    else
      warn "terraform output empty — is the stack applied?"
    fi
  else
    warn "terraform not found or no state file; relying on env vars"
  fi
fi

REGION="${REGION:-us-east-1}"

if [[ -z "$INSTANCE_ID" ]]; then
  fail "could not determine instance id (set INSTANCE_ID=... or run 'terraform apply' first)"
  echo; echo "${RED}${BOLD}FAILED${RESET} — cannot proceed without an instance id."
  exit 1
fi
info "instance: ${INSTANCE_ID}   region: ${REGION}   user: ${HERMES_USER}"

AWS=(aws --region "$REGION" --output json)

# --- 2. EC2 instance state ---------------------------------------------------
section "2. EC2 instance"
desc="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" 2>/dev/null)"
if [[ -z "$desc" ]]; then
  fail "describe-instances failed (bad id, wrong region, or missing AWS credentials)"
  echo; echo "${RED}${BOLD}FAILED${RESET}"; exit 1
fi
state="$(jq -r '.Reservations[0].Instances[0].State.Name // "unknown"' <<<"$desc")"
itype="$(jq -r '.Reservations[0].Instances[0].InstanceType // "?"' <<<"$desc")"
pub_ip="$(jq -r '.Reservations[0].Instances[0].PublicIpAddress // "none"' <<<"$desc")"
if [[ "$state" == "running" ]]; then
  pass "instance is running (${itype}, public IP ${pub_ip})"
else
  fail "instance state is '${state}' (expected 'running')"
fi

# --- 3. SSM agent online -----------------------------------------------------
section "3. SSM connectivity"
ping="$("${AWS[@]}" ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" 2>/dev/null \
  | jq -r '.InstanceInformationList[0].PingStatus // "Missing"')"
if [[ "$ping" == "Online" ]]; then
  pass "SSM agent is Online"
else
  fail "SSM agent status is '${ping}' — remote probes cannot run"
  warn "the box may still be booting/running user_data; retry in a minute"
  echo; echo "${RED}${BOLD}FAILED${RESET} — no SSM channel to the instance."
  exit 1
fi

# --- remote probe helper -----------------------------------------------------
# Runs a bash snippet on the instance via SSM and echoes its stdout. The snippet
# runs as root; use run_as_hermes() inside it to act as the hermes user exactly
# like the startup script does.
run_ssm() {
  local script="$1" cmd_id status params
  params="$(jq -Rn --arg s "$script" '{commands:[$s]}')"
  cmd_id="$("${AWS[@]}" ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "terra-hermes health check" \
    --parameters "$params" \
    2>/dev/null | jq -r '.Command.CommandId // empty')"
  [[ -z "$cmd_id" ]] && { echo "__SSM_SEND_FAILED__"; return 1; }

  for _ in $(seq 1 30); do
    status="$("${AWS[@]}" ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null \
      | jq -r '.Status // "Pending"')"
    case "$status" in
      Success|Failed|Cancelled|TimedOut) break ;;
    esac
    sleep 2
  done

  "${AWS[@]}" ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null \
    | jq -r '.StandardOutputContent // ""'
}

# Remote script: define the same run_as_hermes helper the startup script uses,
# then emit KEY=value lines we parse back here.
REMOTE_SCRIPT=$(cat <<REOF
# SSM RunShellScript executes under /bin/sh (dash); keep this POSIX-sh clean.
set -u
HERMES_USER='${HERMES_USER}'
HERMES_UID="\$(id -u "\$HERMES_USER" 2>/dev/null || echo)"
run_as_hermes() {
  sudo -u "\$HERMES_USER" -H bash -lc "
    export PATH=\"\\\$HOME/.local/bin:\\\$PATH\"
    export XDG_RUNTIME_DIR=\"/run/user/\$HERMES_UID\"
    if [ -f \"\\\$HOME/.hermes/.env\" ]; then set -a; . \"\\\$HOME/.hermes/.env\"; set +a; fi
    \$*
  "
}

# cloud-init / user_data completion
if command -v cloud-init >/dev/null 2>&1; then
  echo "CLOUDINIT=\$(cloud-init status 2>/dev/null | awk -F': ' '/status/{print \$2}')"
else
  echo "CLOUDINIT=unknown"
fi

# hermes binary
if run_as_hermes "command -v hermes" >/dev/null 2>&1; then
  echo "HERMES_BIN=\$(run_as_hermes 'command -v hermes' 2>/dev/null)"
  echo "HERMES_VERSION=\$(run_as_hermes 'hermes --version' 2>/dev/null | head -n1)"
else
  echo "HERMES_BIN="
fi

# model config check
if run_as_hermes "hermes config check" >/dev/null 2>&1; then
  echo "CONFIG_CHECK=ok"
else
  echo "CONFIG_CHECK=fail"
fi

# model provider configuration: the configured provider + default model, and
# whether the API key env var that provider expects is actually populated in
# the hermes env (~/.hermes/.env, sourced by run_as_hermes). The CLI has no
# machine-readable getter, so parse the 'Model:' line from 'hermes config show',
# which renders as a python dict: {'default': '...', 'provider': '...', ...}.
MODEL_LINE="\$(run_as_hermes 'hermes config show' 2>/dev/null | grep -iE '^ *Model:')"
PROVIDER="\$(printf '%s' "\$MODEL_LINE" | sed -n "s/.*'provider': *'\\([^']*\\)'.*/\\1/p")"
MODEL="\$(printf '%s' "\$MODEL_LINE" | sed -n "s/.*'default': *'\\([^']*\\)'.*/\\1/p")"
echo "PROVIDER=\$PROVIDER"
echo "MODEL=\$MODEL"
# map the provider to the API-key env var it uses (matches providers.tf).
case "\$PROVIDER" in
  openrouter) KEY_VAR=OPENROUTER_API_KEY ;;
  anthropic)  KEY_VAR=ANTHROPIC_API_KEY ;;
  openai)     KEY_VAR=OPENAI_API_KEY ;;
  nvidia)     KEY_VAR=NVIDIA_API_KEY ;;
  gemini)     KEY_VAR=GEMINI_API_KEY ;;
  *)          KEY_VAR= ;;
esac
echo "PROVIDER_KEY_VAR=\$KEY_VAR"
if [ -n "\$KEY_VAR" ]; then
  run_as_hermes "test -n \"\\\$\$KEY_VAR\"" >/dev/null 2>&1 && echo "PROVIDER_KEY=present" || echo "PROVIDER_KEY=missing"
else
  echo "PROVIDER_KEY=unknown"
fi

# gateway service state (per-user systemd)
GW_ACTIVE="\$(run_as_hermes 'systemctl --user is-active hermes-gateway 2>/dev/null || hermes gateway status 2>/dev/null | grep -qiE \"active|running\" && echo active || echo inactive' 2>/dev/null | tail -n1)"
echo "GATEWAY=\$GW_ACTIVE"
REOF
)

section "4. Hermes on the instance (via SSM)"
info "sending remote probe…"
OUT="$(run_ssm "$REMOTE_SCRIPT")"

if [[ "$OUT" == "__SSM_SEND_FAILED__" || -z "$OUT" ]]; then
  fail "remote probe produced no output (SSM send-command failed or timed out)"
  echo; echo "${RED}${BOLD}FAILED${RESET}"; exit 1
fi

get() { grep -m1 "^$1=" <<<"$OUT" | cut -d= -f2-; }

CLOUDINIT="$(get CLOUDINIT)"
HERMES_BIN="$(get HERMES_BIN)"
HERMES_VERSION="$(get HERMES_VERSION)"
CONFIG_CHECK="$(get CONFIG_CHECK)"
PROVIDER="$(get PROVIDER)"
MODEL="$(get MODEL)"
PROVIDER_KEY_VAR="$(get PROVIDER_KEY_VAR)"
PROVIDER_KEY="$(get PROVIDER_KEY)"
GATEWAY="$(get GATEWAY)"

case "$CLOUDINIT" in
  done)    pass "cloud-init finished (user_data ran to completion)" ;;
  running) warn "cloud-init still running — bootstrap not finished yet" ;;
  error)   fail "cloud-init reported an error — check /var/log/cloud-init-output.log" ;;
  *)       info "cloud-init status: ${CLOUDINIT:-unknown}" ;;
esac

if [[ -n "$HERMES_BIN" ]]; then
  pass "hermes installed at ${HERMES_BIN}${HERMES_VERSION:+ (${HERMES_VERSION})}"
else
  fail "hermes binary not found for user '${HERMES_USER}'"
fi

section "5. Model provider"
KNOWN_PROVIDERS=" openrouter anthropic openai nvidia gemini opencode-go "
if [[ -n "$PROVIDER" && "$KNOWN_PROVIDERS" == *" $PROVIDER "* ]]; then
  pass "provider is '${PROVIDER}'${MODEL:+, default model '${MODEL}'}"
else
  fail "model.provider is not a known provider (got: '${PROVIDER:-unset}'; expected one of:${KNOWN_PROVIDERS})"
fi

case "$PROVIDER_KEY" in
  present) pass "provider API key is set (${PROVIDER_KEY_VAR:-key} populated in the hermes env)" ;;
  missing) fail "provider API key is missing (${PROVIDER_KEY_VAR:-key} empty/unset in ~/.hermes/.env)" ;;
  *)       warn "could not determine whether the provider API key is set" ;;
esac

if [[ "$CONFIG_CHECK" == "ok" ]]; then
  pass "'hermes config check' passed"
else
  fail "'hermes config check' failed (provider/model/API key misconfigured)"
fi

section "6. Telegram gateway"
if [[ "$GATEWAY" == "active" ]]; then
  pass "gateway service is active"
else
  fail "gateway service is not active (state: ${GATEWAY:-unknown})"
fi

# --- verdict -----------------------------------------------------------------
echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "${GREEN}${BOLD}OK${RESET} — stack deployed, Hermes installed and running."
  exit 0
else
  echo "${RED}${BOLD}FAILED${RESET} — one or more checks did not pass (see above)."
  echo "Debug on the box:  aws ssm start-session --target ${INSTANCE_ID} --region ${REGION}"
  exit 1
fi
