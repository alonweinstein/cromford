#!/bin/bash
# tests/hub-lanes-render-test.sh — the hub-lanes marker pass in render-crontab.sh.
#
# WHY THIS EXISTS. The hub's orchestration lanes must only fire on the box that
# currently holds the hub lease, and the ticket's rule is "rendered, not
# hand-edited": the `/root/harness/bin/hub-lease.sh check && ` prefix is produced
# by the renderer, so a re-render can never silently drop it. That makes three
# things load-bearing, and every row below drives the real
# bin/render-crontab.sh to pin one of them:
#
#   a. the prefix lands on every schedule line inside a
#      `# BEGIN hub-lanes` / `# END hub-lanes` pair and on nothing else, on BOTH
#      renderer code paths (the no-projects shortcut the hub takes, and the
#      normal path after the fleet-blocks splice);
#   b. render(render(x)) == render(x) — the checked-in file IS the render, so an
#      already-prefixed line is left alone;
#   c. a line the pass cannot gate is FATAL with EMPTY stdout. A half-applied
#      marker is the bug class this renderer already refuses for fleet-managed:
#      a swallowed remainder is a lost @reboot line, and output that still looks
#      plausible is exactly what no drift guard can catch.
#
# Comparisons are `cmp` between FILES, never `$(...)` captures: command
# substitution eats trailing newlines, and "byte-for-byte" that cannot see the
# last byte is not byte-for-byte.
#
# Run from anywhere: bash tests/hub-lanes-render-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RENDER="$DIR/bin/render-crontab.sh"
FIX="$DIR/tests/fixtures/hub-lanes"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$RENDER" ] || { echo "FAIL: bin/render-crontab.sh missing or not executable"; exit 1; }

# The lines between each BEGIN/END pair, markers excluded. Used to compare the
# gated content of a render against the expected fixture when the rest of the
# file legitimately differs (S7b splices a fleet block in).
inblock_lines() {
  awk '/^# END hub-lanes/ { inb = 0 } inb { print } /^# BEGIN hub-lanes/ { inb = 1 }' "$1"
}

# ---------------------------------------------------------------------------
# fixture roots: one box with no projects (the hub's own shape), one that owns
# a project (so the fleet splice runs and the hub-lanes pass sees its output)
# ---------------------------------------------------------------------------
mkdir -p "$T/none" "$T/owns/prompts"
cat > "$T/none/fleet.conf" <<'EOF'
# fixture registry — nothing points at hubx, so hubx owns no projects
alpha-os  Acme/alpha-os  https://alpha.example  /api/board  2 box-other
EOF
cat > "$T/owns/fleet.conf" <<'EOF'
# fixture registry — hubx owns alpha-os
alpha-os  Acme/alpha-os  https://alpha.example  /api/board  2 box-hubx
EOF
: > "$T/owns/prompts/product-alpha-os.md"

# ---------------------------------------------------------------------------
# S7 — the marker fixture renders to hub-out.cron, byte for byte
# ---------------------------------------------------------------------------
"$RENDER" --root "$T/none" --base "$FIX/hub-in.cron" hubx > "$T/s7.out" 2>"$T/s7.err"
S7_RC=$?
[ "$S7_RC" = 0 ] && ok || bad "S7: render exited $S7_RC: $(cat "$T/s7.err")"
cmp -s "$T/s7.out" "$FIX/hub-out.cron" && ok \
  || bad "S7: hub-in.cron did not render to hub-out.cron: $(diff "$FIX/hub-out.cron" "$T/s7.out")"

# S7 idempotence — the render of the render is itself. This is what lets the
# checked-in cron file BE the rendered artifact.
"$RENDER" --root "$T/none" --base "$FIX/hub-out.cron" hubx > "$T/s7i.out" 2>"$T/s7i.err"
S7I_RC=$?
[ "$S7I_RC" = 0 ] && ok || bad "S7: idempotent render exited $S7I_RC: $(cat "$T/s7i.err")"
cmp -s "$T/s7i.out" "$FIX/hub-out.cron" && ok \
  || bad "S7: render(hub-out) != hub-out: $(diff "$FIX/hub-out.cron" "$T/s7i.out")"

# ---------------------------------------------------------------------------
# S7b — a box that owns a project gets BOTH the fleet block and the prefixes
# ---------------------------------------------------------------------------
"$RENDER" --root "$T/owns" --base "$FIX/hub-in.cron" hubx > "$T/s7b.out" 2>"$T/s7b.err"
S7B_RC=$?
[ "$S7B_RC" = 0 ] && ok || bad "S7b: render exited $S7B_RC: $(cat "$T/s7b.err")"
grep -q '^# BEGIN fleet-managed project=alpha-os$' "$T/s7b.out" && ok \
  || bad "S7b: no fleet-managed block for alpha-os in the render"
inblock_lines "$T/s7b.out"        > "$T/s7b.gated"
inblock_lines "$FIX/hub-out.cron" > "$T/s7b.want"
cmp -s "$T/s7b.gated" "$T/s7b.want" && ok \
  || bad "S7b: gated lines differ on the normal path: $(diff "$T/s7b.want" "$T/s7b.gated")"
# and the fleet block itself must land OUTSIDE the markers, ungated
grep -q 'hub-lease.sh check && /root/harness/bin/run-triage.sh' "$T/s7b.out" \
  && bad "S7b: the generated fleet block was gated by the hub-lanes pass" || ok

# ---------------------------------------------------------------------------
# S10 — refusals. Non-zero exit, EMPTY stdout, stderr naming the line.
# ---------------------------------------------------------------------------
REFUSE_RC=0
refuses() { # <fixture> <label>
  local fx="$1" label="$2"
  "$RENDER" --root "$T/none" --base "$FIX/$fx" hubx > "$T/$label.out" 2>"$T/$label.err"
  REFUSE_RC=$?
  [ "$REFUSE_RC" != 0 ] && ok || bad "S10/$label: must exit non-zero, got 0"
  [ ! -s "$T/$label.out" ] && ok || bad "S10/$label: stdout must be empty, got $(wc -c < "$T/$label.out") bytes"
  grep -Eq 'line [0-9]+' "$T/$label.err" && ok \
    || bad "S10/$label: stderr must name the offending line: $(cat "$T/$label.err")"
}

refuses error-dangling-begin.cron  dangling ; RC_DANGLING=$REFUSE_RC
refuses error-end-no-begin.cron    endnobegin ; RC_ENDNOBEGIN=$REFUSE_RC
refuses error-nested-begin.cron    nested ; RC_NESTED=$REFUSE_RC
refuses error-bad-line-shebang.cron shellvar
refuses error-bad-line-reboot.cron  reboot
# A bare command is FATAL too. With a first-field pattern loose enough to accept
# one, a six-word command matches "five fields + a command" and the prefix is
# spliced into the MIDDLE of it — a half-applied marker that still exits 0.
refuses error-bare-command.cron     barecmd

# distinct exit codes, so a caller can tell the three marker-balance faults apart
[ "$RC_DANGLING" != "$RC_ENDNOBEGIN" ] && [ "$RC_DANGLING" != "$RC_NESTED" ] \
  && [ "$RC_ENDNOBEGIN" != "$RC_NESTED" ] && ok \
  || bad "S10: marker-balance faults must have distinct exit codes, got dangling=$RC_DANGLING end-no-begin=$RC_ENDNOBEGIN nested=$RC_NESTED"

# ---------------------------------------------------------------------------
# S12 — a marker-free file is a byte-for-byte no-op
# ---------------------------------------------------------------------------
"$RENDER" --root "$T/none" --base "$FIX/plain.cron" hubx > "$T/s12.out" 2>"$T/s12.err"
S12_RC=$?
[ "$S12_RC" = 0 ] && ok || bad "S12: render exited $S12_RC: $(cat "$T/s12.err")"
cmp -s "$T/s12.out" "$FIX/plain.cron" && ok \
  || bad "S12: marker-free file changed: $(diff "$FIX/plain.cron" "$T/s12.out")"

# ---------------------------------------------------------------------------
# CRLF — the prefix goes after the schedule fields and the \r stays LAST
# ---------------------------------------------------------------------------
"$RENDER" --root "$T/none" --base "$FIX/crlf-in.cron" hubx > "$T/crlf.out" 2>"$T/crlf.err"
CRLF_RC=$?
[ "$CRLF_RC" = 0 ] && ok || bad "CRLF: render exited $CRLF_RC: $(cat "$T/crlf.err")"
cmp -s "$T/crlf.out" "$FIX/crlf-out.cron" && ok \
  || bad "CRLF: CRLF block did not render to crlf-out.cron: $(diff "$FIX/crlf-out.cron" "$T/crlf.out" | cat -A)"

# ---------------------------------------------------------------------------
# the documented help text actually mentions the marker (D7: run it as shipped)
# ---------------------------------------------------------------------------
"$RENDER" -h > "$T/help.out" 2>"$T/help.err"
H_RC=$?
[ "$H_RC" = 0 ] && ok || bad "help: -h exited $H_RC"
grep -q 'hub-lanes' "$T/help.out" && ok \
  || bad "help: -h says nothing about the hub-lanes marker"
# The paragraph must print WHOLE. -h prints the header by LINE RANGE, so a
# paragraph appended past the end of that range is documented only in a file
# nobody prints — and the shell-parsing caveat is the sentence that stops an
# operator from putting a top-level ';' inside a block.
grep -q 'does not parse shell' "$T/help.out" && ok \
  || bad "help: -h cuts the hub-lanes paragraph before its last sentence"
# ...and the range must stop AT the header, not run on into the code
tail -1 "$T/help.out" | grep -q '^#' && ok \
  || bad "help: -h ran past the header comment block: last line was $(tail -1 "$T/help.out")"

echo "hub-lanes-render-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ] || exit 1
