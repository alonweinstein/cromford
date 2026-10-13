#!/bin/bash
# tests/remote-gate.bh-1221-test.sh — the two bin/remote-gate.sh follow-ups the
# Fable review of #1213 asked for (BH-1221, items 3 and 4).
#
#   3. THE SIX-HOUR SWEEP HAD NO TEST AT ALL. It is the one part of the composed
#      job that reaches outside its own run and the only `rm -rf` in this repo
#      aimed at a path no ticket owns, and it was skipped in every existing run
#      of the job (tests/remote-gate-test.sh sets RG_RUN_DIR, which is exactly
#      what switches the sweep off). So it shipped unproven in both directions:
#      nothing showed it deleted litter, and nothing showed it spared a run that
#      was still going. Section 3 drives it through the real composed job against
#      fixture roots named by RG_SWEEP_ROOTS, and pins all three outcomes —
#      old goes, fresh stays, and a root a live process is sitting in stays.
#   4. AN OOM-KILLED WORKER READ AS "disk?". Runs live on a tmpfs once the
#      gate's prep has mounted one (#1597; before that, on the root disk), so
#      the host running out of MEMORY and the tmpfs filling up produce the same
#      symptom (a worker that never wrote an rc file) and the hint has to name
#      both — with the two numbers that tell them apart. Section 4 executes the
#      job into a runner failure and reads what it printed.
#
# THE JOB IS EXECUTED, NOT GREPPED, for the same reason tests/remote-gate-test.sh
# executes it: bin/remote-gate.sh composes one shell program and a grep over the
# composer proves only that a string is present in a file.
#
# Nothing here talks to Fly: flyctl, ssh, rsync, nc and ssh-keygen are PATH shims
# that record their argv, and no fixture path is outside this suite's scratch
# tree.
#
# Run from anywhere: tests/remote-gate.bh-1221-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/remote-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/remote-gate.sh does not exist"; exit 1; }

FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/wt" "$T/h/flags" "$T/h/logs"
echo "a worktree file" > "$T/wt/file.txt"
# The tick is a real integration point (remote-gate asks it to wake the host);
# this suite is not about the tick, so its lane is held off in the scratch
# harness. tests/testhost-tick-test.sh and tests/testhost-tick.bh-1221-test.sh
# are where the tick's own behaviour is proved.
: > "$T/h/flags/lane-off-testhost-tick"
# ONE clock read for the whole file; every age below is derived from it.
NOW=$(date -u '+%s')
JOBPATH="/usr/bin:/bin:/usr/sbin:/sbin"

TOUCH_EPOCH=1
touch -d "@$NOW" "$T/.touch-probe" 2>/dev/null || TOUCH_EPOCH=0

# ── the shims ────────────────────────────────────────────────────────────────
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "proxy "*|"proxy") : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue")
    shift 2
    p=""
    for a in "$@"; do case "$a" in -*) ;; *) [ -z "${org_seen:-}" ] && org_seen=1 || { [ -z "$p" ] && p="$a"; } ;; esac; done
    [ -n "$p" ] || exit 1
    printf 'fake-private-key\n' > "$p"; printf 'fake-cert\n' > "$p-cert.pub"
    exit 0 ;;
esac
exit 0
STUB
cat > "$T/fakebin/nc" <<'STUB'
#!/bin/bash
[ -f "$FIX/proxy-up" ] && exit 0
exit 1
STUB
cat > "$T/fakebin/rsync" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
case "$*" in
  *"bash -s"*) cat > "$FIX/job"; exit 0 ;;
esac
exit 0
STUB
cat > "$T/fakebin/ssh-keygen" <<'STUB'
#!/bin/bash
echo "        Valid: from 2026-01-01T00:00:00 to 2099-01-01T00:00:00"
exit 0
STUB
# RECORDERS, not replacements: each logs its argv and then runs the real tool.
# 3g and 3i need to see whether the SWEEP RAN AT ALL, because "the local guard
# held" and "the sweep ran against /srv and found nothing on this machine" leave
# the same fixture behind, and only one of them is the behaviour being pinned.
# readlink is the witness: rg_sweep reads /proc/*/cwd on entry, before it looks
# at a single root, so a recorded readlink means the function was entered and no
# recorded readlink means it never was. `find` is the second half — which roots
# it was asked about.
cat > "$T/fakebin/find" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/find-calls"
exec /usr/bin/find "$@"
STUB
cat > "$T/fakebin/readlink" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/readlink-calls"
exec /usr/bin/readlink "$@"
STUB
chmod +x "$T/fakebin"/*
export FIX

# run <args...> — the gate, in its own env, against the scratch harness. It ends
# with the composed job captured in $FIX/job, which is what the sections below
# execute.
run() {
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$T/h" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 \
    bash "$GATE" "$@" 2>&1); RC=$?
}
reset() { rm -f "$FIX/job" "$T/key" "$T/key-cert.pub"; : > "$FIX/proxy-up"; }

# ── 3. the six-hour sweep: litter goes, live work stays ─────────────────────
if [ "$TOUCH_EPOCH" != 1 ]; then
  echo "note: touch -d @epoch unsupported here — section 3 (the six-hour sweep) skipped"
else
reset
run "$T/wt" -- true
[ -s "$FIX/job" ] && ok || bad "3a no job was composed (nothing to execute)"

mkdir -p "$T/sweep/old" "$T/sweep/fresh" "$T/sweep/live" "$T/rs/base"
touch -d "@$((NOW - 25200))" "$T/sweep/old" "$T/sweep/live"   # seven hours dead
# A run that is still going, six hours in: a process whose cwd is inside the
# candidate. `exec` so the pid the job sees is the one sitting in the directory.
( cd "$T/sweep/live" && exec sleep 30 ) & LIVE=$!
W=0
while [ "$W" -lt 100 ] && [ "$(readlink "/proc/$LIVE/cwd" 2>/dev/null)" != "$T/sweep/live" ]; do
  W=$((W + 1)); sleep 0.05   # determinism: ok bounded wait for a pid's cwd to settle, not a fixed settle
done
rm -f "$FIX/find-calls" "$FIX/readlink-calls"
JOUT=$(env RG_RUN_DIR="$T/rs" RG_SWEEP_ROOTS="$T/sweep" PATH="$T/fakebin:$JOBPATH" bash "$FIX/job" 2>&1); JRC=$?
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

[ ! -e "$T/sweep/old" ] && ok \
  || bad "3b a run root seven hours dead survived the sweep — nobody else cleans this host: $JOUT"
[ -d "$T/sweep/fresh" ] && ok \
  || bad "3c the sweep deleted a fresh run root: $JOUT"
if [ "$W" -lt 100 ]; then
  [ -d "$T/sweep/live" ] && ok \
    || bad "3d the sweep deleted a run root a live process was sitting in — that is a drain deleted from under itself: $JOUT"
else
  echo "note: /proc/<pid>/cwd never showed the fixture cwd here — 3d (the liveness guard) skipped"
fi
[ "$JRC" = 0 ] && ok || bad "3e the sweep made the job exit $JRC — it must never fail the run: $JOUT"
# The positive control for 3g/3i below: when the sweep DOES run, both recorders
# see it. Without this, "no readlink was recorded" proves nothing.
if grep -q '/proc/' "$FIX/readlink-calls" 2>/dev/null && grep -q "$T/sweep" "$FIX/find-calls" 2>/dev/null; then ok; else
  bad "3f the sweep ran but left no trace in the recorders — 3g/3i would then pass vacuously (readlink: $(cat "$FIX/readlink-calls" 2>/dev/null) / find: $(cat "$FIX/find-calls" 2>/dev/null))"
fi

# And the guarantee the existing suite relies on: a job driven locally
# (RG_RUN_DIR set) with no RG_SWEEP_ROOTS sweeps NOTHING, so a test can never
# reach the host's real roots.
mkdir -p "$T/sweep/old" "$T/rs/base"
touch -d "@$((NOW - 25200))" "$T/sweep/old"
rm -f "$FIX/find-calls" "$FIX/readlink-calls"
env RG_RUN_DIR="$T/rs" PATH="$T/fakebin:$JOBPATH" bash "$FIX/job" >/dev/null 2>&1
[ -d "$T/sweep/old" ] && ok \
  || bad "3g a locally driven job swept roots nobody named — RG_SWEEP_ROOTS is the only way in"
if [ -s "$FIX/readlink-calls" ] || grep -q '/srv' "$FIX/find-calls" 2>/dev/null; then
  bad "3h a locally driven job entered the sweep at all ($(wc -l < "$FIX/readlink-calls" 2>/dev/null || echo 0) readlink call(s), find: $(cat "$FIX/find-calls" 2>/dev/null)) — on the host that same call names /srv"
else ok; fi

# And the last line of defence, unchanged by this ticket but worth pinning now
# that a sweep seam exists: a job run with NO RG_RUN_DIR at all refuses before
# the sweep, because the baked-in run root is not a directory anywhere but the
# host. So forgetting RG_SWEEP_ROOTS cannot reach /srv either.
rm -f "$FIX/find-calls" "$FIX/readlink-calls"
JOUT=$(env PATH="$T/fakebin:$JOBPATH" bash "$FIX/job" 2>&1); JRC=$?
[ "$JRC" = 125 ] && ok || bad "3i a job with no run dir on this machine exited $JRC (want 125): $JOUT"
if [ -s "$FIX/readlink-calls" ] || grep -q '/srv' "$FIX/find-calls" 2>/dev/null; then
  bad "3j a job that had no run dir still entered the sweep ($(wc -l < "$FIX/readlink-calls" 2>/dev/null || echo 0) readlink call(s), find: $(cat "$FIX/find-calls" 2>/dev/null))"
else ok; fi
fi

# ── 4. a runner failure names memory AND disk, with the numbers ─────────────
# Suites mode with no `base` to copy: every worker's `cp -a` fails, which is the
# shape a full tmpfs and an OOM-killed worker both produce.
reset
run "$T/wt" tests/a.sh tests/b.sh
mkdir -p "$T/run6"          # deliberately no run6/base
JOUT=$(env RG_RUN_DIR="$T/run6" PATH="$JOBPATH" bash "$FIX/job" 2>&1); JRC=$?
[ "$JRC" = 125 ] && ok || bad "4a a run whose copies all failed exited $JRC (want 125): $JOUT"
case "$JOUT" in
  *"memory or disk on the host"*) ok ;;
  *) bad "4b the runner failure still blames disk alone — an OOM-killed worker looks identical on a tmpfs: $JOUT" ;;
esac
case "$JOUT" in
  *"remote-gate:   Filesystem"*) ok ;;
  *) bad "4c the failure printed no df line, so a reader cannot tell a full tmpfs from an OOM: $JOUT" ;;
esac
if command -v free >/dev/null 2>&1; then
  case "$JOUT" in
    *"Mem:"*) ok ;;
    *) bad "4d free -m is on this box but the failure printed no memory line: $JOUT" ;;
  esac
else
  echo "note: free is not on this box — 4d (the memory line) skipped"
fi
case "$JOUT" in
  *"(disk?)"*) bad "4e the old disk-only hint is still in the output: $JOUT" ;;
  *) ok ;;
esac

# Cmd mode has its own copy-failure line, and it says the same thing.
reset
run "$T/wt" -- true
mkdir -p "$T/run7"          # deliberately no run7/base
JOUT=$(env RG_RUN_DIR="$T/run7" PATH="$JOBPATH" bash "$FIX/job" 2>&1); JRC=$?
[ "$JRC" = 125 ] && ok || bad "4f cmd mode with no tree to copy exited $JRC (want 125): $JOUT"
case "$JOUT" in
  *"memory or disk on the host"*) ok ;;
  *) bad "4g cmd mode's copy failure still blames disk alone: $JOUT" ;;
esac
case "$JOUT" in
  *"remote-gate:   Filesystem"*) ok ;;
  *) bad "4h cmd mode's copy failure printed no host resource lines: $JOUT" ;;
esac

echo "remote-gate BH-1221: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
