#!/bin/bash
# tests/registry-sync.bh-5650-test.sh — BH-5650: bin/registry-sync.sh, the */5
# registry sync tick. The registry API is the REAL harness-jobs worker over
# SQLite (tests/lib/registry-fixture.bh-5650.sh); crontab(1) is a stub on PATH
# that records each install, and the checkout's bin/render-crontab.sh is a stub
# that records each call and either runs this tree's real renderer or fails in
# a chosen way. Box: project-6 (projects project-6 and project-7).
#
#   Y1 db mode from env/global.env, a new version: one render, one install,
#      applied-version = V, both triage lanes installed
#   Y2 registry.sh move-project project-7 to small bumps the version; the next
#      tick installs a crontab with no project-7 triage line (a moved project's
#      drop is allowed) and logs the - line, no ALERTS line
#   Y3 an equal version: 0 render calls, 0 installs
#   Y4 render rc 1, then an empty render, then a crontab(1) reject: no install,
#      applied-version kept, ONE ALERTS line per version, retried each tick;
#      a render equal to the live crontab records the version, no install
#   Y5 the API is down, the cache is at the applied version: rc 0, no render
#   Y6 REGISTRY_SOURCE=file / DB / unset: rc 0, no curl call, no state written
#   Y7 a render that drops the live triage lane of project-6 (still on this box
#      in the registry): refused with an ALERTS line, nothing installed
#   G1 flags/lane-off-registry-sync and a held lock: rc 0, no curl call
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
SYNC="$DIR/bin/registry-sync.sh"
CLI="$DIR/bin/registry.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }

# ---- stubs -------------------------------------------------------------------
cat > "$T/bin/crontab" <<SH
#!/bin/bash
echo "\$*" >> "$T/crontab.calls"
if [ "\${1:-}" = -l ]; then
  [ -f "$T/crontab.live" ] || { echo "no crontab for root" >&2; exit 1; }
  cat "$T/crontab.live"; exit 0
fi
[ ! -e "$T/crontab-reject" ] || { echo "crontab: errors in crontab file" >&2; exit 1; }
cat "\$1" > "$T/crontab.new" && mv "$T/crontab.new" "$T/crontab.live" && echo install >> "$T/crontab.installs"
SH
mkdir -p "$T/co/bin" "$T/env" "$RFX_H/state"
cat > "$T/co/bin/render-crontab.sh" <<SH
#!/bin/bash
echo "\$*" >> "$T/render.calls"
BOX="\${*: -1}"
case "\$(cat "$T/render-mode")" in
  real)  exec "$DIR/bin/render-crontab.sh" --root "$DIR" "\$BOX" ;;
  rc1)   echo "SHELL=/bin/bash"; exit 1 ;;
  empty) exit 0 ;;
  file)  cat "$T/render-file" ;;
esac
SH
chmod +x "$T/bin/crontab" "$T/co/bin/render-crontab.sh"
: > "$T/render.calls"; : > "$T/crontab.installs"
echo real > "$T/render-mode"
echo project-6 > "$RFX_H/state/box-id"
printf 'REGISTRY_SOURCE=db\n' > "$T/env/global.env"

# tick [VAR=value...] — one tick in the fixture's harness, db mode from global.env.
tick() {
  env PATH="$T/bin:$PATH" HARNESS="$RFX_H" HARNESS_ENV_DIR="$T/env" JOBS_URL=https://jobs.test \
    HARNESS_SECRET=fixture-secret REGISTRY_SYNC_CHECKOUT="$T/co" "$@" "$SYNC" 2>"$T/sync.err"
}
renders()  { wc -l < "$T/render.calls" | tr -d ' '; }
installs() { wc -l < "$T/crontab.installs" | tr -d ' '; }
ver()      { rfx_q 'SELECT version FROM registry_meta' | jq '.[0].version'; }
applied()  { cat "$RFX_H/state/registry/applied-version" 2>/dev/null; }
sync_alerts() { cat "$RFX_H/logs/ALERTS.log" 2>/dev/null | grep -c "registry-sync:"; }
triage() { grep -cE "run-triage\.sh $1( |\$)" "$T/crontab.live" 2>/dev/null || true; }
move() { rfx_db "$CLI" move-project "$1" --box "$2" >/dev/null 2>"$T/move.err" || bad "move-project $1 $2 failed: $(cat "$T/move.err")"; }

# ---- Y1 ----------------------------------------------------------------------
V=$(ver)
tick; R=$?
[ "$R" = 0 ] && ok || bad "Y1 rc $R: $(cat "$T/sync.err")"
[ "$(renders)" = 1 ] && ok || bad "Y1 render calls $(renders), want 1"
[ "$(head -1 "$T/render.calls")" = "--root $T/co project-6" ] && ok || bad "Y1 render args '$(head -1 "$T/render.calls")'"
[ "$(installs)" = 1 ] && ok || bad "Y1 installs $(installs), want 1"
[ "$(applied)" = "$V" ] && ok || bad "Y1 applied-version '$(applied)', want $V"
[ "$(triage project-6)" -ge 1 ] && [ "$(triage project-7)" -ge 1 ] && ok || bad "Y1 the installed crontab lacks a triage lane"
grep -q 'crontab + .*run-triage.sh project-7' "$RFX_H/logs/registry-sync.log" && ok || bad "Y1 the + diff is not in registry-sync.log"
[ "$(sync_alerts)" = 0 ] && ok || bad "Y1 wrote an ALERTS line"

# ---- Y3 ----------------------------------------------------------------------
C0=$(rfx_calls)
tick; R=$?
[ "$R" = 0 ] && [ "$(renders)" = 1 ] && [ "$(installs)" = 1 ] && ok || bad "Y3 equal version: rc $R renders $(renders) installs $(installs)"
[ "$(rfx_calls)" = $((C0+1)) ] && ok || bad "Y3 the tick made $(( $(rfx_calls) - C0 )) API calls, want 1 GET"

# ---- Y2 ----------------------------------------------------------------------
move project-7 box-small
[ "$(ver)" = $((V+1)) ] && ok || bad "Y2 move-project did not bump the version"
tick; R=$?
[ "$R" = 0 ] && [ "$(renders)" = 2 ] && [ "$(installs)" = 2 ] && ok || bad "Y2 rc $R renders $(renders) installs $(installs)"
[ "$(triage project-7)" = 0 ] && ok || bad "Y2 project-7's triage lane is still installed"
[ "$(triage project-6)" -ge 1 ] && ok || bad "Y2 project-6's triage lane is gone"
[ "$(applied)" = $((V+1)) ] && ok || bad "Y2 applied-version '$(applied)'"
grep -q 'crontab - .*run-triage.sh project-7' "$RFX_H/logs/registry-sync.log" && ok || bad "Y2 the - line is not in registry-sync.log"
[ "$(sync_alerts)" = 0 ] && ok || bad "Y2 a moved project's drop wrote an ALERTS line"
ls "$RFX_H"/state/registry/crontab.bak-* >/dev/null 2>&1 && ok || bad "Y2 no crontab backup"

# ---- Y4 ----------------------------------------------------------------------
cp "$T/crontab.live" "$T/live.before"
move project-7 box-project-6-1
echo rc1 > "$T/render-mode"
tick; R=$?
[ "$R" = 0 ] && [ "$(renders)" = 3 ] && [ "$(installs)" = 2 ] && ok || bad "Y4 rc1: rc $R renders $(renders) installs $(installs)"
[ "$(applied)" = $((V+1)) ] && ok || bad "Y4 rc1 wrote applied-version '$(applied)'"
[ "$(sync_alerts)" = 1 ] && ok || bad "Y4 rc1: $(sync_alerts) ALERTS lines, want 1"
grep 'registry-sync:' "$RFX_H/logs/ALERTS.log" | grep -q "render failed (rc=1" && ok || bad "Y4 the ALERTS line does not name the render rc"
tick
[ "$(renders)" = 4 ] && ok || bad "Y4 the next tick did not retry the render"
[ "$(sync_alerts)" = 1 ] && ok || bad "Y4 a second tick at the same version alerted again"
cmp -s "$T/crontab.live" "$T/live.before" && ok || bad "Y4 the live crontab changed"
move project-7 box-small
echo empty > "$T/render-mode"
tick
[ "$(installs)" = 2 ] && [ "$(applied)" = $((V+1)) ] && ok || bad "Y4 empty render: installs $(installs) applied '$(applied)'"
[ "$(sync_alerts)" = 2 ] && ok || bad "Y4 empty render at a new version: $(sync_alerts) ALERTS lines, want 2"
tick
[ "$(sync_alerts)" = 2 ] && ok || bad "Y4 empty render alerted twice for one version"
echo real > "$T/render-mode"
tick
[ "$(installs)" = 2 ] && [ "$(applied)" = $((V+3)) ] && ok || bad "Y4 a render equal to the live crontab: installs $(installs) applied '$(applied)', want 2 and $((V+3))"
move project-7 box-project-6-1
: > "$T/crontab-reject"
tick
[ "$(installs)" = 2 ] && [ "$(applied)" = $((V+3)) ] && ok || bad "Y4 crontab reject: installs $(installs) applied '$(applied)'"
grep -q 'REJECTED by crontab' "$RFX_H/logs/registry-sync.log" && ok || bad "Y4 the reject is not logged"
[ "$(sync_alerts)" = 3 ] && ok || bad "Y4 crontab reject: $(sync_alerts) ALERTS lines, want 3"
rm -f "$T/crontab-reject"

# ---- Y7 ----------------------------------------------------------------------
move project-7 box-small
V7=$(ver)
grep -q 'run-triage.sh project-6' "$T/crontab.live" || bad "Y7 precondition: the live crontab runs project-6"
env PATH="$T/bin:$PATH" HARNESS="$RFX_H" REGISTRY_SOURCE=db JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
  "$DIR/bin/render-crontab.sh" --root "$DIR" project-6 2>/dev/null | grep -v 'run-triage.sh project-6' > "$T/render-file"
[ "$(grep -c . "$T/render-file")" -ge 30 ] && grep -q 'watchdog-ping.sh' "$T/render-file" && ok || bad "Y7 precondition: the dropping render is a real one"
echo file > "$T/render-mode"
A0=$(sync_alerts)
tick; R=$?
[ "$R" = 0 ] && [ "$(installs)" = 2 ] && ok || bad "Y7 rc $R installs $(installs): the drop was applied"
[ "$(applied)" = $((V+3)) ] && ok || bad "Y7 wrote applied-version '$(applied)'"
[ "$(sync_alerts)" = $((A0+1)) ] && grep 'registry-sync:' "$RFX_H/logs/ALERTS.log" | tail -1 | grep -q 'DROP.* project-6' \
  && ok || bad "Y7 no ALERTS line names the dropped project-6 lane: $(tail -1 "$RFX_H/logs/ALERTS.log")"
cmp -s "$T/crontab.live" "$T/live.before" && ok || bad "Y7 the live crontab changed"
echo real > "$T/render-mode"
tick
[ "$(applied)" = "$V7" ] && ok || bad "Y7 the real render did not apply after: applied '$(applied)' want $V7"
ls "$RFX_H"/state/registry/alerted-* >/dev/null 2>&1 && bad "Y7 alerted markers survive an apply" || ok

# ---- Y5 ----------------------------------------------------------------------
N5=$(renders); rfx_down 1
tick; R=$?
[ "$R" = 0 ] && [ "$(renders)" = "$N5" ] && ok || bad "Y5 outage: rc $R renders $(renders), want $N5"
grep -q '\[registry\] harness-jobs /api/registry unusable' "$RFX_H/logs/ALERTS.log" && ok || bad "Y5 the ladder wrote no outage line"
tick
[ "$(grep -c '\[registry\] harness-jobs /api/registry unusable' "$RFX_H/logs/ALERTS.log")" = 1 ] && ok || bad "Y5 the outage alerted twice"
[ "$(renders)" = "$N5" ] && [ "$(applied)" = "$V7" ] && ok || bad "Y5 a second outage tick rendered or moved applied-version"
rfx_down 0

# ---- Y6 ----------------------------------------------------------------------
mkdir -p "$T/env6"
for MODE in file DB ""; do
  C0=$(rfx_calls)
  env PATH="$T/bin:$PATH" HARNESS="$T/h6" HARNESS_ENV_DIR="$T/env6" JOBS_URL=https://jobs.test \
    HARNESS_SECRET=fixture-secret REGISTRY_SYNC_CHECKOUT="$T/co" REGISTRY_SOURCE="$MODE" "$SYNC"; R=$?
  [ "$R" = 0 ] && [ "$(rfx_calls)" = "$C0" ] && [ ! -e "$T/h6" ] && ok \
    || bad "Y6 REGISTRY_SOURCE='$MODE': rc $R, $(( $(rfx_calls) - C0 )) curl calls, h6 exists: $([ -e "$T/h6" ] && echo yes)"
done
C0=$(rfx_calls); N6=$(renders)
tick REGISTRY_SOURCE=file; R=$?
[ "$R" = 0 ] && [ "$(rfx_calls)" = "$C0" ] && [ "$(renders)" = "$N6" ] && ok || bad "Y6 the caller's file did not win over global.env's db"

# ---- G1 ----------------------------------------------------------------------
move project-7 box-project-6-1
mkdir -p "$RFX_H/flags"; : > "$RFX_H/flags/lane-off-registry-sync"
C0=$(rfx_calls)
tick; R=$?
[ "$R" = 0 ] && [ "$(rfx_calls)" = "$C0" ] && [ "$(renders)" = "$N6" ] && ok || bad "G1 lane-off flag: rc $R calls +$(( $(rfx_calls) - C0 ))"
rm -f "$RFX_H/flags/lane-off-registry-sync"
mkdir -p "$RFX_H/locks"; exec 8>"$RFX_H/locks/registry-sync.lock"; flock -n 8 || bad "G1 could not take the lock"
tick 8>&-; R=$?
[ "$R" = 0 ] && [ "$(rfx_calls)" = "$C0" ] && [ "$(renders)" = "$N6" ] && ok || bad "G1 held lock: rc $R calls +$(( $(rfx_calls) - C0 ))"
exec 8>&-
tick
[ "$(renders)" = $((N6+1)) ] && [ "$(applied)" = "$(ver)" ] && ok || bad "G1 after the lock is free the tick did not apply"

echo "registry-sync: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
