#!/bin/bash
# bin/auth-fingerprint.sh — WHICH account paid for a call, resolved LIVE.
#
# Sourced library (agent-call.sh, box-chat.sh; executable standalone for
# operators: `auth-fingerprint.sh <runner>` prints "<fp> <label>").
#
# WHY LIVE AND NEVER INFERRED (the operator, 2026-08-31): accounts get switched —
# global.env re-points CLAUDE_CODE_OAUTH_TOKEN, a box re-logs-in, GROK_BILLING
# flips a lane from subscription to the API wallet. Any attribution
# reconstructed later from provisioning records or past events describes the
# account that WAS in effect, not the one that paid. So the fingerprint is
# computed at row-write time from the credential the attempt actually used,
# by the same per-runner logic billing-mode.sh already applies (which env var
# or stored login the CLI will prefer).
#
# NEVER the raw secret: only the first 12 hex of sha256, prefixed "login:"
# when the credential is a stored login file rather than an env token. That
# is enough to tell accounts apart and to join against the label map, and
# useless to an attacker. "none" means no credential was resolvable.
#
# ACCOUNT ROUTING (2026-09-06): the stored-login paths honour CLAUDE_CONFIG_DIR
# and CODEX_HOME, because agent-call.sh runs a routed attempt with those set in
# the child and resolves this fingerprint in the same child env. Unset — every
# call today — they expand to exactly the old $HOME paths.
#
# Labels: fp -> human name, looked up at call time from the repo-managed
# catalog/auth-accounts.json overlaid by state/auth-accounts.local.json
# (box-specific; written by bin/auth-label.sh from a LIVE token, never by
# hand-guessing). An unmapped fp is "unknown" — never a guess, for the same
# reason billing-mode.sh refuses to guess: a wrong label is worse than a
# visible gap someone can go label.

_auth_fp_secret() { # <secret> -> first 12 hex of sha256; the raw value never leaves this function
  printf '%s' "$1" | sha256sum | cut -c1-12
}

_auth_fp_file() { # <file> -> first 12 hex of sha256 of its CONTENT
  sha256sum "$1" 2>/dev/null | cut -c1-12
}

auth_fp_for_runner() { # <runner> -> fp of the credential in effect for that runner NOW, or "none"
  local r="${1:-}"
  case "$r" in
    claude)
      # Mirror billing-mode.sh: with the OAuth token present the call rides
      # the subscription; an API key with no OAuth token is the metered box.
      # No env credential at all means the CLI uses its stored login.
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        _auth_fp_secret "$CLAUDE_CODE_OAUTH_TOKEN"
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        _auth_fp_secret "$ANTHROPIC_API_KEY"
      elif [ -r "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]; then
        printf 'login:%s\n' "$(_auth_fp_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json")"
      else
        echo none
      fi ;;
    grok)
      # agent-call.sh scrubs XAI_API_KEY from the call env unless
      # GROK_BILLING=api, so the key only ever pays in api mode — otherwise
      # the stored device-auth login (~/.grok/auth.json) is the account.
      if [ "${GROK_BILLING:-}" = api ] && [ -n "${XAI_API_KEY:-}" ]; then
        _auth_fp_secret "$XAI_API_KEY"
      elif [ -r "$HOME/.grok/auth.json" ]; then
        printf 'login:%s\n' "$(_auth_fp_file "$HOME/.grok/auth.json")"
      else
        echo none
      fi ;;
    codex)
      # The lane runs on the subscription auth when present (billing-mode.sh:
      # calling the env keys metered would invent spend); keys are the
      # fallback credential on boxes that carry them.
      if [ -r "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then
        printf 'login:%s\n' "$(_auth_fp_file "${CODEX_HOME:-$HOME/.codex}/auth.json")"
      elif [ -n "${CODEX_API_KEY:-}" ]; then
        _auth_fp_secret "$CODEX_API_KEY"
      elif [ -n "${OPENAI_API_KEY:-}" ]; then
        _auth_fp_secret "$OPENAI_API_KEY"
      else
        echo none
      fi ;;
    openrouter)
      if [ -n "${OPENROUTER_API_KEY:-}" ]; then _auth_fp_secret "$OPENROUTER_API_KEY"; else echo none; fi ;;
    fireworks)
      if [ -n "${FIREWORKS_API_KEY:-}" ]; then _auth_fp_secret "$FIREWORKS_API_KEY"; else echo none; fi ;;
    gemini)
      # Same order billing-mode.sh reads: key with no OAuth file is metered;
      # the OAuth login pays otherwise.
      if [ -n "${GEMINI_API_KEY:-}" ] && [ ! -f "$HOME/.gemini/oauth_creds.json" ]; then
        _auth_fp_secret "$GEMINI_API_KEY"
      elif [ -r "$HOME/.gemini/oauth_creds.json" ]; then
        printf 'login:%s\n' "$(_auth_fp_file "$HOME/.gemini/oauth_creds.json")"
      elif [ -n "${GEMINI_API_KEY:-}" ]; then
        _auth_fp_secret "$GEMINI_API_KEY"
      else
        echo none
      fi ;;
    *)
      echo none ;;
  esac
}

auth_account_for_fp() { # <fp> -> label from catalog + local overlay, or "unknown"
  local fp="${1:-}" cat_file local_file label
  if [ -z "$fp" ] || [ "$fp" = none ]; then echo unknown; return 0; fi
  command -v jq >/dev/null 2>&1 || { echo unknown; return 0; }
  # Catalog path, same TK-109 shape as context-budgets: hub/boxes read the
  # deploy checkout; environments without one read the synced $HARNESS copy.
  cat_file="${AUTH_ACCOUNTS_CATALOG:-}"
  if [ -z "$cat_file" ]; then
    cat_file=/root/harness-checkout/catalog/auth-accounts.json
    [ -r "$cat_file" ] || cat_file="${HARNESS:-/root/harness}/catalog/auth-accounts.json"
  fi
  local_file="${AUTH_ACCOUNTS_LOCAL:-${HARNESS:-/root/harness}/state/auth-accounts.local.json}"
  # Overlay wins on collision (add merges in order). The '{}' sentinel keeps
  # the slurp non-empty when neither file exists; a malformed file fails the
  # whole lookup to "unknown", which is the conservative direction.
  label=$( { cat "$cat_file" 2>/dev/null; echo '{}'; cat "$local_file" 2>/dev/null; } \
    | jq -rs --arg fp "$fp" '[.[] | select(type == "object")] | add | .[$fp] // "unknown"' 2>/dev/null)
  # The label lands in a comma-separated row read positionally by awk in two
  # places — a comma or newline inside it would shift columns silently.
  label=$(printf '%s' "$label" | tr -d ',\r' | tr '\n' ' ')
  [ -n "$label" ] || label=unknown
  printf '%s\n' "$label"
}

# Standalone: `auth-fingerprint.sh <runner>` -> "<fp> <label>" for operators.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  _r="${1:?usage: auth-fingerprint.sh <runner>}"
  _fp=$(auth_fp_for_runner "$_r")
  printf '%s %s\n' "$_fp" "$(auth_account_for_fp "$_fp")"
fi
