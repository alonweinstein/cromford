#!/bin/bash
# remediate-agent.sh <akey> <line> <payload-json> — TIER 2 of the alert
# remediation lane (the operator, 2026-08-25: "every alert gets an attempt, and the
# remediator may try to FIX, not just verify").
#
# Tier 1 is bin/remediations/<namespace>.sh: static, read-only, one namespace
# per file. It covers four alert classes. Everything else — and everything tier
# 1 failed open on — reaches a human today. This is the fallback that gets one
# bounded LLM attempt first.
#
# SAME CONTRACT AS A TIER-1 HANDLER, deliberately: same argv, one line of stdout
# as the summary, exit 0 = remediated / 10 = terminal end state / anything else
# = FAIL OPEN and page. beat.sh treats it exactly like a handler, so nothing in
# the hook has to know which tier answered.
#
# What is different, and why each guard exists:
#   - OPT-IN. Runs only when flags/remediation-agent-enabled exists. This is a
#     hub pilot before it is a fleet behaviour; the flag is created by hand, by
#     a human, on one box.
#   - DAILY CAP. An alert storm must not turn into unbounded LLM spend, so at
#     most REMEDIATE_DAILY_CAP (default 20) agent runs per UTC day. Over cap =
#     fail open, page as today.
#   - PAY FOR A PAYLOAD ONCE. A fingerprint of what the model is about to be
#     asked (akey + line + key-sorted payload) is written to
#     state/remediation-payload-dedup.tsv BEFORE the call and settled after it
#     to ok / empty / failed. Inside REMEDIATE_DEDUP_WINDOW (default 24h) an
#     `ok` or `empty` answer is terminal — an empty answer was billed too — and
#     a failed call is retried to REMEDIATE_DEDUP_CAP (default 3) attempts. A
#     hit fails open with its reason on the page; a cached verdict is never
#     replayed as a suppression, because evidence expires.
#   - EVIDENCE OR IT DID NOT HAPPEN. A suppressing verdict (REMEDIATED /
#     TERMINAL) is honoured ONLY when the agent also printed an EVIDENCE: line
#     quoting the condition check it re-ran. Missing evidence is downgraded to
#     ESCALATE. An agent that can write text can claim anything; an agent that
#     must quote a check it ran has to have run one.
#   - AUDITABLE. Every run's full output is kept at a stable path and that path
#     is written into logs/remediation.log. A lane that may act on production
#     without a human watching leaves a transcript or it does not run.
#
# Authority contract (what it may and may not do): prompts/remediator.md, and
# mechanically bin/remediator-settings.json. Full flow: docs/ALERT-REMEDIATION.md
set -uo pipefail
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$BIN" ] || BIN="$H/bin"

AKEY="${1:-}"; LINE="${2:-}"; PAYLOAD="${3:-}"
AGENT_TIMEOUT="${REMEDIATE_AGENT_TIMEOUT:-300}"

# One tab-separated line per run, same shape as tier 1 plus the transcript path.
# `tier2-dispatch` is beat.sh's line for the same run; this one is the wrapper's.
alog() { # alog <exit> <verdict> <summary> [transcript]
  printf '%s\t%s\t%s\texit=%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$AKEY" "remediate-agent" \
    "$1" "$2" "$(printf '%s' "$3" | tr -d '\t\r' | cut -c1-300)" \
    "transcript=${4:--}" >> "$H/logs/remediation.log" 2>/dev/null || true
}

# fail <verdict-label> <one-line diagnosis> — the diagnosis is what beat.sh
# appends to the alert line, so it is written for the human reading the page.
fail() { alog "${AC_RC:--}" "$1" "$2" "${OUT:-}"; printf '%s\n' "$2"; exit 1; }

mkdir -p "$H/state" "$H/logs" 2>/dev/null
OUT=""; AC_RC="-"

[ -n "$AKEY" ] || { echo "remediate-agent called with no akey"; exit 1; }

# --- 0. the switches, re-checked here ---------------------------------------
# beat.sh checks both before it calls this, and this checks them again: the
# script is directly runnable by a human debugging a lane, and a kill switch
# that only holds on one call path is not a kill switch. The kill switch here
# is the settings row switch.remediation-disabled.<box> or
# switch.remediation-disabled (1 = off), read by lane_switch
# (bin/lib/lane-switch.sh); flags/remediation-disabled decides only when
# neither row exists. beat.sh still reads only the file.
# shellcheck source=lib/lane-switch.sh
. "$BIN/lib/lane-switch.sh" || exit 1
lane_switch remediation-disabled && { echo "remediation kill switch is set"; exit 1; }
[ -f "$H/flags/remediation-agent-enabled" ] \
  || { echo "tier-2 remediator is not enabled on this box (flags/remediation-agent-enabled absent)"; exit 1; }

# --- 1. everything the run needs, before a cap slot is spent ------------------
TPL="${REMEDIATOR_PROMPT:-$H/prompts/remediator.md}"
[ -r "$TPL" ] || { echo "remediator prompt template missing at $TPL"; exit 1; }
[ -x "$BIN/agent-call.sh" ] || { echo "agent-call.sh not executable at $BIN"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 unavailable — cannot render the remediator prompt"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "jq unavailable"; exit 1; }
# Without it there is no fingerprint, and a constant fingerprint would dedup
# every payload against every other one. Refuse rather than guess.
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum unavailable — cannot fingerprint the remediation payload"; exit 1; }

# --- 1b. PAY FOR A PAYLOAD ONCE ----------------------------------------------
# The 6h throttle in beat.sh is keyed on the akey and belongs to the CALLER;
# this script is runnable by hand, so the spend guard lives here too. The key is
# the model's input, not the alert: same akey with a changed line is a new
# question and gets a new call.
DEDUP_WIN="${REMEDIATE_DEDUP_WINDOW:-86400}"
case "$DEDUP_WIN" in ''|*[!0-9]*) DEDUP_WIN=86400 ;; esac
DEDUP_CAP="${REMEDIATE_DEDUP_CAP:-3}"
case "$DEDUP_CAP" in ''|*[!0-9]*) DEDUP_CAP=3 ;; esac
# A zero is not "no window" and not "unlimited attempts" — it is a typo, and
# the safe reading of a typo in a spend guard is the documented default.
[ "$DEDUP_WIN" -gt 0 ] || DEDUP_WIN=86400
[ "$DEDUP_CAP" -gt 0 ] || DEDUP_CAP=3
DL="$H/state/remediation-payload-dedup.tsv"
# jq -cS canonicalises key order so the same facts in a different order are the
# same spend; a payload that is not JSON falls back to its own raw text.
FP=$(printf '%s\n%s\n%s' "$AKEY" "$LINE" \
       "$(jq -cS . <<<"$PAYLOAD" 2>/dev/null || printf '%s' "$PAYLOAD")" \
     | sha256sum | cut -c1-32)
# The ledger holds a hash, a count, an outcome and a sanitised akey. Never the
# payload and never the alert line — this file is spend accounting, not a log.
DKEY=$(printf '%s' "$AKEY" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-60)

# dedup_verdict — rc 0 = MISS (a call may be made), rc 1 = HIT (no call).
# On a HIT it prints the one line the human reading the page gets. Read-only.
dedup_verdict() {
  local now row ts att out age
  now=$(date -u +%s)
  row=$(awk -F'\t' -v k="$FP" '$2==k{r=$0} END{print r}' "$DL" 2>/dev/null)
  [ -n "$row" ] || return 0
  ts=$(printf '%s' "$row" | cut -f1);  case "$ts"  in ''|*[!0-9]*) ts=0  ;; esac
  att=$(printf '%s' "$row" | cut -f3); case "$att" in ''|*[!0-9]*) att=0 ;; esac
  out=$(printf '%s' "$row" | cut -f4)
  age=$(( now - ts ))
  [ "$age" -ge "$DEDUP_WIN" ] && return 0
  # An empty answer is a paid answer: the same question buys the same nothing.
  case "$out" in
    ok|empty)
      printf 'this exact alert payload already got an agent run %ss ago (outcome: %s) — not paying for it again inside %ss\n' \
        "$age" "$out" "$DEDUP_WIN"
      return 1 ;;
  esac
  # pending counts as failed: a run killed between the claim and the outcome
  # still spent its attempt.
  if [ "$att" -ge "$DEDUP_CAP" ]; then
    printf 'this exact alert payload already failed %s agent attempts (cap %s) in the last %ss — no further attempt\n' \
      "$att" "$DEDUP_CAP" "$DEDUP_WIN"
    return 1
  fi
  return 0
}

# dedup_claim — rc 0 = claimed (the row is on disk as pending), rc 1 = HIT (the
# diagnosis is on stdout), rc 2 = could not persist, so nothing is spent. The
# verdict is re-read under the lock: that is what makes two identical runs
# racing each other cost one attempt slot each at most, not one call each tick.
dedup_claim() {
  local now
  now=$(date -u +%s)
  # The ledger has to be a REGULAR file, checked explicitly. If the path is a
  # directory, `touch` still succeeds, `mv` lands the new table INSIDE it, and
  # the marker is silently lost while the call goes out — and awk is no backstop
  # for that: mawk errors on a directory argument, gawk warns and skips it with
  # rc 0, so the same code would refuse on one box and spend on the next.
  if [ -e "$DL" ] && [ ! -f "$DL" ]; then return 2; fi
  touch "$DL" 2>/dev/null || return 2
  [ -f "$DL" ] || return 2
  ( exec 9>"$DL.lock" 2>/dev/null || exit 2
    flock -w 5 9 || exit 2
    dedup_verdict || exit 1
    awk -F'\t' -v k="$FP" -v now="$now" -v win="$DEDUP_WIN" -v ak="$DKEY" '
      BEGIN { OFS = "\t" }
      ($1 + 0) < now - 2 * win { next }              # prune, bounded growth
      $2 == k { if (now - ($1 + 0) < win) a = $3 + 0; next }
      { print }
      END { print now, k, a + 1, "pending", ak }
    ' "$DL" > "$DL.tmp" 2>/dev/null || exit 2
    mv -f "$DL.tmp" "$DL" 2>/dev/null || exit 2
    exit 0 )
}

# dedup_settle <ok|empty|failed> — what the call turned out to be. A write that
# fails leaves the row `pending`, which the verdict above already counts as a
# spent failed attempt, so the failure mode is one wasted retry, never a lost
# alert.
dedup_settle() {
  local now o="$1"
  now=$(date -u +%s)
  ( exec 9>"$DL.lock" 2>/dev/null || exit 1
    flock -w 5 9 || exit 1
    awk -F'\t' -v k="$FP" -v now="$now" -v win="$DEDUP_WIN" -v o="$o" -v ak="$DKEY" '
      BEGIN { OFS = "\t" }
      ($1 + 0) < now - 2 * win { next }
      $2 == k { t = $1; a = $3 + 0; next }
      { print }
      END { if (t == "") { t = now; a = 1 } print t, k, a, o, ak }
    ' "$DL" > "$DL.tmp" 2>/dev/null || exit 1
    mv -f "$DL.tmp" "$DL" 2>/dev/null || exit 1 ) \
  || alog "${AC_RC:--}" dedup-settle "could not record the '$o' outcome for this payload marker"
}

# Read-only lookup FIRST, before a daily-cap slot is spent: a storm of one
# identical payload must not starve the real remediations behind it.
DEDUP_MSG=$(dedup_verdict) \
  || { alog - FAILOPEN-dedup "$DEDUP_MSG"; printf '%s\n' "$DEDUP_MSG"; exit 1; }

PROJECT=$(jq -r '.project // ""' <<<"$PAYLOAD" 2>/dev/null)
case "$PROJECT" in ''|*[!A-Za-z0-9_.-]*) PROJECT=fleet ;; esac
# >>> model-route (BH-1510.2): model_routes role `remediate` (REMEDIATE_MODEL
# still wins when set). No route = rc 75 before the daily-cap slot, the dedup
# marker or any spend, alerted by bin/lib/model-route.sh; nothing is guessed.
. "$BIN/lib/lane-model.sh"
MODEL=$(lane_model REMEDIATE_MODEL remediate "$PROJECT") \
  || { alog 75 NO-ROUTE "no model route for role remediate"; echo "no model route for role remediate — no model call made"; exit 75; }
# <<< model-route

# --- 2. DAILY CAP, claimed before the run ------------------------------------
# Claim-first, same discipline as the 6h throttle: a run that hangs or is killed
# must still have consumed its slot, or a storm re-enters here every tick.
CAP="${REMEDIATE_DAILY_CAP:-20}"
case "$CAP" in ''|*[!0-9]*) CAP=20 ;; esac
CF="$H/state/remediation-agent-$(date -u +%Y%m%d).count"
( exec 8>"$CF.lock"; flock -w 5 8 || exit 1
  n=$(cat "$CF" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -ge "$CAP" ] && exit 2
  echo $(( n + 1 )) > "$CF"
  # yesterday's counters are noise, not history — the cost ledger has the truth
  find "$H/state" -maxdepth 1 -name 'remediation-agent-*.count*' -mtime +3 -delete 2>/dev/null
  exit 0 )
CRC=$?
[ "$CRC" = 2 ] && { alog - FAILOPEN-cap "daily agent cap reached ($CAP/day)"; \
  echo "tier-2 daily cap reached ($CAP runs/day) — failing open"; exit 1; }
[ "$CRC" = 0 ] || { alog - FAILOPEN-cap "could not claim a daily-cap slot"; \
  echo "could not claim a tier-2 daily-cap slot"; exit 1; }

# --- 3. a scratch working dir, never a repo checkout --------------------------
# The agent runs with cwd HERE. A repo checkout as cwd is how an unattended
# session ends up committing, and the one thing this lane must never do by
# accident is touch a working tree that someone's build depends on.
SROOT="$H/state/remediation-scratch"
mkdir -p "$SROOT" 2>/dev/null
WORK=$(mktemp -d "$SROOT/run-XXXXXX" 2>/dev/null) || { alog - FAILOPEN "no scratch dir"; \
  echo "could not create a scratch working dir"; exit 1; }
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

# --- 4. the transcript, kept OUTSIDE the scratch dir --------------------------
SAFE=$(printf '%s' "$AKEY" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-80)
mkdir -p "$H/logs/remediator" 2>/dev/null
OUT="$H/logs/remediator/$(date -u +%Y%m%dT%H%M%SZ)-$SAFE-$$.txt"

# --- 5. render the prompt ----------------------------------------------------
# Substitution in python rather than sed: an alert line or payload carries &, /,
# newlines and quotes, and every one of those is a sed escaping bug waiting to
# rewrite the authority contract it is being pasted next to.
PF="$WORK/prompt.md"
REM_AKEY="$AKEY" REM_LINE="$LINE" REM_PAYLOAD="$PAYLOAD" \
python3 - "$TPL" > "$PF" 2>/dev/null <<'PY'
import os, sys
t = open(sys.argv[1]).read()
for k in ("AKEY", "LINE", "PAYLOAD"):
    t = t.replace("{{%s}}" % k, os.environ.get("REM_" + k, ""))
sys.stdout.write(t)
PY
[ -s "$PF" ] || fail FAILOPEN "remediator prompt failed to render — no attempt made"

# --- 6. the tool policy ------------------------------------------------------
# ONE SOURCE OF TRUTH. The deny list is authored once in remediator-settings.json
# and handed to claude twice: as a settings file and as --disallowedTools. Two
# hand-maintained copies of a deny list is how one of them ends up shorter.
#
# HONEST SCOPE, because a deny list is easy to over-credit: --disallowedTools is
# the layer this lane relies on. The settings `permissions.deny` block is
# belt-and-braces and is NOT verified to bind under --dangerously-skip-permissions,
# which agent-call.sh passes on every claude call. Neither layer can express
# "push to any branch except main" — prefix rules have no way to say it — so the
# never-push-main rule is carried by the MUST rules in the prompt and by the
# transcript that makes a breach visible after the fact. That is a real gap and
# it is why the pilot is opt-in on one box.
SETTINGS="$BIN/remediator-settings.json"
DENY=""
[ -r "$SETTINGS" ] && DENY=$(jq -r '.permissions.deny[]?' "$SETTINGS" 2>/dev/null)
[ -n "$DENY" ] || fail FAILOPEN "tool policy unreadable at $SETTINGS — refusing to run the remediator unbounded"


SYSAPPEND="You are the harness tier-2 alert remediator. HARD BOUNDS, no exceptions: never merge/close/edit a PR, never push to main, never write a production database or apply a migration, never run a Vercel action, never destroy or stop a machine, never read or print anything under env/, never install anything, never edit files under bin/ or rules/. When in doubt, answer ESCALATE. Your last two lines must be an EVIDENCE: line and a VERDICT: line."

# --- 7. one bounded attempt --------------------------------------------------
# @<path> prompt form: agent-call.sh reads the file, which keeps a big payload
# out of argv (a >128KB argv element fails execve before the script runs).
cd "$WORK" 2>/dev/null || fail FAILOPEN "could not enter the scratch dir"

# The marker goes down BEFORE the money goes out. If it cannot be written, the
# call does not happen: an unrecorded spend is the one this guard cannot bound.
DEDUP_MSG=$(dedup_claim); DCRC=$?
case "$DCRC" in
  1) alog - FAILOPEN-dedup "$DEDUP_MSG"; printf '%s\n' "$DEDUP_MSG"; exit 1 ;;
  0) ;;
  *) alog - FAILOPEN-dedup "could not persist the payload marker at $DL"
     echo "could not persist the payload marker for this alert — no model call made"; exit 1 ;;
esac

AGENT_SETTINGS="$SETTINGS" \
AGENT_DISALLOWED_TOOLS="$DENY" \
AGENT_SYSTEM_APPEND="$SYSAPPEND" \
  "$BIN/agent-call.sh" remediate "$PROJECT" "$MODEL" "$AGENT_TIMEOUT" "$OUT" "@$PF" >/dev/null 2>&1
AC_RC=$?

# --- 8. read the verdict -----------------------------------------------------
VLINE=$(grep -aE '^[[:space:]]*VERDICT:' "$OUT" 2>/dev/null | tail -1)
ELINE=$(grep -aE '^[[:space:]]*EVIDENCE:' "$OUT" 2>/dev/null | tail -1)
BODY=$(printf '%s' "$VLINE" | sed -E 's/^[[:space:]]*VERDICT:[[:space:]]*//')
WORD=$(printf '%s' "$BODY" | awk '{print toupper($1)}')
SUM=$(printf '%s' "$BODY" | sed -E 's/^[A-Za-z_-]+[[:space:]]*[-:—]?[[:space:]]*//' | tr -d '\t\r' | cut -c1-200)
[ -n "$SUM" ] || SUM="(no summary)"

# --- 8b. settle the payload marker, before any exit path ---------------------
# The lane's rc decides first: a non-zero call is `failed` whatever text landed
# in the file, and it may be retried to the cap. rc 0 with no VERDICT: line is
# `empty` — the model answered, we were billed, and the answer was not usable.
if   [ "$AC_RC" != 0 ]; then dedup_settle failed
elif [ -z "$VLINE" ];   then dedup_settle empty
else                         dedup_settle ok
fi

# A non-zero agent-call means the LANE failed — timeout, crash, every runner
# down. Whatever text landed in the file is not a verdict anyone should act on,
# so it never suppresses; at most it enriches the page that follows.
if [ "$AC_RC" != 0 ]; then
  case "$AC_RC" in
    124|137) fail FAILOPEN-timeout "remediator timed out after ${AGENT_TIMEOUT}s — no verdict" ;;
    *)       fail FAILOPEN-crash   "remediator lane failed (rc=$AC_RC) — no verdict" ;;
  esac
fi
[ -n "$VLINE" ] || fail FAILOPEN-parse "remediator returned no VERDICT: line — treating as escalate"

case "$WORD" in
  REMEDIATED|TERMINAL)
    # THE EVIDENCE RULE. Both suppressing verdicts need it, not just
    # REMEDIATED: TERMINAL suppresses the alert just as completely, so an
    # unevidenced "nothing is owed here" is the same failure wearing a calmer
    # word. Fail-open is worth more than any suppression this lane will make.
    if [ -z "$ELINE" ]; then
      fail FAILOPEN-noevidence "claimed $WORD without re-checking the condition (no EVIDENCE line) — escalated instead: $SUM"
    fi
    EV=$(printf '%s' "$ELINE" | sed -E 's/^[[:space:]]*EVIDENCE:[[:space:]]*//' | tr -d '\t\r' | cut -c1-200)
    alog 0 "$WORD" "$SUM | evidence: $EV" "$OUT"
    printf '%s: %s | evidence: %s\n' "$WORD" "$SUM" "$EV"
    [ "$WORD" = TERMINAL ] && exit 10
    exit 0 ;;
  ESCALATE)
    fail FAILOPEN-escalate "$SUM" ;;
  *)
    fail FAILOPEN-parse "unparseable verdict '${WORD:-empty}' — treating as escalate" ;;
esac
