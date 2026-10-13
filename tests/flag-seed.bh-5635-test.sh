#!/bin/bash
# tests/flag-seed.bh-5635-test.sh — BH-5635.1: `bin/flag.sh seed`, the one-time
# copy of a box's flags/ files into pause_flags rows, and its hub lane.
#
# Driven, not grepped: every case runs the REAL bin/flag.sh seed, installed with
# its closure into a scratch root, against a curl stub on PATH.
#
#   S1  404 -> PUT (value, actor seed, reason); 200 -> skip; the flags.seeded
#       settings row is PUT, then the stamp is written
#   S2  a second run after the stamp sends nothing
#   S3  an outage mid-pass -> rc 1, no stamp, a flags.log line; a rerun finishes
#   S4  only flags/wip-limit-* is read: lanedown-/alerted-/pool-halt-/routing files
#       and the BH-4153 row families (paused-*, automerge-disabled*) never are
#   S9  a flags.seeded row (another hub seeded) -> stamp, no candidate request
#   S10 a failed flags.seeded read or PUT -> rc 1, no stamp
#   S5  free-text content -> PUT with no value, one log line, still stamped
#   S6  the secret never rides in a body
#   S7  flags/lane-off-flag stops the lane before any candidate request
#   S8  the hub lane renders on the hub only, behind the lease check
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flag-seed.bh-5635-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/flag.sh" ] || { echo "FAIL: $DIR/bin/flag.sh is missing"; exit 1; }

T2=2026-09-19T02:00:00Z

mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
# The jobs worker, faked: records "METHOD URL" and the body, answers from files.
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
[ -n "$BODY" ] && printf '%s\n' "$BODY" >> "$BODY_SINK"
if [ -n "${STUB_FAIL_ON:-}" ]; then
  case "$URL" in */api/flags/"$STUB_FAIL_ON") printf '{"error":"boom"}\n500\n'; exit 0 ;; esac
  case "$BODY" in *"\"name\":\"$STUB_FAIL_ON\""*) printf '{"error":"boom"}\n500\n'; exit 0 ;; esac
fi
case "$METHOD $URL" in
  "PUT "*/api/flags)
    n=$(printf '%s' "$BODY" | jq -r .name)
    printf '%s' "$BODY" | jq -c --arg u "$STUB_UPD" \
      '{flag:{name, active, value:(.value // null), actor, reason:(.reason // null), updated_at:$u}}' > "$ROWS/$n.json"
    cat "$ROWS/$n.json"; printf '\n200\n' ;;
  "GET "*/api/settings/flags.seeded)
    [ -n "${STUB_MARK_STATUS:-}" ] && { printf '{"error":"boom"}\n%s\n' "$STUB_MARK_STATUS"; exit 0; }
    if [ -s "$ROWS/settings-flags.seeded.json" ]; then cat "$ROWS/settings-flags.seeded.json"; printf '\n200\n'
    else printf '{"key":"flags.seeded","setting":null,"source":"none"}\n200\n'; fi ;;
  "PUT "*/api/settings)
    [ -n "${STUB_MARKPUT_STATUS:-}" ] && { printf '{"error":"boom"}\n%s\n' "$STUB_MARKPUT_STATUS"; exit 0; }
    printf '%s' "$BODY" | jq -c '{key, setting:{key, value}}' > "$ROWS/settings-flags.seeded.json"
    cat "$ROWS/settings-flags.seeded.json"; printf '\n200\n' ;;
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "$ROWS/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

N=0
mkh() { # mkh -> sets HR to a fresh scratch root with bin/flag.sh and its closure
  N=$((N+1)); HR="$T/h$N"
  mkdir -p "$HR/flags" "$HR/state" "$HR/logs" "$HR/rows"
  scratch_install_closure bin/flag.sh "$HR" >/dev/null || exit 1
  scratch_install_closure bin/jobs-client.sh "$HR" >/dev/null || exit 1
  : > "$HR/req.log"; : > "$HR/body.log"
}
# seed — runs the real `bin/flag.sh seed` in $HR; sets RC.
seed() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HR" HARNESS_SECRET=test-secret-fixture JOBS_RETRIES=0 \
           JOBS_URL=https://jobs.invalid ROWS="$HR/rows" REQ_SINK="$HR/req.log" BODY_SINK="$HR/body.log" \
           JOBS_BOX=box-t STUB_UPD="$T2"
    unset H
    "$HR/bin/flag.sh" seed ) > "$T/out" 2> "$T/err"
  RC=$?
}
# The candidate requests only: the lane gate reads its own switches too.
cand() { grep -E "/api/flags(/(paused|automerge-disabled|wip-limit)[^ ]*)?$" "$HR/req.log"; }
puts() { grep -c '^PUT ' "$HR/req.log"; }
putbody() { grep -F "\"name\":\"$1\"" "$HR/body.log" | tail -1; }
row() { printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s","value":null}}' "$1" "$2" "$T2" > "$HR/rows/$1.json"; }

echo "== S1: 404 -> PUT, 200 -> skip, marker, stamp =="
mkh
printf '2\n' > "$HR/flags/wip-limit-a"; printf '\n' > "$HR/flags/wip-limit-c"; printf '3\n' > "$HR/flags/wip-limit-b"
row wip-limit-a 0
seed
[ "$RC" = 0 ] && ok || bad "S1 rc $RC (err: $(cat "$T/err"))"
[ "$(grep -c '^GET https://jobs.invalid/api/flags/wip-limit-[abc]$' "$HR/req.log")" = 3 ] && ok \
  || bad "S1 want 3 candidate GETs: $(cat "$HR/req.log")"
[ "$(grep -c '^PUT https://jobs.invalid/api/flags$' "$HR/req.log")" = 2 ] && ok || bad "S1 want 2 flag PUTs: $(cat "$HR/req.log")"
[ -z "$(putbody wip-limit-a)" ] && ok || bad "S1 overwrote the existing wip-limit-a row"
# The fleet-wide marker is read first and written last.
ML=$(grep -n '^GET https://jobs.invalid/api/settings/flags.seeded$' "$HR/req.log" | head -1 | cut -d: -f1)
CL=$(grep -n '/api/flags/wip-limit-' "$HR/req.log" | head -1 | cut -d: -f1)
[ -n "$ML" ] && [ -n "$CL" ] && [ "$ML" -lt "$CL" ] && ok || bad "S1 the marker is not read before the candidates (marker line ${ML:-none}, first candidate ${CL:-none})"
[ "$(tail -1 "$HR/req.log")" = "PUT https://jobs.invalid/api/settings" ] && ok || bad "S1 the marker is not PUT last: $(tail -1 "$HR/req.log")"
M=$(grep -F '"key":"flags.seeded"' "$HR/body.log" | tail -1)
case "$(printf '%s' "$M" | jq -r .value)" in *"box=box-t seeded=2 skipped=1") ok ;; *) bad "S1 marker value: $M" ;; esac
B=$(putbody wip-limit-b)
[ "$(printf '%s' "$B" | jq -r .value)" = 3 ] && ok || bad "S1 wip-limit-b value: $B"
[ "$(printf '%s' "$B" | jq -r .actor)" = seed ] && ok || bad "S1 actor: $B"
[ "$(printf '%s' "$B" | jq -r .active)" = 1 ] && ok || bad "S1 active: $B"
[ "$(printf '%s' "$B" | jq -r .reason)" = "BH-5635 seed from box-t flags/" ] && ok || bad "S1 reason: $B"
[ "$(putbody wip-limit-c | jq -r 'has("value")')" = false ] && ok || bad "S1 empty file sent a value: $(putbody wip-limit-c)"
[ -f "$HR/state/flags-seeded" ] && ok || bad "S1 no state/flags-seeded"
grep -q 'seeded=2 skipped=1 box=box-t' "$HR/state/flags-seeded" 2>/dev/null && ok || bad "S1 stamp: $(cat "$HR/state/flags-seeded" 2>/dev/null)"
[ -f "$HR/flags/wip-limit-a" ] && [ -f "$HR/flags/wip-limit-b" ] && ok || bad "S1 seed touched a flags/ file"

echo "== S2: a rerun after the stamp is a no-op =="
: > "$HR/req.log"; : > "$HR/flags/wip-limit-new"
seed
[ "$RC" = 0 ] && ok || bad "S2 rc $RC"
[ ! -s "$HR/req.log" ] && ok || bad "S2 sent requests after the stamp: $(cat "$HR/req.log")"

echo "== S3: an outage mid-pass -> rc 1, no stamp; the rerun finishes =="
mkh
: > "$HR/flags/wip-limit-a"; : > "$HR/flags/wip-limit-b"; : > "$HR/flags/wip-limit-c"
STUB_FAIL_ON=wip-limit-b seed
[ "$RC" = 1 ] && ok || bad "S3 rc $RC, want 1"
[ ! -e "$HR/state/flags-seeded" ] && ok || bad "S3 stamped after an outage"
grep -q 'wip-limit-b' "$HR/logs/flags.log" 2>/dev/null && ok || bad "S3 flags.log does not name wip-limit-b: $(cat "$HR/logs/flags.log" 2>/dev/null)"
grep -q 'wip-limit-c' <<<"$(cand)" && bad "S3 kept going after the outage: $(cat "$HR/req.log")" || ok
grep -q '^PUT https://jobs.invalid/api/settings$' "$HR/req.log" && bad "S3 the marker was written after an outage" || ok
: > "$HR/req.log"; : > "$HR/body.log"
seed
[ "$RC" = 0 ] && ok || bad "S3b rerun rc $RC"
[ -f "$HR/state/flags-seeded" ] && ok || bad "S3b rerun did not stamp"
[ "$(grep -c '^PUT https://jobs.invalid/api/flags$' "$HR/req.log")" = 2 ] && [ -n "$(putbody wip-limit-b)" ] && [ -n "$(putbody wip-limit-c)" ] && [ -z "$(putbody wip-limit-a)" ] && ok \
  || bad "S3b want flag PUTs for wip-limit-b and wip-limit-c only: $(cat "$HR/req.log")"

echo "== S4: only wip-limit-* is read =="
mkh
# paused-*, automerge-disabled and automerge-disabled-* are BH-4153 rows that
# bin/flags-import.sh moves for the flags this box owns; the seed never
# publishes them (a hub-only pause must not become a fleet pause).
for f in lanedown-x alerted-y pool-halt-z hub-lease-renew-paused fly-pool-p builder-fly-p fly-pool-app-p wip-limit-c.tmp.42 \
         paused-c paused-box-small automerge-disabled automerge-disabled-p; do : > "$HR/flags/$f"; done
: > "$HR/flags/wip-limit-c"
seed
[ "$RC" = 0 ] && ok || bad "S4 rc $RC"
for f in lanedown-x alerted-y pool-halt-z hub-lease-renew-paused fly-pool-p builder-fly-p fly-pool-app-p wip-limit-c.tmp.42 \
         paused-c paused-box-small automerge-disabled automerge-disabled-p; do
  grep -q "/api/flags/$f\$" "$HR/req.log" && bad "S4 read $f" || ok
  grep -qF "\"name\":\"$f\"" "$HR/body.log" && bad "S4 PUT $f" || ok
done
grep -q "^GET https://jobs.invalid/api/flags/wip-limit-c\$" "$HR/req.log" && ok || bad "S4 wip-limit-c never read"
[ "$(grep -c '^PUT https://jobs.invalid/api/flags$' "$HR/req.log")" = 1 ] && ok || bad "S4 want 1 flag PUT: $(cat "$HR/req.log")"

echo "== S5: free text is seeded without a value =="
mkh
printf 'five builds\n' > "$HR/flags/wip-limit-d"
seed
[ "$RC" = 0 ] && ok || bad "S5 rc $RC"
[ "$(putbody wip-limit-d | jq -r 'has("value")')" = false ] && ok || bad "S5 body: $(putbody wip-limit-d)"
grep -q 'wip-limit-d' "$HR/logs/flags.log" 2>/dev/null && ok || bad "S5 no flags.log line for the dropped value"
[ -f "$HR/state/flags-seeded" ] && ok || bad "S5 not stamped"

echo "== S6: the secret never rides in a body =="
ALLB=$(cat "$T"/h*/body.log)
[ -n "$ALLB" ] && ok || bad "S6 no bodies recorded"
case "$ALLB" in *test-secret-fixture*) bad "S6 a body carries the secret" ;; *) ok ;; esac

echo "== S7: the lane off-switch stops the seed =="
mkh
: > "$HR/flags/wip-limit-a"; : > "$HR/flags/lane-off-flag"
seed
[ "$RC" = 0 ] && ok || bad "S7 rc $RC, want 0"
[ -z "$(cand)" ] && ok || bad "S7 candidate requests behind the switch: $(cand)"
[ ! -e "$HR/state/flags-seeded" ] && ok || bad "S7 stamped behind the switch"
grep -q 'settings/flags.seeded' "$HR/req.log" && bad "S7 read the marker behind the switch" || ok

echo "== S9: another hub already seeded -> stamp, no candidate request =="
mkh
: > "$HR/flags/wip-limit-a"
printf '{"key":"flags.seeded","setting":{"key":"flags.seeded","value":"2026-10-01T00:00:00Z box=hub-a seeded=3 skipped=0"}}' > "$HR/rows/settings-flags.seeded.json"
seed
[ "$RC" = 0 ] && ok || bad "S9 rc $RC (err: $(cat "$T/err"))"
[ -z "$(cand)" ] && ok || bad "S9 candidate requests after another hub seeded: $(cand)"
[ "$(grep -c '^PUT ' "$HR/req.log")" = 0 ] && ok || bad "S9 PUTs after another hub seeded: $(cat "$HR/req.log")"
grep -q 'marker=2026-10-01T00:00:00Z_box=hub-a' "$HR/state/flags-seeded" 2>/dev/null && ok || bad "S9 stamp: $(cat "$HR/state/flags-seeded" 2>/dev/null)"
grep -q 'seed skipped: settings flags.seeded' "$HR/logs/flags.log" 2>/dev/null && ok || bad "S9 no flags.log line"

echo "== S10: a failed marker read or write -> rc 1, no stamp =="
mkh
: > "$HR/flags/wip-limit-a"
STUB_MARK_STATUS=500 seed
[ "$RC" = 1 ] && ok || bad "S10 marker GET 500 rc $RC, want 1"
[ -z "$(cand)" ] && ok || bad "S10 candidate requests after a failed marker read: $(cand)"
[ ! -e "$HR/state/flags-seeded" ] && ok || bad "S10 stamped after a failed marker read"
mkh
: > "$HR/flags/wip-limit-a"
STUB_MARKPUT_STATUS=500 seed
[ "$RC" = 1 ] && ok || bad "S10b marker PUT 500 rc $RC, want 1"
[ ! -e "$HR/state/flags-seeded" ] && ok || bad "S10b stamped after a failed marker write"
grep -q 'PUT settings flags.seeded answered 500' "$HR/logs/flags.log" 2>/dev/null && ok || bad "S10b no flags.log line: $(cat "$HR/logs/flags.log" 2>/dev/null)"

echo "== S8: the lane renders on the hub only, behind the lease =="
HUBC=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/render-cron.sh" hub 2>/dev/null)
LINE=$(printf '%s\n' "$HUBC" | grep -F '/root/harness/bin/flag.sh seed')
case "$LINE" in "23 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/flag.sh seed"*) ok ;; *) bad "S8 hub line: '$LINE'" ;; esac
printf '%s\n' "$HUBC" | awk '/^# BEGIN hub-lanes/{b=1} /^# END hub-lanes/{b=0} b && /flag\.sh seed/{f=1} END{exit !f}' && ok || bad "S8 line outside a hub-lanes block"
project-4=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/render-cron.sh" project-4 2>/dev/null)
[ -n "$project-4" ] && ok || bad "S8 project-4 render empty"
case "$project-4" in *"flag.sh seed"*) bad "S8 the seed lane renders on project-4" ;; *) ok ;; esac
[ "$(jq -r '.scope + " " + (.boxes|join(",")) + " " + .script' "$DIR/catalog/lanes.d/flag.json" 2>/dev/null)" = "hub hub bin/flag.sh" ] && ok \
  || bad "S8 catalog/lanes.d/flag.json is not a hub lane for bin/flag.sh"

echo "flag-seed.bh-5635: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
