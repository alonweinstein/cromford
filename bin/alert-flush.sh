#!/bin/bash
# alert-flush.sh — the quarantine dead-man valve. Cron */15 on EVERY box.
# Any fleet_alert still sitting in state/alert-quarantine.jsonl after 45 minutes
# means the hub triage lane did not handle it (hub down, its seat down, ssh
# broken). Force-escalate it through the original console path, marked
# [UNTRIAGED 45m] so the reader knows it arrived raw. Quarantine must never be
# able to silence a real fire.
#
# With flags/alerts-db on (BH-1070) the same valve also drains the worker's
# expired CLAIMS — rows a triage lane took and never finished, re-offered after
# their lease — and marks a row `new` only after the console took the beat. The
# flag off, or any failure of the claim, and this is byte for byte the file
# valve it has always been.
#
# THE RE-MARK PASS (BH-2366). With the claim working the hub no longer ssh-grabs
# this box's queue, so an entry whose quarantine mark missed in beat.sh (worker
# blip) is seen by nobody but the 45m valve below. After the TTL pass, each KEPT
# entry with no "dbrow":true is marked `quarantined` again, and stamped only on
# rc 0 — the same network-outside-lock, rewrite-under-flock order as beat.sh.
# Any other rc leaves the entry as it was, on the dead-man path; an outage (rc 1)
# ends the pass for this run. An overdue retraction ("resolved":true) is dropped,
# not sent raw, while the claim works: its row is already closed and nobody else
# collects it any more.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
Q="$H/state/alert-quarantine.jsonl"
set -a; . $HENV/global.env 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-alert-flush
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off alert-flush.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit alert-flush
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    alert-flush

# Before any DB call: with no console to deliver to, nothing here could escalate
# anything, and a claim taken now would only park rows under this box's lease
# for nothing.
[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0

# ── THE SECOND SOURCE (BH-1070) ─────────────────────────────────────────────
# With flags/alerts-db on, the valve's input is the worker's own expired claims
# as well as this box's file: alerts the triage lane claimed and never finished
# are re-offered here after their lease, on any box. DB_OK gates EVERYTHING
# below — a claim that failed (worker down rc 1, route absent rc 2) leaves the
# file path in charge of every entry, exactly as today.
DB_OK=0; ROWS=""
# shellcheck source=bin/lib/alert-state.sh
. "$H/bin/lib/alert-state.sh" 2>/dev/null || true
if command -v alerts_db_on >/dev/null 2>&1 && alerts_db_on; then
  ROWS=$(alert_flush_claim) && DB_OK=1 || DB_OK=0
fi

if [ "$DB_OK" = 1 ] && [ -n "$ROWS" ]; then
  while IFS= read -r ROW; do
    [ -n "$ROW" ] || continue
    case "$ROW" in '#truncated') continue ;; esac
    RID=$(printf '%s' "$ROW" | cut -f1)
    RPROJ=$(printf '%s' "$ROW" | cut -f4)
    RSEV=$(printf '%s' "$ROW" | cut -f12)
    RLINE=$(printf '%s' "$ROW" | cut -f13-)   # line is LAST: an embedded tab stays with it
    [ -n "$RID" ] || continue
    ESC=$(jq -nc --arg p "${RPROJ:-}" --arg id "$RID" --arg s "${RSEV:-critical}" \
      --arg l "[UNTRIAGED 45m] $RLINE" \
      '{kind:"fleet_alert",project:(if $p == "" then "fleet" else $p end),triaged:true,
        akey:("orclane:" + $id),alertid:$id,severity:$s,line:$l}' 2>/dev/null) || continue
    CODE=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
      -d "$ESC" "$CONSOLE_URL/api/beat" 2>/dev/null)
    # DELIVERED, THEN RECORDED — never the other way round. A non-2xx leaves
    # the claim untouched, so the worker re-offers the row after the lease
    # instead of this box swearing it delivered something it did not.
    case "$CODE" in 2??) alert_state_set "$RID" new flush >/dev/null 2>&1 || true ;; esac
  done <<< "$ROWS"
fi

[ -s "$Q" ] || exit 0
NOW=$(date -u +%s)
CUTOFF=$((NOW - 2700))
KEEP=$(mktemp); SEND=$(mktemp)
( exec 7>"$Q.lock"; flock 7
  while IFS=$'\t' read -r TS PAYLOAD; do
    [ -n "${PAYLOAD:-}" ] || continue
    if [ "${TS:-0}" -le "$CUTOFF" ] 2>/dev/null; then
      # A "dbrow":true entry is one beat.sh confirmed into the table, so the
      # claim pass above is what escalates it — sending it from here too would
      # page the same condition twice. Only when the claim SUCCEEDED, though:
      # with DB_OK=0 nothing read the table this run and the file is again the
      # only witness.
      if [ "$DB_OK" = 1 ] \
         && [ "$(jq -r '.dbrow // false' <<<"$PAYLOAD" 2>/dev/null)" = "true" ]; then
        continue
      fi
      # A retraction ("resolved":true, lane-alert.sh --resolve) is never an
      # alert: its emitter already closed the row (alert_state_resolve), and
      # beat.sh never stamps one, so with the hub no longer ssh-grabbing this
      # box (BH-2366) sending it raw would page a condition that is over. Same
      # DB_OK rule: with the claim failed, the file is the only witness again.
      if [ "$DB_OK" = 1 ] \
         && [ "$(jq -r '.resolved // false' <<<"$PAYLOAD" 2>/dev/null)" = "true" ]; then
        continue
      fi
      printf '%s\n' "$PAYLOAD" >> "$SEND"
    else
      printf '%s\t%s\n' "$TS" "$PAYLOAD" >> "$KEEP"
    fi
  done < "$Q"
  cat "$KEEP" > "$Q"
)
while IFS= read -r PAYLOAD; do
  ESC=$(jq -c '.triaged = true | .line = "[UNTRIAGED 45m] " + (.line // "")' <<<"$PAYLOAD" 2>/dev/null) || ESC="$PAYLOAD"
  curl -s --max-time 15 -X POST -H "Authorization: Bearer $HARNESS_SECRET" \
    -H 'Content-Type: application/json' -d "$ESC" "$CONSOLE_URL/api/beat" >/dev/null 2>&1
done < "$SEND"

# >>> re-mark (BH-2366) — KEEP entries only: an overdue unmarked entry was just
# escalated above and a late stamp must never pull it off that path. DB_OK=1
# means the flush claim answered this run; with it 0 the worker is presumed
# down and no request is made.
if [ "$DB_OK" = 1 ] && [ -s "$KEEP" ]; then
  RN=0; RS=0; RRC=0
  while IFS=$'\t' read -r TS PAYLOAD; do
    [ -n "${PAYLOAD:-}" ] || continue
    # beat.sh never marks a retraction, and a stamped entry is already the table's.
    grep -q -F -e '"dbrow":true' -e '"resolved":true' <<<"$PAYLOAD" && continue
    RID=$(jq -r '.alertid // ""' <<<"$PAYLOAD" 2>/dev/null)
    if [ -z "$RID" ]; then
      [ -z "$(jq -r '.alertstate // ""' <<<"$PAYLOAD" 2>/dev/null)" ] || continue
      RID=$(alert_state_key "$(jq -r '.line // ""' <<<"$PAYLOAD" 2>/dev/null)" 2>/dev/null)
    fi
    [ -n "$RID" ] || continue
    RN=$((RN+1))
    RRC=0; alert_state_set "$RID" quarantined flush >/dev/null 2>&1 || RRC=$?
    if [ "$RRC" -eq 0 ]; then
      QNEW=$(jq -c '.dbrow=true' <<<"$PAYLOAD" 2>/dev/null) || QNEW=""
      [ -n "$QNEW" ] || continue
      # Counted only when the line was found AND the rewrite landed: a line
      # drained meanwhile (awk exits 3) or a failed mv is not "stamped".
      ( exec 7>"$Q.lock"; flock 7
        # Through the ENVIRONMENT, never -v (it unescapes backslashes in JSON).
        QT="$TS" QP="$PAYLOAD" QN="$QNEW" awk '
          BEGIN { target = ENVIRON["QT"] "\t" ENVIRON["QP"]
                  stamped = ENVIRON["QT"] "\t" ENVIRON["QN"] }
          { line[NR] = $0; if ($0 == target) last = NR }
          END { if (!last) exit 3
                for (i = 1; i <= NR; i++) print (i == last ? stamped : line[i]) }
        ' "$Q" > "$Q.tmp" 2>/dev/null && mv -f "$Q.tmp" "$Q" 2>/dev/null \
          || { rm -f "$Q.tmp"; exit 1; }
      ) 2>/dev/null && RS=$((RS+1))
    elif [ "$RRC" -eq 1 ]; then
      break
    fi
  done < "$KEEP"
  [ "$RN" -gt 0 ] && command -v as_log >/dev/null 2>&1 \
    && as_log "flush remark: $RS stamped, $((RN-RS)) left unmarked (last rc=$RRC)"
fi
# <<< re-mark

rm -f "$KEEP" "$SEND"
exit 0
