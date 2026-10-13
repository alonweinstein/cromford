#!/bin/bash
# tests/issue-testhost-cert.bh-5210-test.sh — bin/issue-testhost-cert.sh, the
# one hand entry point for a Fly test-host cert, rides the gate's bounded issue
# path and caps what flyctl prints (BH-5210).
#
# WHAT HAPPENED. 2026-10-05 → 07: a session issued a cert by hand, with
# --overwrite, into a scratch path that already held a non-fly file. flyctl
# looped on "File exists, but isn't a fly.io ed25519 private key" for 44 hours
# into a redirected file, which reached 596 GB and filled the disk (ENOSPC).
# The gate's own issue path was already bounded (BH-1836); the hand path was
# not, because there was no hand path.
#
# WHAT THIS PINS, every case through the real CLI (`bin/issue-testhost-cert.sh`,
# which execs `bin/remote-gate.sh --issue-cert`) against PATH shims:
#   W1-W3  a flyctl that spews, spews ignoring SIGPIPE, or drips forever is
#          stopped within the bound, writes at most 1 MiB anywhere, leaves the
#          pair in use untouched and no temp dir or process behind
#   W1i    the spew is cut by the cap even when the caller started with
#          SIGPIPE ignored (the CI runners do)
#   W4     the same with no cert at all is exit 125
#   W5-W6  a good issue goes to a temp dir, no --overwrite, stdin closed, key
#          600, key moved before the cert
#   W7     a fresh cert issues nothing; --force issues anyway
#   W8     a failed issue keeps the pair and names flyctl's own error in ONE line
#   W9     a bad command line is exit 2 and never reaches Fly
#   W10    the timeout is the gate's settings row (a bad value is 125)
#   W11    no flyctl is exit 125
#   W12    a TERM to the wrapper ends the issue and its group, rc 143
#
# Run from anywhere: tests/issue-testhost-cert.bh-5210-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WRAP="$DIR/bin/issue-testhost-cert.sh"
GATE="$DIR/bin/remote-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$WRAP" ] || { echo "FAIL: bin/issue-testhost-cert.sh does not exist"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "SKIP: no timeout(1) to bound the runs"; exit 0; }

FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/nofly" "$T/wt" "$T/h/flags" "$T/h/logs"
echo "not the terminal" > "$FIX/stdin-file"
: > "$T/h/flags/lane-off-testhost-tick"
BG=""
_cleanup() {
  local p
  for p in $(cat "$FIX/hang-pids" 2>/dev/null) $BG; do kill -KILL "$p" 2>/dev/null; done
  # This trap REPLACES tests/lib/scratch.sh's EXIT trap, so run its cleanup too.
  scratch_cleanup 2>/dev/null || true
  return 0
}
trap _cleanup EXIT

# ── the shims ────────────────────────────────────────────────────────────────
# flyctl ssh issue: the mode is a fixture file. Every call logs its argv, its
# stdin and its pid, so the cases read what the wrapper actually ran.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "ssh issue")
    readlink /proc/self/fd/0 >> "$FIX/fly-stdin" 2>/dev/null
    echo $$ >> "$FIX/hang-pids"
    shift 2
    p="$2"; echo "$p" >> "$FIX/fly-paths"
    mode=$(cat "$FIX/mode" 2>/dev/null)
    case "$mode" in
      spew) while :; do echo "File exists, but isn't a fly.io ed25519 private key"; done ;;
      spew-nopipe) trap '' PIPE; while :; do echo "File exists, but isn't a fly.io ed25519 private key"; done ;;
      drip) while :; do echo drip; sleep 0.2; done ;;   # determinism: ok a flyctl that never stops talking is the defect under test
      fail) echo 'Error: not logged in' >&2; exit 1 ;;
    esac
    printf 'new-private-key\n' > "$p"; printf 'new-cert\n' > "$p-cert.pub"
    rm -f "$FIX/cert-to"   # the new cert is good until the ssh-keygen default
    exit 0 ;;
esac
exit 0
STUB
cat > "$T/fakebin/ssh-keygen" <<'STUB'
#!/bin/bash
echo "        Valid: from 2026-01-01T00:00:00 to $(cat "$FIX/cert-to" 2>/dev/null || echo 2099-01-01T00:00:00)"
exit 0
STUB
# mv logs "<src> <dst>" and then does the real move, so W6 reads the order.
REAL_MV=$(command -v mv)
cat > "$T/fakebin/mv" <<STUB
#!/bin/bash
n=\$#; src=\${@:\$((n-1)):1}; dst=\${@:\$n:1}
echo "\$src \$dst" >> "\$FIX/mv-log"
exec "$REAL_MV" "\$@"
STUB
chmod +x "$T/fakebin"/*
cp "$T/fakebin/ssh-keygen" "$T/fakebin/mv" "$T/nofly/"
export FIX

KNOB_T=3
PATHV="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"
IGN=()   # a launcher prefix: W1i starts the wrapper with SIGPIPE ignored
wrap() { # wrap <args…> — the wrapper as shipped, against the shims
  ${IGN[@]+"${IGN[@]}"} env PATH="$PATHV" HOME="$T" HARNESS="$T/h" TESTHOST_ORG=fixture-org \
    REMOTE_GATE_CERT_ISSUE_TIMEOUT_S="$KNOB_T" \
    timeout 40 bash "$WRAP" --key "$T/key" "$@" < "$FIX/stdin-file"
}
run() { local s=$SECONDS; wrap "$@" > "$FIX/out" 2>&1; RC=$?; EL=$((SECONDS - s)); OUT=$(cat "$FIX/out"); }
reset() {
  local p
  for p in $(cat "$FIX/hang-pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  rm -f "$FIX"/fly-calls "$FIX"/fly-stdin "$FIX"/fly-paths "$FIX"/hang-pids "$FIX"/mode \
    "$FIX"/cert-to "$FIX"/mv-log "$FIX"/out "$T/key" "$T/key-cert.pub" "$T/key.issue.lock"
  rm -rf "$T/key.issue.lock.d"
  KNOB_T=3; PATHV="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"
}
date_plus() { # date_plus <minutes> — a LOCAL-time stamp in ssh-keygen's format
  if date -d "$1 minutes" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null; then :   # determinism: ok the expiry under test is relative to now by definition
  else date -v "$1M" '+%Y-%m-%dT%H:%M:%S'; fi                        # determinism: ok same read, BSD date
}
seed_cert() { # seed_cert <minutes left, signed>
  printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"
  date_plus "$1" > "$FIX/cert-to"
}
issues() { [ -f "$FIX/fly-calls" ] || { echo 0; return; }; grep -c '^ssh issue' "$FIX/fly-calls"; }
warns() { printf '%s\n' "$OUT" | grep -c '^remote-gate: WARNING: could not reissue'; }
# A zombie answers kill -0 until whatever adopted it reaps it; it runs nothing.
alive_stubs() {
  local p a=""
  for p in $(cat "$FIX/hang-pids" 2>/dev/null); do
    kill -0 "$p" 2>/dev/null || continue
    case "$(ps -o stat= -p "$p" 2>/dev/null)" in Z*|'') continue ;; esac
    a="$a $p"
  done
  echo "$a"
}
leftover_tmp() { find "$T" -maxdepth 1 -name '.testhost-issue.*' | head -1; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

# bounded_case <name> <mode> <want warning substring> — W1-W3 share their shape.
bounded_case() {
  local name=$1 want=$3 big
  local kt=$KNOB_T
  reset; KNOB_T=$kt; echo "$2" > "$FIX/mode"; seed_cert +60
  run
  [ "$RC" != 124 ] && [ "$EL" -le $((KNOB_T + 5)) ] && ok || bad "$name a $2 flyctl was not stopped in time (rc $RC after ${EL}s)"
  [ "$RC" = 1 ] && ok || bad "$name a $2 issue with a cert valid 1h gave rc $RC (want 1): $(head -c 2000 "$FIX/out")"
  [ "$(wc -c < "$FIX/out")" -le 1048576 ] && ok || bad "$name the wrapper printed $(wc -c < "$FIX/out") bytes (cap 1 MiB)"
  big=$(find "$T" -type f -size +1024k 2>/dev/null)
  [ -z "$big" ] && ok || bad "$name a file over 1 MiB is left behind: $big"
  [ "$(cat "$T/key")" = key ] && [ "$(cat "$T/key-cert.pub")" = cert ] && ok || bad "$name the pair in use changed"
  [ "$(warns)" = 1 ] && ok || bad "$name want exactly one WARNING line, got $(warns): $(head -c 2000 "$FIX/out")"
  case "$OUT" in *WARNING*"$want"*) ok ;; *) bad "$name the WARNING did not say '$want': $(head -c 2000 "$FIX/out")" ;; esac
  [ -z "$(leftover_tmp)" ] && ok || bad "$name a temp dir is left behind: $(leftover_tmp)"
  [ -s "$FIX/hang-pids" ] && ok || bad "$name the stub never ran"
  sleep 0.3   # determinism: ok a KILLed pid can take a moment to be reaped
  [ -z "$(alive_stubs)" ] && ok || bad "$name the flyctl stub is still running:$(alive_stubs)"
}

# ── W1-W3. a flyctl that will not stop ─────────────────────────────────────
# W1's spew must be cut by the cap itself (SIGPIPE, rc 141), well inside the
# timeout: the watchdog alone would let it write for the whole bound, and the
# temp dir it wrote into is gone by the time anything could measure it.
KNOB_T=6; bounded_case W1 spew "flyctl's output reached the 1024 KiB cap (rc 141)"
[ "$EL" -lt 6 ] && ok || bad "W1x the spew ran ${EL}s, to the timeout: the cap did not stop it"
# W1i: the same, from a caller that started with SIGPIPE IGNORED. An ignored
# disposition survives every exec and bash cannot reset it, so without the
# gate's reset the stub gets EPIPE at the cap and spews to the timeout. That is
# how the CI runners start their steps, and how this PR's first W1 went red
# there (dequeued 2026-10-08) while it was green on every laptop.
if command -v perl >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # perl code, not shell
  IGN=(perl -e '$SIG{PIPE} = "IGNORE"; exec { $ARGV[0] } @ARGV or exit 127')
  KNOB_T=6; bounded_case W1i spew "flyctl's output reached the 1024 KiB cap (rc 141)"
  [ "$EL" -lt 6 ] && ok || bad "W1ix with SIGPIPE ignored the spew ran ${EL}s, to the timeout: the cap did not stop it"
  IGN=()
else
  echo "note: W1i skipped — no perl to start the wrapper with SIGPIPE ignored"
fi
KNOB_T=3; bounded_case W2 spew-nopipe "timed out after 3s"
KNOB_T=3; bounded_case W3 drip "timed out after 3s"
sl=$(pgrep -f 'sleep 0.2' 2>/dev/null | while read -r p; do grep -qs "$T" "/proc/$p/environ" && echo "$p"; done)
[ -z "$sl" ] && ok || bad "W3b the drip stub's sleep outlived the run: $sl"

# ── W4. spew with no cert at all ────────────────────────────────────────────
reset; echo spew > "$FIX/mode"
run
[ "$RC" = 125 ] && ok || bad "W4 a spewing issue with no cert gave rc $RC (want 125): $(head -c 2000 "$FIX/out")"
case "$OUT" in *fixture-org*) ok ;; *) bad "W4b the 125 did not name the org: $OUT" ;; esac
[ ! -e "$T/key" ] && ok || bad "W4c a key appeared at $T/key"
[ "$(wc -c < "$FIX/out")" -le 1048576 ] && ok || bad "W4d the wrapper printed more than 1 MiB"

# ── W5-W6. a good issue ─────────────────────────────────────────────────────
reset
run
[ "$RC" = 0 ] && ok || bad "W5 a good issue with no key gave rc $RC: $OUT"
[ "$(issues)" = 1 ] && ok || bad "W5b want exactly one ssh issue, got $(issues)"
grep -q -- '--overwrite' "$FIX/fly-calls" 2>/dev/null && bad "W5c the issue passed --overwrite: $(cat "$FIX/fly-calls")" || ok
case "$(cat "$FIX/fly-paths" 2>/dev/null)" in "$T"/.testhost-issue.*/key) ok ;; *) bad "W5d flyctl was handed '$(cat "$FIX/fly-paths" 2>/dev/null)', not a temp dir beside the key" ;; esac
[ "$(cat "$T/key" 2>/dev/null)" = new-private-key ] && [ "$(cat "$T/key-cert.pub" 2>/dev/null)" = new-cert ] && ok || bad "W5e the new pair is not in place"
[ "$(mode_of "$T/key")" = 600 ] && ok || bad "W5f the key is mode $(mode_of "$T/key"), want 600"
[ -z "$(leftover_tmp)" ] && ok || bad "W5g a temp dir is left behind"
[ "$(cat "$FIX/fly-stdin" 2>/dev/null)" = /dev/null ] && ok || bad "W5h flyctl's stdin was '$(cat "$FIX/fly-stdin" 2>/dev/null)', want /dev/null"
case "$OUT" in *issued*"$T/key"*) ok ;; *) bad "W5i the wrapper did not say it issued a cert to $T/key: $OUT" ;; esac
moves=$(grep '\.testhost-issue\.' "$FIX/mv-log" 2>/dev/null | awk '{print $2}')
[ "$moves" = "$(printf '%s\n%s' "$T/key" "$T/key-cert.pub")" ] && ok || bad "W6 the moves out of the temp dir were not key then cert: $(cat "$FIX/mv-log" 2>/dev/null)"

# ── W7. fresh cert: nothing issued; --force issues ──────────────────────────
reset; seed_cert +2880
run
[ "$RC" = 0 ] && ok || bad "W7 a fresh cert gave rc $RC: $OUT"
[ "$(issues)" = 0 ] && ok || bad "W7b a fresh cert was reissued anyway"
case "$OUT" in *"nothing issued"*) ok ;; *) bad "W7c the wrapper did not say nothing was issued: $OUT" ;; esac
run --force
[ "$RC" = 0 ] && ok || bad "W7d --force on a fresh cert gave rc $RC: $OUT"
[ "$(issues)" = 1 ] && ok || bad "W7e --force made $(issues) issues, want 1"
[ "$(cat "$T/key")" = new-private-key ] && [ "$(cat "$T/key-cert.pub")" = new-cert ] && ok || bad "W7f --force did not replace the pair"

# ── W8. a failed issue names flyctl's error ─────────────────────────────────
reset; echo fail > "$FIX/mode"; seed_cert +60
run
[ "$RC" = 1 ] && ok || bad "W8 a failed issue with a valid cert gave rc $RC (want 1): $OUT"
[ "$(warns)" = 1 ] && ok || bad "W8b want one WARNING line, got $(warns): $OUT"
w=$(printf '%s\n' "$OUT" | grep '^remote-gate: WARNING: could not reissue')
case "$w" in *"flyctl exited 1"*"not logged in"*) ok ;; *) bad "W8c the WARNING did not carry both 'flyctl exited 1' and flyctl's own line: $w" ;; esac
[ "$(cat "$T/key")" = key ] && [ "$(cat "$T/key-cert.pub")" = cert ] && ok || bad "W8d the pair in use changed"

# ── W9. the command line ────────────────────────────────────────────────────
for a in "--hours abc" "--hours 0" "--bogus"; do
  reset
  # shellcheck disable=SC2086
  run $a
  [ "$RC" = 2 ] && ok || bad "W9 '$a' gave rc $RC (want 2): $OUT"
  [ ! -e "$FIX/fly-calls" ] && ok || bad "W9 '$a' reached flyctl"
done
reset
env PATH="$PATHV" HOME="$T" bash "$WRAP" --key '' > "$FIX/out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "W9 --key '' gave rc $RC (want 2): $(cat "$FIX/out")"
[ ! -e "$FIX/fly-calls" ] && ok || bad "W9 --key '' reached flyctl"
env PATH="$PATHV" HOME="$T" HARNESS="$T/h" TESTHOST_KEY="$T/key" timeout 40 bash "$GATE" --force "$T/wt" -- true > "$FIX/out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "W9 remote-gate.sh --force without --issue-cert gave rc $RC (want 2): $(cat "$FIX/out")"
env PATH="$PATHV" HOME="$T" HARNESS="$T/h" TESTHOST_KEY="$T/key" timeout 40 bash "$GATE" --issue-cert "$T/wt" > "$FIX/out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "W9 remote-gate.sh --issue-cert <dir> gave rc $RC (want 2): $(cat "$FIX/out")"
[ ! -e "$FIX/fly-calls" ] && ok || bad "W9 a remote-gate.sh command-line error reached flyctl"
wrap -h > "$FIX/out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'issue-testhost-cert' "$FIX/out" && ok || bad "W9 -h gave rc $RC: $(cat "$FIX/out")"

# ── W10. the same settings row as the gate ──────────────────────────────────
reset; KNOB_T=abc
run
[ "$RC" = 125 ] && ok || bad "W10 REMOTE_GATE_CERT_ISSUE_TIMEOUT_S=abc gave rc $RC (want 125): $OUT"
case "$OUT" in *REMOTE_GATE_CERT_ISSUE_TIMEOUT_S*) ok ;; *) bad "W10b the 125 did not name the knob: $OUT" ;; esac
[ "$(issues)" = 0 ] && ok || bad "W10c a bad knob still reached flyctl"

# ── W11. no flyctl ──────────────────────────────────────────────────────────
reset; PATHV="$T/nofly:/usr/bin:/bin:/usr/sbin:/sbin"
if env PATH="$PATHV" bash -c 'command -v flyctl' >/dev/null 2>&1; then
  echo "note: W11 skipped — a real flyctl is on the system PATH"
else
  run
  [ "$RC" = 125 ] && ok || bad "W11 no flyctl gave rc $RC (want 125): $OUT"
fi

# ── W12. a TERM to the wrapper ends the issue ───────────────────────────────
reset; echo drip > "$FIX/mode"; seed_cert +60; KNOB_T=30
# No timeout(1) in front here: env execs bash, so $! IS the wrapper, which
# execs the gate. The 30 s knob is the bound if the TERM does nothing.
env PATH="$PATHV" HOME="$T" HARNESS="$T/h" TESTHOST_ORG=fixture-org \
  REMOTE_GATE_CERT_ISSUE_TIMEOUT_S="$KNOB_T" \
  bash "$WRAP" --key "$T/key" < "$FIX/stdin-file" > "$FIX/out" 2>&1 &
BG=$!
for _ in $(seq 1 100); do [ -s "$FIX/hang-pids" ] && break; sleep 0.1; done   # determinism: ok a bounded poll for the stub to start
[ -s "$FIX/hang-pids" ] && ok || bad "W12 the drip stub never started"
s=$SECONDS
kill -TERM "$BG" 2>/dev/null
wait "$BG"; RC=$?; EL=$((SECONDS - s)); BG=""
[ "$RC" = 143 ] && ok || bad "W12b a TERM to the wrapper gave rc $RC (want 143): $(cat "$FIX/out")"
[ "$EL" -le 5 ] && ok || bad "W12c the wrapper took ${EL}s to stop after TERM"
sleep 0.3   # determinism: ok a KILLed pid can take a moment to be reaped
[ -z "$(alive_stubs)" ] && ok || bad "W12d the flyctl stub outlived the TERM:$(alive_stubs)"
[ "$(cat "$T/key")" = key ] && [ "$(cat "$T/key-cert.pub")" = cert ] && ok || bad "W12e the pair in use changed"
[ ! -e "$T/key.issue.lock.d" ] && ok || bad "W12f the mkdir lock is left behind"
[ -z "$(leftover_tmp)" ] && ok || bad "W12g a temp dir is left behind"

echo "issue-testhost-cert (BH-5210): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
