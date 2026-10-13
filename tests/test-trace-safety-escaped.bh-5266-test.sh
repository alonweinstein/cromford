#!/bin/bash
# tests/test-trace-safety-escaped.bh-5266-test.sh — bin/test-trace-safety.sh
# must read a redirect inside a `%q`-escaped eval payload the way the inner
# shell will, and must treat `declare`/`typeset`/`local NAME="(…)"` as the
# re-parse it is.
#
# WHY (BH-5266). Batch #5259 went red on three hits from #5059, whose test did
# `CMD=$(printf '%q ' …); eval "set -- $CMD"`. xtrace prints that as
#   + eval 'set -- stat\ -c\ %Y\ /run/x\ 2\>/dev/null\ \|\|\ echo\ 0'
# and the redirect rule read the target as `/dev/null\` (the escaping backslash
# kept, the escaped space ending it), which is not a safe device. The author
# could have dodged the gate with `declare -a ARGV="($CMD)"`, which re-parses
# the string exactly as eval does but was not an interpreter to the gate.
#
# Every fixture is a heredoc under $T, and every target that must be a HIT is
# under /dev/null/no-such-harness, which cannot exist because /dev/null is not
# a directory. Each case is its own tree so its hit count is exact.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/test-trace-safety.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

# case <name>: reads the fixture body on stdin, writes it as the tree's only
# test, runs the real gate over it, and leaves OUT, RC and HITS (the number of
# HIT lines) behind.
case_run() {
  mkdir -p "$T/$1/tests"
  { printf '#!/bin/bash\nset -uo pipefail\n'; cat; printf 'exit 0\n'; } > "$T/$1/tests/$1-test.sh"
  OUT=$("$RUN" "$T/$1" 2>&1); RC=$?
  HITS=$(printf '%s\n' "$OUT" | grep -c '^HIT ')
}

CLEAN='TRACE: 1 tests, 0 nonzero exit(s), 0 hit(s)'

# ── E. the %q eval payload ──────────────────────────────────────────────────
case_run e1 <<'FIXEOF'
CMD=$(printf '%q' 'stat -c %Y /run/harness/heartbeat 2>/dev/null || echo 0')
eval "set -- $CMD"
FIXEOF
{ [ "$RC" -eq 0 ] && [ "$HITS" -eq 0 ] && has "$CLEAN" "$OUT"; } && ok \
  || bad "E1: an escaped 2\\>/dev/null\\ inside eval must resolve to /dev/null and be clean (rc=$RC) [$OUT]"

case_run e2 <<'FIXEOF'
eval ': > /dev/null/no-such-harness/out' 2>/dev/null
FIXEOF
{ [ "$RC" -eq 1 ] && [ "$HITS" -eq 1 ] && has "HIT e2-test.sh redirect /dev/null/no-such-harness/out " "$OUT"; } && ok \
  || bad "E2: a real redirect inside eval must stay exactly one hit (rc=$RC hits=$HITS) [$OUT]"

case_run e3 <<'FIXEOF'
CMD=$(printf '%q' 'echo x 2>/dev/null/no-such-harness/out || true')
eval "set -- $CMD"
FIXEOF
{ [ "$RC" -eq 1 ] && [ "$HITS" -eq 1 ] && has "HIT e3-test.sh redirect /dev/null/no-such-harness/out " "$OUT"; } && ok \
  || bad "E3: unescaping must resolve an unsafe escaped target, not excuse it (rc=$RC hits=$HITS) [$OUT]"

# The #5059 shape exactly: one %q per word, joined with spaces.
case_run e4 <<'FIXEOF'
CMD=$(printf '%q ' stat -c %Y /run/x '2>/dev/null' '||' echo 0)
eval "set -- $CMD"
FIXEOF
{ [ "$RC" -eq 0 ] && [ "$HITS" -eq 0 ] && has "$CLEAN" "$OUT"; } && ok \
  || bad "E4: the #5059 per-word %q eval must be clean (rc=$RC) [$OUT]"

# ── D. declare / typeset / local NAME="(…)" re-parse like eval ──────────────
case_run d1 <<'FIXEOF'
CMD=$(printf '%q' 'stat -c %Y /run/harness/heartbeat 2>/dev/null || echo 0')
declare -a ARGV="($CMD)" 2>/dev/null
FIXEOF
{ [ "$RC" -eq 0 ] && [ "$HITS" -eq 0 ] && has "$CLEAN" "$OUT"; } && ok \
  || bad "D1: declare -a ARGV=\"(\$CMD)\" with a safe escaped payload must be clean (rc=$RC) [$OUT]"

case_run d2 <<'FIXEOF'
declare -a X="(: >/dev/null/no-such-harness/out)" 2>/dev/null
FIXEOF
{ [ "$RC" -eq 1 ] && [ "$HITS" -eq 1 ] && has "HIT d2-test.sh redirect /dev/null/no-such-harness/out " "$OUT"; } && ok \
  || bad "D2: declare -a X=\"(… >unsafe)\" must be one hit (rc=$RC hits=$HITS) [$OUT]"

case_run d3 <<'FIXEOF'
typeset -a X="(: >/dev/null/no-such-harness/out)" 2>/dev/null
FIXEOF
{ [ "$RC" -eq 1 ] && [ "$HITS" -eq 1 ] && has "HIT d3-test.sh redirect /dev/null/no-such-harness/out " "$OUT"; } && ok \
  || bad "D3: typeset -a X=\"(… >unsafe)\" must be one hit (rc=$RC hits=$HITS) [$OUT]"

case_run d4 <<'FIXEOF'
CMD=$(printf '%q' 'stat -c %Y /run/harness/heartbeat 2>/dev/null || echo 0')
f() {
  local -a X="(: >/dev/null/no-such-harness/out)" 2>/dev/null
  local -a Y="($CMD)" 2>/dev/null
}
f
FIXEOF
{ [ "$RC" -eq 1 ] && [ "$HITS" -eq 1 ] && has "HIT d4-test.sh redirect /dev/null/no-such-harness/out " "$OUT"; } && ok \
  || bad "D4: local -a X=\"(… >unsafe)\" must be the one hit, local -a Y=\"(\$CMD)\" none (rc=$RC hits=$HITS) [$OUT]"

# ── N. what must NOT become an interpreter ──────────────────────────────────
case_run n1 <<'FIXEOF'
declare -a W
g() { local msg="see >/root/harness/x"; : "$msg"; }
g
bad() { :; }
bad "declare -a X=(: >/root/harness/y)"
W=('a >/root/x')
FIXEOF
{ [ "$RC" -eq 0 ] && [ "$HITS" -eq 0 ] && has "$CLEAN" "$OUT"; } && ok \
  || bad "N1-N4: a plain declare, a scalar local, a message and a bare array must stay clean (rc=$RC) [$OUT]"

echo "test-trace-safety-escaped: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
