#!/bin/bash
# gh-identity: app-token
# bin/alerts-merge-resolve.sh [--dry] [--closed <owner/repo#N>...] [--queued <owner/repo#N>...]
#   — close pipeline-health's merge alerts once the PRs they name have settled.
#   (BH-3997, 2026-10-03.)
#
# WHY. "<P>: harness PR(s) #a,#b open >12h awaiting merge" and the two "… not in
# the merge queue" alerts stayed open on the console for a day after every PR
# they named had merged. pipeline-health's own retraction goes to `info` and
# never reaches the console row, and the PR-close settlers (bin/alerts-groom.sh
# rule 1, bin/alerts-resolve-closed-prs.sh) never match these lines. This is
# the one place that does, for exactly these three families:
#   awaitmerge       "[pipeline-health] <P>: harness PR(s) #…  open >12h awaiting merge"
#   leadunqueued     "[pipeline-health] <owner/repo> #N has lead-verdict success … not in the merge queue"
#   approveunqueued  "[pipeline-health] https://github.com/<owner/repo>/pull/N is APPROVE … OPEN and CLEAN … not in the merge queue"
# The PRs come from the line's `prs=` token, or (rows written before it
# existed) from the prose, with an awaitmerge row's repo read from fleet.conf.
#
# MODES
#   PASS  (no --closed/--queued; run by bin/alerts-groom.sh every pass): one
#         REST read per distinct PR (ETag-cached, GH_REST_OPTIONAL) and one read
#         of the worker's merge_queue.
#   EVENT (launched by bin/lib/wake-class-pr-closed.sh): the webhook is the
#         evidence, so GitHub is asked nothing. --closed refs are closed,
#         --queued refs carry Mergify's `queued` label, every other ref is open.
#
# SETTLED means merged or closed, or — for the two not-in-queue families only,
# since a queued PR is still awaiting merge — a `queued`/`checking` label (the
# two the BH-3778 detector reads as Mergify holding it) or a merge_queue row.
#   every PR settled            -> POST /api/alerts/resolve {ids, reason} and the
#                                  local state id resolved (alert_state_resolve)
#   some settled, rest not      -> awaitmerge only: the console line is rewritten
#                                  in place to list the rest (same akey, no
#                                  alertstate, so one row and no ping)
#   a PR we could not read      -> never settled; the row stays (fail open)
# --dry prints the decisions and POSTs nothing. Deterministic, no LLM. Exit 0
# on every path; logs to logs/alerts-groom.log with the `merge-resolve` prefix.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

DRY=0; MODE=pass; CUR=""; EV_CLOSED=(); EV_QUEUED=()
REF_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$'
while [ $# -gt 0 ]; do
  case "$1" in
    --dry) DRY=1 ;;
    --closed) CUR=closed; MODE=event ;;
    --queued) CUR=queued; MODE=event ;;
    *) if [[ "$1" =~ $REF_RE ]]; then
         case "$CUR" in closed) EV_CLOSED+=("$1") ;; queued) EV_QUEUED+=("$1") ;; esac
       fi ;;
  esac
  shift
done

[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=bin/lib/alert-state.sh
. "$BIN/lib/alert-state.sh" 2>/dev/null || true
# shellcheck source=bin/lib/gh-rest.sh
. "$BIN/lib/gh-rest.sh" 2>/dev/null || true
# shellcheck source=bin/lib/gh-app-auth.sh
. "$BIN/lib/gh-app-auth.sh" 2>/dev/null || true
LOG="$HARNESS/logs/alerts-groom.log"
mkdir -p "$HARNESS/logs" "$HARNESS/locks" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { # say <text> — the groom log; under --dry, stdout instead
  if [ "$DRY" = 1 ]; then echo "merge-resolve: $*"; else echo "$(STAMP) merge-resolve: $*" >> "$LOG"; fi
}
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# Dedupe, not a queue: the pass and an event drain take the same lock, and the
# loser of a 20s wait skips (the other run, or the next one, covers its rows).
exec 8>"$HARNESS/locks/alerts-merge-resolve.lock"
flock -w 20 8 2>/dev/null || { say "busy, skipped ($MODE)"; exit 0; }

RESP=$(curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open") || exit 0
jq -e '.alerts' >/dev/null 2>&1 <<<"$RESP" || exit 0

AW_RE='\[pipeline-health\] ([a-z0-9._-]+): harness PR\(s\) ([#0-9,]+) open >[0-9]+h awaiting merge'
LU_RE='\[pipeline-health\] ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) #([0-9]+) has lead-verdict success .* not in the merge queue'
AP_RE='\[pipeline-health\] https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+) is APPROVE .*OPEN and CLEAN .*not in the merge queue'
PRS_RE=' prs=([^ ;]+)'

# ── 1. the rows of the three families, and the PRs each one names ──────────
R_ID=(); R_AKEY=(); R_PROJ=(); R_LINE=(); R_FAM=(); R_REFS=()
declare -A REF_ORIG=()   # lowercased ref -> the casing GitHub is asked with
KEPT=0
while IFS=$'\t' read -r ID AKEY PROJ LINE; do
  [ -n "$ID" ] || continue
  M=$(as_strip_stamp "$LINE" 2>/dev/null || printf '%s' "$LINE")
  M="${M% (still firing, n=*)}"
  FAM=""; REFS=""
  if [[ "$M" =~ $AW_RE ]]; then
    FAM=awaitmerge; P="${BASH_REMATCH[1]}"; NUMS="${BASH_REMATCH[2]}"
  elif [[ "$M" =~ $LU_RE ]]; then
    FAM=leadunqueued; REFS="${BASH_REMATCH[1]}#${BASH_REMATCH[2]}"
  elif [[ "$M" =~ $AP_RE ]]; then
    FAM=approveunqueued; REFS="${BASH_REMATCH[1]}#${BASH_REMATCH[2]}"
  else
    continue
  fi
  if [[ "$M" =~ $PRS_RE ]]; then
    REFS=""
    IFS=',' read -r -a PARTS <<<"${BASH_REMATCH[1]}"
    for X in "${PARTS[@]}"; do [[ "$X" =~ $REF_RE ]] && REFS="${REFS:+$REFS }$X"; done
  elif [ "$FAM" = awaitmerge ]; then
    # A row written before the prs= token: the project's repo from fleet.conf.
    SLUG=$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null) || SLUG=""
    if [ -z "$SLUG" ] || [ "$SLUG" = "-" ]; then
      say "keep $ID no repo for project $P in fleet.conf"; KEPT=$((KEPT+1)); continue
    fi
    for X in $(tr ',' ' ' <<<"$NUMS"); do
      X="${X#\#}"; [ -n "$X" ] && REFS="${REFS:+$REFS }$SLUG#$X"
    done
  fi
  [ -n "$REFS" ] || { say "keep $ID no PR refs in the line"; KEPT=$((KEPT+1)); continue; }
  for X in $REFS; do REF_ORIG[$(lc "$X")]="$X"; done
  R_ID+=("$ID"); R_AKEY+=("$AKEY"); R_PROJ+=("$PROJ"); R_LINE+=("$LINE"); R_FAM+=("$FAM"); R_REFS+=("$REFS")
done < <(jq -r '.alerts[] | [(.id|tostring), ((.akey // "") | if . == "" then "-" else . end),
  ((.project // "") | if . == "" then "-" else . end), ((.line // "") | gsub("[\t\n\r]"; " "))] | @tsv' <<<"$RESP")

# ── 2. what each PR is ─────────────────────────────────────────────────────
declare -A FACT=() LABELS=() INQ=()
GH_READS=0
if [ "$MODE" = event ]; then
  for X in "${EV_QUEUED[@]+"${EV_QUEUED[@]}"}"; do FACT[$(lc "$X")]=queued-event; done
  for X in "${EV_CLOSED[@]+"${EV_CLOSED[@]}"}"; do FACT[$(lc "$X")]=closed-event; done
elif [ "${#R_ID[@]}" -gt 0 ]; then
  TMP=$(mktemp "${TMPDIR:-/tmp}/merge-resolve.XXXXXX") || exit 0
  trap 'rm -f "$TMP"' EXIT
  ARMED=""
  for K in "${!REF_ORIG[@]}"; do
    X="${REF_ORIG[$K]}"; SLUG="${X%#*}"; N="${X##*#}"
    if [ "$(lc "$SLUG")" != "$ARMED" ]; then
      command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
      command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG"
      ARMED=$(lc "$SLUG")
    fi
    GH_READS=$((GH_READS+1))
    # Into a FILE, never $( ): gh-rest.sh's status rule. 44 (404) and 75 are
    # both "could not read", and an unread PR is never settled.
    if GH_REST_OPTIONAL=1 gh_rest GET "repos/$SLUG/pulls/$N" > "$TMP" 2>/dev/null \
       && ROW=$(jq -er '[(if .merged_at != null then "merged" elif .state == "closed" then "closed" elif .state == "open" then "open" else error("no state") end),
                         ([.labels[]?.name] | join(","))] | @tsv' "$TMP" 2>/dev/null); then
      IFS=$'\t' read -r FACT[$K] LABELS[$K] <<<"$ROW"
    else
      FACT[$K]=unknown
    fi
  done
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  # The worker's merge_queue, read once and only when a not-in-queue row needs
  # it. Sourced in a subshell: jobs-client.sh sets its own shell options.
  case " ${R_FAM[*]} " in
    *" leadunqueued "*|*" approveunqueued "*)
      if MQ=$( . "$BIN/jobs-client.sh" >/dev/null 2>&1 && merge_queue_list "" queued ); then
        while IFS=$'\t' read -r MP MN MS MR _; do
          [ "$MS" = queued ] || continue
          case "$MN" in ''|*[!0-9]*) continue ;; esac
          if [ -z "$MR" ] || [ "$MR" = "-" ] || [ "$MR" = null ]; then
            MR=$("$BIN/fleet-conf.sh" "$MP" repo 2>/dev/null) || MR=""
          fi
          [ -n "$MR" ] && [ "$MR" != "-" ] && INQ[$(lc "$MR")#$MN]=1
        done <<<"$MQ"
      else
        say "merge_queue unreadable; labels alone decide this pass"
      fi ;;
  esac
fi

# ── 3. decide per row ──────────────────────────────────────────────────────
post() { # post <route> <json> — rc 0 only on a 2xx
  local code
  code=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $HARNESS_SECRET" \
    -H 'Content-Type: application/json' -d "$2" "$CONSOLE_URL/api/$1" 2>/dev/null) || return 1
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}
declare -A BY_REASON=() KC=()   # reason -> "i i i" (indexes into R_*); kinds settled in one row
RESOLVED=0; REWRITTEN=0; UNKNOWN=0
for i in "${!R_ID[@]}"; do
  ID="${R_ID[$i]}"; FAM="${R_FAM[$i]}"
  S=(); REST=(); U=(); KC=()
  for X in ${R_REFS[$i]}; do
    K=$(lc "$X"); F="${FACT[$K]:-open}"; KIND=""
    case "$F" in
      merged|closed|closed-event) KIND="$F" ;;
    esac
    if [ -z "$KIND" ] && [ "$FAM" != awaitmerge ]; then
      if [ "$F" = queued-event ]; then KIND=queued-event
      elif [[ ",${LABELS[$K]:-}," =~ ,(queued|checking), ]]; then KIND=label
      elif [ -n "${INQ[$K]:-}" ]; then KIND=mqrow
      fi
    fi
    if [ -n "$KIND" ]; then S+=("$X"); KC[$KIND]=1
    else REST+=("$X"); [ "$F" = unknown ] && U+=("$X")
    fi
  done
  [ "${#U[@]}" -gt 0 ] && UNKNOWN=$((UNKNOWN+1))
  if [ "${#S[@]}" -gt 0 ] && [ "${#REST[@]}" -eq 0 ]; then
    KS=" $(printf '%s\n' "${!KC[@]}" | sort | tr '\n' ' ')"
    case "$KS" in
      " merged ")                 R="condition cleared: all PRs merged" ;;
      " closed "|" closed merged ") R="condition cleared: all PRs merged or closed" ;;
      *" label "*)                R="condition cleared: PR enqueued (queued label)" ;;
      *" mqrow "*)                R="condition cleared: PR enqueued (merge_queue row)" ;;
      *" closed-event "*)         R="condition cleared: PR closed (webhook)" ;;
      *)                          R="condition cleared: PR enqueued (queued label, webhook)" ;;
    esac
    BY_REASON[$R]="${BY_REASON[$R]:-} $i"
    continue
  fi
  if [ "${#S[@]}" -gt 0 ] && [ "$FAM" = awaitmerge ]; then
    AK="${R_AKEY[$i]}"
    if [ "$AK" = "-" ]; then say "keep $ID no akey to rewrite under"; KEPT=$((KEPT+1)); continue; fi
    NUMS=""; RJ=""
    for X in "${REST[@]}"; do NUMS="${NUMS:+$NUMS,}#${X##*#}"; RJ="${RJ:+$RJ,}$X"; done
    NEW=$(printf '%s' "${R_LINE[$i]}" | sed -E "s/harness PR\(s\) [#0-9,]+ open/harness PR(s) $NUMS open/")
    if [[ "$NEW" =~ $PRS_RE ]]; then NEW=$(printf '%s' "$NEW" | sed -E "s| prs=[^ ;]+| prs=$RJ|")
    else NEW="$NEW prs=$RJ"
    fi
    P="${R_PROJ[$i]}"; [ "$P" = "-" ] && P=""
    MSG="rewrite $ID remaining=$RJ settled=$(IFS=,; echo "${S[*]}")${U[0]:+ unknown=$(IFS=,; echo "${U[*]}")}"
    if [ "$DRY" = 1 ]; then say "$MSG"; REWRITTEN=$((REWRITTEN+1)); continue; fi
    # Straight to the console, NOT through bin/beat.sh: the state machine would
    # `suppress` a repeat of an open id and drop the rewrite. No alertstate, so
    # the console upserts the line on the same akey and does not ping.
    if post beat "$(jq -nc --arg a "$AK" --arg p "$P" --arg l "$NEW" '{kind:"alert", akey:$a, project:$p, line:$l}')"; then
      say "$MSG"; REWRITTEN=$((REWRITTEN+1))
    else
      say "keep $ID rewrite POST failed"; KEPT=$((KEPT+1))
    fi
    continue
  fi
  KEPT=$((KEPT+1))
  [ "${#U[@]}" -gt 0 ] && say "keep $ID unknown=$(IFS=,; echo "${U[*]}")"
done

# ── 4. resolve, one POST per reason ────────────────────────────────────────
for R in "${!BY_REASON[@]}"; do
  read -r -a IDX <<<"${BY_REASON[$R]}"
  if [ "$DRY" = 1 ]; then
    for i in "${IDX[@]}"; do say "resolve ${R_ID[$i]} ($R): $(head -c 100 <<<"${R_LINE[$i]}")"; done
    RESOLVED=$((RESOLVED + ${#IDX[@]})); continue
  fi
  BODY=$(for i in "${IDX[@]}"; do printf '%s\n' "${R_ID[$i]}"; done | jq -Rnc --arg r "$R" '{ids:[inputs | (tonumber? // .)], reason:$r}')
  if ! post alerts/resolve "$BODY"; then
    say "resolve POST failed for ${#IDX[@]} row(s) ($R); kept"; KEPT=$((KEPT + ${#IDX[@]})); continue
  fi
  for i in "${IDX[@]}"; do
    # The local state id (and the alerts table row): the akey first, because a
    # rewritten legacy line no longer re-derives its own id.
    case "${R_AKEY[$i]}" in
      alert:?*) RID="${R_AKEY[$i]#alert:}" ;;
      *) RID=$(alert_state_key "${R_LINE[$i]}" 2>/dev/null) ;;
    esac
    [ -n "$RID" ] && command -v alert_state_resolve >/dev/null 2>&1 && alert_state_resolve "$RID" >/dev/null 2>&1
    say "resolve ${R_ID[$i]} ($R): $(head -c 100 <<<"${R_LINE[$i]}")"
    RESOLVED=$((RESOLVED+1))
  done
done

SUMMARY="rows=${#R_ID[@]} resolved=$RESOLVED rewritten=$REWRITTEN kept=$KEPT unknown=$UNKNOWN gh_reads=$GH_READS"
if [ "$DRY" = 1 ]; then echo "merge-resolve $MODE done (dry): $SUMMARY"
else echo "$(STAMP) merge-resolve $MODE done: $SUMMARY" >> "$LOG"
fi
exit 0
