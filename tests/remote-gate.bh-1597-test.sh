#!/bin/bash
# tests/remote-gate.bh-1597-test.sh — the test hosts stop filling their root
# disks (#1597).
#
# WHAT HAPPENED. All four machines of bh-testhost-example-org have a 7.8 GB root
# overlay, and /srv/tmp was never the tmpfs the docs promised: every run landed
# on the root disk. Suites mktemp'd under /tmp outside the run tree, nothing on
# the HOST cleaned up when a run died, nothing checked for space before copying
# the tree -P times, and the sweep only reached run roots six hours old. Under
# load every builder's gate died with ENOSPC.
#
# WHAT THIS PINS, all through the REAL composed jobs (the ssh shim captures each
# `bash -s` it is handed, in order; the first is the host-side prep, the last is
# the run job), executed locally through the RG_RUN_DIR / RG_SWEEP_* /
# RG_TMPFS_ROOT seams. Nothing here reaches /srv, /tmp or Fly.
#   a. a job whose suite is killed mid-run (TERM or HUP to the job's bash)
#      leaves no run dir behind and no suite still running;
#   b. a suite that mktemp's leaves nothing under the caller's TMPDIR — suite
#      scratch lives in the run tree, which the run removes;
#   c. a host with too little free space is exit 125 with "nothing ran", no
#      copy was made and no suite ran; the -P x du(base) x factor arm counts;
#   d. the sweep (REMOTE_GATE_SWEEP_MIN=30) removes a 31-minute-old dir nothing
#      references, and keeps one a live process has as cwd, names in its
#      cmdline, or holds open, and one with a file inside newer than the age;
#   e. loose rc-*/log-*/cperr-*/runner-*/<epoch>-<pid>* and /tmp tmp.*/scratch.*
#      older than the age go; anything outside those patterns is never touched;
#   f. the tmpfs step: a no-op on a tmpfs, a warning (never a mount, never a
#      failure) when anything is on the root, a mount of the knob's size when the
#      root is empty, and a warning when the mount fails. mount and findmnt are
#      stubs — nothing is ever mounted;
#   k. the knobs are validated before anything talks to the host.
#
# /proc is Linux-only, so the three liveness arms of (d) run where it exists
# (the remote gate, CI) and say they were skipped where it does not.
#
# Run from anywhere: tests/remote-gate.bh-1597-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/remote-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/remote-gate.sh does not exist"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/wt/tests" "$T/h/flags" "$T/h/logs"
: > "$T/h/flags/lane-off-testhost-tick"
NOW=$(date -u '+%s')
JOBPATH="/usr/bin:/bin:/usr/sbin:/sbin"
TOUCH_EPOCH=1
touch -d "@$NOW" "$T/.touch-probe" 2>/dev/null || TOUCH_EPOCH=0
age() { touch -d "@$((NOW - $1 * 60))" "$2"; }   # age <minutes> <path>
HAVE_PROC=0; [ -r "/proc/$$/cmdline" ] && HAVE_PROC=1

# ── the shims ────────────────────────────────────────────────────────────────
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "proxy "*|"proxy") : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue") shift 3; printf 'k\n' > "$1"; printf 'c\n' > "$1-cert.pub"; exit 0 ;;
esac
exit 0
STUB
printf '#!/bin/bash\n[ -f "$FIX/proxy-up" ] && exit 0\nexit 1\n' > "$T/fakebin/nc"
# rsync: a no-op, except with FIX_RSYNC_COPY=1 (section u), where it really
# copies into $FIX/host<dest path>, honouring --files-from as rsync does.
cat > "$T/fakebin/rsync" <<'STUB'
#!/bin/bash
[ "${FIX_RSYNC_COPY:-}" = 1 ] || exit 0
ff=""; z=""
for a in "$@"; do case "$a" in --files-from=*) ff="${a#--files-from=}" ;; --from0) z=--null ;; esac; done
src="${*: -2:1}"; dst="${*: -1}"; dst="$FIX/host${dst#root@localhost:}"
mkdir -p "$dst" || exit 23
# A directory entry in the list recurses, as rsync -r does with --files-from.
if [ -n "$ff" ]; then
  ( cd "$src" && tar cf - $z -T "$ff" ) | ( cd "$dst" && tar xf - ) || exit 23
else
  ( cd "$src" && tar cf - . ) | ( cd "$dst" && tar xf - ) || exit 23
fi
exit 0
STUB
printf '#!/bin/bash\necho "        Valid: from 2026-01-01T00:00:00 to 2099-01-01T00:00:00"\n' > "$T/fakebin/ssh-keygen"
# Every `bash -s` is kept, in order: bash-1 is the prep, the last is the run job.
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/ssh-calls"
case "$*" in
  *"bash -s"*)
    n=$(( $(cat "$FIX/nbash" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/nbash"
    cat > "$FIX/bash-$n"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/*

# The job-side shims live in their own dir so only the job sees them.
mkdir -p "$T/jobbin"
# df: -P answers from the fixture when one is set, anything else is the real df.
cat > "$T/jobbin/df" <<'STUB'
#!/bin/bash
case " $* " in
  *" -P"*|*" -Pk "*)
    if [ -f "$FIX/df-avail-kb" ]; then
      echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
      echo "/dev/fixture 8000000 7000000 $(cat "$FIX/df-avail-kb") 99% /fixture-fs"
      exit 0
    fi ;;
esac
exec /bin/df "$@"
STUB
# findmnt: "is a tmpfs" is a fixture file; mount records and may fail.
cat > "$T/jobbin/findmnt" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/findmnt-calls"
[ -f "$FIX/is-tmpfs" ] && { echo "tmpfs"; exit 0; }
exit 1
STUB
cat > "$T/jobbin/mount" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/mount-calls"
rc=$(cat "$FIX/mount-rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && : > "$FIX/is-tmpfs"
exit "$rc"
STUB
# flock: the real one where it exists (f13 needs real locking); elsewhere (the
# Mac) a stand-in that always gets the lock, so the mount path stays testable.
HAVE_FLOCK=0
if command -v flock >/dev/null 2>&1; then HAVE_FLOCK=1
else printf '#!/bin/bash\nexit 0\n' > "$T/jobbin/flock"; fi
# cp: a recorder, so "no copy was made" is observed, not inferred.
cat > "$T/jobbin/cp" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/cp-calls"
exec /bin/cp "$@"
STUB
chmod +x "$T/jobbin"/*
export FIX

# gate <env...> -- <gate args...> — compose the jobs with the knobs in <env>.
gate() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  rm -f "$FIX"/bash-* "$FIX/nbash" "$FIX/ssh-calls"; : > "$FIX/proxy-up"
  rm -f "$T/key" "$T/key-cert.pub"
  OUT=$(env PATH="$T/fakebin:$JOBPATH" HOME="$T" HARNESS="$T/h" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 ${envs[@]+"${envs[@]}"} \
    bash "$GATE" "$@" 2>&1); RC=$?
  NB=$(cat "$FIX/nbash" 2>/dev/null || echo 0)
  JOB="$FIX/bash-$NB"
  PREP="$FIX/bash-1"; [ "$NB" -ge 2 ] || PREP=""
}
# base <dir> — a run dir with the worktree copied in as base/
base() { mkdir -p "$1"; /bin/cp -R "$T/wt" "$1/base"; }

cat > "$T/wt/tests/slow.sh" <<'EOS'
echo started
exec sleep "$SLOW_S"
EOS
cat > "$T/wt/tests/mk.sh" <<'EOS'
d=$(mktemp -d); echo x > "$d/f"
f=$(mktemp); echo y > "$f"
echo "tmp=$d"
exit 0
EOS
cat > "$T/wt/tests/td.sh" <<'EOS'
printf '%s\n' "$TMPDIR" > "$MARKDIR/td-$$"
exit 0
EOS
cat > "$T/wt/tests/ran.sh" <<'EOS'
: > "$MARKDIR/ran-$$"
exit 0
EOS

# ── a. a killed job leaves nothing behind ───────────────────────────────────
killcase() { # killcase <SIG> <label> <sleep-seconds>
  local sig="$1" label="$2" secs="$3" w=0 jp
  gate -- "$T/wt" tests/slow.sh
  [ -s "$JOB" ] || { bad "a$label no run job was composed: $OUT"; return; }
  base "$T/ra$label"
  env RG_RUN_DIR="$T/ra$label" SLOW_S="$secs" PATH="$T/jobbin:$JOBPATH" TMPDIR="$T/outer-a" \
    bash "$JOB" > "$T/ra$label.out" 2>&1 & jp=$!
  while [ "$w" -lt 200 ] && ! grep -q started "$T/ra$label/log-1" 2>/dev/null; do
    w=$((w + 1)); sleep 0.05   # determinism: ok bounded wait for the suite to start, not a fixed settle
  done
  [ "$w" -lt 200 ] || { bad "a$label the suite never started: $(cat "$T/ra$label.out")"; kill "$jp" 2>/dev/null; return; }
  kill "-$sig" "$jp"
  w=0
  while [ "$w" -lt 200 ] && kill -0 "$jp" 2>/dev/null; do
    w=$((w + 1)); sleep 0.05   # determinism: ok bounded wait for the job to exit
  done
  wait "$jp" 2>/dev/null
  [ ! -e "$T/ra$label" ] && ok \
    || bad "a$label a job killed with SIG$sig left its run dir behind ($(ls "$T/ra$label" 2>/dev/null | tr '\n' ' ')) — only the sweep would ever remove it"
  w=0
  while [ "$w" -lt 100 ] && pgrep -f "sleep $secs\$" >/dev/null 2>&1; do
    w=$((w + 1)); sleep 0.05   # determinism: ok bounded wait for the killed suite to go
  done
  if pgrep -f "sleep $secs\$" >/dev/null 2>&1; then
    bad "a$label a suite of a job killed with SIG$sig is still running and writing"
    pkill -f "sleep $secs\$" 2>/dev/null
  else ok; fi
}
mkdir -p "$T/outer-a"
killcase TERM 1 3171
killcase HUP 2 3172

# ── b. suite scratch stays inside the run ───────────────────────────────────
mkdir -p "$T/outer-b"
gate -- "$T/wt" tests/mk.sh
base "$T/rb"
JOUT=$(env RG_RUN_DIR="$T/rb" PATH="$T/jobbin:$JOBPATH" TMPDIR="$T/outer-b" bash "$JOB" 2>&1); JRC=$?
[ "$JRC" = 0 ] && ok || bad "b1 the mktemp suite's run exited $JRC: $JOUT"
LEFT=$(find "$T/outer-b" -mindepth 1 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "b2 a suite's mktemp landed outside the run and outlived it: $LEFT"
[ ! -e "$T/rb" ] && ok || bad "b3 the run dir outlived a clean run"

# Each suite its OWN scratch, removed with its copy, so a long run holds at most
# -P suites' scratch at once, not every finished suite's until the end.
mkdir -p "$T/tdmarks"
gate -- "$T/wt" tests/td.sh tests/td.sh
base "$T/rtd"
JOUT=$(env RG_RUN_DIR="$T/rtd" MARKDIR="$T/tdmarks" PATH="$T/jobbin:$JOBPATH" bash "$JOB" 2>&1)
TDS=$(cat "$T/tdmarks"/* 2>/dev/null | sort)
case "$TDS" in
  "$T/rtd/tmp/1"*"$T/rtd/tmp/2") ok ;;
  *) bad "b6 the suites did not each get their own TMPDIR under the run (\$R/tmp/<n>): $TDS / $JOUT" ;;
esac

mkdir -p "$T/outer-c"
gate -- "$T/wt" -- bash tests/mk.sh
base "$T/rbc"
JOUT=$(env RG_RUN_DIR="$T/rbc" PATH="$T/jobbin:$JOBPATH" TMPDIR="$T/outer-c" bash "$JOB" 2>&1); JRC=$?
[ "$JRC" = 0 ] && ok || bad "b4 cmd mode's mktemp command exited $JRC: $JOUT"
LEFT=$(find "$T/outer-c" -mindepth 1 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "b5 cmd mode's mktemp landed outside the run: $LEFT"

# ── c. no room, nothing runs ────────────────────────────────────────────────
mkdir -p "$T/marks"
gate REMOTE_GATE_MIN_FREE_MB=1500 -- "$T/wt" tests/ran.sh tests/ran.sh
base "$T/rc1"
printf '1024\n' > "$FIX/df-avail-kb"; rm -f "$FIX/cp-calls"
JOUT=$(env RG_RUN_DIR="$T/rc1" MARKDIR="$T/marks" PATH="$T/jobbin:$JOBPATH" bash "$JOB" 2>&1); JRC=$?
[ "$JRC" = 125 ] && ok || bad "c1 a host with 1 MB free exited $JRC (want 125 — a runner failure, never red suites): $JOUT"
case "$JOUT" in
  *"RUNNER FAILURE — the test host has 1 MB free on /fixture-fs, need 1500; nothing ran"*) ok ;;
  *) bad "c2 the no-room run did not say how much it had and needed: $JOUT" ;;
esac
case "$JOUT" in *"remote-gate:   "*) ok ;; *) bad "c3 the no-room run printed no host resources: $JOUT" ;; esac
[ -z "$(ls "$T/marks")" ] && ok || bad "c4 a suite ran on a host with no room: $(ls "$T/marks")"
grep -q 'run-' "$FIX/cp-calls" 2>/dev/null && bad "c5 a per-suite copy was made on a host with no room: $(cat "$FIX/cp-calls")" || ok

# The positive control: plenty of room, the same job runs both suites.
rm -f "$T/marks"/*
base "$T/rc2"
printf '50000000\n' > "$FIX/df-avail-kb"; rm -f "$FIX/cp-calls"
JOUT=$(env RG_RUN_DIR="$T/rc2" MARKDIR="$T/marks" PATH="$T/jobbin:$JOBPATH" bash "$JOB" 2>&1); JRC=$?
[ "$JRC" = 0 ] && ok || bad "c6 a host with room exited $JRC: $JOUT"
[ "$(ls "$T/marks" | wc -l | tr -d ' ')" = 2 ] && ok || bad "c7 a host with room did not run both suites: $(ls "$T/marks")"
rm -f "$T/marks"/*

# The factor arm: 2 copies x ~3 MB x 3 > 5 MB free, although 5 MB > the floor.
head -c 3000000 /dev/zero > "$T/wt/blob.bin"
gate REMOTE_GATE_MIN_FREE_MB=1 REMOTE_GATE_FREE_FACTOR=3 -- "$T/wt" tests/ran.sh tests/ran.sh
base "$T/rc3"
printf '5120\n' > "$FIX/df-avail-kb"
JOUT=$(env RG_RUN_DIR="$T/rc3" MARKDIR="$T/marks" PATH="$T/jobbin:$JOBPATH" bash "$JOB" 2>&1); JRC=$?
[ "$JRC" = 125 ] && ok || bad "c8 2 copies of a 3 MB tree at factor 3 fit in 5 MB, said the job (exit $JRC): $JOUT"
[ -z "$(ls "$T/marks")" ] && ok || bad "c9 a suite ran although the copies could not fit"
rm -f "$T/wt/blob.bin" "$FIX/df-avail-kb"

# ── d/e. the sweep: sooner, wider, and never a live one ─────────────────────
if [ "$TOUCH_EPOCH" != 1 ]; then
  echo "note: touch -d @epoch unsupported here — sections d and e skipped"
else
gate REMOTE_GATE_SWEEP_MIN=30 -- "$T/wt" -- true
SW="$T/sw"; ST="$T/srvtmp"; TM="$T/tmpd"
mkdir -p "$SW/old31" "$SW/cwd31" "$SW/cmd31" "$SW/fd31" "$SW/deep31" "$SW/fresh5" \
         "$ST/runs" "$ST/1790000000-1234-1" "$TM/tmp.abc" "$TM/scratch.xyz" "$TM/tmp.fresh"
echo x > "$SW/deep31/new"; echo x > "$SW/fd31/held"
for f in rc-9 log-9 cperr-9 runner-9 rc-fresh keepme.txt; do echo x > "$ST/$f"; done
echo x > "$TM/gl.tgz"
age 1 "$SW/deep31/new"
for p in "$SW/old31" "$SW/cwd31" "$SW/cmd31" "$SW/fd31" "$SW/fd31/held" "$SW/deep31" \
         "$ST/rc-9" "$ST/log-9" "$ST/cperr-9" "$ST/runner-9" "$ST/1790000000-1234-1" "$ST/keepme.txt" \
         "$TM/tmp.abc" "$TM/scratch.xyz" "$TM/gl.tgz"; do age 31 "$p"; done
age 5 "$SW/fresh5"; age 5 "$ST/rc-fresh"; age 5 "$TM/tmp.fresh"
LIVE=""
if [ "$HAVE_PROC" = 1 ]; then
  # Per-run sleep arguments (.$$) so the leak check below counts THIS run's
  # fixtures only, on a host where other runs of this suite may be live.
  ( cd "$SW/cwd31" && exec sleep "3191.$$" ) & LIVE="$LIVE $!"
  # The path rides in argv[0] of the sleep ITSELF (exec -a), so there is no
  # parent shell to kill while a child sleep keeps this suite's stdout (I5).
  ( cd / && exec -a "rg-fixture $SW/cmd31/mirror" sleep "3192.$$" ) & LIVE="$LIVE $!"
  ( cd / && exec 7<"$SW/fd31/held" && exec sleep "3193.$$" ) & LIVE="$LIVE $!"
  w=0
  while [ "$w" -lt 100 ] && ! { [ "$(readlink "/proc/${LIVE##* }/fd/7" 2>/dev/null)" = "$SW/fd31/held" ] \
        && grep -q "$SW/cmd31/mirror" /proc/*/cmdline 2>/dev/null; }; do
    w=$((w + 1)); sleep 0.05   # determinism: ok bounded wait for the live fixtures to settle
  done
fi
mkdir -p "$T/rd"; base "$T/rd"
JOUT=$(env RG_RUN_DIR="$T/rd" RG_SWEEP_ROOTS="$SW" RG_SWEEP_SRVTMP="$ST" RG_SWEEP_TMP="$TM" \
  PATH="$T/jobbin:$JOBPATH" bash "$JOB" 2>&1); JRC=$?
for p in $LIVE; do kill "$p" 2>/dev/null; done; wait 2>/dev/null
# NO FIXTURE OUTLIVES THE SECTION (#1604 review, I5). An orphaned fixture keeps
# this suite's stdout open, so any caller that captures the suite — $(...), a
# pipe, the gate's tee — hangs until it ends, and on the shared host it is a
# leaked process per run.
if [ "$HAVE_PROC" = 1 ]; then
  w=0
  while [ "$w" -lt 40 ] && pgrep -f "319[123]\.$$\$" >/dev/null 2>&1; do
    w=$((w + 1)); sleep 0.05   # determinism: ok bounded wait for killed fixtures to be reaped
  done
  if pgrep -f "319[123]\.$$\$" >/dev/null 2>&1; then
    bad "d7 a liveness fixture outlived its kill: $(pgrep -af "319[123]\.$$\$" | tr '\n' ' ') — it holds this suite's stdout"
    pkill -f "319[123]\.$$\$" 2>/dev/null
  else ok; fi
fi
[ "$JRC" = 0 ] && ok || bad "d0 the sweep made the job exit $JRC: $JOUT"
[ ! -e "$SW/old31" ] && ok || bad "d1 a 31-minute-old run root nothing references survived REMOTE_GATE_SWEEP_MIN=30 (was the age still six hours?)"
[ -d "$SW/fresh5" ] && ok || bad "d2 a five-minute-old run root was swept"
[ -d "$SW/deep31" ] && ok || bad "d3 a run root with a one-minute-old file inside was swept — only the top dir's mtime was read"
if [ "$HAVE_PROC" = 1 ]; then
  [ -d "$SW/cwd31" ] && ok || bad "d4 a run root a live process has as its cwd was swept"
  [ -d "$SW/cmd31" ] && ok || bad "d5 a dir a live process names in its cmdline was swept (the leakcheck.py /tmp/scratch.X/mirror case)"
  [ -d "$SW/fd31" ] && ok || bad "d6 a dir a live process holds a file open in was swept"
else
  echo "note: no /proc here — d4-d6 (cwd, cmdline and fd liveness) skipped"
fi
[ ! -e "$ST/rc-9" ] && [ ! -e "$ST/log-9" ] && ok || bad "e1 loose rc-*/log-* older than the age survived"
[ ! -e "$ST/cperr-9" ] && [ ! -e "$ST/runner-9" ] && ok || bad "e2 loose cperr-*/runner-* older than the age survived"
[ ! -e "$ST/1790000000-1234-1" ] && ok || bad "e3 an old <epoch>-<pid>-<n> tree in /srv/tmp survived"
[ ! -e "$TM/tmp.abc" ] && [ ! -e "$TM/scratch.xyz" ] && ok || bad "e4 old /tmp tmp.*/scratch.* survived"
[ -f "$ST/keepme.txt" ] && ok || bad "e5 the sweep removed a /srv/tmp entry outside its patterns"
[ -f "$TM/gl.tgz" ] && ok || bad "e6 the sweep removed a /tmp entry outside its patterns (gl.tgz)"
[ -d "$ST/runs" ] && ok || bad "e7 the sweep removed /srv/tmp/runs itself"
[ -f "$ST/rc-fresh" ] && [ -d "$TM/tmp.fresh" ] && ok || bad "e8 fresh loose files were swept"
fi

# ── f. the tmpfs step ───────────────────────────────────────────────────────
tmpfs_prep() { # tmpfs_prep — run the composed prep against $T/tfs, output in POUT/PRC
  POUT=$(env RG_RUN_DIR="$T/pr" RG_TMPFS_ROOT="$T/tfs" PATH="$T/jobbin:$JOBPATH" bash "$PREP" 2>&1); PRC=$?
}
gate REMOTE_GATE_TMPFS_SIZE=7g -- "$T/wt" -- true
if [ -z "$PREP" ] || [ ! -s "$PREP" ]; then
  bad "f0 no host-side prep job was sent before the upload (the tmpfs step has nowhere to run): $OUT"
else
  rm -rf "$T/tfs" "$T/pr"; mkdir -p "$T/tfs/runs"; : > "$FIX/is-tmpfs"; rm -f "$FIX/mount-calls"
  tmpfs_prep
  [ "$PRC" = 0 ] && ok || bad "f1 the prep on a tmpfs exited $PRC: $POUT"
  [ ! -s "$FIX/mount-calls" ] && ok || bad "f2 the prep mounted over an existing tmpfs: $(cat "$FIX/mount-calls")"
  [ -d "$T/pr/base" ] && ok || bad "f3 the prep did not create the run's base dir"

  rm -rf "$T/tfs" "$T/pr"; mkdir -p "$T/tfs/runs/1790000000-99"; rm -f "$FIX/is-tmpfs" "$FIX/mount-calls"
  tmpfs_prep
  [ "$PRC" = 0 ] && ok || bad "f4 the prep failed the run because a live run was on the root disk (exit $PRC): $POUT"
  [ ! -s "$FIX/mount-calls" ] && ok || bad "f5 the prep mounted a tmpfs over a live run: $(cat "$FIX/mount-calls")"
  case "$POUT" in *"WARNING"*"is on the root disk"*) ok ;; *) bad "f6 the prep did not warn that runs stay on the root disk: $POUT" ;; esac
  [ -d "$T/tfs/runs/1790000000-99" ] && ok || bad "f7 the prep removed a live run"

  rm -rf "$T/tfs" "$T/pr"; mkdir -p "$T/tfs/runs"; rm -f "$FIX/is-tmpfs" "$FIX/mount-calls"
  tmpfs_prep
  [ "$PRC" = 0 ] && ok || bad "f8 the prep on an empty root disk exited $PRC: $POUT"
  grep -qF -- "-t tmpfs -o size=7g tmpfs $T/tfs" "$FIX/mount-calls" 2>/dev/null && ok \
    || bad "f9 the prep did not mount a REMOTE_GATE_TMPFS_SIZE tmpfs on an empty root: $(cat "$FIX/mount-calls" 2>/dev/null) / $POUT"

  rm -rf "$T/tfs" "$T/pr"; mkdir -p "$T/tfs/runs"; rm -f "$FIX/is-tmpfs" "$FIX/mount-calls"; printf '32\n' > "$FIX/mount-rc"
  tmpfs_prep
  [ "$PRC" = 0 ] && ok || bad "f10 a failed mount failed the run (exit $PRC): $POUT"
  case "$POUT" in *"WARNING"*"is on the root disk"*) ok ;; *) bad "f11 a failed mount did not warn: $POUT" ;; esac
  rm -f "$FIX/mount-rc"

  # A locally driven prep with no RG_TMPFS_ROOT never reaches for /srv/tmp.
  rm -rf "$T/pr"; rm -f "$FIX/is-tmpfs" "$FIX/mount-calls" "$FIX/findmnt-calls"
  env RG_RUN_DIR="$T/pr" PATH="$T/jobbin:$JOBPATH" bash "$PREP" >/dev/null 2>&1
  [ ! -s "$FIX/mount-calls" ] && [ ! -s "$FIX/findmnt-calls" ] && ok \
    || bad "f12 a locally driven prep reached for a mount it was not given: $(cat "$FIX/mount-calls" "$FIX/findmnt-calls" 2>/dev/null)"
fi

# A WEDGED LOCK HOLDER MUST NOT STALL EVERY GATE ON THE HOST (#1604 review, I4).
# With the lock held elsewhere, the prep waits REMOTE_GATE_LOCK_WAIT_S, warns,
# does not mount, and finishes — it never blocks for as long as the holder does.
if [ "$HAVE_FLOCK" = 1 ]; then
  gate REMOTE_GATE_TMPFS_SIZE=7g REMOTE_GATE_LOCK_WAIT_S=1 -- "$T/wt" -- true
  rm -rf "$T/tfs" "$T/pr"; mkdir -p "$T/tfs/runs"; rm -f "$FIX/is-tmpfs" "$FIX/mount-calls"
  flock "$T/tfs.mount.lock" sleep "3194.$$" & HOLD=$!
  w=0
  while [ "$w" -lt 100 ] && flock -n "$T/tfs.mount.lock" true 2>/dev/null; do
    w=$((w + 1)); sleep 0.05   # determinism: ok bounded wait for the holder to take the lock
  done
  env RG_RUN_DIR="$T/pr" RG_TMPFS_ROOT="$T/tfs" PATH="$T/jobbin:$JOBPATH" bash "$PREP" > "$T/f13.out" 2>&1 & PP=$!
  w=0
  while [ "$w" -lt 200 ] && kill -0 "$PP" 2>/dev/null; do
    w=$((w + 1)); sleep 0.05   # determinism: ok bounded wait for the prep to give up on the lock
  done
  if kill -0 "$PP" 2>/dev/null; then
    bad "f13 the prep was still waiting on a held lock after 10 s — one wedged prep stalls every gate on the host"
    pkill -P "$PP" 2>/dev/null; kill "$PP" 2>/dev/null
  else
    wait "$PP"; PRC=$?
    [ "$PRC" = 0 ] && ok || bad "f14 a busy lock failed the run (exit $PRC): $(cat "$T/f13.out")"
    grep -q 'WARNING.*lock' "$T/f13.out" && ok || bad "f15 a busy lock did not say so: $(cat "$T/f13.out")"
  fi
  [ ! -s "$FIX/mount-calls" ] && ok || bad "f16 the prep mounted without holding the lock: $(cat "$FIX/mount-calls")"
  kill "$HOLD" 2>/dev/null; pkill -f "3194\.$$\$" 2>/dev/null; wait 2>/dev/null
else
  echo "note: no flock here — f13-f16 (the lock timeout) skipped"
fi

# ── k. the knobs are checked before the host is touched ─────────────────────
gate 'REMOTE_GATE_TMPFS_SIZE=20g;reboot' -- "$T/wt" -- true
[ "$RC" = 125 ] && ok || bad "k1 a tmpfs size that is not a size exited $RC (want 125): $OUT"
[ "$NB" = 0 ] && ok || bad "k2 a job went to the host with an unusable tmpfs size"
gate REMOTE_GATE_SWEEP_MIN=soon -- "$T/wt" -- true
[ "$RC" = 125 ] && ok || bad "k3 a sweep age that is not a number exited $RC (want 125): $OUT"
case "$OUT" in *REMOTE_GATE_SWEEP_MIN*) ok ;; *) bad "k4 the knob failure did not name the knob: $OUT" ;; esac
# THE FLOOR IS IN CODE (#1604 review, I1): a caller's env bypasses the registry
# clamp, and one builder with REMOTE_GATE_SWEEP_MIN=2 would make every sweep on
# a shared host a two-minute sweep. The floor is the suite cap plus a fifth:
# REMOTE_GATE_SUITE_TIMEOUT=1500 s -> 30 minutes.
gate REMOTE_GATE_SWEEP_MIN=2 -- "$T/wt" -- true
grep -q '^RG_SWEEP_MIN=30 ' "$JOB" 2>/dev/null && ok \
  || bad "k5 REMOTE_GATE_SWEEP_MIN=2 from the env reached the host as $(grep -o '^RG_SWEEP_MIN=[^ ]*' "$JOB" 2>/dev/null) (want the floor, 30)"
gate REMOTE_GATE_SWEEP_MIN=45 -- "$T/wt" -- true
grep -q '^RG_SWEEP_MIN=45 ' "$JOB" 2>/dev/null && ok || bad "k6 a sweep age above the floor was not kept as given"

# ── u. the upload is what the gate needs, not the whole directory (#1604, I6) ──
# A checkout uploads its tracked files and its working-tree changes (untracked,
# not ignored) — what CI checks out plus the uncommitted work — never ignored
# bulk: the lead's Mac checkout carried 100 MB of ignored refs/, which is 154 MB
# a base, 5.5 GB for a -P 12 run by the free-space rule.
if ! env PATH="$T/fakebin:$JOBPATH" git --version >/dev/null 2>&1; then
  echo "note: no working git on the gate's PATH here — section u (the upload list) skipped"
else
  G="$T/gw"; mkdir -p "$G/refs/bulk" "$G/tests"
  ( cd "$G" && git init -q -b main 2>/dev/null || git init -q
    git symbolic-ref HEAD refs/heads/main
    printf 'refs/\n' > .gitignore; echo tracked > tracked.txt; echo gone > gone.txt
    git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture
    rm gone.txt; echo new > untracked.txt; echo edited > tracked.txt ) >/dev/null 2>&1
  echo ignored > "$G/refs/bulk/big.bin"
  # An UNIGNORED untracked nested repo (the Mac's refs/remotes/pr/<n>/ shape):
  # ls-files -co lists it as one `nested/` entry, and rsync --files-from would
  # then upload the whole tree under it.
  mkdir -p "$G/nested" && ( cd "$G/nested" && git init -q && echo inner > inner.bin ) >/dev/null 2>&1
  scratch_rm "$FIX/host" >/dev/null 2>&1 || true
  gate FIX_RSYNC_COPY=1 REMOTE_GATE_BASE=main -- "$G" -- true
  UB=$(find "$FIX/host" -type d -name base -path '*/runs/*' 2>/dev/null | head -1)
  if [ -z "$UB" ]; then bad "u0 nothing was uploaded (rc $RC): $OUT"; else
    [ "$(cat "$UB/tracked.txt" 2>/dev/null)" = edited ] && ok || bad "u1 a tracked file (with its uncommitted edit) was not uploaded"
    [ -f "$UB/untracked.txt" ] && ok || bad "u2 an untracked, not-ignored file was not uploaded (uncommitted work must go up)"
    [ ! -e "$UB/refs/bulk/big.bin" ] && ok || bad "u3 an ignored file was uploaded — ignored bulk inflates every copy and the free-space need"
    [ ! -e "$UB/gone.txt" ] && ok || bad "u4 a deleted tracked file came back in the upload"
    [ ! -e "$UB/nested/inner.bin" ] && ok || bad "u5 an untracked nested git repo went up whole (ls-files lists it as 'nested/', and --files-from recursed into it)"
  fi
fi

echo "remote-gate BH-1597: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
