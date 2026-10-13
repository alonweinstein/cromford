#!/bin/bash
# tests/testhost-tick.bh-1597-test.sh — the testhost tick reports every
# machine's disk and alerts on a full root (#1597, item 6).
#
# WHY. testhost-2 reached 87% of its 7.8 GB root while thirteen runs were live,
# and the first anybody heard of it was a builder's gate dying on ENOSPC. The
# tick already reaches the app over `flyctl ssh console` every five minutes, so
# one `df` more per machine turns that into a line in the log and an alert
# (bin/lane-alert.sh, the lane's existing path) before the disk is full.
#
# WHAT THIS PINS. The REAL bin/testhost-tick.sh against a scratch $HARNESS, a
# flyctl stub that EXECUTES the probe the tick composes (with a `df` shim that
# answers per machine from a fixture), and a lane-alert.sh recorder:
#   g1 a started machine at 90% raises the alert, and 50% does not;
#   g2 every started machine in the app is probed, a stopped one is not;
#   g3 each probed machine gets a log line with its root and /srv/tmp use;
#   g4 TESTHOST_DISK_ALERT_PCT is the threshold (the boundary is "above"),
#      and 0 turns the alert off;
#   g5 a machine back under the threshold resolves the condition it raised;
#   g6 an answer that does not parse raises nothing;
#   g7 a worker that does not answer still costs no Fly call (the lane's rule).
#
# Run from anywhere: tests/testhost-tick.bh-1597-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
TICK="$DIR/bin/testhost-tick.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$TICK" ] || { echo "FAIL: bin/testhost-tick.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FIX="$T/fix"; H="$T/h"
mkdir -p "$FIX/settings" "$FIX/disk" "$T/fakebin" "$T/probebin" "$H/bin/lib" "$H/catalog" "$H/flags" "$H/logs" "$H/state"
cp "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
NOW=$(date -u '+%s')

cat > "$H/bin/jobs-client.sh" <<'STUB'
JOBS_BOX=fixture
flag_sync()  { return 1; }
setting_get() {
  [ -f "$FIX/d1-down" ] && return 1
  [ -f "$FIX/settings/$1" ] || return 2
  cat "$FIX/settings/$1"
}
setting_set() {
  [ -f "$FIX/d1-down" ] && return 1
  printf '%s' "$2" > "$FIX/settings/$1"
  return 0
}
STUB
cat > "$H/bin/ci-runners-status.sh" <<'STUB'
#!/bin/bash
echo '{"repo":"example-org/cromford","label":"bh-ci","total":4,"online":4,"idle":4,"busy":0,"offline":0}'
exit 0
STUB
cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/alert-calls"
exit 0
STUB
chmod +x "$H/bin/ci-runners-status.sh" "$H/bin/lane-alert.sh"

# df on the probed "machine": the machine id comes from the flyctl stub.
cat > "$T/probebin/df" <<'STUB'
#!/bin/bash
p=$(cat "$FIX/disk/$RG_FIX_MID" 2>/dev/null || echo 10)
echo "Filesystem     1024-blocks    Used Available Capacity Mounted on"
echo "/dev/vdb           8000000 7000000   1000000      $p% /"
STUB
chmod +x "$T/probebin/df"

# flyctl: the machine list is a fixture; `ssh console --machine <id> -C <probe>`
# EXECUTES the probe with the df shim first on PATH, so what is pinned is the
# command the tick sends, not a number somebody handed it. The busy probe (no
# --machine) answers idle.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$*" in
  *"machine list"*|*"machines list"*) cat "$FIX/machines.json"; exit 0 ;;
  *"machine status"*)
    printf 'Machine ID: 873eddb0433018\nState: started\n\nVM\n CPU Kind │ performance\n vCPUs │ 16\n'; exit 0 ;;
  *"ssh console"*)
    # THE REAL CLI FORWARDS STDIN (#1604 review, B1: verified live). Reading it
    # here is what makes a probe inside a `while read` loop that forgot
    # </dev/null eat the rest of the machine list, exactly as flyctl does.
    cat > /dev/null
    prev=""; probe=""; mid=""
    for a in "$@"; do
      [ "$prev" = "-C" ] && probe="$a"
      [ "$prev" = "--machine" ] && mid="$a"
      prev="$a"
    done
    echo "Connecting to fdaa:..."
    if [ -z "$mid" ]; then echo "TESTHOST_BUSY 1"; exit 0; fi
    [ -f "$FIX/garbage-$mid" ] && { echo "Error: something"; exit 0; }
    export RG_FIX_MID="$mid" PATH="$PROBEBIN:$PATH"
    eval "$probe"
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/*
cat > "$FIX/machines.json" <<'JSON'
[{"id":"m1","name":"testhost-1","state":"started"},
 {"id":"m2","name":"testhost-2","state":"started"},
 {"id":"m3","name":"testhost-3","state":"stopped"}]
JSON
export FIX
export PROBEBIN="$T/probebin"

run() {
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$H" \
    TESTHOST_APP=bh-testhost-fixture ${PCT:+TESTHOST_DISK_ALERT_PCT=$PCT} \
    bash "$TICK" "$@" 2>&1 </dev/null); RC=$?
}
reset() {
  rm -f "$FIX/fly-calls" "$FIX/alert-calls" "$FIX/d1-down" "$FIX"/garbage-* "$FIX"/settings/* "$H/logs/testhost-tick.log"
  scratch_rm "$H/state/lane-gate" >/dev/null 2>&1 || true
  rm -f "$H/state/testhost-disk"/*   # which conditions this lane raised (flat files)
  printf '%s' "$NOW" > "$FIX/settings/testhost.last_used"
  printf '50\n' > "$FIX/disk/m1"; printf '90\n' > "$FIX/disk/m2"; printf '99\n' > "$FIX/disk/m3"
  PCT=""
}
alerts() { cat "$FIX/alert-calls" 2>/dev/null; }

# ── g1-g3. the default threshold, every started machine ────────────────────
reset; run
[ "$RC" = 0 ] && ok || bad "g0 the tick exited $RC: $OUT"
case "$(alerts)" in
  *"testhost-2"*"90%"*) ok ;;
  *) bad "g1a a machine at 90% raised no alert: $(alerts) / $OUT" ;;
esac
case "$(alerts)" in
  *"--resolve"*"testhost-1"*) bad "g1b a machine at 50% sent a resolve for a condition it never raised: $(alerts)" ;;
  *"testhost-1"*) bad "g1c a machine at 50% raised an alert: $(alerts)" ;;
  *) ok ;;
esac
grep -q -- "--machine m1" "$FIX/fly-calls" && grep -q -- "--machine m2" "$FIX/fly-calls" && ok \
  || bad "g2a not every started machine was probed: $(cat "$FIX/fly-calls")"
grep -q -- "--machine m3" "$FIX/fly-calls" && bad "g2b a stopped machine was probed (that starts nothing, but it is a failed ssh every tick)" || ok
grep -q "testhost-1.*root 50%.*/srv/tmp" "$H/logs/testhost-tick.log" 2>/dev/null && ok \
  || bad "g3a no per-machine disk line for testhost-1: $(cat "$H/logs/testhost-tick.log" 2>/dev/null)"
grep -q "testhost-2.*root 90%" "$H/logs/testhost-tick.log" 2>/dev/null && ok \
  || bad "g3b no per-machine disk line for testhost-2"

# ── g4. the knob is the threshold ───────────────────────────────────────────
reset; PCT=95; run
case "$(alerts)" in *"testhost-2"*) bad "g4a TESTHOST_DISK_ALERT_PCT=95 still alerted at 90%: $(alerts)" ;; *) ok ;; esac
reset; PCT=89; run
case "$(alerts)" in *"testhost-2"*"90%"*) ok ;; *) bad "g4b TESTHOST_DISK_ALERT_PCT=89 did not alert at 90%: $(alerts)" ;; esac
reset; printf '85\n' > "$FIX/disk/m2"; run
case "$(alerts)" in *"testhost-2"*) bad "g4c 85% alerted at the default threshold of 85 — the rule is ABOVE: $(alerts)" ;; *) ok ;; esac
reset; printf '86\n' > "$FIX/disk/m2"; run
case "$(alerts)" in *"testhost-2"*"86%"*) ok ;; *) bad "g4d 86% did not alert at the default threshold: $(alerts)" ;; esac
reset; PCT=0; run
case "$(alerts)" in *"testhost-2"*) bad "g4e TESTHOST_DISK_ALERT_PCT=0 did not turn the alert off: $(alerts)" ;; *) ok ;; esac

# ── g5. back under the threshold resolves ───────────────────────────────────
reset; run
rm -f "$FIX/alert-calls"; printf '40\n' > "$FIX/disk/m2"; run
case "$(alerts)" in *"--resolve"*"testhost-2"*) ok ;; *) bad "g5 a machine back at 40% did not resolve its alert: $(alerts)" ;; esac

# ── g6. an answer that does not parse raises nothing ────────────────────────
reset; : > "$FIX/garbage-m2"; run
case "$(alerts)" in *"testhost-2"*) bad "g6a an unparseable disk answer raised or resolved something: $(alerts)" ;; *) ok ;; esac
grep -q "testhost-2.*unreadable\|testhost-2.*did not answer" "$H/logs/testhost-tick.log" 2>/dev/null && ok \
  || bad "g6b an unparseable answer was not logged as such: $(cat "$H/logs/testhost-tick.log" 2>/dev/null)"

# ── g7. no worker, no Fly call ──────────────────────────────────────────────
reset; : > "$FIX/d1-down"; run
[ ! -s "$FIX/fly-calls" ] && ok || bad "g7 an unreachable worker still cost a Fly call: $(cat "$FIX/fly-calls")"

echo "testhost-tick BH-1597: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
