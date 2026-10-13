#!/bin/bash
# transcript-scrub.sh — stdin -> stdout, with every secret this box knows about
# replaced by [REDACTED].
#
# WHY THIS EXISTS AS ITS OWN SCRIPT. A transcript is the one artefact in this
# fleet that is BOTH high value and high risk: it is the whole conversation, and
# an agent session reads env files, echoes curl commands and pastes bearer
# headers into its own reasoning as a matter of routine. Pushing that to a
# database the console reads would be the single fastest way to put a live
# credential somewhere it does not belong. So the scrub is a separate, testable
# unit rather than three inline sed calls in bin/agent-call.sh, and
# tests/transcript-scrub-test.sh drives it with secret-shaped fixtures.
#
# TWO LAYERS, and they are deliberately different in kind:
#
#   1. LITERAL VALUES. Every value assigned in a file under the dir
#      harness_env_dir resolves is treated as a secret and replaced wherever it
#      appears — no pattern matching, no guessing at shape. This is the layer
#      that catches the credential this fleet actually holds, including the ones
#      with no recognisable prefix.
#   2. SHAPES. Bearer headers, ?s= query params, KEY=VALUE where the key name
#      says secret, and the well-known vendor token prefixes. This is the layer
#      that catches a credential this box does NOT have in its env dir — one the
#      agent read out of a repo, a CI log or another machine.
#
# OVER-REDACTION IS THE INTENDED FAILURE MODE. Any env value of 8+ characters is
# redacted even when it is something as harmless as a base URL, because the
# alternative is a heuristic that decides which of the operator's env values are "not
# really secret" and is wrong once. A transcript with a redacted domain in it is
# still readable; a transcript with a live token in it is a leak.
#
# usage: transcript-scrub.sh < in > out
# env:
#   HARNESS_ENV_DIR                 where the env files live (else harness_env_dir)
#   TRANSCRIPT_SCRUB_COUNT_FILE     if set, the number of replacements is written there
#   TRANSCRIPT_SCRUB_MIN_LEN        shortest env value treated as a secret (default 8)
set -uo pipefail
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir)

ENV_DIR="${HARNESS_ENV_DIR:-$HENV}"
MIN_LEN="${TRANSCRIPT_SCRUB_MIN_LEN:-8}"
MARK='[REDACTED]'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tscrub.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
IN="$TMP/in"; cat > "$IN"

# ── layer 1: literal env values ──────────────────────────────────────────────
# Collected from every readable file in the env dir, dotfiles included
# (env/.watchdog-secret holds a bare secret with no KEY= at all, and missing it
# because of a glob would be exactly the kind of quiet hole this guards).
collect_values() {
  local f line v
  shopt -s nullglob dotglob
  for f in "$ENV_DIR"/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    # `|| [ -n "$line" ]` because env/.watchdog-secret is written with printf and
    # has NO trailing newline — a plain read loop drops its last line, which is
    # the entire file, which is the entire secret.
    while IFS= read -r line || [ -n "$line" ]; do
      # Strip a CR from CRLF files before anything else — a needle with a
      # trailing \r matches nothing and the secret ships through intact.
      line="${line%$'\r'}"
      case "$line" in
        '#'*|'') continue ;;
      esac
      if [[ "$line" == *=* ]]; then
        v="${line#*=}"
      else
        # A bare-secret file (env/.watchdog-secret). The whole line is the value.
        v="$line"
      fi
      # Unwrap one layer of quoting, then drop surrounding whitespace.
      v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      [ "${#v}" -ge "$MIN_LEN" ] || continue
      # A pure number is a setting (a timeout, a port, a threshold), not a
      # credential, and redacting every occurrence of "21600" would gut a
      # transcript to protect nothing.
      case "$v" in
        *[!0-9]*) ;;
        *) continue ;;
      esac
      # Placeholders in a half-filled env file are not secrets, and redacting
      # "<your-token-here>" would hide the fact that the var is UNSET.
      case "$v" in
        '<'*'>') continue ;;
      esac
      printf '%s\n' "$v"
    done < "$f"
  done
  shopt -u nullglob dotglob
}

# Longest first: when one secret is a prefix of another (a token and the same
# token inside a URL), replacing the short one first would leave the tail of the
# long one sitting in the output.
collect_values 2>/dev/null | sort -u | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- > "$TMP/values"

: > "$TMP/sed1"
while IFS= read -r v; do
  [ -n "$v" ] || continue
  # BRE escape for the needle, and & / \ escape for the replacement. Without
  # this a value containing a "." or a "*" would match far more than itself,
  # and one containing "/" would produce an unparseable sed script that fails
  # the whole scrub open — the exact outcome this must not have.
  esc=$(printf '%s' "$v" | sed 's/[][\.*^$\/\\]/\\&/g')
  printf 's/%s/%s/g\n' "$esc" '\[REDACTED\]' >> "$TMP/sed1"
done < "$TMP/values"

if [ -s "$TMP/sed1" ]; then
  sed -f "$TMP/sed1" "$IN" > "$TMP/stage1" 2>/dev/null || cp "$IN" "$TMP/stage1"
else
  cp "$IN" "$TMP/stage1"
fi

# ── layer 2: shapes ──────────────────────────────────────────────────────────
# Each rule keeps the LABEL and redacts only the value, so a reader can still
# see that the session set CRON_SECRET without learning what it is.
sed -E \
  -e 's/([Bb]earer|BEARER)[[:space:]]+[A-Za-z0-9._~+/=-]{8,}/\1 [REDACTED]/g' \
  -e 's/([?&](s|secret|token|key|api_key|apikey|access_token|auth|sig|signature)=)[^&[:space:]"'"'"'<>]{6,}/\1[REDACTED]/g' \
  -e 's/([A-Za-z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE_KEY|CREDENTIAL|BEARER)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*"?)[^[:space:]"'"'"'&,;]{6,}/\1[REDACTED]/g' \
  -e 's/([Aa]uthorization[[:space:]]*:[[:space:]]*)[^[:space:]"'"'"']{8,}/\1[REDACTED]/g' \
  -e 's/sk-[A-Za-z0-9_-]{16,}/[REDACTED]/g' \
  -e 's/(gh[pousr]_)[A-Za-z0-9]{20,}/\1[REDACTED]/g' \
  -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
  -e 's/xox[abprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
  -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}/[REDACTED]/g' \
  -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
  -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED PRIVATE KEY BLOCK]/g' \
  -e 's/^[A-Za-z0-9+/]{60,}={0,2}$/[REDACTED]/' \
  "$TMP/stage1" > "$TMP/out" 2>/dev/null || cp "$TMP/stage1" "$TMP/out"

if [ -n "${TRANSCRIPT_SCRUB_COUNT_FILE:-}" ]; then
  # Replacements = markers that are in the output and were not in the input. An
  # input that already said [REDACTED] does not get counted twice.
  before=$(grep -o -F "$MARK" "$IN" 2>/dev/null | wc -l | tr -d ' ')
  after=$(grep -o -F "$MARK" "$TMP/out" 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\n' "$(( after - before ))" > "$TRANSCRIPT_SCRUB_COUNT_FILE" 2>/dev/null || true
fi

cat "$TMP/out"
