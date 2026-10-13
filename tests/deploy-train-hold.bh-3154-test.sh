#!/bin/bash
# tests/deploy-train-hold.bh-3154-test.sh — BH-3154 (BH-2510.4): a HELD
# deploy_queue row stops the train.
#
# The real bin/deploy-train.sh is driven against one stubbed `curl` that is the
# jobs worker (settings + the deploy-queue routes over a TSV store), the
# project's version endpoint and the deploy hook at once — the fixture of
# tests/deploy-train-hold.bh-3154-test.sh, plus LIST_FAIL, a space-separated
# list of statuses whose deploy-queue GET dies like an outage.
#
#   1. rows on, a held row, nothing queued, production behind main: no
#      self-sourced departure, no hook, and ONE log line naming the held sha8.
#   2. rows on, the queued read fails (file-dir fallback) and the held read
#      fails too: nothing departs, the file stays, one `fail closed` line.
#   3. rows on, no held row: departs as it does today.
#   4. a held row for ANOTHER project does not stop this one.
#   5. a held row stops the whole train: the queued row next to it is neither
#      claimed nor departed.
#   6. rows off: not one `status=held` request, and the file batch departs.
#   7. rows on, the queued read fails, the held read answers empty: the file
#      batch departs as it does today.
#   8. the SETTINGS read fails on a box that has seen the knob on (the refute
#      review's path 2): the knob resolves off, yet the held row still stops
#      the file batch, and an unanswered held list fails closed.
#   9. the settings read fails on a box that never saw the knob on: a held
#      row that answers still stops it; an unanswered held list reads the
#      file dir, since that box cannot have a hold.
#  10. the knob is turned OFF with a row still held: the hold is kept, ONE
#      ALERTS line says so (not one per tick), and after UNHOLD the next
#      off tick departs and drops the marker.
#
# Run from anywhere: tests/deploy-train-hold.bh-3154-test.sh   (exit 0 = pass)
# No network, no LLM. One clock anchor (NOW), everything derived from it.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/env" "$H/locks" "$H/state/deploy-queue/p" \
         "$T/fakebin" "$T/calls" "$T/builds/b1"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
# BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load, so
# a fixture that copies it must copy its modules too.
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/env-path.sh "$H/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh

# a two-commit repo standing in for /root/repos/<project>; origin/main = HEAD
git init -q "$T/repo" && (cd "$T/repo" \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two \
  && git init -q --bare "$T/origin.git" && git remote add origin "$T/origin.git" \
  && git push -q origin HEAD:main && git update-ref refs/remotes/origin/main HEAD)
TARGET=$(git -C "$T/repo" rev-parse HEAD)
OLD=$(git -C "$T/repo" rev-parse HEAD~1)

printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_BOX=box-a\nJOBS_RETRIES=0\nJOBS_TIMEOUT=5\nJOBS_ALERT=0\n' \
  > "$H/env/global.env"
printf 'VERSION_URL=https://version.invalid/api/version\nDEPLOY_HOOK_URL=https://hook.invalid/deploy\nDEPLOY_ROLLBACK=off\n' \
  > "$H/env/p.env"

cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
echo "org/repo"
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
echo "$1" >> "$SINK_DIR/beat"
SH
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$SINK_DIR/gh"; echo "https://github.com/org/repo/pull/1"
SH
# flock is Linux-only; the train's per-box slot lock is not what this suite is
# about — the CLAIM is the cross-box guard, and that is what is driven.
cat > "$T/fakebin/flock" <<'SH'
#!/bin/bash
exit 0
SH

# ── the fake worker, the version endpoint and the deploy hook, as one curl ────
# $DQ_STORE is the deploy_queue table as TSV:
#   project  sha  status  build_dir  claimed_by  enqueued_at  departed_at  reason  updated_at
# with `-` for NULL. It implements the four routes as the worker does: put is
# idempotent on (project, sha) and RE-OPENS a terminal row, list filters and
# orders by enqueued_at, claim takes only a `queued` row (or a `claimed` one
# older than stale_min that never departed), depart is refused unless `claimed`.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  *hook.invalid*)    echo "hook" >> "$SINK_DIR/hook"; exit "${HOOK_RC:-0}" ;;
  *version.invalid*) printf '{"sha":"%s"}' "$(cat "$LIVE_FILE" 2>/dev/null)"; exit 0 ;;
esac
# Everything below is the jobs worker. CURL_MODE=down takes out THIS host only,
# so a train can be run with a dead worker and a live production endpoint.
[ "${CURL_MODE:-up}" = down ] && exit 7
NOWISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
row_json() {
  awk -F'\t' '
    function j(v) { return (v == "-") ? "null" : "\"" v "\"" }
    { printf "{\"project\":\"%s\",\"sha\":\"%s\",\"status\":\"%s\",\"build_dir\":%s,\"claimed_by\":%s,\"enqueued_at\":\"%s\",\"departed_at\":%s,\"reason\":%s,\"updated_at\":\"%s\"}",
        $1, $2, $3, j($4), j($5), $6, j($7), j($8), $9 }'
}
dq_get() { awk -F'\t' -v p="$1" -v s="$2" '$1==p && $2==s {print; exit}' "$DQ_STORE"; }
dq_del() {
  awk -F'\t' -v p="$1" -v s="$2" '!($1==p && $2==s)' "$DQ_STORE" > "$DQ_STORE.t" && mv "$DQ_STORE.t" "$DQ_STORE"
}
case "$M $URL" in
  "GET "*/api/settings/*)
    [ "${SETTINGS_FAIL:-0}" = 1 ] && exit 7
    K="${URL##*/}"; V=absent
    [ "$K" = deploy_queue_rows ] && V="${FLAG_DQ:-0}"
    case "$V" in
      absent|none) printf '{}\n404\n' ;;
      *) printf '{"setting":{"key":"%s","value":"%s"}}\n200\n' "$K" "$V" ;;
    esac
    ;;
  "POST "*/api/deploy-queue/claim)
    if [ "${CLAIM_MODE:-}" = down-after-1 ]; then
      N=$(cat "$SINK_DIR/claimn" 2>/dev/null); N=$(( ${N:-0} + 1 )); echo "$N" > "$SINK_DIR/claimn"
      [ "$N" -gt 1 ] && exit 7
    fi
    P=$(jq -r '.project // ""' <<<"$BODY"); S=$(jq -r '.sha // ""' <<<"$BODY")
    BOX=$(jq -r '.box // ""' <<<"$BODY"); SM=$(jq -r '.stale_min // 0' <<<"$BODY")
    case "$SM" in ''|*[!0-9]*) SM=0 ;; esac
    CUR=$(dq_get "$P" "$S")
    [ -n "$CUR" ] || { printf '{"error":"nothing queued"}\n404\n'; exit 0; }
    TAKE=no
    if [ "${CLAIM_MODE:-}" != lose ]; then
      [ "$(cut -f3 <<<"$CUR")" = queued ] && TAKE=yes
      if [ "$(cut -f3 <<<"$CUR")" = claimed ] && [ "$(cut -f7 <<<"$CUR")" = "-" ] && [ "$SM" -gt 0 ]; then
        U=$(date -u -d "$(cut -f9 <<<"$CUR")" +%s 2>/dev/null); U="${U:-0}"
        [ $(( $(date +%s) - U )) -ge $(( SM * 60 )) ] && TAKE=yes
      fi
    fi
    if [ "$TAKE" = yes ]; then
      NEW=$(awk -F'\t' -v OFS='\t' -v b="$BOX" -v n="$NOWISO" '{ $3="claimed"; $5=b; $9=n; print }' <<<"$CUR")
      dq_del "$P" "$S"; printf '%s\n' "$NEW" >> "$DQ_STORE"
      printf '{"deploy":%s,"claimed":true,"as_of":"%s"}\n200\n' "$(row_json <<<"$NEW")" "$NOWISO"
    else
      printf '{"error":"another claimant took this departure","refused":true,"scope":"deploy-queue","deploy":%s}\n409\n' \
        "$(row_json <<<"$CUR")"
    fi
    ;;
  "POST "*/api/deploy-queue/depart)
    P=$(jq -r '.project // ""' <<<"$BODY"); S=$(jq -r '.sha // ""' <<<"$BODY")
    ST=$(jq -r '.status // ""' <<<"$BODY"); R=$(jq -r '.reason // "-"' <<<"$BODY")
    case "$ST" in done|failed|queued) ;; *) printf '{"error":"bad status"}\n400\n'; exit 0 ;; esac
    CUR=$(dq_get "$P" "$S")
    [ -n "$CUR" ] || { printf '{"error":"nothing queued"}\n404\n'; exit 0; }
    if [ "$(cut -f3 <<<"$CUR")" != claimed ]; then
      printf '{"error":"departure refused: row is %s, not claimed","refused":true,"deploy":%s}\n409\n' \
        "$(cut -f3 <<<"$CUR")" "$(row_json <<<"$CUR")"
      exit 0
    fi
    NEW=$(awk -F'\t' -v OFS='\t' -v s="$ST" -v r="$R" -v n="$NOWISO" \
      '{ $3=s; if (s=="queued") { $5="-"; $7="-" } else { $7=n }; $8=r; $9=n; print }' <<<"$CUR")
    dq_del "$P" "$S"; printf '%s\n' "$NEW" >> "$DQ_STORE"
    printf '{"deploy":%s,"as_of":"%s"}\n200\n' "$(row_json <<<"$NEW")" "$NOWISO"
    ;;
  "POST "*/api/deploy-queue)
    P=$(jq -r '.project // ""' <<<"$BODY"); S=$(jq -r '.sha // ""' <<<"$BODY")
    B=$(jq -r '.build_dir // "-"' <<<"$BODY")
    [[ "$S" =~ ^[0-9a-f]{7,64}$ ]] || { printf '{"error":"bad sha"}\n400\n'; exit 0; }
    CUR=$(dq_get "$P" "$S")
    case "$(cut -f3 <<<"$CUR")" in
      queued|claimed|held) printf '{"deploy":%s,"duplicate":true}\n200\n' "$(row_json <<<"$CUR")"; exit 0 ;;
    esac
    [ "$B" = "-" ] && [ -n "$CUR" ] && B=$(cut -f4 <<<"$CUR")
    [ -n "$CUR" ] && dq_del "$P" "$S"
    printf '%s\t%s\tqueued\t%s\t-\t%s\t-\t-\t%s\n' "$P" "$S" "$B" "$NOWISO" "$NOWISO" >> "$DQ_STORE"
    printf '{"deploy":{"project":"%s","sha":"%s","status":"queued"},"duplicate":false,"as_of":"%s"}\n201\n' \
      "$P" "$S" "$NOWISO"
    ;;
  "GET "*/api/deploy-queue*)
    # LIST_FAIL: the statuses whose list read dies like an outage (BH-3154).
    for FS in ${LIST_FAIL:-}; do case "$URL" in *"status=$FS"*) exit 7 ;; esac; done
    P=""; case "$URL" in *project=*) P="${URL##*project=}"; P="${P%%&*}" ;; esac
    ST=""; case "$URL" in *status=*) ST="${URL##*status=}"; ST="${ST%%&*}" ;; esac
    SM=0;  case "$URL" in *stale_min=*) SM="${URL##*stale_min=}"; SM="${SM%%&*}" ;; esac
    case "$SM" in ''|*[!0-9]*) SM=0 ;; esac
    sort -t"$(printf '\t')" -k6,6 -k2,2 "$DQ_STORE" | awk -F'\t' -v p="$P" -v st="$ST" -v sm="$SM" -v now="$(date +%s)" '
      function j(v) { return (v == "-") ? "null" : "\"" v "\"" }
      BEGIN { printf "{\"deploy_queue\":[" }
      (p == "" || $1 == p) && (st == "" || $3 == st) {
        if (sm + 0 > 0) {
          if ($3 != "claimed" || $7 != "-") next
          cmd = "date -u -d \"" $9 "\" +%s"; u = 0; cmd | getline u; close(cmd)
          if (now - u < sm * 60) next
        }
        if (n++) printf ","
        printf "{\"project\":\"%s\",\"sha\":\"%s\",\"status\":\"%s\",\"build_dir\":%s,\"claimed_by\":%s,\"enqueued_at\":\"%s\",\"departed_at\":%s,\"reason\":%s,\"updated_at\":\"%s\"}",
          $1, $2, $3, j($4), j($5), $6, j($7), j($8), $9
      }
      END { print "]}" }'
    echo 200
    ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin/"* "$H/bin/"*.sh

DQ_STORE="$T/dq.tsv"; : > "$DQ_STORE"
DQDIR="$H/state/deploy-queue/p"
SINK="$T/req.txt"
: > "$T/live"

# train — one real departure, with the fixture's knobs in the environment.
train() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" \
           REQ_SINK="$SINK" DQ_STORE="$DQ_STORE" SINK_DIR="$T/calls" LIVE_FILE="$T/live" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_DQ="${FLAG_DQ:-0}" CLAIM_MODE="${CLAIM_MODE:-}" \
           HOOK_RC="${HOOK_RC:-0}" TRAIN_POLLS=2 TRAIN_POLL_SECS=0 \
           DEPLOY_TRAIN_REPO_DIR="$T/repo" LIST_FAIL="${LIST_FAIL:-}" \
           SETTINGS_FAIL="${SETTINGS_FAIL:-0}" \
           SELF_SOURCE_MIN_AGE_MIN="${SELF_SOURCE_MIN_AGE_MIN:-20}" \
           DEPLOY_CLAIM_STALE_MIN="${DEPLOY_CLAIM_STALE_MIN:-30}"
    "$DIR/bin/deploy-train.sh" p ) 2>/dev/null
}
# request — one real bin/deploy-request.sh, the production entry point every
# merge path calls after a verified merge.
request() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" \
           REQ_SINK="$SINK" DQ_STORE="$DQ_STORE" SINK_DIR="$T/calls" LIVE_FILE="$T/live" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_DQ="${FLAG_DQ:-0}" \
           DEPLOY_QUEUE_ROWS="${DEPLOY_QUEUE_ROWS:-}"
    "$DIR/bin/deploy-request.sh" p org/repo "$1" "${2:-$T/builds/b1}" ) 2>/dev/null
}

reset_tick() { : > "$SINK"; rm -f "$T/calls/hook" "$T/calls/beat" "$T/calls/gh" "$T/calls/claimn"; }
reset_all()  { reset_tick; : > "$DQ_STORE"; rm -f "$DQDIR"/* "$H/logs/"*.log; scratch_rm "$H/state/deploy-hold-armed"; }
MARK="$H/state/deploy-hold-armed/p"
rows_n()  { awk 'END{print NR+0}' "$DQ_STORE"; }
field()   { awk -F'\t' -v s="$2" -v c="$3" '$2==s {print $c; exit}' "$DQ_STORE"; }
files_n() { ls -A "$DQDIR" 2>/dev/null | awk 'END{print NR+0}'; }
# grep -c, never grep -q, on a pipe: a short-circuiting consumer turns a true
# assertion red under pipefail.
sink_n()  { grep -cF "$1" "$SINK"; }
line_of() { grep -nF "$1" "$SINK" | head -1 | cut -d: -f1; }
log_n()   { grep -c "$1" "$H/logs/deploy-train.log" 2>/dev/null; }
hooks_n() { if [ -f "$T/calls/hook" ]; then awk 'END{print NR+0}' "$T/calls/hook"; else echo 0; fi; }
# held_row <project> <sha> — a row an operator HOLD left (the worker's own
# write is pinned in worker/jobs/test/deploy-hold.bh-3154.test.js).
held_row() {
  local iso; iso=$(date -u -d "@$((NOW - 600))" '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s\t%s\theld\t/b\t-\t%s\t-\tbad migration\t%s\n' "$1" "$2" "$iso" "$iso" >> "$DQ_STORE"
}
HELD8=${TARGET:0:8}

# ══ 1. A HELD ROW AND NOTHING QUEUED: NO SELF-SOURCED DEPARTURE ═══════════
# Production serves OLD, origin/main is TARGET: without the hold the train
# self-sources TARGET and departs on it.
reset_all
printf '%s' "$OLD" > "$T/live"
held_row p "$TARGET"
FLAG_DQ=1 SELF_SOURCE_MIN_AGE_MIN=0 train; RC=$?
[ "$RC" = 0 ] && ok || bad "1 a held tick exits 0 (rc=$RC)"
[ "$(hooks_n)" = 0 ] && ok || bad "1 no hook may fire while a row is held, got $(hooks_n)"
[ "$(files_n)" = 0 ] && ok || bad "1 no self-sourced file may be written, got $(files_n)"
[ "$(rows_n)" = 1 ] && [ "$(field p "$TARGET" 3)" = held ] \
  && ok || bad "1 the store must be the one held row (rows=$(rows_n) status=$(field p "$TARGET" 3))"
[ "$(sink_n '/api/deploy-queue/claim')" = 0 ] && ok || bad "1 nothing is claimed"
[ "$(log_n 'deploy hold')" = 1 ] && [ "$(log_n "deploy hold: $HELD8")" = 1 ] \
  && ok || bad "1 exactly one log line naming the held sha8, got: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"
[ "$(log_n 'self-sourced')" = 0 ] && ok || bad "1 the train must not say it self-sourced"
[ "$(awk 'END{print NR+0}' "$H/logs/deploy-train.log")" = 1 ] \
  && ok || bad "1 one line per tick, got: $(cat "$H/logs/deploy-train.log")"

# ══ 2. FILE-DIR FALLBACK AND AN UNREADABLE HELD LIST: FAIL CLOSED ═════════
reset_all
printf '%s' "$TARGET" > "$T/live"
printf '%s %s\n' "$TARGET" "$T/builds/b1" > "$DQDIR/$NOW-${TARGET:0:8}"
FLAG_DQ=1 LIST_FAIL="queued held" train; RC=$?
[ "$RC" = 0 ] && ok || bad "2 a fail-closed tick exits 0 (rc=$RC)"
[ "$(hooks_n)" = 0 ] && ok || bad "2 no hook may fire when the held list did not answer, got $(hooks_n)"
[ "$(files_n)" = 1 ] && ok || bad "2 the queued file stays, got $(files_n)"
[ "$(sink_n 'status=held')" -ge 1 ] && ok || bad "2 the held list must be asked for: $(cat "$SINK")"
[ "$(log_n 'fail closed')" = 1 ] \
  && ok || bad "2 exactly one fail-closed line, got: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"
[ "$(log_n 'train VERIFIED')" = 0 ] && ok || bad "2 nothing departed"

# ══ 3. NO HELD ROW: THE TRAIN DEPARTS AS IT DOES TODAY ═══════════════════
reset_all
printf '%s' "$TARGET" > "$T/live"
FLAG_DQ=1 request "$TARGET" >/dev/null
reset_tick
FLAG_DQ=1 train; RC=$?
[ "$RC" = 0 ] && ok || bad "3 exits 0 (rc=$RC)"
[ "$(hooks_n)" = 1 ] && ok || bad "3 the hook fires once, got $(hooks_n)"
[ "$(field p "$TARGET" 3)" = done ] && ok || bad "3 the row departs done, got '$(field p "$TARGET" 3)'"
[ "$(files_n)" = 0 ] && ok || bad "3 its file is removed"
[ "$(log_n 'deploy hold')" = 0 ] && ok || bad "3 no hold line without a held row"

# ══ 4. A HELD ROW FOR ANOTHER PROJECT DOES NOT STOP THIS ONE ═════════════
reset_all
printf '%s' "$TARGET" > "$T/live"
held_row q "$OLD"
FLAG_DQ=1 request "$TARGET" >/dev/null
reset_tick
FLAG_DQ=1 train
[ "$(hooks_n)" = 1 ] && ok || bad "4 p departs past q's hold, got $(hooks_n) hooks"
[ "$(field p "$TARGET" 3)" = done ] && ok || bad "4 p's row is done"
[ "$(awk -F'\t' -v s="$OLD" '$1=="q" && $2==s {print $3}' "$DQ_STORE")" = held ] && ok || bad "4 q's row stays held"
[ "$(log_n 'deploy hold')" = 0 ] && ok || bad "4 no hold line for another project's row"

# ══ 5. A HOLD STOPS THE WHOLE TRAIN, NOT JUST ITS OWN SHA ════════════════
# A departure verifies origin/main HEAD, so every queued sha rides with any
# departure: leaving the held one out of the batch would still ship its code.
reset_all
printf '%s' "$TARGET" > "$T/live"
FLAG_DQ=1 request "$TARGET" >/dev/null
held_row p "$OLD"
reset_tick
FLAG_DQ=1 train; RC=$?
[ "$RC" = 0 ] && ok || bad "5 exits 0 (rc=$RC)"
[ "$(hooks_n)" = 0 ] && ok || bad "5 no hook while a row is held, got $(hooks_n)"
[ "$(field p "$TARGET" 3)" = queued ] && [ "$(field p "$TARGET" 5)" = "-" ] \
  && ok || bad "5 the queued row stays queued and unclaimed ($(field p "$TARGET" 3) / $(field p "$TARGET" 5))"
[ "$(sink_n '/api/deploy-queue/claim')" = 0 ] && ok || bad "5 nothing is claimed"
[ "$(files_n)" = 1 ] && ok || bad "5 the queued file stays"
[ "$(log_n "deploy hold: ${OLD:0:8}")" = 1 ] && ok || bad "5 the line names the held sha8: $(cat "$H/logs/deploy-train.log")"

# ══ 6. ROWS OFF: NOT ONE HELD READ, AND THE FILE BATCH DEPARTS ═══════════
reset_all
printf '%s' "$TARGET" > "$T/live"
held_row p "$OLD"
FLAG_DQ=0 request "$TARGET" >/dev/null
reset_tick
FLAG_DQ=0 train; RC=$?
[ "$RC" = 0 ] && ok || bad "6 exits 0 (rc=$RC)"
[ "$(sink_n 'status=held')" = 0 ] && ok || bad "6 rows off makes no held request: $(grep 'status=held' "$SINK")"
[ "$(hooks_n)" = 1 ] && ok || bad "6 the file batch departs, got $(hooks_n) hooks"
[ "$(files_n)" = 0 ] && ok || bad "6 and its file is removed"

# ══ 7. FILE-DIR FALLBACK, HELD LIST ANSWERS EMPTY: DEPARTS AS TODAY ══════
reset_all
printf '%s' "$TARGET" > "$T/live"
printf '%s %s\n' "$TARGET" "$T/builds/b1" > "$DQDIR/$NOW-${TARGET:0:8}"
FLAG_DQ=1 LIST_FAIL="queued" train; RC=$?
[ "$RC" = 0 ] && ok || bad "7 exits 0 (rc=$RC)"
[ "$(hooks_n)" = 1 ] && ok || bad "7 the file batch departs, got $(hooks_n) hooks"
[ "$(files_n)" = 0 ] && ok || bad "7 and its file is removed"
[ "$(log_n 'fail closed')" = 0 ] && [ "$(log_n 'deploy hold')" = 0 ] \
  && ok || bad "7 no hold line: $(cat "$H/logs/deploy-train.log")"

# ══ 8. SETTINGS READ FAILS ON AN ARMED BOX: THE HOLD STILL HOLDS ═════════
# The worker takes a HOLD only while the settings row is on, and a settings
# read that does not answer resolves the knob off. Tick one sees the knob on
# (the box is armed); tick two loses the settings read with the held sha's
# file still in the dir — the file-dir path must not ship it.
reset_all
printf '%s' "$OLD" > "$T/live"
held_row p "$TARGET"
printf '%s %s\n' "$TARGET" "$T/builds/b1" > "$DQDIR/$NOW-${TARGET:0:8}"
FLAG_DQ=1 train
[ -e "$MARK" ] && ok || bad "8 a knob-on tick leaves the armed marker"
[ "$(hooks_n)" = 0 ] && ok || bad "8 the knob-on tick departs nothing, got $(hooks_n)"
reset_tick; rm -f "$H/logs/"*.log
FLAG_DQ=1 SETTINGS_FAIL=1 train; RC=$?
[ "$RC" = 0 ] && ok || bad "8 exits 0 (rc=$RC)"
[ "$(sink_n 'api/settings/deploy_queue_rows')" -ge 1 ] && ok || bad "8 the settings read was attempted"
[ "$(sink_n 'status=held')" -ge 1 ] && ok || bad "8 the held list is read though the knob resolved off"
[ "$(hooks_n)" = 0 ] && ok || bad "8 no hook may fire for a held sha on a settings outage, got $(hooks_n)"
[ "$(files_n)" = 1 ] && ok || bad "8 the held sha's file stays, got $(files_n)"
[ "$(field p "$TARGET" 3)" = held ] && ok || bad "8 the row stays held"
[ "$(log_n "deploy hold: $HELD8")" = 1 ] && [ "$(awk 'END{print NR+0}' "$H/logs/deploy-train.log")" = 1 ] \
  && ok || bad "8 one line naming the held sha8: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"
# …and the held list failing as well: departs nothing (fail closed).
reset_tick; rm -f "$H/logs/"*.log
FLAG_DQ=1 SETTINGS_FAIL=1 LIST_FAIL="held" train; RC=$?
[ "$RC" = 0 ] && ok || bad "8b exits 0 (rc=$RC)"
[ "$(hooks_n)" = 0 ] && ok || bad "8b no hook when neither settings nor held list answered, got $(hooks_n)"
[ "$(files_n)" = 1 ] && ok || bad "8b the file stays, got $(files_n)"
[ "$(log_n 'fail closed')" = 1 ] && ok || bad "8b one fail-closed line: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"
# …and the whole worker down (every jobs call dies), production still up.
reset_tick; rm -f "$H/logs/"*.log
FLAG_DQ=1 CURL_MODE=down train
[ "$(hooks_n)" = 0 ] && ok || bad "8c no hook with the worker down on an armed box, got $(hooks_n)"
[ "$(files_n)" = 1 ] && ok || bad "8c the file stays"
[ "$(log_n 'fail closed')" = 1 ] && ok || bad "8c one fail-closed line: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"

# ══ 9. SETTINGS READ FAILS ON A BOX THAT NEVER SAW THE KNOB ON ═══════════
reset_all
printf '%s' "$OLD" > "$T/live"
held_row p "$TARGET"
printf '%s %s\n' "$TARGET" "$T/builds/b1" > "$DQDIR/$NOW-${TARGET:0:8}"
FLAG_DQ=1 SETTINGS_FAIL=1 train
[ "$(hooks_n)" = 0 ] && ok || bad "9 a held row that answers stops an unarmed box too, got $(hooks_n)"
[ "$(files_n)" = 1 ] && ok || bad "9 the file stays"
[ -e "$MARK" ] && ok || bad "9 a held row seen arms the box"
# an unarmed box whose held list does not answer either: the file dir, as today.
reset_all
printf '%s' "$TARGET" > "$T/live"
printf '%s %s\n' "$TARGET" "$T/builds/b1" > "$DQDIR/$NOW-${TARGET:0:8}"
SETTINGS_FAIL=1 LIST_FAIL="held" train
[ "$(hooks_n)" = 1 ] && ok || bad "9b an unarmed box departs its file batch, got $(hooks_n)"
[ "$(files_n)" = 0 ] && ok || bad "9b and its file is removed"
[ "$(log_n 'never seen deploy_queue_rows on')" = 1 ] && ok || bad "9b one line says why: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"

# ══ 10. KNOB TURNED OFF WITH A ROW STILL HELD ═════════════════════════════
reset_all
printf '%s' "$TARGET" > "$T/live"
held_row p "$OLD"
FLAG_DQ=1 train                                  # armed while on
FLAG_DQ=0 request "$TARGET" >/dev/null
reset_tick; rm -f "$H/logs/"*.log
FLAG_DQ=0 train
[ "$(hooks_n)" = 0 ] && ok || bad "10 an accepted hold survives the knob going off, got $(hooks_n)"
[ "$(files_n)" = 1 ] && ok || bad "10 the file stays"
[ "$(grep -c 'DEPLOY HOLD: deploy_queue_rows is off' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "10 one ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
reset_tick
FLAG_DQ=0 train
[ "$(grep -c 'DEPLOY HOLD: deploy_queue_rows is off' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "10 the ALERT is once per held set, not per tick"
# UNHOLD (the row goes back to queued; with the knob off the file carries it)
awk -F'\t' -v OFS='\t' -v s="$OLD" '$2==s {$3="queued"} {print}' "$DQ_STORE" > "$DQ_STORE.t" && mv "$DQ_STORE.t" "$DQ_STORE"
reset_tick
FLAG_DQ=0 train
[ "$(hooks_n)" = 1 ] && ok || bad "10 after UNHOLD the off tick departs, got $(hooks_n)"
[ ! -e "$MARK" ] && ok || bad "10 and drops the armed marker"
reset_tick
FLAG_DQ=0 request "$TARGET" >/dev/null; reset_tick
FLAG_DQ=0 train
[ "$(sink_n 'status=held')" = 0 ] && ok || bad "10 a disarmed off box makes no held read again"

echo "deploy-train-hold.bh-3154-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
