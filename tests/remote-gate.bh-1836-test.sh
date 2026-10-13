#!/bin/bash
# tests/remote-gate.bh-1836-test.sh — the cert reissue in bin/remote-gate.sh
# must not hang the gate (BH-1836).
#
# WHAT HAPPENED. On 2026-09-23 `flyctl ssh issue <org> ~/.fly/testhost-key
# --hours 72 --overwrite` hung: two issuers sat for 37 and 52 minutes and every
# agent's gate stalled behind them. `--overwrite` onto the live key blocks; the
# same issue to a NEW path finishes in seconds. And when the issue failed fast,
# the gate exited 125 even with a cert that still had hours left.
#
# WHAT THIS PINS, every case through the real CLI (`bin/remote-gate.sh <dir> --
# true`) against PATH shims:
#   A  a flyctl that hangs does not hang the gate, and the hung issuer is killed
#   B  the issue goes to a temp dir beside the key, never with --overwrite, with
#      stdin on /dev/null, and the new pair is moved into place (key mode 600)
#   C  a failed issue falls back to a still-valid cert with ONE warning, and is
#      exit 125 only when the cert is missing or expired (by a minute, too)
#   D  concurrent gates issue once; a gate with a valid cert never waits on the
#      lock; a gate with none waits a bounded time
#   E  the timeout knob is validated before anything reaches Fly
#
# Every gate run is under `timeout 40`, so the pre-fix code shows up as a red
# case (rc 124), not as a suite that never ends.
#
# Run from anywhere: tests/remote-gate.bh-1836-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/remote-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/remote-gate.sh does not exist"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "SKIP: no timeout(1) to bound the gate runs"; exit 0; }

FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/wt" "$T/h/flags" "$T/h/logs"
echo "a worktree file" > "$T/wt/file.txt"
echo "not the terminal" > "$FIX/stdin-file"
: > "$T/h/flags/lane-off-testhost-tick"
HOLDERS=()
_cleanup() {
  local p
  for p in $(cat "$FIX/hang-pids" 2>/dev/null) ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  # This trap REPLACES tests/lib/scratch.sh's EXIT trap, so run its cleanup
  # here too or every run leaks its scratch dir (lead review, #1851).
  scratch_cleanup 2>/dev/null || true
  return 0
}
trap _cleanup EXIT

# ── the shims ────────────────────────────────────────────────────────────────
# flyctl ssh issue: the mode is a fixture file. Every call logs its argv and
# what its stdin is, so B1 and B5 read what the gate actually passed.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*|"proxy") : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue")
    readlink /proc/self/fd/0 >> "$FIX/fly-stdin" 2>/dev/null
    shift 2
    # flyctl ssh issue <org> <path> --hours N
    p="$2"; echo "$p" >> "$FIX/fly-paths"
    hang() { echo $$ >> "$FIX/hang-pids"; exec sleep 120; }   # determinism: ok a stub that never answers is the defect under test
    case " $* " in *" --overwrite "*) [ -f "$FIX/hang-on-overwrite" ] && hang ;; esac
    [ -f "$FIX/hang" ] && hang
    [ -f "$FIX/fail" ] && exit 1
    [ -f "$FIX/empty" ] && exit 0
    [ -f "$FIX/slow" ] && sleep 2   # determinism: ok a slow issuer is what makes two gates overlap
    printf 'new-private-key\n' > "$p"; printf 'new-cert\n' > "$p-cert.pub"
    rm -f "$FIX/cert-to"   # the new cert is good until the ssh-keygen default
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
case "$*" in *"bash -s"*) cat > "$FIX/job"; exit 0 ;; esac
exit 0
STUB
cat > "$T/fakebin/ssh-keygen" <<'STUB'
#!/bin/bash
echo "        Valid: from 2026-01-01T00:00:00 to $(cat "$FIX/cert-to" 2>/dev/null || echo 2099-01-01T00:00:00)"
exit 0
STUB
chmod +x "$T/fakebin"/*
export FIX

# gate_env — the command prefix every run uses. Stdin is a real file, not
# /dev/null, so B5 can tell the gate's own redirect from an inherited one.
KNOB_T=3
gate() {
  env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$T/h" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 \
    REMOTE_GATE_CERT_ISSUE_TIMEOUT_S="$KNOB_T" \
    timeout 40 bash "$GATE" "$T/wt" -- true < "$FIX/stdin-file"
}
run() { local s=$SECONDS; OUT=$(gate 2>&1); RC=$?; EL=$((SECONDS - s)); }
reset() {
  rm -f "$FIX"/fly-calls "$FIX"/fly-stdin "$FIX"/fly-paths "$FIX"/job "$FIX"/proxy-up \
    "$FIX"/cert-to "$FIX"/hang-on-overwrite "$FIX"/hang "$FIX"/fail "$FIX"/empty "$FIX"/slow \
    "$T/key" "$T/key-cert.pub" "$T/key.issue.lock"
  KNOB_T=3
}
date_plus() { # date_plus <minutes> — a LOCAL-time stamp in ssh-keygen's format (see remote-gate-test.sh 2e)
  if date -d "$1 minutes" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null; then :   # determinism: ok the expiry under test is relative to now by definition
  else date -v "$1M" '+%Y-%m-%dT%H:%M:%S'; fi                        # determinism: ok same read, BSD date
}
seed_cert() { # seed_cert <minutes left, signed>
  printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"
  date_plus "$1" > "$FIX/cert-to"
}
issues() { [ -f "$FIX/fly-calls" ] || { echo 0; return; }; grep -c '^ssh issue' "$FIX/fly-calls"; }
warns() { printf '%s\n' "$OUT" | grep -c '^remote-gate: WARNING: could not reissue'; }

# ── A. a flyctl that hangs does not hang the gate ───────────────────────────
reset; : > "$FIX/hang-on-overwrite"
run
[ "$RC" != 124 ] && [ "$EL" -lt 20 ] && ok || bad "A1 a flyctl that hangs on --overwrite hung the gate (rc $RC after ${EL}s): $OUT"

reset; : > "$FIX/hang"; seed_cert +60
run
[ "$RC" = 0 ] && [ "$EL" -lt 20 ] && ok || bad "A2 a hung issue with a cert valid 1h gave rc $RC after ${EL}s (want 0 within the bound): $OUT"
case "$OUT" in *WARNING*"timed out"*) ok ;; *) bad "A2b the hung issue did not warn 'timed out': $OUT" ;; esac
[ "$(cat "$T/key")" = key ] && ok || bad "C2 a hung issue changed the key in place"
alive=""
for p in $(cat "$FIX/hang-pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
[ -z "$alive" ] && ok || bad "A3 the hung issuer is still running after the gate returned:$alive"

# ── B. temp dir, no --overwrite, stdin closed, atomic move ──────────────────
reset
run
[ "$RC" = 0 ] && ok || bad "B0 a clean issue with no key gave rc $RC: $OUT"
[ "$(issues)" = 1 ] && ok || bad "B1a want one ssh issue call, got: $(cat "$FIX/fly-calls" 2>/dev/null)"
grep -q -- '--overwrite' "$FIX/fly-calls" 2>/dev/null && bad "B1 the issue passed --overwrite (it blocks): $(cat "$FIX/fly-calls")" || ok
p=$(head -1 "$FIX/fly-paths" 2>/dev/null)
case "$p" in "$T/.testhost-issue."*/*) ok ;; *) bad "B2 flyctl was handed '$p', not a path in a temp dir beside the key" ;; esac
[ "$p" != "$T/key" ] && ok || bad "B2b flyctl was handed the live key path"
[ -n "$p" ] && [ ! -e "$(dirname "$p")" ] && ok || bad "B3 the temp dir '$(dirname "$p")' is still there"
[ "$(cat "$T/key" 2>/dev/null)" = new-private-key ] && [ "$(cat "$T/key-cert.pub" 2>/dev/null)" = new-cert ] \
  && ok || bad "B4 the new key/cert are not in place: key='$(cat "$T/key" 2>/dev/null)' cert='$(cat "$T/key-cert.pub" 2>/dev/null)'"
mode=$(stat -c %a "$T/key" 2>/dev/null || stat -f %Lp "$T/key" 2>/dev/null)
[ "$mode" = 600 ] && ok || bad "B4b the key is mode '$mode', not 600"
[ "$(cat "$FIX/fly-stdin" 2>/dev/null)" = /dev/null ] && ok || bad "B5 flyctl's stdin was '$(cat "$FIX/fly-stdin" 2>/dev/null)', not /dev/null"

# ── C. fall back to a still-valid cert; 125 only when it has expired ────────
reset; : > "$FIX/fail"; seed_cert +60
run
[ "$RC" = 0 ] && ok || bad "C1 a failed issue with a cert valid 1h gave rc $RC (want 0): $OUT"
[ "$(warns)" = 1 ] && ok || bad "C1b want exactly one WARNING line, got $(warns): $OUT"
case "$OUT" in *"flyctl exited 1"*) ok ;; *) bad "C1c the warning did not say flyctl exited 1: $OUT" ;; esac
[ "$(cat "$T/key")" = key ] && ok || bad "C1d a failed issue changed the key in place"
[ -f "$FIX/job" ] && ok || bad "C1e the gate fell back but sent no job"

reset; : > "$FIX/fail"; seed_cert -60
run
[ "$RC" = 125 ] && ok || bad "C3 a failed issue with a cert expired 1h ago gave rc $RC (want 125): $OUT"
[ -f "$FIX/job" ] && bad "C3b a job was sent with an expired cert" || ok

reset; : > "$FIX/fail"; seed_cert -1
run
[ "$RC" = 125 ] && ok || bad "C3c a cert expired ONE MINUTE ago was used as valid (rc $RC; integer hours read it as 0): $OUT"

reset; : > "$FIX/fail"
run
[ "$RC" = 125 ] && ok || bad "C4 a failed issue with no key gave rc $RC (want 125): $OUT"
case "$OUT" in *fixture-org*) ok ;; *) bad "C4b the 125 did not name the org: $OUT" ;; esac

reset; : > "$FIX/fail"; printf 'key\n' > "$T/key"
run
[ "$RC" = 125 ] && ok || bad "C4c a key with no -cert.pub was used as valid (rc $RC): $OUT"

reset; : > "$FIX/empty"; seed_cert +60
run
[ "$RC" = 0 ] && ok || bad "C5 an issue that wrote nothing, with a valid cert, gave rc $RC (want 0): $OUT"
case "$OUT" in *WARNING*"wrote no key"*) ok ;; *) bad "C5b the warning did not say 'wrote no key': $OUT" ;; esac

# ── D. the lock: one issue for N gates, never a queue ───────────────────────
reset; : > "$FIX/slow"
gate > "$FIX/d1-a.out" 2>&1 & pa=$!
gate > "$FIX/d1-b.out" 2>&1 & pb=$!
wait "$pa"; ra=$?; wait "$pb"; rb=$?
[ "$(issues)" = 1 ] && ok || bad "D1 two concurrent gates issued $(issues) times (want 1): $(cat "$FIX/fly-calls" 2>/dev/null)"
[ "$ra" = 0 ] && [ "$rb" = 0 ] && ok || bad "D1b concurrent gates gave rc $ra and $rb (want 0 0): $(cat "$FIX/d1-a.out" "$FIX/d1-b.out")"

if command -v flock >/dev/null 2>&1; then
  reset; seed_cert +60
  flock "$T/key.issue.lock" sleep 6 & HOLDERS+=($!)   # determinism: ok a lock holder that outlives the gate's fast path
  sleep 1                                              # determinism: ok let the holder take the lock first
  run
  [ "$RC" = 0 ] && [ "$EL" -lt 3 ] && ok || bad "D2 a valid cert with the lock held gave rc $RC after ${EL}s (want 0 in <3s, no wait): $OUT"
  [ "$(issues)" = 0 ] && ok || bad "D2b the gate issued while another held the lock"

  reset; KNOB_T=2
  flock "$T/key.issue.lock" sleep 60 & HOLDERS+=($!)  # determinism: ok a wedged issuer holding the lock
  sleep 1                                              # determinism: ok let the holder take the lock first
  run
  [ "$RC" = 125 ] && [ "$EL" -lt 25 ] && ok || bad "D3 no cert with the lock wedged gave rc $RC after ${EL}s (want 125 in <25s): $OUT"
  kill "${HOLDERS[@]}" 2>/dev/null
else
  echo "note: flock is not on PATH here; D2/D3 not run"
fi

# ── E. the knob is validated before anything reaches Fly ────────────────────
reset; KNOB_T=abc
run
[ "$RC" = 125 ] && ok || bad "E1 REMOTE_GATE_CERT_ISSUE_TIMEOUT_S=abc gave rc $RC (want 125): $OUT"
case "$OUT" in *REMOTE_GATE_CERT_ISSUE_TIMEOUT_S*) ok ;; *) bad "E1b the 125 did not name the knob: $OUT" ;; esac
[ "$(issues)" = 0 ] && ok || bad "E1c an invalid knob still called ssh issue"

echo "remote-gate.bh-1836: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
