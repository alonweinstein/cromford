#!/bin/bash
# bin/stale-owed-tickets.sh — hub cron (hourly): the anti-rot sweep (the operator ask
# 2026-08-13, after TK-49 sat 20h with an open PR and a died review).
#
# The triage gate only wakes on BOARD CHANGES — a ticket we owe action on that
# nobody touches is exactly the thing it never revisits. This sweep is the
# mechanical (no-AI) complement:
#   1. For each project, list open tickets where OUR side owes the next move
#      (waitingOn=team, or ready-verdict todo, or review-status on our turn)
#      with no activity for STALE_H hours.
#   2. Write each as a READY-QUEUE.log line on the OWNING box (triage treats
#      those as candidates even when the board is unchanged) and drop the
#      one-shot flags/force-triage-<project> so the next cron slot runs full.
#   3. Emit counts to state/stale-owed.json — fleet-status-push carries them to
#      the watchdog, which pages only if a count PERSISTS (self-heal first).
#   4. Orphaned-build scan (the TK-49 class): hub build dirs whose RESULT says
#      REVIEW_BLOCKED but whose review.md has no VERDICT, older than 90 min —
#      one actionable ALERTS line each (deduped per build dir via .stale-flagged).
#      Then the builds-of-record ledger (BH-2350): a REVIEW_BLOCKED build with
#      NO dir on this box and no `verdict` artifact on its job is the same
#      orphan, invisible to the find. Deduped in state/stale-owed-orphans.json.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-stale-owed-tickets
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off stale-owed-tickets.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
# The builds-of-record ledger (BH-2350) for the section 4 ledger pass. Either
# missing leaves bor_union undefined, and section 4 is the find it always was.
# shellcheck source=/dev/null
. "${HARNESS:-/root/harness}/bin/jobs-client.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/jobs-client.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "${HARNESS:-/root/harness}/bin/lib/builds-of-record.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/builds-of-record.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit stale-owed-tickets
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    stale-owed-tickets
STALE_H="${STALE_H:-4}"
NOW=$(date +%s)
LOG="$H/logs/stale-owed.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# THE READY SET (BH-1033). Step 2 above has always been "ssh into the owning box
# and append a line", which is the one write in this sweep that can fail
# silently and leave the ticket invisible on the box that owns it. A `ready`
# build_queue row is fleet-visible and needs no ssh. The append stays for a full
# cycle; the row is written beside it, never instead of it.
# shellcheck source=bin/lib/ready-queue.sh
[ -r "$H/bin/lib/ready-queue.sh" ] && . "$H/bin/lib/ready-queue.sh" 2>/dev/null
command -v rq_put >/dev/null 2>&1 || rq_put() { :; }

# >>> board projects
# Every fleet.conf row with a real board prefix. The four-name loop this
# replaces meant a ticket owed on any newer project was never counted as stale
# and never re-queued — the anti-rot sweep silently covering less than half the
# fleet. Box comes from bin/box-for.sh (fleet.conf column 6, with the legacy
# naming fallback) rather than a table of tailscale IPs, and the token from
# bin/internal-token-for.sh, which requires the env file to define exactly ONE
# *_INTERNAL_API_TOKEN: the old TOKVAR table named PROJECT_2_INTERNAL_API_TOKEN, which
# is not what project-2's env file calls it, so that project had been running
# on the fallback grep all along.
# An empty list would write state/stale-owed.json with zero counts, and zero
# owed-stale tickets fleet-wide is exactly what a healthy fleet looks like.
BOARD_PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" stale-owed --with-board) || {
  echo "$(STAMP) FATAL: fleet.conf unreadable — no projects to sweep, exiting" >> "$LOG"; exit 1; }
# <<< board projects

OUT='{}'
for P in $BOARD_PROJECTS; do
  set -a; . "$HENV/$P.env" 2>/dev/null; set +a
  BASEURL=$("$H/bin/fleet-conf.sh" "$P" prod); [ "$BASEURL" = "-" ] && BASEURL=""
  PREFIX=$("$H/bin/fleet-conf.sh" "$P" board_prefix)
  TOKEN=$("$H/bin/internal-token-for.sh" "$P") || TOKEN=""
  [ -n "$TOKEN" ] && [ -n "$BASEURL" ] || { echo "$(STAMP) $P: no token/base — skipped" >> "$LOG"; continue; }
  BOARDS=$(curl -s -m 20 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$BASEURL$PREFIX/boards")
  BID=$(echo "$BOARDS" | jq -r 'if type=="array" then .[0].id else (.boards[0].id // empty) end' 2>/dev/null)
  [ -n "$BID" ] || { echo "$(STAMP) $P: board list failed" >> "$LOG"; continue; }
  # BH-1007: a row with no .key is keyed `<keyPrefix>-<number>`, and keyPrefix is
  # a property of the BOARD (project-4 schema.prisma Board.keyPrefix, default "AR",
  # the same field the app builds `key` from), NOT fleet.conf column 4 — that
  # column is the board API URL PATH (`/api/accounting/requests-board`), so using
  # it here would emit `/api/accounting/requests-board-1838` as a ticket key on
  # every key-less project-4 row and triage could not resolve one of them. A board
  # that does not expose keyPrefix keeps the old `#<number>` shape: a short
  # honest placeholder beats an invented prefix.
  KP=$(echo "$BOARDS" | jq -r 'if type=="array" then (.[0].keyPrefix // empty) else (.boards[0].keyPrefix // empty) end' 2>/dev/null)
  TICKETS=$(curl -s -m 30 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$BASEURL$PREFIX/boards/$BID/tickets")
  # Owed-by-us + stale: mechanical, shape-tolerant (bare array or {tickets:[]}).
  STALE=$(echo "$TICKETS" | jq -c --argjson now "$NOW" --argjson h "$STALE_H" --arg kp "$KP" '
    [ (if type=="array" then . else (.tickets // []) end)[]
      | select((.status // "") as $s | $s != "done" and $s != "closed" and $s != "in_progress")
      # E2E probe artifacts are not rot ("[E2E] TK-12 ..." leak, 2026-08-13);
      # a leak is its own alert (probe-leak scan below), never a triage queue line.
      | select((.title // "") | startswith("[E2E]") | not)
      | select(
          ((.waitingOn // "") == "team")
          or ((.status=="todo") and ((.triageVerdict // "")=="ready")
              and ((.waitingOn // "") != "client") and ((.waitingOn // "") != "requester"))
          or ((.status=="review") and ((.waitingOn // "") != "requester") and ((.waitingOn // "") != "client"))
        )
      | (.lastActivityAt // .updatedAt // .createdAt) as $t
      | select($t != null)
      | select((($now - (($t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601? ) // $now)) / 3600) >= $h)
      | {key: (.key // (if .number != null then (if $kp == "" then "#" else $kp + "-" end) + (.number|tostring) else .id end)), title: (.title // "(untitled)"|.[0:70]), status, waitingOn, hours: ((($now - (($t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601?) // $now)) / 3600) | floor)}
    ]' 2>/dev/null) || STALE='[]'
  N=$(echo "$STALE" | jq 'length')
  OUT=$(echo "$OUT" | jq -c --arg p "$P" --argjson s "$STALE" '.[$p] = {count: ($s|length), tickets: $s}')
  # Probe-leak scan: open "[E2E] ..." tickets are CI cleanup failures piling up
  # on a client-facing board (60 leaked on project-4 before anyone noticed). One
  # ALERTS line per project per day.
  # Only probes OLDER than 90 min count: the project-4 roles suite self-sweeps
  # leaked probes in its own beforeAll (TK-678) but deliberately spares
  # anything under 1h (could belong to a live run). Fresh probes from a merge
  # burst self-heal on the next e2e run; a pile of OLD ones means no e2e has
  # run since, or the sweep itself broke — that is the real alert condition
  # (2026-08-20: six <40min probes from a 6-merge burst paged for nothing).
  PROBES=$(echo "$TICKETS" | jq --argjson cutoff "$(( $(date +%s) - 5400 ))" '[ (if type=="array" then . else (.tickets // []) end)[]
    | select((.status // "") != "done" and (.status // "") != "closed")
    | select((.title // "") | startswith("[E2E]"))
    | select(((.createdAt // "1970") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) < $cutoff) ] | length' 2>/dev/null || echo 0)
  if [ "${PROBES:-0}" -ge 5 ] && ! grep -q "$(date -u +%Y-%m-%d).*probe-leak $P" "$H/logs/ALERTS.log" 2>/dev/null; then
    HARNESS="$H" "$H/bin/alert-line.sh" "[stale-sweep] probe-leak $P: $PROBES [E2E] probe tickets older than 90m still open — the suite's beforeAll self-sweep (TK-678) should have archived these on the next run; either no e2e has run since, or the sweep broke. The alert medic owns this line: archive the probe tickets and check why the self-sweep stopped."
  fi
  # Re-queue cooldown (2026-08-13, TK-199/TK-88 spam loop): the sweep counts a
  # ticket every run (the watchdog needs persistence), but only QUEUES it once
  # per 24h — an open ticket the watcher already declined re-fired a bail
  # comment on every sweep. Counts stay full; only the READY-QUEUE line and the
  # force-triage flag are suppressed for keys queued in the last 24h.
  CD="$H/state/stale-owed-queued.json"; [ -s "$CD" ] || echo '{}' > "$CD"
  QUEUEABLE=$(echo "$STALE" | jq -c --argjson now "$NOW" --slurpfile cd "$CD" --arg p "$P" \
    '[ .[] | select((($cd[0][$p + ":" + .key] // 0) | . < ($now - 86400))) ]')
  NQ=$(echo "$QUEUEABLE" | jq 'length')
  if [ "$NQ" -gt 0 ]; then
    # `project=` names the owner (BH-4120): a box's READY-QUEUE.log is shared by
    # its projects, and bin/lib/ready-queue.sh scopes each project's ready set
    # by this token first. Without it two in-app boards that share a key prefix
    # (PB) would each read the other's lines as their own.
    LINES=$(echo "$QUEUEABLE" | jq -r --arg p "$P" '.[] | .key + " OWED-STALE " + (.hours|tostring) + "h [" + .status + "/" + (.waitingOn // "-") + "] " + .title + " project=" + $p')
    # >>> ready rows (BH-1033)
    # One row per queueable key, on BOTH branches: the local append and the ssh
    # push are each a file on one box, and this is the copy the fleet can see.
    # Written BEFORE the push, so a box that is unreachable this hour still has
    # its work recorded somewhere the next tick can find it.
    printf '%s\n' "$LINES" | while IFS= read -r L; do
      [ -n "$L" ] || continue
      rq_put "$H" "$P" "$(printf '%s' "$L" | grep -oE '^[A-Z]+-[0-9A-Za-z]+')" "" "$L"
    done
    # <<< ready rows
    IP=$("$H/bin/box-for.sh" "$P" 2>/dev/null || echo local)
    if [ "$IP" = local ] || [ -z "$IP" ]; then
      # Idempotent append: never duplicate a line the watcher has not consumed.
      NEW=$(printf '%s\n' "$LINES" | while IFS= read -r L; do grep -qxF "$L" "$H/logs/READY-QUEUE.log" 2>/dev/null || printf '%s\n' "$L"; done)
      [ -n "$NEW" ] && { printf '%s\n' "$NEW" >> "$H/logs/READY-QUEUE.log"; touch "$H/flags/force-triage-$P"; }
    else
      printf '%s\n' "$LINES" | timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 "root@$IP" \
        "cat >> /root/harness/logs/READY-QUEUE.log && touch /root/harness/flags/force-triage-$P" 2>/dev/null \
        || echo "$(STAMP) $P: push to box $IP FAILED" >> "$LOG"
    fi
    echo "$(STAMP) $P: $N owed-stale, $NQ queued (rest in 24h cooldown)" >> "$LOG"
    jq -c --argjson now "$NOW" --arg p "$P" --argjson q "$QUEUEABLE" \
      'reduce $q[] as $t (.; .[$p + ":" + $t.key] = $now)' "$CD" > "$CD.tmp" && mv "$CD.tmp" "$CD"
  elif [ "$N" -gt 0 ]; then
    echo "$(STAMP) $P: $N owed-stale, all in 24h cooldown — nothing queued" >> "$LOG"
  fi
done
printf '%s\n' "$OUT" > "$H/state/stale-owed.json.tmp" && mv "$H/state/stale-owed.json.tmp" "$H/state/stale-owed.json"

# --- 4. orphaned builds (review died mid-run; nothing owns the retry) --------
find "$H/builds" -maxdepth 2 -name RESULT -mmin +90 2>/dev/null | while read -r R; do
  D=$(dirname "$R")
  [ -f "$D/.stale-flagged" ] && continue
  head -1 "$R" | grep -q "REVIEW_BLOCKED" || continue
  verdict_parse -L "$D/review.md" >/dev/null 2>&1 && continue
  HARNESS="$H" "$H/bin/alert-line.sh" "[stale-sweep] ORPHANED BUILD: $(basename "$D") — RESULT=REVIEW_BLOCKED but review.md has no VERDICT (review died mid-run). Hub: re-run the review stage or close it out; nothing else will."
  touch "$D/.stale-flagged"
done

# The ledger pass (BH-2350). The find above covers every dir on this box; this
# covers the REVIEW_BLOCKED builds the ledger records with no dir here, whose
# orphan test is "the job has no verdict artifact". A row with a local dir, or
# whose job is already staged here as a -remote copy (its RESULT carries the
# JOB_ID: line), is the find's and is never alerted twice. An outage (rc 1 from
# bor_union or job_verdict_state) alerts nothing and stamps nothing.
# STALE_ORPHAN_LOOKBACK_H (settings row, default 168) bounds the window, so the
# first run does not page for every historic REVIEW_BLOCKED row in the ledger.
if command -v bor_union >/dev/null 2>&1 && command -v job_verdict_state >/dev/null 2>&1; then
  ORF="$H/state/stale-owed-orphans.json"
  LOOKBACK_H="${STALE_ORPHAN_LOOKBACK_H:-168}"
  case "$LOOKBACK_H" in ''|*[!0-9]*|0) LOOKBACK_H=168 ;; esac
  # Missing or unparseable reads as {}: the scan re-alerts once, never goes quiet.
  ORPH=$(jq -c 'if type == "object" then . else {} end' "$ORF" 2>/dev/null) || ORPH='{}'
  [ -n "$ORPH" ] || ORPH='{}'
  STAGED=$'\n'"$(sed -n 's/^JOB_ID: //p' "$H"/builds/*/RESULT 2>/dev/null)"$'\n'
  ERRF=$(mktemp 2>/dev/null) || ERRF="$H/state/.stale-owed-bor.err"
  for P in $BOARD_PROJECTS; do
    ROWS=$(bor_union "$P" 2>"$ERRF"); RC=$?
    if [ "$RC" = 1 ]; then
      echo "$(STAMP) $P: ledger read failed — local find only" >> "$LOG"; continue
    fi
    grep -q 'BOR_TRUNCATED=1' "$ERRF" 2>/dev/null \
      && echo "$(STAMP) $P: ledger read capped at ${BOR_LIMIT:-500} rows — older records not scanned" >> "$LOG"
    [ "$RC" = 0 ] || continue
    while IFS=$'\t' read -r KEY BDIR BOX UPD RLINE _PR JOB; do
      case "$RLINE" in REVIEW_BLOCKED*) ;; *) continue ;; esac
      [ -n "$BDIR" ] && [ -n "$JOB" ] && [ "$JOB" != - ] || continue
      bor_local_dir "$BDIR" >/dev/null && continue
      case "$STAGED" in *$'\n'"$JOB"$'\n'*) continue ;; esac
      [ -n "$UPD" ] || continue
      TS=$(date -u -d "$UPD" +%s 2>/dev/null) || continue
      AGE=$(( NOW - TS ))
      [ "$AGE" -ge 5400 ] && [ "$AGE" -le $(( LOOKBACK_H * 3600 )) ] || continue
      OK="$P:$BDIR"
      jq -e --arg k "$OK" 'has($k)' <<<"$ORPH" >/dev/null 2>&1 && continue
      job_verdict_state "$JOB" >/dev/null 2>&1; VRC=$?
      [ "$VRC" = 2 ] || continue
      # The ALERTS line FIRST, then the stamp: a crash between them re-alerts
      # once; a stamp with no line cannot happen.
      HARNESS="$H" "$H/bin/alert-line.sh" "[stale-sweep] ORPHANED BUILD: $BDIR ($P $KEY, box $BOX, job $JOB) — ledger RESULT=REVIEW_BLOCKED and the job has no verdict artifact (review died mid-run, no local dir on this box). Hub: re-run the review stage or close it out; nothing else will."
      ORPH=$(jq -c --arg k "$OK" --argjson now "$NOW" '.[$k] = $now' <<<"$ORPH")
      { printf '%s\n' "$ORPH" > "$ORF.tmp" && mv -f "$ORF.tmp" "$ORF"; } 2>/dev/null
    done <<<"$ROWS"
  done
  rm -f "$ERRF"
  # Prune keys past the window plus a day: their rows can no longer be candidates.
  if [ -s "$ORF" ]; then
    jq -c --argjson cut $(( NOW - LOOKBACK_H * 3600 - 86400 )) 'with_entries(select(.value >= $cut))' "$ORF" > "$ORF.tmp" 2>/dev/null \
      && mv -f "$ORF.tmp" "$ORF" 2>/dev/null
  fi
fi
