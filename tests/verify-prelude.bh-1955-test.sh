#!/bin/bash
# tests/verify-prelude.bh-1955-test.sh — HARNESS-VERIFY's npm arm runs the repo's
# build prelude before the suite, records which one ran, and evidence.md says so.
#
# THE DEFECT THIS PINS (BH-1955 item 18). HARNESS_SUITE_RUN ran `npm run
# test:unit` on a fresh checkout of a prisma repo with no `prisma generate`, so a
# suite that imports the generated client was red for a reason no diff caused,
# and nothing in the record said a prelude was even considered.
#
# The block is lifted VERBATIM from bin/run-build.sh by its markers (the way
# head-bound-approval-test does), run in a scratch repo with `npx` and `npm`
# stubs that append their argv to ONE order log. bin/evidence-summary.sh is the
# real script over the build dir that run wrote.
#
# No network, nothing written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

mkdir -p "$T/fakebin" "$T/h/bin"
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/order.log"
echo "npx stub output"
exit \${NPX_RC:-0}
EOF
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/order.log"
echo "npm stub output"
exit 0
EOF
chmod +x "$T/fakebin/npx" "$T/fakebin/npm"

REPO="$T/repo"; BUILD="$T/build"
suite() { # suite [prisma|prisma-dir|none] -> runs HARNESS_SUITE_RUN lenses in a fresh repo
  scratch_rm "$REPO"; scratch_rm "$BUILD"; mkdir -p "$REPO" "$BUILD"; : > "$T/order.log"
  printf '{"scripts":{"test:unit":"vitest run"}}\n' > "$REPO/package.json"
  case "$1" in
    prisma)     mkdir -p "$REPO/prisma"; echo 'generator client {}' > "$REPO/prisma/schema.prisma" ;;
    prisma-dir) mkdir -p "$REPO/prisma/schema"; echo 'model A {}' > "$REPO/prisma/schema/a.prisma" ;;
  esac
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD PROJECT=p KEY=K-1 TEST_SELECT=0
    STAMP() { date -u +%FT%TZ; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
}
ev() { bash "$DIR/bin/evidence-summary.sh" "$BUILD" 2>/dev/null; }

# P1 — a prisma schema: generate runs first, then the suite.
suite prisma
[ "$(sed -n 1p "$T/order.log")" = "prisma generate" ] && ok || bad "P1: line 1 of the order must be 'prisma generate', got: $(cat "$T/order.log")"
[ "$(sed -n 2p "$T/order.log")" = "run test:unit" ]   && ok || bad "P1: line 2 must be the suite, got: $(cat "$T/order.log")"
[ "$(grep -c . "$T/order.log")" = 2 ] && ok || bad "P1: exactly two commands must run, got: $(cat "$T/order.log")"
# P2 — the record names it, and evidence.md renders it.
grep -qx 'HARNESS_PRELUDE: npx prisma generate (rc=0)' "$BUILD/harness-suite.txt" && ok || bad "P2: harness-suite.txt must carry the prelude line: $(cat "$BUILD/harness-suite.txt")"
grep -qx 'HARNESS_EXIT: 0' "$BUILD/harness-suite.txt" && ok || bad "P2: the suite's own exit must still be recorded"
grep -q 'prelude: npx prisma generate (rc=0)' "$BUILD/pipeline.log" && ok || bad "P2: pipeline.log must name the prelude: $(cat "$BUILD/pipeline.log")"
OUT=$(ev)
grep -qF '| repo suite prelude, run by the harness | `npx prisma generate (rc=0)` |' <<<"$OUT" && ok || bad "P2: evidence.md must render the prelude row: $OUT"
# A failed generate is evidence, never a stop and never a green.
NPX_RC=1 suite prisma
grep -qx 'HARNESS_PRELUDE: npx prisma generate (rc=1)' "$BUILD/harness-suite.txt" && ok || bad "P2: a failed generate must be recorded as rc=1: $(cat "$BUILD/harness-suite.txt")"
grep -qx 'run test:unit' "$T/order.log" && ok || bad "P2: the suite must still run after a failed generate: $(cat "$T/order.log")"
# The multi-file schema directory counts too.
suite prisma-dir
[ "$(sed -n 1p "$T/order.log")" = "prisma generate" ] && ok || bad "P1: a prisma/schema/ directory must also get generate first: $(cat "$T/order.log")"
# P3 — no prisma: the suite alone, and the record says none.
suite none
[ "$(cat "$T/order.log")" = "run test:unit" ] && ok || bad "P3: with no prisma schema only the suite runs, got: $(cat "$T/order.log")"
grep -qx 'HARNESS_PRELUDE: none (no prisma schema)' "$BUILD/harness-suite.txt" && ok || bad "P3: the record must say no prelude ran: $(cat "$BUILD/harness-suite.txt")"
# P4 — a legacy record with no prelude line renders no prelude row.
scratch_rm "$BUILD"; mkdir -p "$BUILD"
printf 'HARNESS_SUITE: full — npm run test\nok\nHARNESS_EXIT: 0\n' > "$BUILD/harness-suite.txt"
OUT=$(ev)
grep -q 'HARNESS_EXIT: 0' <<<"$OUT" && ok || bad "P4: evidence.md must still render the suite row: $OUT"
grep -q 'suite prelude' <<<"$OUT" && bad "P4: a legacy record must render no prelude row" || ok

echo "verify-prelude.bh-1955: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
