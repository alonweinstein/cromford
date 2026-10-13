#!/bin/bash
# tests/context-gate-reexec-test.sh — a stale harness checkout must cost a build
# one re-exec, never a watcher tick.
#
# The case (2026-09-28): STEP 0 of bin/context-gate.sh synced a checkout that
# was behind origin and then REFUSED the attempt ("deferred; the next watcher
# tick picks the ticket up"). The watcher ticks every ~20 min and main merges
# every few, so by the next tick the checkout was behind again and the build was
# deferred again — BH-1174 and BH-1795 starved all afternoon.
#
# What is pinned here:
#   (a) behind -> sync -> the gate says "synced, re-exec" (rc 3), the caller
#       re-execs run-build.sh ONCE, and the build proceeds on the FRESH script
#       in the SAME build dir;
#   (b) behind AGAIN on that re-exec -> sync and PROCEED, no second defer;
#   (c) diverged/dirty (30) -> still refused, no re-exec;
#   (d) flags/context-gate-disabled -> no sync, no re-exec, build proceeds.
# The caller wiring is extracted VERBATIM from the pipeline (tests/lib/rb-all.sh)
# (the driver's own `# >>> ctx reexec` block included), so this drives the production text, not a copy.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/builds" "$T/build"
cp "$DIR/bin/context-gate.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H/bin/"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '{ "harness_bin_in_sync": true, "machine_rules_in_sync": true }\n' > "$T/sig.json"
printf '#!/bin/bash\ncat "%s"\n' "$T/sig.json" > "$H/bin/context-signature.sh"

# harness-sync stub: --check answers from $T/check-rc (10 behind, 30 diverged,
# 0 fresh); a real sync appends to $T/sync-calls, installs the FRESH driver
# over the live one (what the rsync does on a box), and exits $T/sync-rc.
cat > "$H/bin/harness-sync.sh" <<SYNC
#!/bin/bash
if [ "\${1:-}" = --check ]; then
  rc=\$(cat "$T/check-rc"); case "\$rc" in 10) echo "behind origin by 3";; 30) echo "diverged from origin";; *) echo fresh;; esac
  exit "\$rc"
fi
echo sync >> "$T/sync-calls"
[ -f "$T/fresh-driver.sh" ] && cp "$T/fresh-driver.sh" "$H/bin/run-build.sh"
echo "synced aaa..bbb"
exit "\$(cat "$T/sync-rc" 2>/dev/null || echo 0)"
SYNC
chmod +x "$H/bin"/*.sh

# --- the production text under test -------------------------------------------
awk '/^# >>> ctx reexec$/{f=1;next} /^# <<< ctx reexec$/{exit} f' "$RB_ALL" > "$T/reexec-env.sh"
[ -s "$T/reexec-env.sh" ] && ok || bad "could not extract '# >>> ctx reexec' from the pipeline — markers missing?"
awk '/^# >>> context gate$/{f=1;next} /^# <<< context gate$/{exit} f' "$RB_ALL" > "$T/gate-call.sh"
[ -s "$T/gate-call.sh" ] && ok || bad "could not extract '# >>> context gate' from the pipeline — markers missing?"

# A driver = the two production blocks between a stub head and a stub tail.
# Each build starts in a NEW dir (nanosecond name) so dir reuse is observable.
mkdriver() { # mkdriver <version> <out>
  {
    printf '#!/bin/bash\nset -uo pipefail\nVERSION=%s\n' "$1"
    printf 'PROJECT="$1"; TICKET="$2"; KEY="$3"; REPO=%q; export HARNESS=%q\n' "$T/repo" "$H"
    printf 'BUILD="$HARNESS/builds/$PROJECT-$KEY-$(date +%%s%%N)"\n'
    cat "$T/reexec-env.sh"
    printf 'mkdir -p "$BUILD"\n'
    printf 'STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }\n'
    cat "$T/gate-call.sh"
    printf 'echo "PROCEEDED $VERSION $BUILD reexec=${RB_CTX_REEXEC:-unset}" >> %q\n' "$T/proceeded"
  } > "$2"
  chmod +x "$2"
}
mkdriver STALE "$T/stale-driver.sh"
mkdriver FRESH "$T/fresh-driver.sh"

reset() { # reset <check-rc> [sync-rc]
  echo "$1" > "$T/check-rc"; echo "${2:-0}" > "$T/sync-rc"
  cp "$T/stale-driver.sh" "$H/bin/run-build.sh"
  scratch_rm "$H/builds"; scratch_rm "$H/flags"; mkdir -p "$H/builds" "$H/flags"
  rm -f "$T/sync-calls" "$T/proceeded"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/agent-rules.log"
}
gate() { ( HARNESS="$H" HARNESS_CHECKOUT="$T/ck" bash "$H/bin/context-gate.sh" demo-os "$T/build" "$T/repo" ); }
# timeout: a regressed loop guard must FAIL here, never hang the suite.
drive() { ( cd "$T" && timeout 20 bash "$H/bin/run-build.sh" demo-os 77 DEMO-1 ) >/dev/null 2>&1; }
n() { grep -c . "$1" 2>/dev/null || echo 0; }
alerts() { cat "$H/logs/ALERTS.log" 2>/dev/null; }

# --- the gate's own contract ----------------------------------------------------
reset 10
OUT=$(gate); RC=$?
[ "$RC" = 3 ] && ok || bad "behind + synced must answer rc 3 (re-exec now), not a refusal (rc=$RC out=$OUT)"
[ "$(n "$T/sync-calls")" = 1 ] && ok || bad "behind must sync exactly once (calls: $(n "$T/sync-calls"))"
grep -q 'DEFERRED' <<<"$(alerts)" && bad "a synced checkout must not write a DEFERRED alert (got: $(alerts))" || ok
grep -qi 'restart.*fresh harness' <<<"$(alerts)" && ok || bad "the alert must say the build restarted on the fresh harness (got: $(alerts))"

reset 10
OUT=$( RB_CTX_REEXEC=1 gate ); RC=$?
[ "$RC" = 0 ] && ok || bad "(b) behind AGAIN on the re-exec must sync and PROCEED (rc=$RC out=$OUT)"
[ "$(n "$T/sync-calls")" = 1 ] && ok || bad "(b) the re-exec pass must still sync (calls: $(n "$T/sync-calls"))"
grep -qi 're-exec' "$H/logs/agent-rules.log" && ok || bad "(b) proceeding while behind must leave a note in agent-rules.log (got: $(cat "$H/logs/agent-rules.log"))"
grep -q 'DEFERRED' <<<"$(alerts)" && bad "(b) no second defer (got: $(alerts))" || ok

reset 10 20
OUT=$(gate); RC=$?
[ "$RC" = 1 ] && ok || bad "a sync that FAILED must still refuse — the fresh code is not on disk (rc=$RC out=$OUT)"

reset 30
OUT=$(gate); RC=$?
[ "$RC" = 1 ] && ok || bad "(c) diverged must be refused (rc=$RC)"
OUT=$( RB_CTX_REEXEC=1 gate ); RC=$?
[ "$RC" = 1 ] && ok || bad "(c) diverged must be refused on a re-exec pass too (rc=$RC)"
[ "$(n "$T/sync-calls")" = 0 ] && ok || bad "(c) diverged must never sync"

reset 10; touch "$H/flags/context-gate-disabled"
OUT=$(gate); RC=$?
[ "$RC" = 0 ] && grep -q 'disabled' <<<"$OUT" && ok || bad "(d) the kill switch must pass the gate (rc=$RC out=$OUT)"
[ "$(n "$T/sync-calls")" = 0 ] && ok || bad "(d) the kill switch must not sync"

# --- end to end through the caller ---------------------------------------------
# (a)+(b): the stub checkout is behind on EVERY check, which is the starvation
# case exactly — main moved again between the sync and the re-exec.
reset 10
drive
[ "$(n "$T/proceeded")" = 1 ] && ok || bad "(a) the build must proceed exactly once (got: $(cat "$T/proceeded" 2>/dev/null))"
grep -q '^PROCEEDED FRESH ' "$T/proceeded" 2>/dev/null && ok || bad "(a) the build must proceed on the FRESH driver the sync installed (got: $(cat "$T/proceeded" 2>/dev/null))"
[ "$(n "$T/sync-calls")" = 2 ] && ok || bad "(a)/(b) one sync per pass, two passes, no more (calls: $(n "$T/sync-calls"))"
[ "$(find "$H/builds" -mindepth 1 -maxdepth 1 -type d | grep -c .)" = 1 ] && ok \
  || bad "(a) the re-exec must reuse the first pass's build dir, not orphan it ($(ls "$H/builds"))"
grep -q 'reexec=unset' "$T/proceeded" 2>/dev/null && ok || bad "(a) RB_CTX_REEXEC must not leak into the build's children (got: $(cat "$T/proceeded" 2>/dev/null))"
[ -z "$(cat "$H/builds"/*/RESULT 2>/dev/null)" ] && ok || bad "(a) no RESULT may be written on the way through (got: $(cat "$H/builds"/*/RESULT))"
grep -q 'DEFERRED' <<<"$(alerts)" && bad "(b) no DEFERRED alert anywhere in the run (got: $(alerts))" || ok
[ "$(grep -ci 'restart' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "exactly one restart alert per build (got: $(alerts))"

# (c) diverged through the caller: refused, never re-exec'd.
reset 30
drive; RC=$?
[ "$RC" = 3 ] && ok || bad "(c) diverged must exit the build with the refusal code 3 (rc=$RC)"
[ ! -s "$T/proceeded" ] && ok || bad "(c) diverged must not proceed (got: $(cat "$T/proceeded"))"
grep -q '^BUILD_REFUSED' "$H/builds"/*/RESULT 2>/dev/null && ok || bad "(c) diverged must write BUILD_REFUSED"

# (d) kill switch through the caller: proceeds on the stale driver, no sync.
reset 10; touch "$H/flags/context-gate-disabled"
drive
grep -q '^PROCEEDED STALE ' "$T/proceeded" 2>/dev/null && [ "$(n "$T/proceeded")" = 1 ] && ok \
  || bad "(d) kill switch: proceed once, no re-exec (got: $(cat "$T/proceeded" 2>/dev/null))"

# Belt and braces: if the gate ever answered 3 on a pass that already
# re-exec'd, the caller must refuse rather than exec a second time.
reset 0
printf '#!/bin/bash\necho "synced, re-exec"\nexit 3\n' > "$H/bin/context-gate.sh"; chmod +x "$H/bin/context-gate.sh"
drive
[ "$(n "$T/proceeded")" = 0 ] && ok || bad "a second rc 3 must be refused, never a re-exec loop (got: $(cat "$T/proceeded"))"
grep -q '^BUILD_REFUSED' "$H/builds"/*/RESULT 2>/dev/null && ok || bad "a second rc 3 must write BUILD_REFUSED"
cp "$DIR/bin/context-gate.sh" "$H/bin/"

echo "context-gate-reexec-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
