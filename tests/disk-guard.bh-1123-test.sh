#!/bin/bash
# tests/disk-guard.bh-1123-test.sh — BH-1123: alert at 85% disk, refuse to
# start a build at 92%, on board boxes and the hub, both thresholds lane knobs.
#
# What is proved here, every half DRIVEN rather than grepped:
#   1. bin/lib/disk-guard.sh reads `df -P /`'s Use% as a whole number, and an
#      unreadable df (rc 1, `-`, header only) is NOTHING, never 0%;
#   2. the thresholds: env beats the fallback, garbage/0/150 fall back, and the
#      refusal reason is printed at/over the refuse line and silent under it
#      or on an unreadable disk (a broken probe must not stop the fleet);
#   3. the shipped lane bin/disk-guard.sh: 84% fires nothing, 85% fires
#      disk-high-<host> warn, 92% fires disk-refuse-<host> critical as well, an
#      open condition resolves when the disk drops back, unreadable df and the
#      lane's off switch call nothing;
#   4. the `# >>> disk gate` block lifted out of bin/run-build.sh: 91% passes,
#      92% is BUILD_DEFERRED + exit 3 with the reading and the knob named, a
#      pool machine (BUILDER_EXEC=1) and a missing lib pass, and the block sits
#      after hub-no-build and before overlap not-before (before any plan);
#   5. the knobs are the REGISTRY's: lane_knob answers 92/85 from
#      catalog/lanes.d/disk-guard.json, and a settings row of 90 moves the gate.
# Run from anywhere: tests/disk-guard.bh-1123-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset DISK_ALERT_PCT DISK_BUILD_REFUSE_PCT BUILDER_EXEC LANE_REGISTRY 2>/dev/null || true
HOST=$(hostname)

# A df that answers what the case says. 2097152 KB available = 2048 MB.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/df" <<'SH'
#!/bin/bash
H='Filesystem     1024-blocks     Used Available Capacity Mounted on'
case "${FAKE_DF:-}" in
  fail)   exit 1 ;;
  dash)   printf '%s\n/dev/root 41152736 - - - /\n' "$H" ;;
  header) printf '%s\n' "$H" ;;
  *)      printf '%s\n/dev/root 41152736 30000000 2097152 %s%% /\n' "$H" "${FAKE_DF_PCT:-50}" ;;
esac
SH
chmod +x "$T/fakebin/df"
# BH-4440: a firing disk-high now names the top 5 dirs from `du -xk -d 2 /`;
# this fixture answers it so the suite never walks the real root disk.
printf '#!/bin/bash\nprintf "100\\t/var/log\\n"\n' > "$T/fakebin/du"
chmod +x "$T/fakebin/du"
FPATH="$T/fakebin:$PATH"

# A scratch harness: the real libs, a stub lane-alert that records its argv.
mkh() { # mkh <dir> — a harness tree with the libs and the stub alert path
  mkdir -p "$1/bin/lib" "$1/logs" "$1/flags" "$1/state" "$1/catalog" "$1/env"
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$1/bin/lib/"
  [ -f "$DIR/bin/lib/disk-guard.sh" ] && cp "$DIR/bin/lib/disk-guard.sh" "$1/bin/lib/"
  cat > "$1/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${HARNESS}/alerts.argv"
SH
  chmod +x "$1/bin/lane-alert.sh"
}
mkh "$T/h"

lib() { # lib <shell text> — run it with the lib sourced, the fake df first on PATH
  env PATH="$FPATH" HARNESS="$T/h" FAKE_DF="${FAKE_DF:-}" FAKE_DF_PCT="${FAKE_DF_PCT:-}" \
      ${KENV:+$KENV} bash -c '. "$0"; '"$1" "$DIR/bin/lib/disk-guard.sh" 2>/dev/null
}

# ══ 1. the reading ═══════════════════════════════════════════════════════════
for p in 84 85 92 97; do
  got=$(FAKE_DF_PCT=$p lib 'disk_used_pct /')
  [ "$got" = "$p" ] && ok || bad "1 df at $p% must read $p (got '$got')"
done
for mode in fail dash header; do
  got=$(FAKE_DF=$mode lib 'disk_used_pct /; echo "|rc=$?"')
  [ "$got" = "|rc=0" ] && ok || bad "1 an unreadable df ($mode) must read as NOTHING, never 0 (got '$got')"
done
got=$(FAKE_DF_PCT=50 lib 'disk_free_mb /')
[ "$got" = 2048 ] && ok || bad "1 disk_free_mb must be the Available column in MB (got '$got')"

# ══ 2. thresholds and the refusal reason ═════════════════════════════════════
got=$(lib 'disk_guard_knob DISK_ALERT_PCT 85')
[ "$got" = 85 ] && ok || bad "2 no registry, no env -> the fallback 85 (got '$got')"
got=$(KENV="DISK_ALERT_PCT=80" lib 'disk_guard_knob DISK_ALERT_PCT 85')
[ "$got" = 80 ] && ok || bad "2 env DISK_ALERT_PCT=80 must win over the fallback (got '$got')"
for junk in abc 0 150; do
  got=$(KENV="DISK_ALERT_PCT=$junk" lib 'disk_guard_knob DISK_ALERT_PCT 85')
  [ "$got" = 85 ] && ok || bad "2 DISK_ALERT_PCT=$junk must fall back to 85, never be obeyed (got '$got')"
done
for p in 92 97; do
  out=$(FAKE_DF_PCT=$p lib 'disk_build_refuse_reason; echo "|rc=$?"')
  case "$out" in "disk / at $p% on $HOST (builds refused at 92%"*"DISK_BUILD_REFUSE_PCT"*"2048 MB free|rc=0") ok ;;
    *) bad "2 at $p% the refusal must name the reading, host, threshold, knob and free space (got '$out')" ;; esac
done
out=$(FAKE_DF_PCT=91 lib 'disk_build_refuse_reason; echo "|rc=$?"')
[ "$out" = "|rc=1" ] && ok || bad "2 at 91% nothing is refused and nothing printed (got '$out')"
for mode in fail dash header; do
  out=$(FAKE_DF=$mode lib 'disk_build_refuse_reason; echo "|rc=$?"')
  [ "$out" = "|rc=1" ] && ok || bad "2 an unreadable df ($mode) must NOT refuse a build (got '$out')"
done
out=$(FAKE_DF_PCT=95 KENV="DISK_BUILD_REFUSE_PCT=96" lib 'disk_build_refuse_reason; echo "|rc=$?"')
[ "$out" = "|rc=1" ] && ok || bad "2 env DISK_BUILD_REFUSE_PCT=96 must move the line: 95% passes (got '$out')"

# ══ 3. the shipped lane ══════════════════════════════════════════════════════
cp "$(rendered_registry)" "$T/h/catalog/lanes.json" 2>/dev/null
lane() { # lane [env...] -> rc; argv of every lane-alert call in $T/h/alerts.argv
  rm -f "$T/h/alerts.argv"
  ( env PATH="$FPATH" HARNESS="$T/h" HOME="$T" "$@" bash "$DIR/bin/disk-guard.sh" >/dev/null 2>&1 )
}
calls() { cat "$T/h/alerts.argv" 2>/dev/null; }
rm -rf "$T/h/state/alerts"
lane FAKE_DF_PCT=84; RC=$?
[ "$RC" = 0 ] && [ -z "$(calls)" ] && ok || bad "3 84% with nothing open: rc 0 and no alert call at all (rc=$RC, calls: $(calls))"
[ ! -s "$T/h/logs/disk-guard.log" ] && ok || bad "3 84% is quiet: nothing in logs/disk-guard.log ($(cat "$T/h/logs/disk-guard.log"))"

lane FAKE_DF_PCT=85
calls | grep -q "^--id disk-high-$HOST --severity warn disk-guard .*85%" && ok \
  || bad "3 85% must fire disk-high-$HOST warn naming the reading (calls: $(calls))"
grep -q "disk-refuse-" <<<"$(calls)" && bad "3 85% must not fire the refuse alert (calls: $(calls))" || ok
grep -q '85%' "$T/h/logs/disk-guard.log" && ok || bad "3 at/over the alert line one summary line is logged"
calls | grep -q 'disk-clean' && ok || bad "3 the alert text names the next action (bin/disk-clean.sh)"

lane FAKE_DF_PCT=92
calls | grep -q "^--id disk-high-$HOST --severity warn disk-guard " && ok || bad "3 92% still fires disk-high (calls: $(calls))"
calls | grep -q "^--id disk-refuse-$HOST --severity critical disk-guard .*92%.*refused" && ok \
  || bad "3 92% must fire disk-refuse-$HOST critical, saying builds are refused (calls: $(calls))"

# resolve only what is open: state/alerts/<id>.json is lane-alert's own store
mkdir -p "$T/h/state/alerts"
echo '{}' > "$T/h/state/alerts/disk-high-$HOST.json"
echo '{}' > "$T/h/state/alerts/disk-refuse-$HOST.json"
lane FAKE_DF_PCT=84
calls | grep -q "^--resolve --id disk-high-$HOST disk-guard " && ok || bad "3 84% resolves an open disk-high (calls: $(calls))"
calls | grep -q "^--resolve --id disk-refuse-$HOST disk-guard " && ok || bad "3 84% resolves an open disk-refuse (calls: $(calls))"
grep -q -- '--severity' <<<"$(calls)" && bad "3 84% fires nothing (calls: $(calls))" || ok
lane FAKE_DF_PCT=88
calls | grep -q "^--resolve --id disk-refuse-$HOST " && ok || bad "3 88% resolves disk-refuse but ($(calls))"
calls | grep -q "^--id disk-high-$HOST --severity warn" && ok || bad "3 88% keeps disk-high firing ($(calls))"
rm -rf "$T/h/state/alerts"

for mode in fail dash; do
  lane FAKE_DF=$mode; RC=$?
  [ "$RC" = 0 ] && [ -z "$(calls)" ] && ok || bad "3 unreadable df ($mode): rc 0 and no alert or resolve (rc=$RC, calls: $(calls))"
done
grep -q 'unreadable' "$T/h/logs/disk-guard.log" && ok || bad "3 an unreadable df is logged as unknown"

lane FAKE_DF_PCT=80 DISK_ALERT_PCT=80
calls | grep -q "^--id disk-high-$HOST --severity warn" && ok || bad "3 env DISK_ALERT_PCT=80 moves the alert line to 80 ($(calls))"

: > "$T/h/flags/lane-off-disk-guard"
lane FAKE_DF_PCT=97; RC=$?
[ "$RC" = 0 ] && [ -z "$(calls)" ] && ok || bad "3 flags/lane-off-disk-guard stops the lane (rc=$RC, calls: $(calls))"
rm -f "$T/h/flags/lane-off-disk-guard"

# ══ 4. the run-build block ═══════════════════════════════════════════════════
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> disk gate/{f=1;next} /^# <<< disk gate/{exit} f' "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "4 could not extract the disk gate — # >>> disk gate markers missing?"
mkdir -p "$T/b"
gate() { # gate <harness> [env...] -> rc; RESULT in $T/b/RESULT
  local h="$1"; shift
  rm -f "$T/b/RESULT" "$h/alerts.argv"; : > "$T/b/pipeline.log"
  ( env PATH="$FPATH" HARNESS="$h" BUILD="$T/b" PROJECT=tproj KEY=TK-9 HOME="$T" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "$*" > "$BUILD/RESULT"; echo "$*"; }
             . "$0"' "$T/gate.sh" >/dev/null 2>&1 )
}
gate "$T/h" FAKE_DF_PCT=91; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/b/RESULT" ] && ok || bad "4 91%: rc 0 and no RESULT (rc=$RC, $(cat "$T/b/RESULT" 2>/dev/null))"
gate "$T/h" FAKE_DF_PCT=92; RC=$?
[ "$RC" = 3 ] && ok || bad "4 92% must exit 3 (rc=$RC)"
R=$(cat "$T/b/RESULT" 2>/dev/null)
case "$R" in "BUILD_DEFERRED disk / at 92% on $HOST (builds refused at 92%"*DISK_BUILD_REFUSE_PCT*) ok ;;
  *) bad "4 92% RESULT must start 'BUILD_DEFERRED disk / at 92%' and name the knob (got '$R')" ;; esac
grep -q "^--id disk-refuse-$HOST --severity critical disk-guard build tproj/TK-9 refused" "$T/h/alerts.argv" 2>/dev/null \
  && ok || bad "4 the refusal raises disk-refuse-$HOST critical ($(cat "$T/h/alerts.argv" 2>/dev/null))"
grep -q 'disk gate' "$T/b/pipeline.log" && ok || bad "4 the refusal is in pipeline.log"
gate "$T/h" FAKE_DF_PCT=97 BUILDER_EXEC=1; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/b/RESULT" ] && ok || bad "4 BUILDER_EXEC=1 (pool) at 97% is not gated (rc=$RC)"
gate "$T/h" FAKE_DF=fail; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/b/RESULT" ] && ok || bad "4 an unreadable df must not refuse a build (rc=$RC)"
mkh "$T/nolib"; rm -f "$T/nolib/bin/lib/disk-guard.sh"
gate "$T/nolib" FAKE_DF_PCT=97; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/b/RESULT" ] && ok || bad "4 a missing bin/lib/disk-guard.sh fails OPEN (rc=$RC)"
grep -q 'disk-guard.sh' "$T/b/pipeline.log" && ok || bad "4 a missing lib says so in pipeline.log ($(cat "$T/b/pipeline.log"))"
# block order: after hub-no-build, before overlap not-before (so before any plan or claim)
L_HUB=$(grep -n '^# <<< hub-no-build' "$RB_ALL" | head -1 | cut -d: -f1)
L_DG=$(grep -n '^# >>> disk gate' "$RB_ALL" | head -1 | cut -d: -f1)
L_OV=$(grep -n '^# >>> overlap not-before' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$L_HUB" ] && [ -n "$L_DG" ] && [ -n "$L_OV" ] && [ "$L_HUB" -lt "$L_DG" ] && [ "$L_DG" -lt "$L_OV" ] && ok \
  || bad "4 the disk gate must sit after '# <<< hub-no-build' and before '# >>> overlap not-before' (lines ${L_HUB:-?} ${L_DG:-?} ${L_OV:-?})"

# ══ 5. the knobs are the registry's ══════════════════════════════════════════
NOW=1758300000
knob() { env HARNESS="$T/h" LANE_GATE_NOW="$NOW" bash -c '. "$HARNESS/bin/lib/lane-gate.sh"; lane_knob disk-guard "$0"' "$1" 2>/dev/null; }
[ "$(knob DISK_BUILD_REFUSE_PCT)" = 92 ] && ok || bad "5 registry default DISK_BUILD_REFUSE_PCT must be 92 (got '$(knob DISK_BUILD_REFUSE_PCT)')"
[ "$(knob DISK_ALERT_PCT)" = 85 ] && ok || bad "5 registry default DISK_ALERT_PCT must be 85 (got '$(knob DISK_ALERT_PCT)')"
jq -e '.lanes[]|select(.id=="disk-guard")|.knobs[]|select(.env=="DISK_BUILD_REFUSE_PCT")|(.settable!=false) and .min!=null and .max!=null' \
  "$T/h/catalog/lanes.json" >/dev/null 2>&1 && ok || bad "5 DISK_BUILD_REFUSE_PCT must be settable and bounded in the registry"
printf '{"fetched_at":%s,"values":{"lane.disk-guard.disk_build_refuse_pct":"90"},"seeded":{}}' "$NOW" > "$T/h/state/settings-cache.json"
[ "$(knob DISK_BUILD_REFUSE_PCT)" = 90 ] && ok || bad "5 a settings row of 90 must resolve (got '$(knob DISK_BUILD_REFUSE_PCT)')"
gate "$T/h" FAKE_DF_PCT=90 LANE_GATE_NOW="$NOW"; RC=$?
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED disk / at 90% .*refused at 90%' "$T/b/RESULT" 2>/dev/null && ok \
  || bad "5 with the row at 90 a 90% disk refuses the build (rc=$RC, $(cat "$T/b/RESULT" 2>/dev/null))"
gate "$T/h" FAKE_DF_PCT=89 LANE_GATE_NOW="$NOW"; RC=$?
[ "$RC" = 0 ] && ok || bad "5 with the row at 90 an 89% disk builds (rc=$RC)"
rm -f "$T/h/state/settings-cache.json"

echo "disk-guard.bh-1123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
