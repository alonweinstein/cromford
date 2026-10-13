#!/bin/bash
# tests/fly-pool-rows-parity.bh-2522-test.sh — BH-2522: bin/fly-pool-rows-parity.sh
# compares the pool's files with the machines rows, backfills the rows from the
# files, and flips fly_machines_rows on only when every file has its row and
# the settings row is still the untouched seed.
#
# Drives the REAL script (and, in P8, the real bin/fly-pool-tick.sh) against a
# scratch $HARNESS with a stubbed curl that plays the worker: GET/PUT
# /api/machines over $FIX/rows.json and GET/PUT /api/settings over
# $FIX/settings.json. Every request is logged to $FIX/req.log, and the flip is
# asserted on that log: the PUT /api/settings body, or its absence.
#
# One clock: PARITY_NOW pins "now", and every spawned_at below is a literal
# relative to it (1790000000 = 2026-09-21 14:13:20Z).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset FLY_MACHINES_ROWS

PNOW=1790000000
OLDTS="2026-09-21 12:00:00Z"     # 8000s before PNOW, well past the grace window
YOUNGTS="2026-09-21 14:12:20Z"   # 60s before PNOW, inside it

H="$T/h"; FIX="$T/fix"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly-pool" "$FIX" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
printf 'testbox\n' > "$H/state/box-name"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.log"\n' "$FIX" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# The worker. Arguments are read the way bin/lib/jobs/req.sh passes them:
# -X <method>, --data-binary <body>, and the URL last.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
M=GET; BODY=""; URL=""; P=""
for a; do
  case "$P" in X) M="$a";; D) BODY="$a";; esac; P=""
  case "$a" in -X) P=X;; --data-binary) P=D;; https://*) URL="$a";; esac
done
PATHQ="${URL#https://jobs.invalid}"
printf '%s %s %s\n' "$M" "$PATHQ" "$BODY" >> "$FIX/req.log"
[ -f "$FIX/down" ] && exit 7
case "$M $PATHQ" in
  "GET /api/settings/fly_machines_rows")
    if [ -f "$FIX/settings.json" ]; then printf '{"key":"fly_machines_rows","setting":%s}\n200' "$(cat "$FIX/settings.json")"
    else printf '{"key":"fly_machines_rows","setting":null}\n200'; fi ;;
  "PUT /api/settings")
    if [ -f "$FIX/settings-put-fail" ]; then printf '{"error":"boom"}\n500'; exit 0; fi
    printf '%s' "$BODY" | jq -c '{key,value,actor,note}' > "$FIX/settings.json"
    printf '{"ok":true}\n200' ;;
  "GET /api/machines"*)
    [ -f "$FIX/machines-404" ] && { printf 'nope\n404'; exit 0; }
    if [ -f "$FIX/machines-full" ]; then
      jq -nc '{machines: [range(500) | {machine_id:"f\(.)",project:"alpha",app:"pool-alpha",role:"pool",key:"F-\(.)",state:"started"}]}'
      printf '\n200'; exit 0
    fi
    PR=""; case "$PATHQ" in *project=*) PR="${PATHQ##*project=}"; PR="${PR%%&*}";; esac
    LV=0; case "$PATHQ" in *live=1*) LV=1;; esac
    jq -c --arg p "$PR" --argjson l "$LV" '{machines: [ .[] | select(($p == "" or .project == $p) and ($l == 0 or (.state != "destroyed" and .state != "gone"))) ]}' "$FIX/rows.json"
    printf '\n200' ;;
  "PUT /api/machines")
    if [ ! -f "$FIX/put-noop" ]; then
      jq -c --argjson b "$BODY" '[ .[] | select(.machine_id != $b.machine_id) ] + [$b | {machine_id,project,app,role,key,ticket,auth_account,state}]' "$FIX/rows.json" > "$FIX/rows.n" && mv "$FIX/rows.n" "$FIX/rows.json"
    fi
    printf '{"ok":true}\n200' ;;
  *) printf 'unrouted\n404' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

POOLD="$H/state/fly-pool/alpha"
reset() { # a clean fixture: pool on for alpha with a dedicated app, seed settings row
  scratch_rm "$H/state/fly-pool"; scratch_rm "$FIX"; scratch_rm "$H/flags"; mkdir -p "$POOLD" "$FIX" "$H/flags"
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  printf '' > "$H/flags/fly-pool-alpha"; printf 'pool-alpha\n' > "$H/flags/fly-pool-app-alpha"
  printf '{"key":"fly_machines_rows","value":"off","actor":"seed"}' > "$FIX/settings.json"
  printf '[]' > "$FIX/rows.json"
}
pfile() { # pfile <mid> <key> [spawned_at] — a pool file exactly as bin/fly-pool.sh writes it
  jq -nc --arg m "$1" --arg k "$2" --arg ts "${3:-$OLDTS}" \
    '{machine:$m,key:$k,ticket_id:("t-"+$k),attempt:0,deferrals:0,deaths:0,spawned_at:$ts,auth_account:"acct1"}' > "$POOLD/$1.json"
}
prow() { # prow <mid> <key> [state]
  jq -c --arg m "$1" --arg k "$2" --arg s "${3:-started}" \
    '. + [{machine_id:$m,project:"alpha",app:"pool-alpha",role:"pool",key:$k,state:$s}]' "$FIX/rows.json" > "$FIX/rows.n" && mv "$FIX/rows.n" "$FIX/rows.json"
}
run() { : > "$FIX/req.log"
  HARNESS="$H" FIX="$FIX" PATH="$T/fakebin:$PATH" PARITY_NOW="$PNOW" JOBS_RETRIES=0 \
    bash "$DIR/bin/fly-pool-rows-parity.sh" "$@" >/dev/null 2>&1; echo $?; }
verdict() { jq -r '.verdict' "$H/state/fly-pool/.parity.json" 2>/dev/null; }
report()  { jq -r "$1" "$H/state/fly-pool/.parity.json" 2>/dev/null; }
settings_puts() { grep -c '^PUT /api/settings ' "$FIX/req.log" 2>/dev/null || true; }
machine_puts()  { grep -c '^PUT /api/machines ' "$FIX/req.log" 2>/dev/null || true; }

# ---------- P1 files and rows agree -> parity ----------
reset; pfile m1 K-1; pfile m2 K-2; prow m1 K-1; prow m2 K-2
RC=$(run)
[ "$RC" = 0 ] && [ "$(verdict)" = parity ] && ok || bad "P1 two matching files/rows must be parity rc 0 (rc=$RC verdict=$(verdict))"
[ "$(report '.projects.alpha.files')" = 2 ] && [ "$(report '.projects.alpha.rows')" = 2 ] && ok || bad "P1 report must count files and rows: $(cat "$H/state/fly-pool/.parity.json" 2>/dev/null)"
[ "$(settings_puts)" = 0 ] && [ "$(machine_puts)" = 0 ] && ok || bad "P1 no --backfill/--flip must write nothing: $(cat "$FIX/req.log")"
[ "$(grep -c '^GET /api/machines' "$FIX/req.log")" = 1 ] && ok || bad "P1 one machines read per project per run (D21): $(grep machines "$FIX/req.log")"

# ---------- P2 a file with no row: drift, then backfilled to parity ----------
reset; pfile m1 K-1; prow m1 K-1; pfile m3 K-3
RC=$(run)
[ "$RC" = 1 ] && [ "$(verdict)" = drift ] && [ "$(report '.projects.alpha.file_without_row[0]')" = m3 ] \
  && ok || bad "P2 a file with no row is drift rc 1 naming it (rc=$RC $(report .projects.alpha))"
[ "$(machine_puts)" = 0 ] && ok || bad "P2 without --backfill no row may be written"
RC=$(run --backfill)
[ "$RC" = 0 ] && [ "$(verdict)" = parity ] && ok || bad "P2 --backfill must end in parity (rc=$RC verdict=$(verdict))"
PUTB=$(grep '^PUT /api/machines ' "$FIX/req.log" | sed 's/^PUT \/api\/machines //')
[ "$(printf '%s' "$PUTB" | jq -r '[.machine_id,.key,.role,.app,.project,.ticket,.auth_account] | join(" ")')" = "m3 K-3 pool pool-alpha alpha t-K-3 acct1" ] \
  && ok || bad "P2 the backfill PUT must carry the file's machine/key/ticket/account and the pool app: $PUTB"
[ "$(grep -c '^GET /api/machines' "$FIX/req.log")" = 2 ] && ok || bad "P2 a backfill must re-read the rows to confirm it"
# The re-read is the proof, not the PUT's rc: a worker that answers 200 and
# stores nothing is still drift.
reset; pfile m3 K-3; : > "$FIX/put-noop"
RC=$(run --backfill --flip)
[ "$RC" = 1 ] && [ "$(verdict)" = drift ] && [ "$(settings_puts)" = 0 ] && ok || bad "P2 a PUT that did not land is drift and never flips (rc=$RC verdict=$(verdict))"

# ---------- P3 parity + seed row + --flip -> exactly one flip ----------
reset; pfile m1 K-1; prow m1 K-1
RC=$(run --backfill --flip)
[ "$RC" = 0 ] && [ "$(settings_puts)" = 1 ] && ok || bad "P3 parity on a seed row must PUT the setting once (rc=$RC puts=$(settings_puts))"
SB=$(grep '^PUT /api/settings ' "$FIX/req.log" | sed 's/^PUT \/api\/settings //')
[ "$(printf '%s' "$SB" | jq -r '[.key,.value,.actor] | join(" ")')" = "fly_machines_rows on testbox" ] && ok || bad "P3 the PUT must set fly_machines_rows=on as this box: $SB"
printf '%s' "$SB" | jq -r .note | grep -q 'BH-2522' && ok || bad "P3 the flip must say why in its note: $SB"
[ "$(report .flip)" = done ] && ok || bad "P3 the report must record flip=done: $(report .flip)"
grep -q 'fly_machines_rows flipped on after parity (files=1 rows=1)' "$H/logs/fly-pool.log" && ok || bad "P3 one fly-pool.log line for the flip: $(cat "$H/logs/fly-pool.log")"
grep -q '"event":"fly_machines_rows_flipped"' "$FIX/beats.log" 2>/dev/null && ok || bad "P3 the flip must beat a fleet_event"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "P3 a successful flip is not an alert: $(cat "$H/logs/ALERTS.log")"
# Already on: the next tick asks nothing of the settings table.
RC=$(run --backfill --flip)
[ "$RC" = 0 ] && [ "$(settings_puts)" = 0 ] && [ "$(report .flag)" = on ] && ok || bad "P3/P6 value already on must not PUT again (rc=$RC puts=$(settings_puts) flag=$(report .flag))"

# ---------- P4 drift (row key differs) never flips ----------
reset; pfile m1 K-1; prow m1 K-OLD
RC=$(run --flip)
[ "$RC" = 1 ] && [ "$(settings_puts)" = 0 ] && [ "$(report '.projects.alpha.file_without_row[0]')" = m1 ] \
  && ok || bad "P4 a row whose key differs is drift and must not flip (rc=$RC puts=$(settings_puts))"

# ---------- P5 an operator's off is final ----------
reset; pfile m1 K-1; prow m1 K-1
printf '{"key":"fly_machines_rows","value":"off","actor":"operator"}' > "$FIX/settings.json"
RC=$(run --backfill --flip)
[ "$RC" = 0 ] && [ "$(settings_puts)" = 0 ] && ok || bad "P5 value off written by an operator must never be flipped (rc=$RC puts=$(settings_puts))"
[ "$(report .flip)" = operator ] && ok || bad "P5 the report must say operator: $(report .flip)"
grep -q 'operator-set, not flipping' "$H/logs/fly-pool.log" && ok || bad "P5 the log must say operator-set: $(cat "$H/logs/fly-pool.log")"
RC=$(run --backfill --flip)
[ "$(grep -c 'operator-set, not flipping' "$H/logs/fly-pool.log")" = 1 ] && ok || bad "P5 operator-set is logged once, not every tick"
printf '{"key":"fly_machines_rows","value":"off","actor":"hub"}' > "$FIX/settings.json"
RC=$(run --flip)
[ "$(settings_puts)" = 0 ] && ok || bad "P5 a box actor (hub) with off is an operator decision too"

# ---------- P6 adversarial negatives: none may PUT the setting ----------
# worker down
reset; pfile m1 K-1; prow m1 K-1; : > "$FIX/down"
RC=$(run --backfill --flip)
[ "$RC" = 2 ] && [ "$(verdict)" = unknown ] && [ "$(settings_puts)" = 0 ] && ok || bad "P6 worker down must be unknown rc 2, no flip (rc=$RC verdict=$(verdict))"
# worker 404 on the machines route (an older deploy)
reset; pfile m1 K-1; prow m1 K-1; : > "$FIX/machines-404"
RC=$(run --backfill --flip)
[ "$RC" = 2 ] && [ "$(verdict)" = unknown ] && [ "$(settings_puts)" = 0 ] && ok || bad "P6 a 404 must be unknown rc 2, no flip (rc=$RC verdict=$(verdict))"
# a full page is a truncated page
reset; pfile m1 K-1; : > "$FIX/machines-full"
RC=$(run --backfill --flip)
[ "$RC" = 2 ] && [ "$(verdict)" = unknown ] && [ "$(settings_puts)" = 0 ] && [ "$(machine_puts)" = 0 ] \
  && ok || bad "P6 a 500-row page must be unknown rc 2, no writes (rc=$RC verdict=$(verdict))"
# a file with no key
reset; pfile m1 K-1; prow m1 K-1; echo '{"machine":"m9","ticket_id":"t9","spawned_at":"2026-09-21 12:00:00Z"}' > "$POOLD/m9.json"
RC=$(run --backfill --flip)
[ "$RC" = 1 ] && [ "$(report '.projects.alpha.unreadable[0]')" = m9.json ] && [ "$(settings_puts)" = 0 ] \
  && ok || bad "P6 a file with no key is unreadable, never skipped (rc=$RC $(report .projects.alpha))"
# no pool app flag: a backfill would have to guess the app
reset; rm -f "$H/flags/fly-pool-app-alpha"; pfile m1 K-1
RC=$(run --backfill --flip)
[ "$RC" = 2 ] && [ "$(machine_puts)" = 0 ] && [ "$(settings_puts)" = 0 ] && ok || bad "P6 no app flag must not backfill or flip (rc=$RC puts=$(machine_puts)/$(settings_puts))"
# the env decides this box
reset; pfile m1 K-1; prow m1 K-1
RC=$(FLY_MACHINES_ROWS=off run --backfill --flip)
[ "$RC" = 0 ] && [ "$(settings_puts)" = 0 ] && [ "$(report .flip)" = env ] && [ "$(report .flag_source)" = env ] \
  && ok || bad "P6 FLY_MACHINES_ROWS in env must never flip the row (rc=$RC flip=$(report .flip))"
# a file younger than the grace window is neither compared nor backfilled, and
# it holds the flip until it is old enough to be judged
reset; pfile m1 K-1; prow m1 K-1; pfile m2 K-2 "$YOUNGTS"
RC=$(run --backfill --flip)
[ "$RC" = 0 ] && [ "$(report '.projects.alpha.young')" = 1 ] && [ "$(report '.projects.alpha.file_without_row | length')" = 0 ] \
  && ok || bad "P6 a young file is not counted as drift (rc=$RC $(report .projects.alpha))"
[ "$(machine_puts)" = 0 ] && [ "$(settings_puts)" = 0 ] && [ "$(report .flip)" = deferred_young ] \
  && ok || bad "P6 a young file is not backfilled and holds the flip (puts=$(machine_puts)/$(settings_puts) flip=$(report .flip))"
# a PUT that fails: no flip recorded, one deduped ALERT
reset; pfile m1 K-1; prow m1 K-1; : > "$FIX/settings-put-fail"
RC=$(run --flip)
[ "$(report .flip)" = failed ] && [ "$(grep -c 'fly_machines_rows' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "P6 a failed flip must be flip=failed with one ALERT (flip=$(report .flip)): $(cat "$H/logs/ALERTS.log")"
RC=$(run --flip)
[ "$(grep -c 'fly_machines_rows' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "P6 the flip-failed ALERT is deduped per day"

# ---------- P7 after the flip: report-only, persistent drift alerts once a day ----------
reset; printf '{"key":"fly_machines_rows","value":"on","actor":"testbox"}' > "$FIX/settings.json"
pfile m1 K-1
RC=$(run --backfill --flip)
[ "$RC" = 1 ] && [ "$(machine_puts)" = 0 ] && [ "$(settings_puts)" = 0 ] && ok || bad "P7 with the flag on nothing is backfilled or flipped (rc=$RC puts=$(machine_puts)/$(settings_puts))"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "P7 one drifting run is not yet an alert: $(cat "$H/logs/ALERTS.log")"
RC=$(run --backfill --flip)
[ "$(grep -c 'm1' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "P7 the same machine drifting twice must alert once: $(cat "$H/logs/ALERTS.log")"
[ -f "$H/flags/alerted-fly-rows-drift-20260921" ] && ok || bad "P7 the alert is deduped by a dated flag: $(ls "$H/flags")"
RC=$(run --backfill --flip)
[ "$(grep -c . "$H/logs/ALERTS.log")" = 1 ] && ok || bad "P7 a third drifting run the same day must not alert again"

# ---------- P8 the production entry point: the pool tick runs the preflight ----------
reset; pfile m1 K-1; prow m1 K-1
cp "$DIR/bin/fly-pool-tick.sh" "$DIR/bin/fly-pool-rows-parity.sh" "$H/bin/"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/fly-pool.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/fly-lock-guard.sh"
printf '#!/bin/bash\necho 1\n' > "$H/bin/pool-cap.sh"
chmod +x "$H/bin/"*.sh
rm -f "$H/state/fly-pool/.parity.json"
HARNESS="$H" FIX="$FIX" PATH="$T/fakebin:$PATH" PARITY_NOW="$PNOW" JOBS_RETRIES=0 bash "$H/bin/fly-pool-tick.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "P8 the tick's own exit must be unchanged (rc=$RC)"
[ "$(verdict)" = parity ] && ok || bad "P8 bin/fly-pool-tick.sh must run the parity preflight (no .parity.json: $(ls -a "$H/state/fly-pool"))"
[ "$(settings_puts)" = 1 ] && ok || bad "P8 the tick runs it with --flip (puts=$(settings_puts))"

echo "fly-pool-rows-parity.bh-2522-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
