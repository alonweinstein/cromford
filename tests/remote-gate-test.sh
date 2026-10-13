#!/bin/bash
# tests/remote-gate-test.sh — bin/remote-gate.sh, the shared-Fly-test-host gate
# (BH-1205).
#
# WHAT THIS PINS AND WHY. The gate is the thing a builder or a reviewer runs
# INSTEAD of docker to decide whether a branch is green, so the one outcome it
# must never have is a quiet zero. Every section below is a way the prototype
# could have reported success without running anything:
#
#   - Fly unreachable (no proxy, no route) must be a NAMED error and a nonzero
#     exit, not "0 suites, 0 failing".
#   - ssh's own transport failure (rc 255) must not be read as 255 failing
#     suites, and must not be read as success either.
#   - a suite that is not on this branch exits 127 from `bash <path>`, which is
#     indistinguishable from a real failure unless the run says so.
#   - the SSH certificate Fly issues lives 72 hours; a gate that only reissues
#     after the cert has expired fails every run in the gap, and a gate that
#     reissues on every run burns a Fly API call per suite run.
#
# THE JOB IS EXECUTED, NOT GREPPED. bin/remote-gate.sh composes one shell
# program and hands it to the host over stdin; the ssh stub captures that
# program and sections 5-7 RUN IT locally against fixture suites (`RG_RUN_DIR`
# is the job's own run-root knob, which is what makes that possible). A grep for
# "the job mentions xargs" would have passed on a job that ran nothing — the
# same shape as the nine wirings in #1136 that every grep-based test declared
# wired while none of them gated.
#
# Nothing here talks to Fly: flyctl, ssh, rsync, nc and ssh-keygen are PATH
# shims that record their argv.
#
# Run from anywhere: tests/remote-gate-test.sh   (exit 0 = all pass)
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
# The tick is a real integration point: remote-gate asks it to wake the host.
# This suite is not about the tick, so the lane is held OFF in its scratch
# harness and the tick returns having done nothing. tests/testhost-tick-test.sh
# is where the tick's own behaviour is proved.
: > "$T/h/flags/lane-off-testhost-tick"

# ── the shims ────────────────────────────────────────────────────────────────
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*|"proxy")
    [ -f "$FIX/proxy-refuses" ] && { echo "Error: could not reach fly" >&2; exit 1; }
    : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue")
    shift 2
    # flyctl ssh issue <org> <path> --hours N
    p=""
    for a in "$@"; do case "$a" in -*) ;; *) [ -z "${org_seen:-}" ] && org_seen=1 || { [ -z "$p" ] && p="$a"; } ;; esac; done
    [ -n "$p" ] || exit 1
    printf 'fake-private-key\n' > "$p"; printf 'fake-cert\n' > "$p-cert.pub"
    : > "$FIX/issued"; exit 0 ;;
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
echo "$*" >> "$FIX/rsync-calls"
[ -f "$FIX/rsync-fails" ] && exit 23
exit 0
STUB
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/ssh-calls"
# ssh-unreachable drops the JOB SEND only. Failing every call instead killed the
# `mkdir -p` first, so the dedicated rc-255 handling further down the gate was
# never reached by the section that names it.
case "$*" in
  *"bash -s"*)
    [ -f "$FIX/ssh-unreachable" ] && { echo "ssh: connect to host localhost port 10022: Connection refused" >&2; exit 255; }
    cat > "$FIX/job"; exit "$(cat "$FIX/job-rc" 2>/dev/null || echo 0)" ;;
esac
[ -f "$FIX/ssh-mkdir-unreachable" ] && { echo "ssh: connect refused" >&2; exit 255; }
exit 0
STUB
cat > "$T/fakebin/ssh-keygen" <<'STUB'
#!/bin/bash
# -L -f <cert> — print what the real one prints, with the expiry the fixture says.
echo "        Valid: from 2026-01-01T00:00:00 to $(cat "$FIX/cert-to" 2>/dev/null || echo 2099-01-01T00:00:00)"
exit 0
STUB
chmod +x "$T/fakebin"/*
export FIX

# run <args...> — the gate, in its own env, against the scratch harness.
run() {
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$T/h" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 \
    bash "$GATE" "$@" 2>&1); RC=$?
}
reset() { rm -f "$FIX"/fly-calls "$FIX"/ssh-calls "$FIX"/rsync-calls "$FIX"/job \
  "$FIX"/job-rc "$FIX"/issued "$FIX"/proxy-up "$FIX"/proxy-refuses "$FIX"/ssh-unreachable \
  "$FIX"/rsync-fails "$FIX"/cert-to "$FIX"/ssh-mkdir-unreachable "$T/key" "$T/key-cert.pub"; }

# ── 1. usage and arguments ───────────────────────────────────────────────────
reset
run --help
[ "$RC" = 0 ] && ok || bad "1a --help exited $RC"
case "$OUT" in *"remote-gate.sh"*) ok ;; *) bad "1b --help printed no usage: $OUT" ;; esac

reset; run
[ "$RC" = 2 ] && ok || bad "1c no arguments exited $RC (want 2)"

reset; run "$T/nope" tests/x.sh
[ "$RC" = 2 ] && ok || bad "1d a missing directory exited $RC (want 2)"
case "$OUT" in *remote-gate:*) ok ;; *) bad "1e a missing directory printed no remote-gate: line: $OUT" ;; esac

reset; run "$T/wt"
[ "$RC" = 2 ] && ok || bad "1f a directory with no suites and no -- exited $RC (want 2)"

reset; run --tail nope "$T/wt" tests/a.sh
[ "$RC" = 2 ] && ok || bad "1g --tail with a non-number exited $RC (want 2)"

reset; run -P 0 "$T/wt" tests/a.sh
[ "$RC" = 2 ] && ok || bad "1h -P 0 exited $RC (want 2)"

# ── 2. the cert: reissue when missing, when nearly expired, never otherwise ──
# Fly's cert lives 72h. The decision is made from `ssh-keygen -L`, so a cert
# somebody else issued (the operator, an earlier run) is honoured.
reset
run "$T/wt" -- true
[ -f "$FIX/issued" ] && ok || bad "2a no key on disk and no cert was issued"
grep -q -- "--overwrite" "$FIX/fly-calls" 2>/dev/null && bad "2b the reissue passed --overwrite (it blocks; BH-1836): $(cat "$FIX/fly-calls" 2>/dev/null)" || ok
grep -q -- "--hours 72" "$FIX/fly-calls" 2>/dev/null && ok || bad "2c the reissue did not ask for 72 hours: $(cat "$FIX/fly-calls" 2>/dev/null)"
grep -q "fixture-org" "$FIX/fly-calls" 2>/dev/null && ok || bad "2d the reissue did not name TESTHOST_ORG: $(cat "$FIX/fly-calls" 2>/dev/null)"

reset
printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"
date_plus() { # date_plus <hours> — a local-time stamp in ssh-keygen's format
  # LOCAL time, not -u: ssh-keygen prints the window in local time and
  # _rg_epoch parses it as local. With `date -u` here, a GNU box west of UTC
  # reads this one-hour cert as an eight-hour one and 2f passes for the wrong
  # reason.
  if date -d "+$1 hours" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null; then :   # determinism: ok the expiry under test is relative to now by definition
  else date -v "+$1H" '+%Y-%m-%dT%H:%M:%S'; fi                      # determinism: ok same read, BSD date
}
date_plus 48 > "$FIX/cert-to"
run "$T/wt" -- true
[ -f "$FIX/issued" ] && bad "2e a cert valid for another 48h was reissued anyway" || ok

reset
printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"
date_plus 1 > "$FIX/cert-to"
run "$T/wt" -- true
[ -f "$FIX/issued" ] && ok || bad "2f a cert one hour from expiry was NOT reissued (every run in the gap fails)"

# ── 3. Fly unreachable is a named error, never a silent pass ────────────────
# 125, NOT 2, and that is the point of the section: two failing suites also
# exits 2, so a caller could not tell "the branch is red" from "nothing ran".
# 125 is above the suite-count cap (124) and is what docker uses for the same
# thing. A command-line mistake stays 2 — section 1 pins that half.
reset
: > "$FIX/proxy-refuses"
run "$T/wt" tests/a.sh
[ "$RC" = 125 ] && ok || bad "3a an unreachable Fly exited $RC (want 125 — never 0, and never a suite count)"
case "$OUT" in *remote-gate:*[Ff]ly*|*remote-gate:*proxy*) ok ;; *) bad "3b the unreachable error did not name Fly or the proxy: $OUT" ;; esac
[ -f "$FIX/job" ] && bad "3c a job was sent to a host we could not reach" || ok

reset
: > "$FIX/proxy-up"; : > "$FIX/ssh-unreachable"
run "$T/wt" tests/a.sh
[ "$RC" = 125 ] && ok || bad "3d ssh rc 255 became exit $RC — 255 is not a suite count"
case "$OUT" in *remote-gate:*255*) ok ;; *) bad "3e the rc-255 path did not name it (did the mkdir fail first?): $OUT" ;; esac

reset
: > "$FIX/proxy-up"; : > "$FIX/rsync-fails"
run "$T/wt" tests/a.sh
[ "$RC" = 125 ] && ok || bad "3f a failed upload exited $RC (want 125)"

reset
: > "$FIX/proxy-up"; : > "$FIX/ssh-mkdir-unreachable"
run "$T/wt" tests/a.sh
[ "$RC" = 125 ] && ok || bad "3g a host that refused the run dir exited $RC (want 125)"

# ── 4. the upload ───────────────────────────────────────────────────────────
# -rlptD, not -a: `-a` carries ownership, and a root-owned tree under a suite
# that isolates HOME makes git refuse the repo ("dubious ownership"), which
# reads as a broken branch rather than a broken upload.
reset; : > "$FIX/proxy-up"
run "$T/wt" -- true
grep -q -- "-rlptD" "$FIX/rsync-calls" 2>/dev/null && ok || bad "4a the upload did not use -rlptD: $(cat "$FIX/rsync-calls" 2>/dev/null)"
grep -q -- "--delete" "$FIX/rsync-calls" 2>/dev/null && ok || bad "4b the upload was not --delete (a stale file from the last run survives)"

# ── 5. -- mode: the job runs the command, and the exit is the command's ─────
reset; : > "$FIX/proxy-up"; echo 7 > "$FIX/job-rc"
run "$T/wt" -- bin/checks-run.sh --tree .
[ "$RC" = 7 ] && ok || bad "5a -- mode exited $RC, not the command's 7"
grep -q "checks-run.sh" "$FIX/job" 2>/dev/null && ok || bad "5b the job does not carry the command: $(cat "$FIX/job" 2>/dev/null | head -5)"
grep -q "HARNESS_TEST_SANDBOX=1" "$FIX/job" 2>/dev/null && ok || bad "5c the job does not set HARNESS_TEST_SANDBOX=1 (scratch.sh refuses to run as root without it)"
grep -q "git init" "$FIX/job" 2>/dev/null && ok || bad "5d the job does not snapshot the upload as a git repo (check-attr and git archive suites need one)"

# ── 6. suites mode: the captured job really runs suites ─────────────────────
# The job is executed here against three fixture suites: one green, one red,
# one that is not on this branch at all.
reset; : > "$FIX/proxy-up"; echo 0 > "$FIX/job-rc"
run "$T/wt" tests/pass.sh tests/red.sh tests/gone.sh
[ -s "$FIX/job" ] && ok || bad "6a no job was composed"

mkdir -p "$T/run/base/tests"
printf '#!/bin/bash\nexit 0\n' > "$T/run/base/tests/pass.sh"
printf '#!/bin/bash\nexit 3\n' > "$T/run/base/tests/red.sh"
JOUT=$(env RG_RUN_DIR="$T/run" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$FIX/job" 2>&1); JRC=$?
[ "$JRC" = 2 ] && ok || bad "6b the job exited $JRC for 1 green + 2 broken suites (exit = failing suites): $JOUT"
case "$JOUT" in *"tests/red.sh"*) ok ;; *) bad "6c the failing suite was not named: $JOUT" ;; esac
case "$JOUT" in *"2 failing"*) ok ;; *) bad "6d the job printed no failing count: $JOUT" ;; esac
case "$JOUT" in *"not on this branch"*) ok ;; *) bad "6e rc 127 was not explained as a suite missing from this branch: $JOUT" ;; esac

# ── 7. a green run is green, and --full still prints the passing suites ─────
reset; : > "$FIX/proxy-up"
run "$T/wt" tests/pass.sh
mkdir -p "$T/run2/base/tests"; printf '#!/bin/bash\nexit 0\n' > "$T/run2/base/tests/pass.sh"
JOUT=$(env RG_RUN_DIR="$T/run2" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$FIX/job" 2>&1); JRC=$?
[ "$JRC" = 0 ] && ok || bad "7a a green suite exited $JRC: $JOUT"

reset; : > "$FIX/proxy-up"
run --full "$T/wt" tests/pass.sh
mkdir -p "$T/run3/base/tests"; printf '#!/bin/bash\necho hello-from-the-suite\nexit 0\n' > "$T/run3/base/tests/pass.sh"
JOUT=$(env RG_RUN_DIR="$T/run3" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$FIX/job" 2>&1); JRC=$?
[ "$JRC" = 0 ] && ok || bad "7b --full turned a green run red ($JRC)"
case "$JOUT" in *hello-from-the-suite*) ok ;; *) bad "7c --full printed no log for a passing suite: $JOUT" ;; esac

# ── 9. a finished suite's copy goes back immediately ───────────────────────
# The prototype kept every per-suite copy of the tree until the whole run
# ended. On 516 suites that filled the host, later suites failed on ENOSPC and
# their logs were gone by the time the summary read them: 433 "failures" that
# were the runner, not the branch. Run sequentially, the second suite must see
# exactly one copy — its own.
reset; : > "$FIX/proxy-up"
run -P 1 "$T/wt" tests/look.sh tests/look.sh
mkdir -p "$T/run4/base/tests"
{ echo '#!/bin/bash'
  printf 'ls -d ../run-* 2>/dev/null | wc -l | tr -d " " > %s/seen-$(basename "$PWD")\n' "$T"
  echo 'exit 0'; } > "$T/run4/base/tests/look.sh"
env RG_RUN_DIR="$T/run4" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$FIX/job" >/dev/null 2>&1
[ "$(cat "$T/seen-run-2" 2>/dev/null)" = 1 ] && ok \
  || bad "9 the second suite saw $(cat "$T/seen-run-2" 2>/dev/null) copies of the tree — a finished suite's copy is not being removed"

# ── 10. a runner failure is not a red branch ───────────────────────────────
# The host filling up is the shape this section exists for. With no `base` to
# copy, every worker's `cp -a` fails: the run must come back as a RUNNER
# FAILURE and exit 125, never as "3 suites, 3 failing" — which is what the
# first whole-corpus run on a full disk actually printed.
reset; : > "$FIX/proxy-up"
run "$T/wt" tests/a.sh tests/b.sh tests/c.sh
mkdir -p "$T/run6"          # deliberately no run6/base
JOUT=$(env RG_RUN_DIR="$T/run6" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$FIX/job" 2>&1); JRC=$?
[ "$JRC" = 125 ] && ok || bad "10a a run whose copies all failed exited $JRC (want 125): $JOUT"
case "$JOUT" in *"RUNNER FAILURE"*) ok ;; *) bad "10b the runner failure was not named: $JOUT" ;; esac
case "$JOUT" in *"3 suites, 3 failing"*) bad "10c a runner failure was reported as three red suites" ;; *) ok ;; esac
case "$JOUT" in *"says nothing about the branch"*) ok ;; *) bad "10d the run did not say the result is not about the branch: $JOUT" ;; esac

# ── 11. an unrecorded run says so loudly ───────────────────────────────────
# A gate run the idle-stop lane cannot see is the thing that gets a host
# stopped under a drain. On a Mac (no worker credential) that is the normal
# case, so the line has to be impossible to miss rather than one sed-prefixed
# line among the tick's own output.
# The lane comes OFF for this one case so the real tick runs: with no worker
# reachable from the scratch harness its stamp fails, which is exactly the Mac
# case. It is put back afterwards.
reset; : > "$FIX/proxy-up"; rm -f "$T/h/flags/lane-off-testhost-tick"
run "$T/wt" -- true
: > "$T/h/flags/lane-off-testhost-tick"
case "$OUT" in *WARNING*"NOT recorded"*) ok ;; *) bad "11 an unrecorded run printed no warning: $OUT" ;; esac

# ── 12. runs go on the host's tmpfs ────────────────────────────────────────
# / on that machine is 7.8 GB and shared with everything else; /srv/tmp is
# where the gate's prep job mounts a tmpfs (#1597 — it was never provisioned
# before). Twelve ~50 MB copies of the tree do not fit on the former when
# eight agents are draining, and the failure lands inside the job.
reset; : > "$FIX/proxy-up"
run "$T/wt" -- true
grep -q "/srv/tmp/runs/" "$FIX/rsync-calls" 2>/dev/null && ok \
  || bad "12 the upload did not target the tmpfs run root: $(cat "$FIX/rsync-calls" 2>/dev/null)"

# ── 8. no session scratchpad ────────────────────────────────────────────────
# The prototype kept its key, its proxy log and its job files in one agent
# session's scratchpad. A gate that only works inside the session that built it
# is not in the repo.
# A PATH into one, not the word: the header explains why the prototype's
# scratchpad had to go, and that sentence is not the bug.
grep -qE '/private/tmp/claude-[0-9]|scratchpad/' "$GATE" && bad "8 bin/remote-gate.sh still points at a session scratchpad" || ok

echo "remote-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
