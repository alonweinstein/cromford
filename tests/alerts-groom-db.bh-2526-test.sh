#!/bin/bash
# tests/alerts-groom-db.bh-2526-test.sh — rules 2-4 of bin/alerts-groom.sh read
# the coordination DB, not a box over ssh (BH-2526).
#
# Runs the REAL bin/alerts-groom.sh with only its harness root rewritten, over
# the REAL bin/jobs-client.sh + bin/lib/jobs/*.sh, bin/fleet-conf.sh,
# bin/box-for.sh and bin/project-of.sh. What is stubbed is what would leave the
# machine: curl (the jobs worker and the console), ssh and gh. The assertion is
# what the groomer DID: the ids it POSTed to the console resolve, the lines it
# wrote to logs/alerts-groom.log, and that ssh was never invoked.
#
# The three facts and their DB twins:
#   rule 4 watcher recovered  -> GET /api/lanes        (lane_tick's row: state + last_tick_kind)
#   rule 3 build handled      -> GET /api/artifacts    (kind=commented, ref = the build dir)
#   rule 2 migration applied  -> GET /api/jobs?kind=migration + /api/jobs/<id> events
#
# THE NEGATIVES CARRY THE WEIGHT. Resolving closes a client-visible alert, so a
# stale lane whose last tick was a `run` (a DEAD box, G2), a failing tick (G3),
# a prefix-sharing build dir (G7), a FAILED/SKIPPED/other-PR migration event
# (G5), a pending or missing lane row (G8) and a DB outage (G9) must all hold
# the row — and the dead box and the outage must SAY so in the log, because a
# pass that held rows on a dead box must never read like a quiet one.
#
# Run from anywhere: tests/alerts-groom-db.bh-2526-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "alerts-groom-db.bh-2526: jq missing, cannot run"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/builds" \
         "$T/fakebin" "$T/fix"
printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\n' \
  > "$H/env/global.env"
cat > "$T/fleet.conf" <<'EOC'
project-4  example-org/project-4  https://os.project-4.example  /api/board  8 box-project-4-1 10.0.0.9
EOC
export FLEET_CONF="$T/fleet.conf"

sed "s|/root/harness|$H|g" "$DIR/bin/alerts-groom.sh" > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"
for s in jobs-client.sh fleet-conf.sh box-for.sh project-of.sh; do cp "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/"
[ -r "$DIR/bin/lib/groom-db.sh" ] && cp "$DIR/bin/lib/groom-db.sh" "$H/bin/lib/"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/fleet-projects-or-alert.sh"; chmod +x "$H/bin/fleet-projects-or-alert.sh"
printf '#!/usr/bin/env python3\n' > "$H/bin/alerts-supersede.py"

# --- stubs -------------------------------------------------------------------
# curl: the jobs host speaks the jobs-client wire (body line, then status line);
# the console answers raw JSON. Every request is recorded in req.log; the
# console resolve body goes to posts.jsonl.
{ echo '#!/bin/bash'; echo "FIX=$T/fix"; echo "OUT=$T"; cat <<'CURLEOF'
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$OUT/req.log"
case "$URL" in
  *jobs.invalid*)
    [ "${CURL_MODE:-ok}" = down ] && exit 7
    case "$METHOD $URL" in
      "GET "*/api/lanes)          printf '%s\n200\n' "$(cat "$FIX/lanes.json")" ;;
      "GET "*/api/artifacts\?*)   printf '%s\n200\n' "$(cat "$FIX/artifacts.json")" ;;
      "GET "*/api/jobs\?*)        printf '%s\n200\n' "$(cat "$FIX/jobs.json")" ;;
      "GET "*/api/jobs/*)
        id="${URL##*/api/jobs/}"
        if [ -r "$FIX/job-$id.json" ]; then printf '%s\n200\n' "$(cat "$FIX/job-$id.json")"
        else printf '{"error":"no such job"}\n404\n'; fi ;;
      *) printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  *console.invalid/api/alerts/open)    cat "$FIX/console.json" ;;
  *console.invalid/api/alerts/resolve) printf '%s\n' "$BODY" >> "$OUT/posts.jsonl"; echo '{"ok":true}' ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# ssh: never answers. Any call at all is a finding (G10).
printf '#!/bin/sh\necho "$*" >> "%s/ssh.log"\nexit 255\n' "$T" > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
printf '#!/bin/sh\necho OPEN\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
: > "$T/ssh.log"

# --- fixtures ----------------------------------------------------------------
BOX=box-project-4-1
BD="project-4-TK-9-202609250101"
alerts() { # alerts <id> <line> [<id> <line>...]
  local a="[" sep=""
  while [ $# -ge 2 ]; do
    a="$a$sep$(jq -nc --arg i "$1" --arg l "$2" '{id:$i,createdAt:"2026-09-26T00:00:00Z",akey:"beat:x",line:$l}')"
    sep=","; shift 2
  done
  printf '{"alerts":%s]}' "$a" > "$T/fix/console.json"
}
lanes() { # lanes <project> <box> <state> <last_tick_kind> [tick_age]
  if [ $# -eq 0 ]; then echo '{"lanes":[]}' > "$T/fix/lanes.json"; return; fi
  jq -nc --arg p "$1" --arg b "$2" --arg s "$3" --arg k "$4" --argjson a "${5:-120}" \
    '{lanes:[{project:$p,box:$b,state:$s,silence_s:$a,tick_age_s:$a,last_tick_kind:$k,
              stale_after_s:1800,last_tick_at:"2026-09-25T20:00:00Z",ticked_since_declared:true}]}' \
    > "$T/fix/lanes.json"
}
arts() { # arts <ref>...
  local a="[" sep="" r
  for r in "$@"; do
    a="$a$sep$(jq -nc --arg r "$r" '{job_id:"j-art",artifact_kind:"commented",artifact_ref:$r,box:"box-project-4-1",updated_at:"2026-09-25T20:00:00Z"}')"
    sep=","
  done
  printf '{"artifacts":%s]}' "$a" > "$T/fix/artifacts.json"
}
migjob() { # migjob <verdict> <detail> [<verdict> <detail>...] — one migration job with these events
  local n; n=$(ls "$T/fix"/job-mig-*.json 2>/dev/null | wc -l | tr -d ' ')
  local id="mig-$n" ev="[" sep=""
  while [ $# -ge 2 ]; do
    ev="$ev$sep$(jq -nc --arg v "$1" --arg d "$2" '{stage:"apply",verdict:$v,detail:$d,actor:"hub"}')"
    sep=","; shift 2
  done
  printf '{"job":{"id":"%s","kind":"migration"},"events":%s]}' "$id" "$ev" > "$T/fix/job-$id.json"
  jq -c --arg i "$id" '.jobs += [{id:$i,kind:"migration",project:"project-4"}]' "$T/fix/jobs.json" > "$T/fix/jobs.tmp" \
    && mv "$T/fix/jobs.tmp" "$T/fix/jobs.json"
}
reset() {
  rm -f "$T/fix"/job-*.json "$T/posts.jsonl" "$T/req.log"
  echo '{"jobs":[]}' > "$T/fix/jobs.json"
  lanes; arts
  : > "$H/logs/alerts-groom.log"
}
groom() {
  PATH="$T/fakebin:$PATH" CURL_MODE="${CURL_MODE:-ok}" bash "$H/bin/alerts-groom.sh" >/dev/null 2>&1
}
resolved() { jq -r '.ids[]' "$T/posts.jsonl" 2>/dev/null | grep -qx "$1"; }
glog() { cat "$H/logs/alerts-groom.log" 2>/dev/null; }

WLINE="[project-4] triage run exited rc=1 (tick 2026-09-25T20:00Z)"

# ---- G1 live row, last tick ran -> recovered --------------------------------
reset; alerts g1 "$WLINE"; lanes project-4 "$BOX" live run
groom
resolved g1 && ok || bad "G1 a live lane whose last tick ran must settle the rc=1 row (posts: $(cat "$T/posts.jsonl" 2>/dev/null))"
grep -q 'resolve g1 (watcher-recovered)' <(glog) && ok || bad "G1 resolve reason must be watcher-recovered (log: $(glog))"

# ---- G2 DEAD BOX: stale row whose last tick was a run ------------------------
reset; alerts g2 "$WLINE"; lanes project-4 "$BOX" stale run 99999
groom
! resolved g2 && ok || bad "G2 a stale (dead) lane must NOT settle, whatever its last tick said"
grep -q "hold g2 (watcher-dead: $BOX" <(glog) && ok || bad "G2 the dead box must be named in a hold line (log: $(glog))"
grep -q 'pass done: .*dead=1' <(glog) && ok || bad "G2 the pass summary must carry dead=1 (log: $(glog))"

# ---- G3 live but failing -----------------------------------------------------
reset; alerts g3 "$WLINE"; lanes project-4 "$BOX" live failed
groom
! resolved g3 && ok || bad "G3 a live lane whose last tick FAILED must not settle"
grep -q 'pass done: resolved 0' <(glog) && ok || bad "G3 a pass that settles nothing still writes its summary (log: $(glog))"

# ---- G4 migration APPLIED for exactly this PR --------------------------------
MLINE="[project-4] MIGRATION-PR merged: #42 (add ledger table) — confirm SQL applied to prod"
reset; alerts g4 "$MLINE"; migjob APPLIED "PR#42 serving=abcd1234"
groom
resolved g4 && ok || bad "G4 an APPLIED stage_event for PR#42 must settle the row"
grep -q 'resolve g4 (migration-applied)' <(glog) && ok || bad "G4 reason must be migration-applied (log: $(glog))"

# ---- G5 FAILED alongside APPLIED / SKIPPED / other PR numbers ----------------
# The FAILED detail is the one migration-autopilot.sh's FAIL() writes, expanded
# for PR 42, so this case reads the producer's wire shape rather than a guess.
fail_detail=$(awk '/^FAIL\(\) *\{/ { f = 1 } f && /mig_job_close failed FAILED / { sub(/.*mig_job_close failed FAILED /, ""); print; exit }' \
  "$DIR/bin/migration-autopilot.sh")
[ -n "$fail_detail" ] && ok || bad "G5 FAIL() in migration-autopilot.sh must close its job with a FAILED event"
fail_detail=$(set -- x 42 "apply returned status=500"; eval "printf '%s' $fail_detail")
grep -qE 'PR#42([^0-9]|$)' <<<"$fail_detail" && ok \
  || bad "G5 FAIL()'s FAILED detail must name the PR as PR#<n> (got: $fail_detail)"
reset; alerts g5a "$MLINE"; migjob APPLIED "PR#42 serving=abcd1234"; migjob FAILED "$fail_detail"
groom
! resolved g5a && ok || bad "G5 one FAILED file in the PR must hold the row"
reset; alerts g5b "$MLINE"; migjob SKIPPED "non-harness PR#42 by someone"
groom
! resolved g5b && ok || bad "G5 SKIPPED alone must never settle"
reset; alerts g5c "$MLINE"; migjob APPLIED "PR#421 serving=abcd1234"; migjob APPLIED "PR#4 serving=abcd1234"
groom
! resolved g5c && ok || bad "G5 PR#421 / PR#4 must not match an alert about #42 (digit boundary)"

# ---- G6 commented artifact for this build dir --------------------------------
BLINE="[project-4] build RESULT unhandled: $H/builds/$BD/RESULT"
reset; alerts g6 "$BLINE"; arts "/root/harness/builds/$BD"
groom
resolved g6 && ok || bad "G6 a commented artifact naming the build dir must settle the row"
grep -q 'resolve g6 (build-handled)' <(glog) && ok || bad "G6 reason must be build-handled (log: $(glog))"
grep -q 'GET https://jobs.invalid/api/artifacts?kind=commented&project=project-4' "$T/req.log" \
  && ok || bad "G6 the feed must be asked for kind=commented of the project (req: $(cat "$T/req.log" 2>/dev/null))"

# ---- G7 prefix-sharing dir / withdrawn ref -----------------------------------
reset; alerts g7a "$BLINE"; arts "/root/harness/builds/project-4-TK-9-2026092501"
groom
! resolved g7a && ok || bad "G7 a dir that only shares a prefix must not settle"
reset; alerts g7b "$BLINE"; arts withdrawn
groom
! resolved g7b && ok || bad "G7 a withdrawn ref must not settle"

# ---- G8 pending row / no row -> unknown, declared ----------------------------
reset; alerts g8a "$WLINE"; lanes project-4 "$BOX" pending -
groom
! resolved g8a && ok || bad "G8 a pending lane must not settle"
grep -q 'hold g8a (watcher-unknown' <(glog) && ok || bad "G8 a pending lane must log watcher-unknown (log: $(glog))"
reset; alerts g8b "$WLINE"; lanes
groom
! resolved g8b && ok || bad "G8 no lane row must not settle"
grep -q 'hold g8b (watcher-unknown' <(glog) && ok || bad "G8 no lane row must log watcher-unknown (log: $(glog))"

# ---- G9 the jobs host is down ------------------------------------------------
reset; alerts g9w "$WLINE" g9m "$MLINE" g9b "$BLINE"
lanes project-4 "$BOX" live run; arts "/root/harness/builds/$BD"; migjob APPLIED "PR#42 serving=abcd1234"
CURL_MODE=down groom
! resolved g9w && ! resolved g9m && ! resolved g9b && ok || bad "G9 an outage must settle nothing (posts: $(cat "$T/posts.jsonl" 2>/dev/null))"
U=$(glog | grep -o 'pass done: .*unknown=[0-9]*' | grep -o 'unknown=[0-9]*$' | cut -d= -f2)
[ -n "$U" ] && [ "$U" -gt 0 ] && ok || bad "G9 the summary must declare unknown>0 on an outage (log: $(glog))"

# ---- G10 no ssh at any point -------------------------------------------------
[ ! -s "$T/ssh.log" ] && ok || bad "G10 ssh was invoked: $(head -3 "$T/ssh.log")"

# ---- G11 no ssh/scp token in the groomer outside comments --------------------
N=$(grep -vE '^[[:space:]]*#' "$DIR/bin/alerts-groom.sh" | grep -cwE 'ssh|scp')
[ "$N" = 0 ] && ok || bad "G11 bin/alerts-groom.sh still has $N non-comment ssh/scp line(s)"

echo "alerts-groom-db.bh-2526: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
