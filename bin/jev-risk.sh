#!/bin/bash
# bin/jev-risk.sh — BH-5024 (BH-4973.3): Jev, a second opinion on a PR's risk
# tier. Jev is TypeSafe's jev-latest: it is shown the head's diff and the rule
# tier (bin/lib/risk-tier.sh) and answers a choice of low | medium | high with a
# probability. In this wave it decides NOTHING: the answer is a ledger row and a
# log line. This script is the ONLY code path that spends on Jev.
#
#   bin/jev-risk.sh ask <owner/repo> <pr> <head> <rule-tier> <compare-json>
#   bin/jev-risk.sh question <rule-tier> <compare-json>
#
# ask, in this order, every step fail-closed:
#   1. config  the jev_risk.api_url row (NOT seeded: there is no vendor URL in
#              this repo) and TYPESAFE_API_KEY (env/global.env). Either missing:
#              `not-configured`, rc 3, no claim and no call. jev_risk.model
#              (fallback jev-latest), jev_risk.timeout_s (30) and
#              jev_risk.max_diff_chars (60000) are read the same way.
#   2. spool   a paid answer whose settle failed is kept in
#              state/jev-risk/<repo>-<pr>-<head12>-<qv>.json; it is settled
#              from there and the vendor is not called again.
#   3. claim   POST /api/jev-risk/claim. A 409 terminal is the stored answer,
#              printed with a trailing `cached`, rc 0, no call. 409 in_flight or
#              attempt_cap, or a worker that cannot answer: `skipped <why>`,
#              rc 4, no call. Never "call and hope".
#   4. call    one curl POST to api_url, `--max-time` timeout_s, the key in an
#              Authorization header read from a 600 temp file (never argv, never
#              logged), body {model, input, choices:["low","medium","high"]}.
#   5. spool   the settle body is written to the spool BEFORE the settle. It
#              carries the claim's attempts, which the worker fences the settle
#              on: a late settle from a claim that went stale and was reclaimed
#              is a 409 and cannot overwrite the claim that replaced it.
#   6. parse   jev_parse: a 2xx whose JSON has a choice in low|medium|high and
#              a probability in [0, 1] is ok; any other 2xx (empty, {}, another
#              label, HTML) is empty, billed and terminal; a non-2xx, a timeout
#              or a connection error is failed (error "curl rc <n>"), retried to
#              jev_risk.max_attempts.
#              The settle removes the spool file on a 2xx (or a 409: the row was
#              already settled another way).
# question prints the text ask would send, cut at the same jev_risk.max_diff_chars
# row (JEV_MAX_DIFF_CHARS overrides it), so the pilot's Haiku baseline is shown
# exactly what Jev is shown.
# Prints one line: <status>\t<jev_tier|->\t<prob|->\t<rule_tier>[\t<extra>]
# rc 0 ok | empty | cached, 1 failed, 3 not-configured, 4 skipped, 2 usage.
# JEV_CALLER names the asker on the ledger row (shadow:<box> | pilot).
#
# The TypeSafe request and response shape is an assumption (no contract is in
# the repo): jev_call and jev_parse are the two functions to change if the
# vendor answers differently.
set -uo pipefail
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/env-path.sh
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a
# shellcheck source=/dev/null
. "$HENV/global.env" 2>/dev/null; set +a

JEV_QV=v1
JEV_PROMPT='You are reviewing a pull request before merge. The rule-based risk classifier gave it the tier below. Read the diff and answer how risky it is to merge without a senior review: low, medium or high, with your probability for that choice.'
usage() { echo "usage: bin/jev-risk.sh ask <owner/repo> <pr> <head> <rule-tier> <compare-json> | question <rule-tier> <compare-json>" >&2; exit 2; }

# jev_question <rule-tier> <compare-json> <max-chars> — the question text.
jev_question() {
  local q
  q=$(jq -r --arg t "$1" --arg p "$JEV_PROMPT" '
    "\($p)\n\nRule tier: \($t)\n\nFiles (\(.files | length)):\n"
    + ([.files[] | "\(.status // "modified") \(.filename) +\(.additions // 0) -\(.deletions // 0)"] | join("\n"))
    + "\n\nDiff:\n"
    + ([.files[] | "--- \(.filename)\n\(.patch // "[no patch: binary or too large]")"] | join("\n"))' "$2" 2>/dev/null) || return 1
  [ -n "$q" ] || return 1
  if [ "${#q}" -gt "$3" ]; then q="${q:0:$3}"$'\n[truncated]'; fi
  printf '%s\n' "$q"
}

# jev_call <url> <model> <timeout> <question-file> <response-file> — one POST;
# prints "<http-code> <curl-rc>" (code "000" on a connection error or timeout).
# The rc rides the output because the caller runs this in $(...), where a
# variable it set would never reach jev_parse.
jev_call() {
  local hf bf code JCRC
  hf=$(mktemp "${TMPDIR:-/tmp}/jev-h.XXXXXX") || return 1
  chmod 600 "$hf"; printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY" > "$hf"
  bf=$(mktemp "${TMPDIR:-/tmp}/jev-b.XXXXXX") || { rm -f "$hf"; return 1; }
  jq -nc --arg m "$2" --rawfile i "$4" '{model:$m, input:$i, choices:["low","medium","high"]}' > "$bf"
  JCRC=0
  code=$(curl -sS --max-time "$3" --connect-timeout 5 -o "$5" -w '%{http_code}' -X POST \
    -H 'content-type: application/json' -H "@$hf" --data-binary "@$bf" "$1" 2>/dev/null) || JCRC=$?
  rm -f "$hf" "$bf"
  [ "$JCRC" = 0 ] || code=000
  printf '%s %s' "${code:-000}" "$JCRC"
}

# jev_parse <http-code> <response-file> <curl-rc> — the settle body's outcome
# fields as JSON: {status, jev_tier?, jev_prob?, error?}.
jev_parse() {
  local code="$1" f="$2" crc="${3:-0}" out
  case "$code" in
    2[0-9][0-9])
      out=$(jq -c 'if type == "object" and (.choice | type) == "string" and (.choice | IN("low","medium","high"))
                      and (.probability | type) == "number" and .probability >= 0 and .probability <= 1
                   then {status:"ok", jev_tier:.choice, jev_prob:.probability} else empty end' "$f" 2>/dev/null)
      [ -n "$out" ] && { printf '%s' "$out"; return 0; }
      jq -nc --arg c "$code" '{status:"empty", error:("http " + $c + " with no usable choice")}' ;;
    *) jq -nc --arg c "$code" --arg r "$crc" '{status:"failed", error:(if $c == "000" then "curl rc " + $r else "http " + $c end)}' ;;
  esac
}

# settle_spool <file> — POST the spooled settle body; rc 0 settled (file gone),
# 1 the worker did not take it (file kept).
settle_spool() {
  local rc=0
  JOBS_ALERT=0 _jobs_req POST /api/jev-risk/settle "$(cat "$1")" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) rm -f "$1"; return 0 ;;
    9) echo "jev-risk: settle of $(basename "$1") answered 409 (already settled another way); spool dropped" >&2
       rm -f "$1"; return 0 ;;
  esac
  echo "jev-risk: settle failed (http ${JOBS_HTTP:-none}); the answer stays in $1 for the next ask" >&2
  return 1
}

# knob <key> <fallback> — a positive-integer settings row, else the fallback.
knob() { local v; v=$(setting_get "$1" 2>/dev/null | tr -d '[:space:]'); [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]] && printf '%s' "$v" || printf '%s' "$2"; }

# emit <settle-body-json> <rule-tier> [extra] — the one output line, and the rc.
emit() {
  local st t p
  st=$(jq -r .status <<<"$1"); t=$(jq -r '.jev_tier // "-"' <<<"$1"); p=$(jq -r '.jev_prob // "-"' <<<"$1")
  printf '%s\t%s\t%s\t%s%s\n' "$st" "$t" "$p" "$2" "${3:+$'\t'$3}"
  [ "$st" = failed ] && return 1
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  question)
    [ "$#" -eq 2 ] || usage
    command -v jq >/dev/null 2>&1 || { echo "jev-risk: jq missing" >&2; exit 1; }
    QMAX="${JEV_MAX_DIFF_CHARS:-}"
    if [ -z "$QMAX" ] && [ -r "$H/bin/jobs-client.sh" ]; then
      # shellcheck source=bin/jobs-client.sh
      . "$H/bin/jobs-client.sh"; QMAX=$(knob jev_risk.max_diff_chars 60000)
    fi
    jev_question "$1" "$2" "${QMAX:-60000}" || { echo "jev-risk: compare $2 unreadable" >&2; exit 1; }
    exit 0 ;;
  ask) [ "$#" -eq 5 ] || usage ;;
  *) usage ;;
esac

SLUG="$1"; PR="$2"; HEAD=$(printf '%s' "$3" | tr 'A-F' 'a-f'); RTIER="$4"; CMP="$5"
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || usage
case "$RTIER" in low|medium|high) ;; *) usage ;; esac
skip() { printf 'skipped\t-\t-\t%s\t%s\n' "$RTIER" "$1"; exit 4; }
[ -r "$CMP" ] || skip "compare-unreadable"
[ -r "$H/bin/jobs-client.sh" ] || skip "no-jobs-client"
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh"

# 1. config. A missing row (rc 2) is not-configured; an unreadable one is a skip.
URL=""; rc=0; URL=$(setting_get jev_risk.api_url) || rc=$?
URL=$(printf '%s' "$URL" | tr -d '[:space:]')
[ "$rc" = 1 ] && skip "worker-unreachable"
if [ "$rc" != 0 ] || [[ ! "$URL" =~ ^https://[^[:space:]]+$ ]] || [ -z "${TYPESAFE_API_KEY:-}" ]; then
  printf 'not-configured\t-\t-\t%s\n' "$RTIER"; exit 3
fi
MODEL=$(setting_get jev_risk.model 2>/dev/null | tr -d '[:space:]'); [[ "$MODEL" =~ ^[A-Za-z0-9._:-]{1,64}$ ]] || MODEL=jev-latest
JT=$(knob jev_risk.timeout_s 30)
JMAXC=$(knob jev_risk.max_diff_chars 60000)
CALLER=$(printf '%s' "${JEV_CALLER:-manual}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9:._-' | head -c 64)
[[ "$CALLER" =~ ^[a-z] ]] || CALLER=manual

KEYJ=$(jq -nc --arg r "$SLUG" --argjson p "$PR" --arg h "$HEAD" --arg q "$JEV_QV" '{repo:$r, pr:$p, head_sha:$h, question_version:$q}')
SAFE=$(printf '%s' "${SLUG//\//_}" | tr -cd 'A-Za-z0-9._-')
SPOOLD="$H/state/jev-risk"; SPOOL="$SPOOLD/$SAFE-$PR-${HEAD:0:12}-$JEV_QV.json"

# 2. a paid answer that was never settled: settle it, never buy it again.
if [ -s "$SPOOL" ]; then
  SB=$(jq -c . "$SPOOL" 2>/dev/null) || { echo "jev-risk: $SPOOL is not JSON; dropped" >&2; rm -f "$SPOOL"; skip "spool-unreadable"; }
  settle_spool "$SPOOL" || skip "settle-pending"
  emit "$SB" "$RTIER" spooled; exit $?
fi

# 3. claim before any spend.
CBODY=$(jq -c --arg t "$RTIER" --arg m "$MODEL" --arg c "$CALLER" '. + {rule_tier:$t, model:$m, caller:$c}' <<<"$KEYJ")
rc=0; RESP=$(JOBS_ALERT=0 _jobs_req POST /api/jev-risk/claim "$CBODY" 2>/dev/null) || rc=$?
case "$rc" in
  0) ATT=$(jq -r '.row.attempts // empty' <<<"$RESP" 2>/dev/null)
     [[ "$ATT" =~ ^[1-9][0-9]{0,5}$ ]] || skip "claim-unreadable" ;;
  9) case "$(jq -r '.error // empty' <<<"$RESP" 2>/dev/null)" in
       terminal) emit "$(jq -c '.row | {status, jev_tier, jev_prob}' <<<"$RESP")" "$RTIER" cached; exit $? ;;
       in_flight) skip in_flight ;;
       attempt_cap) skip attempt_cap ;;
       *) skip "claim-409" ;;
     esac ;;
  *) skip "worker-unreachable" ;;
esac

# The settle is fenced on this claim's attempt: a caller whose claim went stale
# and was reclaimed can no longer settle over the claim that replaced it.
SKEYJ=$(jq -c --argjson a "$ATT" '. + {attempts:$a}' <<<"$KEYJ")

# 4. the call.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jev-risk.XXXXXX") || skip "mktemp"
trap 'rm -rf "$WORK"' EXIT
if ! jev_question "$RTIER" "$CMP" "$JMAXC" > "$WORK/q"; then
  # Nothing was bought: hand the claim back as failed so it can be asked again.
  JOBS_ALERT=0 _jobs_req POST /api/jev-risk/settle "$(jq -c '. + {status:"failed", error:"compare unreadable; not called"}' <<<"$SKEYJ")" >/dev/null 2>&1
  skip "compare-unreadable"
fi
: > "$WORK/resp"
read -r CODE CRC <<<"$(jev_call "$URL" "$MODEL" "$JT" "$WORK/q" "$WORK/resp")"

# 5 + 6. parse, spool, settle.
OUTC=$(jev_parse "${CODE:-000}" "$WORK/resp" "${CRC:-0}")
SBODY=$(jq -c --argjson o "$OUTC" --rawfile raw "$WORK/resp" '. + $o + {raw:($raw | .[0:8000])}' <<<"$SKEYJ")
mkdir -p "$SPOOLD" 2>/dev/null
( umask 077; printf '%s' "$SBODY" > "$SPOOL" ) || echo "jev-risk: could not write $SPOOL; settling without a spool" >&2
if [ -s "$SPOOL" ]; then
  settle_spool "$SPOOL" || true
else
  JOBS_ALERT=0 _jobs_req POST /api/jev-risk/settle "$SBODY" >/dev/null 2>&1 || echo "jev-risk: settle failed (http ${JOBS_HTTP:-none}) and there is no spool; the claim goes stale and is retried" >&2
fi
emit "$SBODY" "$RTIER"
