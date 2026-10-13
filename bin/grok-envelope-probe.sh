#!/bin/bash
# bin/grok-envelope-probe.sh [--model <m>] [--out <dir>] [--flip] [--force]
#
# BH-1636 item 1. ONE metered grok call that answers the question GROK_OUTPUT_JSON
# has been waiting on since BH-1494: does grok's `--output-format json` envelope
# carry the answer at `.result`, and does it price? It asks grok to echo a
# nonce, then checks the envelope for that nonce at `.result` and runs
# bin/grok-usage.sh --envelope over it for a non-zero dollar figure. It keeps
# what it saw in the fixture layout tests/cost-grok-usage.bh-1494-test.sh §A8
# reads, and with --flip, and only after an `ok` verdict, writes the settings
# row lib.agent-call.grok_output_json=1 and reads it back.
#
# Run BY HAND on a box with grok >= the catalog floor and working grok auth
# (project-4 has run grok triage since 2026-09-20). It is not a cron lane: a lane
# would spend against an xAI team that has sat at its credit cap.
#
#   /root/harness/bin/grok-envelope-probe.sh --flip
#   then, in a PR: cp -r /root/harness/state/grok-probe/<version> tests/fixtures/grok-usage/
#
# NEVER TWICE, NEVER BLIND. The job ledger (kind grok-envelope-probe, key
# <grok version>:<model>) is read before the call. `ok` and `billed-fail` mean
# this probe was already paid for: nothing is called (--force buys another).
# `refused` (the vendor served nothing) and a `started:<epoch>` over an hour old
# (a crashed or timed-out run) are retried. A `started` row younger than that is
# a probe in flight. A ledger this box cannot read or write is a refusal to
# spend. The `started` status carries its epoch because a status is all
# `jobs-client.sh ledger-get` returns.
#
# EVERY CALL THAT REACHED THE VENDOR IS COSTED (the operator, 2026-09-24: "A billed grok
# call must land a priced cost row"). One logs/cost.csv row per call, stage
# grok-envelope-probe, written through bin/lib/cost-row.sh's cost_row_emit and
# priced from its tokens at catalog/model-prices.json (BH-3984), else the
# envelope's own dollars (always kept in result_usd), else a blank cost_usd with
# UNPRICED:* in the note (never a made-up 0). A vendor refusal with no usage is a priced $0
# naming the refusal. The row lands BEFORE the ledger verdict, so a ledger that
# dies after the call still leaves the spend on the books. A run that stops
# before the call writes no row: nothing was spent. The DB copy of the row comes
# from the */10 bin/cost-rows-push.sh mirror (this script does not load the jobs
# client, so cost_row_emit's at-source POST is skipped, as in claude-cost.sh).
#
# Exit codes: 0 ok (or already probed), 1 the probe ran and failed (refused,
# billed-fail), 3 nothing to probe with (no grok, below the floor, no model
# route), 4 the ledger was unusable (no call, or a call it could not record),
# 5 the flip did not read back. Every non-zero exit writes ONE ALERTS.log line.
#
# Test seams (env): GROK_PROBE_HOME (where .grok lives, default $HOME),
# GROK_PROBE_JOBS (the jobs-client to call), GROK_PROBE_CATALOG, HARNESS_ALERTS,
# MODEL_PRICES (cost-row.sh's price table). The row's project is
# ${COST_PROJECT:-fleet}; ticket/job/pr/run tags come from COST_KEY/COST_JOB/
# COST_PR/COST_RUN_ID. A lane that ever runs this unattended needs a cap on
# `refused` retries first: they are uncapped because the probe is hand-run.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ALERTS="${HARNESS_ALERTS:-$H/logs/ALERTS.log}"
GHOME="${GROK_PROBE_HOME:-$HOME}"
JOBS="${GROK_PROBE_JOBS:-$HERE/jobs-client.sh}"
CATALOG="${GROK_PROBE_CATALOG:-$HERE/../catalog/cli-min-versions.json}"
GU="$HERE/grok-usage.sh"
KIND=grok-envelope-probe
KEY_SETTING=lib.agent-call.grok_output_json
STALE_S=3600
BOX=$(tr -dc 'a-z0-9-' 2>/dev/null < "$H/state/box-id"); BOX="${BOX:-$(hostname 2>/dev/null)}"
# shellcheck source=bin/lib/cli-version.sh
. "$HERE/lib/cli-version.sh"
# The cost-row writer, sibling first (bin/agent-call.sh's chain). A box whose
# sync has not landed it still appends the raw row: the row write never fails
# the probe and never goes missing.
# shellcheck source=/dev/null
if   [ -r "$HERE/lib/cost-row.sh" ];  then . "$HERE/lib/cost-row.sh"
elif [ -r "$H/bin/lib/cost-row.sh" ]; then . "$H/bin/lib/cost-row.sh"; fi
# shellcheck source=/dev/null
if   [ -r "$HERE/auth-fingerprint.sh" ];  then . "$HERE/auth-fingerprint.sh"
elif [ -r "$H/bin/auth-fingerprint.sh" ]; then . "$H/bin/auth-fingerprint.sh"; fi
command -v cost_append         >/dev/null 2>&1 || cost_append()         { printf '%s\n' "$1" >> "$COST"; }
command -v cost_row_emit       >/dev/null 2>&1 || cost_row_emit()       { cost_append "$1"; }
command -v cost_csv_field      >/dev/null 2>&1 || cost_csv_field()      { printf '%s' "${1:-}" | tr -d '\r\n"' | tr ',' ' '; }
command -v cost_row_tags       >/dev/null 2>&1 || cost_row_tags()       { printf ',,,'; }
command -v cost_row_price      >/dev/null 2>&1 || cost_row_price()      { printf '%s|%s' "${8:-}" "${9:-}"; }
command -v cost_price_tokens   >/dev/null 2>&1 || cost_price_tokens()   { printf ''; return 1; }
command -v auth_fp_for_runner  >/dev/null 2>&1 || auth_fp_for_runner()  { echo none; }
command -v auth_account_for_fp >/dev/null 2>&1 || auth_account_for_fp() { echo unknown; }
COST="$H/logs/cost.csv"
HARNESS="$H"

MODEL=""; OUTDIR=""; FLIP=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="${2:-}"; shift 2 ;;
    --out)   OUTDIR="${2:-}"; shift 2 ;;
    --flip)  FLIP=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,51p' "$0"; exit 0 ;;
    *) echo "grok-envelope-probe: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say()   { echo "grok-envelope-probe: $*"; }
stop()  { # stop <rc> <what happened> <next step> — the one ALERTS line, then exit
  mkdir -p "$(dirname "$ALERTS")" 2>/dev/null
  echo "$(STAMP) [$BOX] grok-envelope-probe: $2. Next: $3" >> "$ALERTS"
  say "$2 (exit $1). Next: $3"
  exit "$1"
}

# --- 1. the binary and its floor (nothing spent) ---------------------------------
GROK=""
if [ -x "$GHOME/.grok/bin/grok" ]; then GROK="$GHOME/.grok/bin/grok"; else GROK=$(command -v grok 2>/dev/null || true); fi
[ -n "$GROK" ] || stop 3 "no grok binary ($GHOME/.grok/bin/grok or PATH)" "run this on a box with grok installed (bin/cli-update.sh installs it)"
VER=$(cli_version_of "$GROK") || VER=""
[ -n "$VER" ] && [ "$VER" != missing ] || stop 3 "$GROK --version printed no version" "check the grok install on this box"

# --- 2. the model: --model, else grok.default rung 0 (never a literal) -------------
if [ -z "$MODEL" ]; then
  # shellcheck source=bin/lib/model-route.sh
  . "$HERE/lib/model-route.sh"
  MODEL=$(model_for grok.default 2>/dev/null) || MODEL=""
fi
[ -n "$MODEL" ] || stop 3 "no model: model_routes has no grok.default row and this box has no cached one" "seed grok.default in model_routes, or pass --model"
case "$MODEL" in *[!A-Za-z0-9._/-]*) stop 3 "model '$MODEL' is not id-shaped" "pass a model id" ;; esac

# The floor is the catalog's for this model; a model the catalog does not name
# gets the highest grok floor it carries, so an unlisted model is not unfloored.
FLOOR=""
read -r _ FLOOR < <(cli_min_for_model "$CATALOG" "$MODEL" 2>/dev/null) || FLOOR=""
if [ -z "$FLOOR" ]; then
  while read -r v; do
    [ -n "$v" ] && { [ -z "$FLOOR" ] || cli_version_gt "$v" "$FLOOR"; } && FLOOR="$v"
  done < <(jq -r '.models[]? | select(.cli=="grok") | .min' "$CATALOG" 2>/dev/null)
fi
[ -n "$FLOOR" ] || stop 3 "no grok floor in $CATALOG" "check catalog/cli-min-versions.json"
cli_version_ge "$VER" "$FLOOR" || stop 3 "grok $VER is below the $FLOOR floor for $MODEL, nothing spent" "run bin/cli-update.sh on $BOX, then re-run this probe"

LKEY="$VER:$MODEL"
OUTDIR="${OUTDIR:-$H/state/grok-probe/$VER}"
say "grok $VER at $GROK, model $MODEL (floor $FLOOR), ledger $KIND/$LKEY"

# --- 3. dedup before spend ---------------------------------------------------------
PRIOR=$("$JOBS" ledger-get "$KIND" "$LKEY" 2>/dev/null | tr -d '\r\n'); LRC=${PIPESTATUS[0]}
case "$LRC" in
  0|2) ;;
  *) stop 4 "the job ledger is unreachable (ledger-get rc=$LRC), so whether this probe was already paid for is unknown; nothing was called" "fix the worker or HARNESS_SECRET on $BOX, then re-run" ;;
esac
[ "$LRC" = 2 ] && PRIOR=""
if [ -n "$PRIOR" ] && [ "$FORCE" != 1 ]; then
  case "$PRIOR" in
    ok|billed-fail)
      say "already probed: $KIND/$LKEY is '$PRIOR'. Nothing called. --force buys another probe."
      exit 0 ;;
    started:*)
      # Digits only before it meets $(( )): bash arithmetic evaluates what it is
      # given, and this string came back from the network. Unparseable = stale.
      SEP="${PRIOR#started:}"; [[ "$SEP" =~ ^[0-9]{1,12}$ ]] || SEP=0
      AGE=$(( $(date +%s) - 10#$SEP ))
      if [ "$AGE" -lt "$STALE_S" ]; then
        stop 4 "a probe for $LKEY started ${AGE}s ago and has no verdict yet; not doubling it" "wait for it, or re-run with --force if that run is dead"
      fi
      say "a started row ${AGE}s old has no verdict: a crashed run. Probing again." ;;
  esac
fi
"$JOBS" ledger-put "$KIND" "$LKEY" "started:$(date +%s)" "box=$BOX" >/dev/null 2>&1 \
  || stop 4 "could not write the started row to the job ledger; nothing was called" "fix the worker or HARNESS_SECRET on $BOX, then re-run"

# --- 4. the call: exactly one, bounded ------------------------------------------------
W=$(mktemp -d "${TMPDIR:-/tmp}/grok-probe.XXXXXX") || stop 4 "no temp dir" "check /tmp on $BOX"
trap 'rm -rf "$W"' EXIT
NONCE="probe-$(date +%s)-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
PROMPT="Reply with exactly this token and nothing else: $NONCE"
UJ="$GHOME/.grok/logs/unified.jsonl"
OFF=$(stat -c %s "$UJ" 2>/dev/null || echo 0)
GENV=(env); [ "${GROK_BILLING:-}" = api ] || GENV=(env -u XAI_API_KEY -u GROK_CODE_XAI_API_KEY)
T0=$(date +%s)
CMD_SHOWN="grok --always-approve --output-format json --max-turns 1 -m $MODEL -p \"Reply with exactly this token and nothing else: <nonce>\""
timeout 180 "${GENV[@]}" PATH="$GHOME/.grok/bin:$PATH" "$GROK" --always-approve --output-format json \
  --max-turns 1 -m "$MODEL" -p "$PROMPT" </dev/null > "$W/envelope.json" 2> "$W/stderr"
CRC=$?
T1=$(date +%s)

# --- 5. the verdict ---------------------------------------------------------------------
# The refusal patterns are bin/agent-call.sh's ac_refusal_note (its
# LADDER_CREDITS_REGEX and vendor status tokens) plus xAI's "credit limit"
# wording; that file is a lane, not a library, so it cannot be sourced here.
REFUSAL_RE='key limit exceeded|credit[ _]limit|insufficient[ _](credits|quota|funds|balance)|out[ _]of[ _]credits|credit balance( is)? too low|credits? (exhausted|depleted)|billing_error|payment required|quota exceeded'
STATUS_RE='(API Error|HTTP|status(_code)?|"code")[": ]+(401|402|403|429)\b'
VERDICT=""; DETAIL=""; GU_LINE=""
if [ "$CRC" != 0 ] && grep -qiE "$REFUSAL_RE|$STATUS_RE" "$W/stderr" "$W/envelope.json" 2>/dev/null; then
  VERDICT=refused; DETAIL="rc=$CRC $(grep -oiE "$REFUSAL_RE|$STATUS_RE" "$W/stderr" "$W/envelope.json" 2>/dev/null | head -1 | cut -d: -f2- | tr -cd 'A-Za-z0-9 _.-')"
elif [ "$CRC" != 0 ]; then
  VERDICT=billed-fail; DETAIL="rc=$CRC"
elif [ ! -s "$W/envelope.json" ]; then
  VERDICT=billed-fail; DETAIL=empty-envelope
elif ! jq -e --arg n "$NONCE" 'type=="object" and (.result|type)=="string" and (.result|contains($n))' "$W/envelope.json" >/dev/null 2>&1; then
  VERDICT=billed-fail; DETAIL=result-field-miss
else
  GU_LINE=$("$GU" --envelope "$W/envelope.json" 0 "$W/no-walk" 2>/dev/null || true)
  IFS='|' read -r G_IN G_OUT _ _ G_USD <<<"${GU_LINE// /|}"
  if [ -z "$G_USD" ] || ! awk -v u="$G_USD" 'BEGIN{exit !(u+0 > 0)}'; then
    VERDICT=billed-fail; DETAIL=unpriced
  else
    VERDICT=ok; DETAIL="result=ok usd=$G_USD in=$G_IN out=$G_OUT"
  fi
fi

# --- 6/7. capture, after the secret scan (a refused call has nothing to keep) ----------
SID=""; CAPTURED=0
if [ "$VERDICT" != refused ] && [ -s "$W/envelope.json" ]; then
  mkdir -p "$W/cap"
  cp "$W/envelope.json" "$W/cap/envelope.json"
  SID=$(jq -r 'if type=="object" then (.session_id // .sessionId // .session.id // empty) else empty end' "$W/envelope.json" 2>/dev/null | head -1)
  UJ_NOTE=""
  if [ -z "$SID" ]; then
    UJ_NOTE="not written: the envelope carries no session id, so no line of $UJ can be tied to this call"
  elif [ ! -s "$UJ" ]; then
    UJ_NOTE="not written: $UJ does not exist or is empty"
  else
    SZ=$(stat -c %s "$UJ" 2>/dev/null || echo 0); [ "$SZ" -ge "$OFF" ] || OFF=0
    tail -c +$((OFF+1)) "$UJ" | grep -F -- "$SID" > "$W/cap/unified.jsonl"
    if [ -s "$W/cap/unified.jsonl" ]; then
      UJ_NOTE="$(wc -l < "$W/cap/unified.jsonl") line(s) appended to $UJ after byte $OFF that carry session $SID"
    else
      rm -f "$W/cap/unified.jsonl"
      UJ_NOTE="not written: no line appended to $UJ during the call carries session $SID"
    fi
  fi
  WALK_LINE="(no unified.jsonl captured)"
  if [ -s "$W/cap/unified.jsonl" ]; then
    mkdir -p "$W/walk/logs"; cp "$W/cap/unified.jsonl" "$W/walk/logs/unified.jsonl"
    WALK_LINE=$("$GU" 0 "$W/walk" 2>/dev/null || true)
  fi
  ENV_LINE=$("$GU" --envelope "$W/envelope.json" 0 "$W/no-walk" 2>/dev/null || true)
  cat > "$W/cap/PROVENANCE.md" <<EOF
# CAPTURED — grok $VER \`--output-format json\` envelope (bin/grok-envelope-probe.sh)

Captured by a real metered call, not reconstructed.

| | |
|---|---|
| box | $BOX |
| captured (UTC) | $(date -u '+%Y-%m-%dT%H:%M:%SZ') |
| grok version | $VER ($GROK) |
| model | $MODEL |
| command | \`$CMD_SHOWN\` |
| exit code | $CRC |
| verdict | $VERDICT ($DETAIL) |
| session id | ${SID:-none (no session id in the envelope)} |

## Files

- \`envelope.json\`: the CLI's stdout, verbatim.
- \`unified.jsonl\`: $UJ_NOTE.

## bin/grok-usage.sh over them (input output cache_read cache_write usd)

- \`grok-usage.sh --envelope envelope.json 0\` printed: \`$ENV_LINE\`
- \`grok-usage.sh 0 <dir holding logs/unified.jsonl>\` printed: \`$WALK_LINE\`
EOF
  if grep -qE 'xai-[A-Za-z0-9]{20,}|Bearer |"(access|refresh|id)_token"' "$W/cap"/* 2>/dev/null \
     || grep -qi 'authorization' "$W/cap"/* 2>/dev/null; then
    VERDICT=billed-fail; DETAIL=secret-in-capture
    say "the capture carries a credential-shaped string; nothing written to $OUTDIR"
  else
    mkdir -p "$OUTDIR" && cp "$W/cap"/* "$OUTDIR/" && CAPTURED=1
  fi
fi

say "verdict $VERDICT ($DETAIL)"
[ "$CAPTURED" = 1 ] && say "captured to $OUTDIR: $(cd "$OUTDIR" && ls | paste -sd' ')"

# --- the cost row: the call reached the vendor, so it is costed, whatever the verdict ------
# Written after the secret scan (the note carries the FINAL verdict) and before
# the ledger verdict, so an unrecorded verdict is never an uncosted spend.
C_IN=""; C_OUT=""; C_CR=""; C_CW=""; G_USD=""; ROW_SRC=none
if [ -s "$W/envelope.json" ]; then
  C_LINE=$("$GU" --envelope "$W/envelope.json" 0 "$W/no-walk" 2>/dev/null || true)
  IFS='|' read -r C_IN C_OUT C_CR C_CW G_USD <<<"${C_LINE// /|}"
  [ -n "$C_IN$C_OUT$C_CR$C_CW$G_USD" ] && ROW_SRC=result
fi
C_USD="$G_USD"; C_NOTE="probe:$VERDICT:$DETAIL"
# The fleet's price of the tokens is cost_usd whenever the table can price them
# (BH-3984, bin/agent-call.sh's grok rule); the envelope's own dollars stay in
# result_usd (G_USD) and are cost_usd only for a model the table lacks.
if [ -n "$C_IN$C_OUT$C_CR$C_CW" ]; then
  _GP=$(cost_price_tokens "$MODEL" "$C_IN" "$C_OUT" "$C_CR" "$C_CW") || _GP=""
  [ -n "$_GP" ] && C_USD="$_GP"
fi
# A refusal that reported no usage billed nothing: a priced $0, the reason in
# the note (the rule bin/agent-call.sh applies to an openrouter refusal).
[ "$VERDICT" = refused ] && [ -z "$C_IN$C_OUT$C_CR$C_CW$C_USD" ] && C_USD=0
C_PN=$(cost_row_price grok "$MODEL" "$CRC" "$C_IN" "$C_OUT" "$C_CR" "$C_CW" "$C_USD" "$C_NOTE")
C_USD="${C_PN%%|*}"; C_NOTE="${C_PN#*|}"
BMODE=$("${GENV[@]}" "$HERE/billing-mode.sh" grok 2>/dev/null) || BMODE=""
AUTH_FP=$( [ "${GROK_BILLING:-}" = api ] || unset XAI_API_KEY GROK_CODE_XAI_API_KEY; HOME="$GHOME" auth_fp_for_runner grok 2>/dev/null) || AUTH_FP=""
AUTH_ACCT=$(auth_account_for_fp "${AUTH_FP:-none}" 2>/dev/null) || AUTH_ACCT=""
ROW="$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$(hostname),$(cost_csv_field "${COST_PROJECT:-fleet}"),$KIND,grok,$(cost_csv_field "$MODEL"),$CRC,$((T1-T0)),$C_IN,$C_OUT,$C_CR,$C_CW,$C_USD,$(cost_csv_field "${BMODE:-unknown}"),$(cost_csv_field "${AUTH_FP:-none}"),$(cost_csv_field "${AUTH_ACCT:-unknown}"),$(cost_csv_field "$SID"),$ROW_SRC,$G_USD,$(cost_row_tags),$(cost_csv_field "$C_NOTE"),$(cost_csv_field "${AGENT_CALL_LANE:-}")"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
[ -f "$COST" ] || printf '%s\n' "${COST_ROW_HDR:-ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id}" > "$COST" 2>/dev/null
cost_row_emit "$ROW" || true
say "cost row: $KIND grok $MODEL rc=$CRC usd=${C_USD:-blank}${C_NOTE:+ ($C_NOTE)}"

# --- the ledger records the verdict BEFORE anything acts on it ----------------------------
if ! "$JOBS" ledger-put "$KIND" "$LKEY" "$VERDICT" "$DETAIL" >/dev/null 2>&1; then
  stop 4 "probe $LKEY ran (verdict $VERDICT: $DETAIL) but the job ledger did not take the verdict; not flipping an unrecorded spend" \
    "fix the worker, then: $JOBS ledger-put $KIND $LKEY $VERDICT '$DETAIL'"
fi
case "$VERDICT" in
  refused) stop 1 "probe $LKEY refused by the vendor ($DETAIL); nothing billed, GROK_OUTPUT_JSON unchanged" "re-run once the xAI team has credit or grok auth works" ;;
  billed-fail) stop 1 "probe $LKEY billed and failed ($DETAIL); GROK_OUTPUT_JSON unchanged" "read ${OUTDIR} (if written) to see what the envelope carries; bin/agent-call.sh reads .result" ;;
esac

# --- 8. the flip ------------------------------------------------------------------------
NOTE="BH-1636 probe $VER/$MODEL on $BOX $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [ "$FLIP" != 1 ]; then
  say "not flipped (no --flip). To flip: $HERE/jobs-client.sh setting-set $KEY_SETTING 1 \"$NOTE\""
  exit 0
fi
"$JOBS" setting-set "$KEY_SETTING" 1 "$NOTE" >/dev/null 2>&1 \
  || stop 5 "setting-set $KEY_SETTING 1 failed after an ok probe" "re-run: $HERE/jobs-client.sh setting-set $KEY_SETTING 1 \"$NOTE\""
BACK=$("$JOBS" setting-get "$KEY_SETTING" 2>/dev/null | tr -d '\r\n')
[ "$BACK" = 1 ] || stop 5 "$KEY_SETTING read back '$BACK' after setting it to 1" "check GET /api/settings/$KEY_SETTING and set it again"
say "flipped: $KEY_SETTING = 1 (read back)"
exit 0
