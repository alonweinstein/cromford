#!/bin/bash
# tests/box-ops-orgo.bh-5749-test.sh — bin/box-ops.sh restart|resize|stop|retire
# (bin/lib/box-ops-orgo.sh): the Orgo verbs next to the cron claim loop.
#
# Runs the REAL bin/box-ops.sh, bin/lib/box-ops-orgo.sh, the Orgo seam
# (bin/lib/restore-drill-orgo.sh), bin/fleet-conf.sh, bin/box-for.sh and
# bin/jobs-client.sh in a scratch repo root ($R, with fleet.conf, a fixture
# catalog and a git origin) and a scratch harness root ($H). Stubbed: curl
# (plays Orgo and the jobs worker's PUT /api/flags), ssh (plays
# quiesce-for-resize.sh on the box), bin/box-name.sh and bin/box-register.sh.
# Every call lands in $T/seq.log in the order it was made.
#   O1  resize: results lacks ram / is empty / is missing -> rc 1, no OK
#   O2  resize: results fine, the re-read GET shows the old cpu -> rc 1
#   O3  resize up with no / a wrong / the new-total confirm: COST, rc 2, no ssh, no PATCH
#   O4  resize up, ram pool 1 GB short: NEEDS PURCHASE, rc 3, no ssh, no PATCH
#   O5  quiesce rc 1, or rc 0 with no SAFE_TO_RESIZE: rc 1, no PATCH
#   O6  happy path: ssh quiesce, then PATCH {"ram":8}, then GET; rc 0, OK
#   O7  resize dry run: PLAN lines, no ssh, no PATCH
#   O8  resize down with no confirm: rc 0, one PATCH
#   O9  retire with a project and no --to: rc 2, names pa pb, no box-register, tree clean
#   O10 retire --to: the moves, then --retire; no DELETE; state has the host; dry run calls nothing
#   O11 retire --delete while origin/main names the host (or only cron/boxes/<id>.d): rc 4, no DELETE
#   O12 retire --delete after the merge: one DELETE, GET 404, deleted_at; a re-run deletes nothing
#   O13 stop: PUT paused-pa, paused-pb, both flag files, then POST /stop
#   O14 stop: the paused-pb PUT fails: rc 1, no POST /stop
#   O15 stop dry run: no PUT, no POST, PLAN lines
#   O16 restart: POST then running; HTTP 500; never running; dry run
#   O17 refusals with zero curl calls; 0 or 2 name matches
#   O18 the key value is in no output and no log
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

R="$T/repo"; H="$T/h"
mkdir -p "$R/bin" "$R/catalog" "$H/env" "$T/fakebin" "$T/orgo"
for s in bin/box-ops.sh bin/lib/box-ops-orgo.sh bin/fleet-conf.sh bin/box-for.sh bin/jobs-client.sh; do
  [ -f "$DIR/$s" ] || { bad "missing $s"; continue; }
  scratch_install_closure "$s" "$R" >/dev/null || { echo "FAIL: closure install $s"; exit 1; }
done
: > "$H/env/global.env"

cat > "$R/catalog/orgo-plans.json" <<'EOF'
{"accounts": {
  "fixture-acct": {"plan": "startup_v2", "key_env": "FIXTURE_ORGO_KEY", "template_ref": "tpl-fixture",
    "cost_account": "fixture-cost", "register_like": null,
    "limits": {"max_vcpus_per_computer": 4, "ram_tiers_gb": [4, 8, 16, 32]},
    "pool": {"computers": 10, "vcpus": 40, "ram_gb": 64, "disk_gb": null},
    "prices_usd_mo": {"computer": 1, "vcpu": 10, "ram_gb": 4, "disk_gb": null},
    "defaults": {"vcpus": 4, "mem_gb": 8, "disk_gb": null}},
  "fixture-tight": {"plan": "startup_v2", "key_env": "FIXTURE_ORGO_KEY", "template_ref": "tpl-fixture",
    "cost_account": "fixture-cost", "register_like": null,
    "limits": {"max_vcpus_per_computer": 4, "ram_tiers_gb": [4, 8, 16, 32]},
    "pool": {"computers": 10, "vcpus": 40, "ram_gb": 11, "disk_gb": null},
    "prices_usd_mo": {"computer": 1, "vcpu": 10, "ram_gb": 4, "disk_gb": null},
    "defaults": {"vcpus": 4, "mem_gb": 8, "disk_gb": null}},
  "fixture-nopool": {"plan": "startup_v2", "key_env": "FIXTURE_ORGO_KEY", "template_ref": "tpl-fixture",
    "cost_account": "fixture-cost", "register_like": null,
    "limits": {"max_vcpus_per_computer": 4, "ram_tiers_gb": [4, 8, 16, 32]},
    "pool": {"computers": null, "vcpus": null, "ram_gb": null, "disk_gb": null},
    "prices_usd_mo": {"computer": 1, "vcpu": 10, "ram_gb": 4, "disk_gb": null},
    "defaults": {"vcpus": 4, "mem_gb": 8, "disk_gb": null}}
}}
EOF
printf '{"box_aliases": {}, "accounts": {}}\n' > "$R/catalog/cost-accounts.json"

cat > "$R/bin/box-name.sh" <<'EOF'
#!/bin/bash
echo node-selfbox
EOF
cat > "$R/bin/box-register.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/register.log"
printf 'REG %s\n' "$*" >> "$STUB_DIR/seq.log"
echo "NEXT: fixture box-register next line"
[ "$1" = --retire ] && exit "${STUB_RETIRE_RC:-0}"
exit "${STUB_REG_RC:-0}"
EOF
chmod +x "$R/bin/box-name.sh" "$R/bin/box-register.sh"

# Git: origin-yes main still names node-oldbox; origin-crond keeps only
# cron/boxes/oldbox.d; origin-gone forgets the box.
G() { git -C "$R" -c user.name=fixture -c user.email=fixture@example.com "$@"; }
FLEET='pa acme/pa - - 1 node-oldbox 192.0.2.5
pb acme/pb - - 1 node-oldbox 192.0.2.5
pc acme/pc - - 1 node-newbox 192.0.2.77'
printf '%s\n' "$FLEET" > "$R/fleet.conf"
printf 'state/\n' > "$R/.gitignore"
G init -q -b main && G add -A && G commit -qm base || { echo "FAIL: git fixture"; exit 1; }
for o in yes crond gone; do git init -q --bare "$T/origin-$o.git"; done
G push -q "$T/origin-yes.git" main || exit 1
printf 'pa acme/pa - - 1 node-newbox 192.0.2.77\npb acme/pb - - 1 node-newbox 192.0.2.77\npc acme/pc - - 1 node-newbox 192.0.2.77\n' > "$R/fleet.conf"
mkdir -p "$R/cron/boxes/oldbox.d" && printf '# fixture\n' > "$R/cron/boxes/oldbox.d/000-path.cron"
G add -A && G commit -qm crond && G push -q "$T/origin-crond.git" main || exit 1
G rm -rq cron && G commit -qm gone && G push -q "$T/origin-gone.git" main || exit 1
G reset -q --hard HEAD~2 || exit 1
G remote add origin "$T/origin-yes.git" || exit 1

# curl: Orgo under https://orgo.fixture/api, the jobs worker under https://jobs.fixture.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET url="" body="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift ;;
    --data-binary) data=$2; shift ;;
    -m|-H|-w|--connect-timeout) shift ;;
    http*) url=$1 ;;
  esac
  shift
done
case "$data" in "") ;; @-) body=$(cat) ;; @*) body=$(cat "${data#@}") ;; *) body=$data ;; esac
O="$STUB_DIR/orgo"; C="$O/comp.json"
case "$url" in
  https://jobs.fixture/*)
    p=/${url#https://jobs.fixture/}
    n=$(jq -r '.name // empty' <<< "$body" 2>/dev/null); a=$(jq -r '.active // empty' <<< "$body" 2>/dev/null)
    printf '%s %s %s %s\n' "$m" "$p" "$n" "$a" >> "$STUB_DIR/seq.log"
    if [ "$m $p" = "PUT /api/flags" ] && [ "$n" != "${STUB_FLAG_FAIL:-}" ]; then
      printf '%s\n%s' "$(jq -nc --arg n "$n" --argjson a "$a" '{flag:{name:$n, active:$a, updated_at:"2026-10-10T00:00:00Z"}}')" 200
    else
      printf '%s\n%s' '{"error":"fixture"}' 500
    fi
    exit 0 ;;
esac
p=${url#https://orgo.fixture/api}
printf '%s %s\n' "$m" "$p" >> "$STUB_DIR/seq.log"
[ -n "$body" ] && printf '%s %s %s\n' "$m" "$p" "$body" >> "$STUB_DIR/bodies.log"
OID=$(jq -r .id "$C")
case "$m $p" in
  "GET /computers")
    if [ -n "${STUB_LIST_RAW:-}" ]; then printf '%s\n%s' "$STUB_LIST_RAW" 200; exit 0; fi
    if [ -f "$O/deleted" ]; then l=$(cat "$O/others.json"); else l=$(jq -c --slurpfile c "$C" '. + $c' "$O/others.json"); fi
    printf '%s\n%s' "$l" 200 ;;
  "GET /computers/$OID")
    if [ -f "$O/deleted" ]; then printf '%s\n%s' '{"error":"not found"}' 404; exit 0; fi
    printf '%s\n%s' "$(cat "$C")" 200 ;;
  "POST /computers/$OID/restart")
    [ "${STUB_RESTART_CODE:-200}" = 200 ] || { printf '%s\n%s' '{}' "$STUB_RESTART_CODE"; exit 0; }
    jq --arg s "${STUB_AFTER_STATUS:-running}" '.status = $s' "$C" > "$C.t" && mv "$C.t" "$C"
    printf '%s\n%s' '{"ok":true}' 200 ;;
  "POST /computers/$OID/stop")
    [ "${STUB_STOP_CODE:-200}" = 200 ] || { printf '%s\n%s' '{}' "$STUB_STOP_CODE"; exit 0; }
    jq --arg s "${STUB_AFTER_STATUS:-stopped}" '.status = $s' "$C" > "$C.t" && mv "$C.t" "$C"
    printf '%s\n%s' '{"ok":true}' 200 ;;
  "PATCH /computers/$OID/resize")
    [ -z "${STUB_PATCH_NOAPPLY:-}" ] && jq --argjson b "$body" '. + $b' "$C" > "$C.t" && mv "$C.t" "$C"
    if [ -n "${STUB_RESULTS+set}" ]; then r=$STUB_RESULTS
    else r=$(jq -c '{results: [keys[] | {key: ., ok: true}]}' <<< "$body"); fi
    printf '%s\n%s' "$r" 200 ;;
  "DELETE /computers/$OID")
    touch "$O/deleted"; printf '%s\n%s' '{"ok":true}' 200 ;;
  *) printf '%s\n%s' '{}' 404 ;;
esac
EOF
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
printf 'SSH %s %s\n' "$1" "${*:2}" >> "$STUB_DIR/seq.log"
printf '%s\n' "${STUB_Q_OUT-$'quiesce: paused\nSAFE_TO_RESIZE snap-fixture'}"
exit "${STUB_Q_RC:-0}"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/ssh"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_BOX_PREFIX=node- \
       ORGO_API_BASE=https://orgo.fixture/api BOX_LAUNCH_POLL_S=1 \
       JOBS_URL=https://jobs.fixture HARNESS_SECRET=fixture-jobs-secret JOBS_RETRIES=0
KEY=sk-fixture-SECRET
SEQ="$T/seq.log"; RST="$H/state/box-ops/oldbox.json"

reset() {
  for d in "$H/state" "$H/logs" "$H/locks" "$H/flags" "$SEQ" "$T/bodies.log" "$T/register.log" "$T/orgo/deleted"; do
    scratch_rm "$d" || exit 1
  done
  mkdir -p "$H/state/box-launch" "$H/logs"
  printf '{"id":"oldbox","orgo_id":"c-old","host":"node-oldbox"}\n' > "$H/state/box-launch/oldbox.json"
  printf '{"id":"c-old","name":"node-oldbox","cpu":4,"ram":4,"disk":null,"status":"running"}\n' > "$T/orgo/comp.json"
  printf '[{"id":"c-x","name":"node-other","cpu":4,"ram":4,"disk":null,"status":"running"}]\n' > "$T/orgo/others.json"
  unset STUB_LIST_RAW STUB_RESTART_CODE STUB_STOP_CODE STUB_AFTER_STATUS STUB_PATCH_NOAPPLY STUB_RESULTS \
        STUB_FLAG_FAIL STUB_Q_OUT STUB_Q_RC STUB_REG_RC STUB_RETIRE_RC BOX_LAUNCH_DEADLINE_S
  export FIXTURE_ORGO_KEY=$KEY ORGO_API_KEY=$KEY
  G remote set-url origin "$T/origin-yes.git"
  G checkout -q -- . && G clean -qfd -e state/
}
leakcheck() { cat "$T/out" "$T/err" >> "$T/all-output" 2>/dev/null; }
run() { bash "$R/bin/box-ops.sh" "$@" >"$T/out" 2>"$T/err"; RC=$?; leakcheck; }
n()   { [ -f "$2" ] || { echo 0; return; }; grep -cE "$1" "$2"; return 0; }
lastl() { tail -n 1 "$T/out"; }
lineno() { grep -nE "$1" "$SEQ" 2>/dev/null | head -1 | cut -d: -f1; }
ctx() { echo "rc=$RC out=[$(cat "$T/out")] err=[$(cat "$T/err")] seq=[$(tr '\n' ';' 2>/dev/null < "$SEQ")]"; }
npatch() { n '^PATCH ' "$SEQ"; }
nssh()   { n '^SSH ' "$SEQ"; }
UP=(resize oldbox --account fixture-acct --mem-gb 8)

# --- O1 results lacks ram / empty / missing ---------------------------------------
reset
export STUB_RESULTS='{"results":[{"key":"cpu","ok":true}]}'
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 1 ] && ok || bad "O1 $(ctx)"
grep -q 'Orgo ignored resize key ram' "$T/err" && ok || bad "O1 no 'ignored resize key ram': $(ctx)"
lastl | grep -q 'result=FAIL' && ok || bad "O1 summary=[$(lastl)]"
reset
export STUB_RESULTS='{"results":[]}'
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 1 ] && grep -q 'Orgo ignored resize key ram' "$T/err" && ok || bad "O1 empty results $(ctx)"
reset
export STUB_RESULTS='{"results":[{"field":"ram","status":"ignored"}]}'
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 1 ] && grep -q 'Orgo ignored resize key ram' "$T/err" && ok || bad "O1 status ignored $(ctx)"
reset
export STUB_RESULTS='{"ok":true}'
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 1 ] && grep -q 'no results array' "$T/err" && lastl | grep -q 'result=FAIL' && ok || bad "O1 missing results $(ctx)"

# --- O2 results fine, re-read shows the old spec ------------------------------------
reset
export STUB_PATCH_NOAPPLY=1
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 1 ] && lastl | grep -q 'result=FAIL' && ok || bad "O2 $(ctx)"
grep -q 'OK' <<< "$(lastl)" && bad "O2 summary says OK" || ok

# --- O3 resize up with no / wrong / new-total confirm -------------------------------
for c in none 15 73; do
  reset
  if [ "$c" = none ]; then run "${UP[@]}" --apply; else run "${UP[@]}" --apply --confirm-monthly-usd "$c"; fi
  [ "$RC" = 2 ] && ok || bad "O3 confirm=$c $(ctx)"
  grep -qxF 'COST: resize oldbox +$16/mo (now $57/mo, after $73/mo) — re-run with --confirm-monthly-usd 16' "$T/out" \
    && ok || bad "O3 confirm=$c no COST line: $(ctx)"
  [ "$(nssh)" = 0 ] && [ "$(npatch)" = 0 ] && ok || bad "O3 confirm=$c ssh/patch ran $(ctx)"
done

# --- O4 ram pool 1 GB short ------------------------------------------------------------
reset
run resize oldbox --account fixture-tight --mem-gb 8 --apply --confirm-monthly-usd 16
[ "$RC" = 3 ] && ok || bad "O4 $(ctx)"
grep -qxF 'NEEDS PURCHASE: ram-gb 1 $4/mo' "$T/out" && ok || bad "O4 no NEEDS PURCHASE line $(ctx)"
[ "$(nssh)" = 0 ] && [ "$(npatch)" = 0 ] && ok || bad "O4 ssh/patch ran $(ctx)"
reset
run resize oldbox --account fixture-nopool --mem-gb 8 --apply --confirm-monthly-usd 16
[ "$RC" = 2 ] && grep -q 'not configured' "$T/err" && [ "$(npatch)" = 0 ] && [ "$(nssh)" = 0 ] && ok || bad "O4 null pool $(ctx)"

# --- O5 quiesce fails ------------------------------------------------------------------
reset
export STUB_Q_RC=1
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 1 ] && [ "$(nssh)" = 1 ] && [ "$(npatch)" = 0 ] && grep -q 'drain failed' "$T/err" && ok || bad "O5 rc 1 $(ctx)"
reset
export STUB_Q_OUT='quiesce: something else'
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 1 ] && [ "$(npatch)" = 0 ] && ok || bad "O5 no SAFE_TO_RESIZE $(ctx)"

# --- O6 happy path ------------------------------------------------------------------------
reset
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 0 ] && ok || bad "O6 $(ctx)"
lastl | grep -q '^box-ops: verb=resize box=oldbox orgo=c-old result=OK' && ok || bad "O6 summary=[$(lastl)]"
a=$(lineno '^SSH root@192\.0\.2\.5 /root/harness/bin/quiesce-for-resize\.sh$'); b=$(lineno '^PATCH /computers/c-old/resize$')
c=$(grep -nE '^GET /computers/c-old$' "$SEQ" | tail -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && ok || bad "O6 order a=$a b=$b c=$c $(ctx)"
[ "$(grep '^PATCH /computers/c-old/resize ' "$T/bodies.log" | cut -d' ' -f3-)" = '{"ram":8}' ] && ok \
  || bad "O6 PATCH body=[$(cat "$T/bodies.log")]"
grep -q '^NEXT: watchers on oldbox are paused by quiesce' "$T/out" && ok || bad "O6 no NEXT line"
# a re-run sees the target and does not PATCH again
: > "$SEQ"
run "${UP[@]}" --apply --confirm-monthly-usd 16
[ "$RC" = 0 ] && [ "$(npatch)" = 0 ] && [ "$(nssh)" = 0 ] && grep -q 'resize: oldbox already 4c/8gb' "$T/out" && ok || bad "O6 re-run $(ctx)"

# --- O7 dry run --------------------------------------------------------------------------
reset
run "${UP[@]}"
[ "$RC" = 0 ] && [ "$(nssh)" = 0 ] && [ "$(npatch)" = 0 ] && ok || bad "O7 $(ctx)"
grep -q '^PLAN drain ' "$T/out" && grep -q '^PLAN PATCH /computers/c-old/resize {"ram":8}' "$T/out" && grep -q '^PLAN verify ' "$T/out" \
  && ok || bad "O7 PLAN lines $(ctx)"
lastl | grep -q 'result=PLAN' && ok || bad "O7 summary=[$(lastl)]"
[ ! -e "$H/locks" ] && ok || bad "O7 dry run took a lock"

# --- O8 resize down with no confirm --------------------------------------------------------
reset
jq '.ram = 8' "$T/orgo/comp.json" > "$T/c.t" && mv "$T/c.t" "$T/orgo/comp.json"
run resize oldbox --account fixture-acct --mem-gb 4 --apply
[ "$RC" = 0 ] && [ "$(npatch)" = 1 ] && ok || bad "O8 $(ctx)"

# --- O9 retire refuses with a project on the box ---------------------------------------------
reset
run retire oldbox --apply
[ "$RC" = 2 ] && ok || bad "O9 $(ctx)"
grep -q 'projects still point at box oldbox: pa pb; pass --to <box-id>' "$T/err" && ok || bad "O9 message $(ctx)"
[ ! -s "$T/register.log" ] && ok || bad "O9 box-register was called"
[ -z "$(G status --porcelain)" ] && ok || bad "O9 tree changed: $(G status --porcelain)"
[ ! -e "$RST" ] && ok || bad "O9 wrote state"

# --- O10 retire --to ----------------------------------------------------------------------
reset
run retire oldbox --to newbox
[ "$RC" = 0 ] && [ ! -s "$T/register.log" ] && [ ! -e "$RST" ] && ok || bad "O10 dry run $(ctx)"
grep -q "^PLAN move bin/box-register.sh newbox --ip 192.0.2.77 --project pa " "$T/out" && ok || bad "O10 dry run PLAN $(ctx)"
run retire oldbox --to newbox --apply
[ "$RC" = 0 ] && ok || bad "O10 $(ctx)"
want="newbox --ip 192.0.2.77 --project pa --root $R --apply
newbox --ip 192.0.2.77 --project pb --root $R --apply
--retire oldbox --root $R --apply"
[ "$(cat "$T/register.log" 2>/dev/null)" = "$want" ] && ok || bad "O10 register argv=[$(cat "$T/register.log" 2>/dev/null)]"
[ "$(n '^DELETE ' "$SEQ")" = 0 ] && ok || bad "O10 DELETE without --delete"
[ "$(jq -r .host "$RST" 2>/dev/null)" = node-oldbox ] && [ "$(jq -r .orgo_id "$RST" 2>/dev/null)" = c-old ] && ok || bad "O10 state=[$(cat "$RST" 2>/dev/null)]"
grep -q '^NEXT: fixture box-register next line' "$T/out" && grep -q '^NEXT: commit, open the PR, merge, then re-run with --delete --apply' "$T/out" \
  && ok || bad "O10 NEXT lines $(ctx)"
reset
export STUB_REG_RC=3
run retire oldbox --to newbox --apply
[ "$RC" = 1 ] && [ "$(n '^[-]-retire' "$T/register.log")" = 0 ] && ok || bad "O10 a move rc 3 is rc 1, no --retire $(ctx)"
# box-register --retire rc 3 (BH-1965 order) is a refusal (rc 2), never rc 3 (NEEDS PURCHASE)
reset
export STUB_RETIRE_RC=3
run retire oldbox --to newbox --apply
[ "$RC" = 2 ] && [ "$(n ' --project p[ab] ' "$T/register.log")" = 2 ] && lastl | grep -q 'result=REFUSED box-register --retire rc=3' \
  && ok || bad "O10 retire rc 3 $(ctx)"
# a re-run once no project points at the box needs no --to and makes no move
reset
printf 'pa acme/pa - - 1 node-newbox 192.0.2.77\npb acme/pb - - 1 node-newbox 192.0.2.77\npc acme/pc - - 1 node-newbox 192.0.2.77\n' > "$R/fleet.conf"
mkdir -p "$R/cron/boxes/oldbox.d"
run retire oldbox --ip 192.0.2.5 --apply
[ "$RC" = 0 ] && [ "$(cat "$T/register.log" 2>/dev/null)" = "--retire oldbox --ip 192.0.2.5 --root $R --apply" ] && ok || bad "O10 no-project retire $(ctx)"

# --- O11 --delete before the merge ---------------------------------------------------------
for o in yes crond; do
  reset
  G remote set-url origin "$T/origin-$o.git"
  run retire oldbox --delete --apply
  [ "$RC" = 4 ] && grep -q '^WAITING: ' "$T/out" && ok || bad "O11 origin-$o $(ctx)"
  [ "$(n '^DELETE ' "$SEQ")" = 0 ] && ok || bad "O11 origin-$o DELETEd"
  lastl | grep -q 'result=WAITING' && ok || bad "O11 origin-$o summary=[$(lastl)]"
done

# --- O12 --delete after the merge ----------------------------------------------------------
reset
G remote set-url origin "$T/origin-gone.git"
run retire oldbox --delete --apply
[ "$RC" = 0 ] && ok || bad "O12 $(ctx)"
[ "$(n '^DELETE /computers/c-old$' "$SEQ")" = 1 ] && ok || bad "O12 deletes=$(n '^DELETE ' "$SEQ")"
d=$(lineno '^DELETE '); g=$(grep -nE '^GET /computers/c-old$' "$SEQ" | tail -1 | cut -d: -f1)
[ -n "$d" ] && [ -n "$g" ] && [ "$g" -gt "$d" ] && ok || bad "O12 no GET after DELETE"
[ -n "$(jq -r '.deleted_at // empty' "$RST" 2>/dev/null)" ] && ok || bad "O12 deleted_at=[$(cat "$RST" 2>/dev/null)]"
run retire oldbox --delete --apply
[ "$RC" = 0 ] && [ "$(n '^DELETE ' "$SEQ")" = 1 ] && grep -q 'already deleted' "$T/out" && ok || bad "O12 re-run $(ctx)"
# a DELETE answered 2xx while the computer is still on the account is a failure
reset
G remote set-url origin "$T/origin-gone.git"
mv "$T/fakebin/curl" "$T/curl.real"
printf '#!/bin/bash\n"%s" "$@"; rc=$?; rm -f "$STUB_DIR/orgo/deleted"; exit $rc\n' "$T/curl.real" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
run retire oldbox --delete --apply
[ "$RC" = 1 ] && [ -z "$(jq -r '.deleted_at // empty' "$RST" 2>/dev/null)" ] && ok || bad "O12 still present $(ctx)"
mv "$T/curl.real" "$T/fakebin/curl"

# --- O13 stop pauses first ----------------------------------------------------------------
reset
run stop oldbox --apply
[ "$RC" = 0 ] && ok || bad "O13 $(ctx)"
[ "$(n '^PUT /api/flags paused-p[ab] 1$' "$SEQ")" = 2 ] && ok || bad "O13 PUTs $(ctx)"
# TEST-CHANGE (merge of main's BH-4153, #4332): paused-* is a DB row now. A
# PUT the worker answered leaves the row in this box's flag cache and no local
# file, so the pause is read from that cache row (fleet scope), not as a file.
fon() { jq -e '.on == true' "$H/state/flags-cache/fleet/$1" >/dev/null 2>&1 && [ ! -f "$H/flags/$1" ]; }
fon paused-pa && fon paused-pb && ok || bad "O13 paused-pa/paused-pb not set (flag cache under $H)"
! fon paused-pc && ok || bad "O13 paused a project on another box"
a=$(lineno '^PUT /api/flags paused-pb'); s=$(lineno '^POST /computers/c-old/stop$')
[ -n "$a" ] && [ -n "$s" ] && [ "$a" -lt "$s" ] && [ "$(n '^POST /computers/c-old/stop$' "$SEQ")" = 1 ] && ok || bad "O13 order a=$a s=$s"
grep -q '^NEXT: lift with bin/jobs-client.sh flag-set paused-pa off' "$T/out" && ok || bad "O13 no NEXT line"
lastl | grep -q '^box-ops: verb=stop box=oldbox orgo=c-old result=OK' && ok || bad "O13 summary=[$(lastl)]"
: > "$SEQ"
run stop oldbox --apply
[ "$RC" = 0 ] && [ "$(n '^POST ' "$SEQ")" = 0 ] && ok || bad "O13 re-run POSTed $(ctx)"

# --- O14 a flag PUT fails -----------------------------------------------------------------
reset
export STUB_FLAG_FAIL=paused-pb
run stop oldbox --apply
[ "$RC" = 1 ] && [ "$(n '^POST ' "$SEQ")" = 0 ] && ok || bad "O14 $(ctx)"
grep -q 'pause flag paused-pb not published; box not stopped' "$T/err" && ok || bad "O14 message $(ctx)"

# --- O15 stop dry run ---------------------------------------------------------------------
reset
run stop oldbox
[ "$RC" = 0 ] && [ "$(n '^(PUT|POST) ' "$SEQ")" = 0 ] && ok || bad "O15 $(ctx)"
grep -qx 'PLAN pause paused-pa' "$T/out" && grep -qx 'PLAN pause paused-pb' "$T/out" && grep -qx 'PLAN stop POST /computers/c-old/stop' "$T/out" \
  && ok || bad "O15 PLAN lines $(ctx)"
[ ! -e "$H/flags/paused-pa" ] && ok || bad "O15 dry run wrote a flag"

# --- O16 restart ---------------------------------------------------------------------------
reset
jq '.status = "starting"' "$T/orgo/comp.json" > "$T/c.t" && mv "$T/c.t" "$T/orgo/comp.json"
run restart oldbox --apply
[ "$RC" = 0 ] && [ "$(n '^POST /computers/c-old/restart$' "$SEQ")" = 1 ] && lastl | grep -q 'result=OK' && ok || bad "O16 $(ctx)"
reset
export STUB_RESTART_CODE=500
run restart oldbox --apply
[ "$RC" = 1 ] && grep -q 'restart HTTP 500' "$T/err" && lastl | grep -q 'result=FAIL' && ok || bad "O16 500 $(ctx)"
reset
export STUB_AFTER_STATUS=starting BOX_LAUNCH_DEADLINE_S=1
run restart oldbox --apply
[ "$RC" = 1 ] && grep -q 'not running after 1s' "$T/err" && ok || bad "O16 deadline $(ctx)"
reset
run restart oldbox
[ "$RC" = 0 ] && [ "$(n '^POST ' "$SEQ")" = 0 ] && grep -qx 'PLAN restart POST /computers/c-old/restart' "$T/out" && ok || bad "O16 dry run $(ctx)"

# --- O17 refusals ---------------------------------------------------------------------------
refuse_case() {  # <label> <args...>
  local l="$1"; shift
  rm -f "$SEQ"
  run "$@"
  [ "$RC" = 2 ] && ok || bad "O17 $l $(ctx)"
  [ ! -s "$SEQ" ] && ok || bad "O17 $l made a call"
}
reset
refuse_case "hub" stop hub --apply
refuse_case "own box" stop selfbox --apply
refuse_case "hyphen id" restart old-box --apply
refuse_case "unknown flag" restart oldbox --frob --apply
refuse_case "unknown verb" frobnicate x
refuse_case "no id" stop
refuse_case "resize no account" resize oldbox --mem-gb 8 --apply
refuse_case "resize bad tier" resize oldbox --account fixture-acct --mem-gb 6 --apply
refuse_case "resize vcpus over cap" resize oldbox --account fixture-acct --vcpus 8 --apply
BOX_LAUNCH_POLL_S=0 refuse_case "bad poll knob" restart oldbox --apply
unset FIXTURE_ORGO_KEY ORGO_API_KEY
refuse_case "no key" restart oldbox --apply
grep -q 'not configured: ORGO_API_KEY unset' "$T/err" && ok || bad "O17 no-key message $(ctx)"
refuse_case "no account key" resize oldbox --account fixture-acct --mem-gb 8 --apply
grep -q 'not configured: FIXTURE_ORGO_KEY unset' "$T/err" && ok || bad "O17 no-account-key message $(ctx)"
reset
rm -f "$H/state/box-launch/oldbox.json"
printf '[]\n' > "$T/orgo/others.json"
export STUB_LIST_RAW='[]'
run restart oldbox --apply
[ "$RC" = 2 ] && grep -q '0 Orgo computers named node-oldbox' "$T/err" && [ "$(n '^POST ' "$SEQ")" = 0 ] && ok || bad "O17 0 matches $(ctx)"
export STUB_LIST_RAW='[{"id":"c-1","name":"node-oldbox"},{"id":"c-2","name":"node-oldbox"}]'
run stop oldbox --apply
[ "$RC" = 2 ] && grep -q '2 Orgo computers named node-oldbox' "$T/err" && [ "$(n '^(POST|PUT) ' "$SEQ")" = 0 ] && ok || bad "O17 2 matches $(ctx)"
unset STUB_LIST_RAW
run restart oldbox --apply
[ "$RC" = 0 ] && lastl | grep -q 'orgo=c-old result=OK' && ok || bad "O17 1 match by name $(ctx)"
# the lock is dedupe: held = exit 0, no call
reset
mkdir -p "$H/locks"
exec 7>"$H/locks/box-ops-orgo-oldbox.lock"; flock -n 7
run restart oldbox --apply
[ "$RC" = 0 ] && grep -qx 'box-ops: oldbox already running' "$T/out" && [ ! -s "$SEQ" ] && ok || bad "O17 lock held $(ctx)"
exec 7>&-

# --- O18 no secret anywhere ------------------------------------------------------------------
leak=$(grep -rlF "$KEY" "$T/all-output" "$H/logs" "$H/state" 2>/dev/null)
[ -z "$leak" ] && ok || bad "O18 the key leaked into: $leak"
grep -rqF fixture-jobs-secret "$T/all-output" "$H/logs" 2>/dev/null && bad "O18 the jobs secret leaked" || ok
[ -s "$T/all-output" ] && ok || bad "O18 no output was collected"

echo "box-ops-orgo: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
