#!/bin/bash
# bin/machine-enroll.sh — BH-5348: enroll a machine outside the pool as a
# participant (worker/jobs/src/routes/participants.js), check its status, and,
# from the console side, approve, deny or revoke it.
#
# THE PARTICIPANT TOKEN. `request` generates 32 random bytes (64 hex) into
# HARNESS_PARTICIPANT_TOKEN_FILE (default
# ~/.config/cromford/participant-token, mode 600) and sends the worker
# only its sha256. The token itself never leaves this machine except as the
# x-participant-token header on this machine's own calls, it is never on argv
# (ps shows argv) and never printed. `request` keeps the file ONLY when the
# worker answers 201 with a pending row; every other outcome, a kill included,
# removes it, so there is never a token file pointing at no row.
#
# THE LEAD TOKEN. approve, deny and revoke need LEAD_VERDICT_TOKEN_FILE (the
# same file and default as bin/lead-verdict.sh). Like the bearer and the
# participant token it travels to curl in a 0600 header file that is removed
# on exit, never on argv.
#
# Every /api route needs HARNESS_SECRET and JOBS_URL, from the environment or
# env/global.env (bin/jobs-client.sh loads them).
#
# usage: bin/machine-enroll.sh request <name> --roles a,b [--owner o] [--billing-account x]
#          generate the token, ask for a pending row; prints `pending <id> <name>`.
#          Refuses when the token file already exists. rc 0 | 1.
#        bin/machine-enroll.sh status
#          ask the worker who this token is. Prints `approved <id> <name> roles=a,b`
#          (rc 0), or `pending` / `denied` / `revoked` (rc 3). rc 1 on any error.
#        bin/machine-enroll.sh approve <id> --roles a,b [--by who]
#        bin/machine-enroll.sh deny <id> [--by who]
#        bin/machine-enroll.sh revoke <id> [--by who]
#          console side, needs the lead token. Prints `<status> <id> <name>`,
#          plus ` (unchanged)` on a repeat. rc 0 | 1.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HARNESS:-$(cd "$SELF_DIR/.." && pwd)}"
export HARNESS
# shellcheck source=/dev/null
. "$SELF_DIR/jobs-client.sh" || { echo "machine-enroll: bin/jobs-client.sh did not load" >&2; exit 1; }

usage() { sed -n '/^# usage:/,/^#          plus ` (unchanged)`/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "machine-enroll: $*" >&2; exit 1; }

TOKEN_FILE="${HARNESS_PARTICIPANT_TOKEN_FILE:-$HOME/.config/cromford/participant-token}"
LEAD_VERDICT_TOKEN_FILE="${LEAD_VERDICT_TOKEN_FILE:-$HOME/.config/cromford/lead-verdict-token}"

# Cleanup: temp files always; the token file only when this run created it and
# the worker never answered 201 (ME_OWN=1, ME_KEEP=0).
ME_TMP=""; ME_OWN=0; ME_KEEP=0
me_cleanup() {
  [ -n "$ME_TMP" ] && rm -rf "$ME_TMP"
  [ "$ME_OWN" = 1 ] && [ "$ME_KEEP" != 1 ] && rm -f "$TOKEN_FILE"
}
trap me_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
me_tmpdir() { [ -n "$ME_TMP" ] || ME_TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/machine-enroll.XXXXXX") || die "mktemp failed"; }

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

# me_hdr [<header-name> <file>] — writes the 0600 header file: the bearer, the
# content type, and at most one secret header whose value is the first line of
# <file>. Sets ME_HDR. The secret goes through printf (a builtin), never argv.
me_hdr() {
  local name="${1:-}" file="${2:-}" v=""
  [ -n "${HARNESS_SECRET:-}" ] || die "HARNESS_SECRET is not set (env or env/global.env)"
  me_tmpdir
  ME_HDR="$ME_TMP/hdr"
  (umask 077; printf 'authorization: Bearer %s\ncontent-type: application/json\n' "$HARNESS_SECRET" > "$ME_HDR") || die "cannot write the header file"
  if [ -n "$name" ]; then
    v=$(head -1 "$file" | tr -d ' \r\n')
    [ -n "$v" ] || die "the token file $file is empty"
    printf '%s: %s\n' "$name" "$v" >> "$ME_HDR"
  fi
  unset v
}

# me_call <method> <path> [bodyfile] — sets ME_HTTP and ME_BODY; returns 1 when
# curl itself failed (unreachable), 0 otherwise, whatever the code.
me_call() {
  local method="$1" path="$2" body="${3:-}" out
  ME_HTTP=""; ME_BODY=""
  if [ -n "$body" ]; then
    out=$(curl -sS -m "${JOBS_TIMEOUT:-8}" --connect-timeout 3 -w $'\n%{http_code}' -X "$method" \
            -H "@$ME_HDR" --data-binary "@$body" "$JOBS_URL$path" 2>/dev/null) || return 1
  else
    out=$(curl -sS -m "${JOBS_TIMEOUT:-8}" --connect-timeout 3 -w $'\n%{http_code}' -X "$method" \
            -H "@$ME_HDR" "$JOBS_URL$path" 2>/dev/null) || return 1
  fi
  ME_HTTP="${out##*$'\n'}"; ME_BODY="${out%$'\n'*}"
  return 0
}
me_err() { printf '%s' "$ME_BODY" | jq -r '.error // empty' 2>/dev/null; }
need_url() { [ -n "${JOBS_URL:-}" ] || die "JOBS_URL not set (env or env/global.env)"; }

cmd_request() {
  local name="" roles="" owner="" billing="" tok hash body err
  [ $# -ge 1 ] || usage
  name="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --roles) roles="${2:-}"; shift 2 || usage ;;
      --owner) owner="${2:-}"; shift 2 || usage ;;
      --billing-account) billing="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$name" ] && [ -n "$roles" ] || usage
  if [ -e "$TOKEN_FILE" ] || [ -L "$TOKEN_FILE" ]; then
    die "$TOKEN_FILE already exists — it may be an enrolled credential, so it is never overwritten. Revoke that participant first (bin/machine-enroll.sh revoke <id>), then remove the file."
  fi
  need_url
  [ -n "${HARNESS_SECRET:-}" ] || die "HARNESS_SECRET is not set (env or env/global.env)"
  (umask 077; mkdir -p "$(dirname "$TOKEN_FILE")") || die "cannot create $(dirname "$TOKEN_FILE")"
  # noclobber: created here or not at all, so a file that appeared since the
  # check above is never truncated and never ours to remove.
  (umask 077; set -C; : > "$TOKEN_FILE") 2>/dev/null || die "cannot create $TOKEN_FILE"
  ME_OWN=1
  if command -v openssl >/dev/null 2>&1; then
    tok=$(openssl rand -hex 32)
  else
    tok=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
  fi
  [[ "$tok" =~ ^[0-9a-f]{64}$ ]] || die "could not generate a token"
  printf '%s' "$tok" > "$TOKEN_FILE" || die "cannot write $TOKEN_FILE"
  unset tok
  chmod 600 "$TOKEN_FILE" || die "cannot chmod 600 $TOKEN_FILE"
  hash=$(sha256 < "$TOKEN_FILE")
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "could not hash $TOKEN_FILE"

  me_hdr
  body="$ME_TMP/body"
  jq -n --arg roles "$roles" --arg name "$name" --arg h "$hash" --arg o "$owner" --arg b "$billing" \
    '{name: $name, requested_roles: ($roles | split(",")), token_sha256: $h}
     + (if $o == "" then {} else {owner: $o} end)
     + (if $b == "" then {} else {billing_account: $b} end)' > "$body" || die "could not build the request body"
  me_call POST /api/participants/request "$body" || die "worker unreachable ($JOBS_URL); $TOKEN_FILE removed"
  local id status sname
  id=$(printf '%s' "$ME_BODY" | jq -r '.participant.id // empty' 2>/dev/null)
  status=$(printf '%s' "$ME_BODY" | jq -r '.participant.status // empty' 2>/dev/null)
  sname=$(printf '%s' "$ME_BODY" | jq -r '.participant.name // empty' 2>/dev/null)
  if [ "$ME_HTTP" = 201 ] && [ -n "$id" ] && [ "$status" = pending ]; then
    ME_KEEP=1
    echo "pending $id ${sname:-$name}"
    return 0
  fi
  err=$(me_err)
  die "worker refused (http ${ME_HTTP:-none}): ${err:-no pending participant in the answer}; $TOKEN_FILE removed"
}

cmd_status() {
  local m err
  [ $# -eq 0 ] || usage
  [ -r "$TOKEN_FILE" ] || die "no readable token file at $TOKEN_FILE (HARNESS_PARTICIPANT_TOKEN_FILE) — run request first"
  m=$(mode_of "$TOKEN_FILE")
  [ "$m" = 600 ] || echo "machine-enroll: warning: $TOKEN_FILE is mode ${m:-unknown}, not 600 — chmod 600 it" >&2
  need_url
  me_hdr x-participant-token "$TOKEN_FILE"
  me_call GET /api/participants/whoami || die "worker unreachable ($JOBS_URL)"
  err=$(me_err)
  if [ "$ME_HTTP" = 200 ]; then
    printf '%s' "$ME_BODY" | jq -r '"\(.status) \(.id) \(.name) roles=\((.granted_roles // []) | join(","))"' \
      || die "unreadable whoami answer"
    return 0
  fi
  if [ "$ME_HTTP" = 403 ] && [[ "$err" =~ ^participant\ is\ (pending|denied|revoked)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    exit 3
  fi
  die "worker refused (http ${ME_HTTP:-none}): ${err:-no error in the answer}"
}

cmd_decide() {
  local verb="$1" id="" roles="" by="" rflag=0 body path err
  shift
  [ $# -ge 1 ] || usage
  id="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --roles) [ "$verb" = approve ] || usage; roles="${2:-}"; rflag=1; shift 2 || usage ;;
      --by) by="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$id" ] || usage
  if [ "$verb" = approve ] && { [ "$rflag" = 0 ] || [ -z "$roles" ]; }; then usage; fi
  [ -r "$LEAD_VERDICT_TOKEN_FILE" ] || die "$verb needs the lead token file (LEAD_VERDICT_TOKEN_FILE, now $LEAD_VERDICT_TOKEN_FILE) — not readable"
  need_url
  me_hdr x-lead-verdict-token "$LEAD_VERDICT_TOKEN_FILE"
  body="$ME_TMP/body"
  jq -n --arg roles "$roles" --arg verb "$verb" --arg by "$by" \
    '(if $by == "" then {} else {actor: $by} end)
     + (if $verb == "approve" then {granted_roles: ($roles | split(","))} else {} end)' > "$body" || die "could not build the request body"
  path="/api/participants/$(jq -rn --arg v "$id" '$v|@uri')/$verb"
  me_call POST "$path" "$body" || die "worker unreachable ($JOBS_URL)"
  if [ "$ME_HTTP" = 200 ]; then
    printf '%s' "$ME_BODY" | jq -er 'select(.participant.id != null) | "\(.participant.status) \(.participant.id) \(.participant.name)\(if .unchanged == true then " (unchanged)" else "" end)"' \
      || die "200 without a participant in the answer"
    return 0
  fi
  err=$(me_err)
  die "worker refused $verb (http ${ME_HTTP:-none}): ${err:-no error in the answer}"
}

case "${1:-}" in
  request) shift; cmd_request "$@" ;;
  status) shift; cmd_status "$@" ;;
  approve|deny|revoke) v="$1"; shift; cmd_decide "$v" "$@" ;;
  *) usage ;;
esac
