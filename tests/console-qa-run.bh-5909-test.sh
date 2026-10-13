#!/bin/bash
# tests/console-qa-run.bh-5909-test.sh — bin/console-qa-run.mjs, the browser
# QA driver of a console preview (BH-5909 slice 1), the parts a test can reach
# without a browser:
#
#   R1  the widths are 1440 and 390
#   R2  consoleFailures adds horizontal body scroll at 390, keeps qa-drive's
#       verdicts, and says nothing about a clean record
#   R3  no QA session token: QA COVERAGE screens=0 and QA: FAIL, exit 1, and no
#       browser is started
#   R4  importing bin/qa-drive.mjs does not run ITS main(): the file is not
#       named *qa-drive.mjs (that guard keys on the argv name)
#   R5  a token never reaches the output
#
# Run: bash tests/console-qa-run.bh-5909-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
[ -f "$DIR/bin/console-qa-run.mjs" ] || { echo "FAIL: bin/console-qa-run.mjs does not exist"; exit 1; }

cat > "$T/unit.mjs" <<UNIT
import { VIEWPORTS, consoleFailures } from "$DIR/bin/console-qa-run.mjs";
const base = { path: "/", url: null, status: 200, landedOnAuthWall: false, consoleErrors: [], failedRequests: [], horizontalScroll: false, nativeDialog: null, shot: "x.png", error: null };
console.log("widths=" + VIEWPORTS.map((v) => v.name + ":" + v.width).join(","));
console.log("clean=" + consoleFailures({ ...base, viewport: "390" }).length);
console.log("scroll390=" + consoleFailures({ ...base, viewport: "390", horizontalScroll: true }).join("|"));
console.log("scroll1440=" + consoleFailures({ ...base, viewport: "1440", horizontalScroll: true }).length);
console.log("http=" + consoleFailures({ ...base, viewport: "1440", status: 500 }).join("|"));
UNIT
OUT=$(node "$T/unit.mjs" 2>&1)
grep -qx 'widths=1440:1440,390:390' <<<"$OUT" && ok || bad "R1 widths: $OUT"
grep -qx 'clean=0' <<<"$OUT" && ok || bad "R2 a clean record has no failure: $OUT"
grep -qx 'scroll390=/@390: horizontal body scroll' <<<"$OUT" && ok || bad "R2 scroll at 390 fails: $OUT"
grep -qx 'scroll1440=0' <<<"$OUT" && ok || bad "R2 scroll at 1440 is not judged: $OUT"
grep -qx 'http=/@1440: HTTP 500' <<<"$OUT" && ok || bad "R2 qa-drive's verdicts stay: $OUT"

mkdir -p "$T/out"
RC=0; OUT=$(env -u CONSOLE_QA_TOKEN node "$DIR/bin/console-qa-run.mjs" https://x.example.invalid "$DIR" "$T/out" / 2>&1) || RC=$?
[ "$RC" = 1 ] && ok || bad "R3 no token exits 1, got $RC"
[ "$(tail -2 <<<"$OUT" | head -1)" = 'QA COVERAGE: screens=0 flows=0 shots=0' ] && [ "$(tail -1 <<<"$OUT")" = 'QA: FAIL' ] && ok || bad "R3 the report: $OUT"
grep -q 'not a QA session token' <<<"$OUT" && ok || bad "R3 the reason: $OUT"
grep -qiE 'clerk|QA_TEST_USER_ID|usage: qa-drive' <<<"$OUT" && bad "R4 qa-drive's main ran on import: $OUT" || ok

RC=0; OUT=$(CONSOLE_QA_TOKEN=not-a-token-fixture node "$DIR/bin/console-qa-run.mjs" https://x.example.invalid "$DIR" "$T/out" / 2>&1) || RC=$?
grep -q 'not-a-token-fixture' <<<"$OUT" && bad "R5 the token reached the output: $OUT" || ok
grep -q 'not-a-token-fixture' "$T/out/observed.json" && bad "R5 the token reached observed.json" || ok

echo "console-qa-run.bh-5909: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
