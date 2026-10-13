#!/bin/bash
# tests/board-conformance-report.bh-3947-test.sh — the board-conformance report
# slice (BH-3961, part of BH-3947): change-only alerting and the --file-ticket
# draft in bin/lib/board-conformance/report.sh.
#
# Drives the REAL bin/board-conformance.sh and the real report.sh/common.sh in
# the scratch harness from tests/lib/board-conformance-fixture.sh. Only the
# scratch copy of board.sh is swapped, so bc_probe_board emits the gap items a
# case needs. lane-alert.sh is the fixture's stub (argv -> $CALLS). Fixed
# BC_NOW, no sleep, no network.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/board-conformance-report.bh-3947-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/board-conformance-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

ENTRY="$DIR/bin/board-conformance.sh"
REPORT="$DIR/bin/lib/board-conformance/report.sh"
LIVE_BEFORE=$(ls -la /root/harness/state/board-conformance 2>/dev/null)
export BCT="$T"

run() { OUT=$("$HARNESS/bin/board-conformance.sh" "$@" 2>"$T/err"); RC=$?; }
calls() { if [ -f "$CALLS" ]; then wc -l < "$CALLS"; else echo 0; fi; }
W() { printf '%s' "$HARNESS/state/board-conformance/p1.alerted"; }
# gaps <name...> — the scratch board probe reports each name missing, plus one ok item.
gaps() {
  local b='bc_probe_board() {' n
  for n in "$@"; do b="$b bc_item $n missing \"$n absent\";"; done
  b="$b bc_item x.ok ok n; return 0; }"
  printf '# shellcheck shell=bash\n%s\n' "$b" > "$HARNESS/bin/lib/board-conformance/board.sh"
}

for f in "$ENTRY" "$REPORT"; do
  check "static bash -n $f" 'bash -n "$f"'
  if command -v shellcheck >/dev/null 2>&1; then
    check "static shellcheck $f" 'shellcheck -S error "$f" >/dev/null'
  fi
done
check "D43 no /root/harness in report.sh" '! grep -n /root/harness "$REPORT"'

# --- C-first: a first-ever run with no gaps sends nothing ----------------------
bc_fixture_setup || bad "fixture setup"
gaps
run p1
check "C-first rc 0 (got $RC: $(cat "$T/err"))" '[ "$RC" -eq 0 ]'
check "C-first no alert" '[ "$(calls)" -eq 0 ]'
check "C-first no .alerted content" '[ ! -s "$(W)" ]'

# --- C10a: three gaps -> exactly one warn line for the project -----------------
bc_fixture_setup || bad "fixture setup"
gaps reporter.userId triageVerdict boards.keyPrefix
run p1
check "C10a rc 1 (got $RC: $(cat "$T/err"))" '[ "$RC" -eq 1 ]'
check "C10a one line (got $(calls))" '[ "$(calls)" -eq 1 ]'
L=$(sed -n 1p "$CALLS" 2>/dev/null)
check "C10a id (got: $L)" 'grep -qF -- "--id board-conformance:p1" <<<"$L"'
check "C10a severity warn" 'grep -qF -- "--severity warn" <<<"$L"'
check "C10a lane + count" 'grep -qF "board-conformance p1: 3 contract gaps" <<<"$L"'
check "C10a first run: all new, none cleared" 'grep -qF "(new: boards.keyPrefix, reporter.userId, triageVerdict; cleared: none)" <<<"$L"'
check "C10a names the state file" 'grep -qF "state/board-conformance/p1.json" <<<"$L"'
check "C10a .alerted is the sorted set" '[ "$(cat "$(W)")" = "$(printf "boards.keyPrefix\nreporter.userId\ntriageVerdict")" ]'

# --- C9: the same set again -> nothing -------------------------------------------
run p1
check "C9 same set adds 0 lines (got $(calls))" '[ "$(calls)" -eq 1 ]'
# --- C9-order: the watermark in another order is still the same set ----------------
printf 'triageVerdict\n\nreporter.userId\nboards.keyPrefix\n' > "$(W)"
run p1
check "C9-order reordered watermark adds 0 lines (got $(calls))" '[ "$(calls)" -eq 1 ]'

# --- C10b: one fixed, one added -> one delta line, after a silent resolve ------------
mkdir -p "$HARNESS/state/alerts"
echo '{"count":1,"first_seen":1,"last_seen":1,"resolved_at":0,"severity":"warn"}' > "$HARNESS/state/alerts/board-conformance:p1.json"
gaps reporter.userId boards.keyPrefix internal.version
run p1
check "C10b one new line (got $(calls))" '[ "$(calls)" -eq 2 ]'
L=$(sed -n 2p "$CALLS" 2>/dev/null)
check "C10b delta names both (got: $L)" 'grep -qF "p1: 3 contract gaps (new: internal.version; cleared: triageVerdict)" <<<"$L"'
check "C10b same id + warn" 'grep -qF -- "--id board-conformance:p1 --severity warn" <<<"$L"'
check "C10b-resolve open row silently resolved" "jq -e '.resolved_at>0' \"$HARNESS/state/alerts/board-conformance:p1.json\" >/dev/null"
check "C10b .alerted updated" '[ "$(cat "$(W)")" = "$(printf "boards.keyPrefix\ninternal.version\nreporter.userId")" ]'

# --- C11: gaps gone -> one resolve; again -> nothing ----------------------------------
gaps
run p1
check "C11 rc 0" '[ "$RC" -eq 0 ]'
check "C11 one new line (got $(calls))" '[ "$(calls)" -eq 3 ]'
L=$(sed -n 3p "$CALLS" 2>/dev/null)
check "C11 resolve line (got: $L)" '[ "$L" = "--id board-conformance:p1 --resolve board-conformance p1: board now meets the contract" ]'
check "C11 no 'contract gaps' on resolve (D13)" '! grep -qF "contract gaps" <<<"$L"'
check "C11 .alerted empty" '[ -e "$(W)" ] && [ ! -s "$(W)" ]'
run p1
check "C11 third run 0 lines (got $(calls))" '[ "$(calls)" -eq 3 ]'

# --- C-order: the watermark is written only after lane-alert returns -------------------
bc_fixture_setup || bad "fixture setup"
printf '#!/bin/bash\ncp "$HARNESS/state/board-conformance/p1.alerted" "$BCT/at-send" 2>/dev/null || : > "$BCT/at-send-absent"\nprintf "%%s\\n" "$*" >> "$CALLS"\n' > "$HARNESS/bin/lane-alert.sh"
gaps a.one
run p1
check "C-order first send saw no watermark" '[ -e "$T/at-send-absent" ] && [ ! -e "$T/at-send" ]'
gaps a.two
run p1
check "C-order second send saw the OLD set (got: $(cat "$T/at-send" 2>/dev/null))" '[ "$(cat "$T/at-send" 2>/dev/null)" = a.one ]'
check "C-order watermark is the new set after" '[ "$(cat "$(W)")" = a.two ]'

# --- C-rc: lane-alert's rc is not read -----------------------------------------------
bc_fixture_setup || bad "fixture setup"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$CALLS"\nexit 1\n' > "$HARNESS/bin/lane-alert.sh"
gaps a.one
run p1
check "C-rc entry rc unchanged (got $RC)" '[ "$RC" -eq 1 ]'
check "C-rc one call" '[ "$(calls)" -eq 1 ]'
check "C-rc watermark still written" '[ "$(cat "$(W)" 2>/dev/null)" = a.one ]'

# --- C-failed: a failed probe sends nothing and leaves the watermark ----------------------
bc_fixture_setup || bad "fixture setup"
gaps a.one
run p1
printf '# shellcheck shell=bash\nbc_probe_board() { BC_PROBE_NOTE=down; return 3; }\n' > "$HARNESS/bin/lib/board-conformance/board.sh"
run p1
check "C-failed rc 3" '[ "$RC" -eq 3 ]'
check "C-failed no new call (got $(calls))" '[ "$(calls)" -eq 1 ]'
check "C-failed watermark untouched" '[ "$(cat "$(W)")" = a.one ]'

# --- C-unparseable: a state with no gaps array is not "zero gaps" (D11) -------------------
( . "$REPORT"; HARNESS="$HARNESS" bc_alert_on_change p1 <(echo '{"items":{}}') ) 2>"$T/unp.err"
check "C-unparseable rc 0, no call" '[ "$(calls)" -eq 1 ]'
check "C-unparseable watermark untouched" '[ "$(cat "$(W)")" = a.one ]'
check "C-unparseable says why" 'grep -q "no gaps array" "$T/unp.err"'
( . "$REPORT"; HARNESS="$HARNESS" bc_alert_on_change p1 <(echo '{"gaps":{"k":"a.two"}}') ) 2>/dev/null
check "C-unparseable object gaps: no call" '[ "$(calls)" -eq 1 ]'
check "C-unparseable object gaps: watermark untouched" '[ "$(cat "$(W)")" = a.one ]'

# --- C13: --file-ticket prints the draft and touches nothing ---------------------------
bc_fixture_setup || bad "fixture setup"
gaps reporter.userId triageVerdict
run p1
cp "$CURL_LOG" "$T/curl.before"; cp "$CALLS" "$T/calls.before"
run --file-ticket p1
check "C13 rc 0 (got $RC: $(cat "$T/err"))" '[ "$RC" -eq 0 ]'
check "C13 title" 'grep -qx "# Bring the p1 board to full contract" <<<"$OUT"'
check "C13 count line" 'grep -qF "found 2 gaps against docs/BOARD-API-CONTRACT.md" <<<"$OUT"'
check "C13 reporter.userId bullet" 'grep -qxF -- "- \`reporter.userId\`: missing. reporter.userId absent (docs/BOARD-API-CONTRACT.md, \"### GET /tickets/{id}\")" <<<"$OUT"'
check "C13 triageVerdict bullet" 'grep -qxF -- "- \`triageVerdict\`: missing. triageVerdict absent (docs/BOARD-API-CONTRACT.md, \"### triageVerdict\")" <<<"$OUT"'
check "C13 out-of-scope line" 'grep -qxF "Out of scope: write routes (unverified)." <<<"$OUT"'
check "C13 no ok item" '! grep -q x.ok <<<"$OUT"'
check "C13 no network" 'cmp -s "$CURL_LOG" "$T/curl.before"'
check "C13 no alert" 'cmp -s "$CALLS" "$T/calls.before"'

# --- C13-clean: a probe with no gaps says so, never "0 gaps" (D13) -----------------------
bc_fixture_setup || bad "fixture setup"
gaps
run p1
run --file-ticket p1
check "C13-clean rc 0" '[ "$RC" -eq 0 ]'
check "C13-clean says no gaps" 'grep -qx "No contract gaps in the last probe." <<<"$OUT"'
check "C13-clean no count" '! grep -q "found 0" <<<"$OUT"'

# --- C13-nostate / C13-failed / C-root ------------------------------------------------------
bc_fixture_setup || bad "fixture setup"
run --file-ticket p1
check "C13-nostate rc 2 (got $RC)" '[ "$RC" -eq 2 ]'
check "C13-nostate message" 'grep -q "run the probe first" "$T/err"'
check "C13-nostate stdout empty" '[ -z "$OUT" ]'
printf '# shellcheck shell=bash\nbc_probe_board() { BC_PROBE_NOTE=down; return 3; }\n' > "$HARNESS/bin/lib/board-conformance/board.sh"
run p1
run --file-ticket p1
check "C13-failed rc 2 (got $RC)" '[ "$RC" -eq 2 ]'
check "C13-failed message" 'grep -qF "The last probe failed (down); re-run it before filing." "$T/err"'
check "C13-failed no draft" '! grep -q "Bring the" <<<"$OUT"'
echo 'not json' > "$HARNESS/state/board-conformance/p1.json"
run --file-ticket p1
check "C13-garbage rc 2 (got $RC)" '[ "$RC" -eq 2 ]'
rc=$( unset HARNESS H; . "$REPORT"; bc_file_ticket p1 >/dev/null 2>"$T/root.err"; echo $? )
check "C-root empty root rc 2 (got $rc)" '[ "$rc" = 2 ]'
check "C-root refuses on the root, not on a path" 'grep -qx "board-conformance: no harness root" "$T/root.err"'
rc=$( unset HARNESS H; . "$REPORT"; bc_alert_on_change p1 /dev/null 2>/dev/null; echo $? )
check "C-root alert empty root rc 0 (got $rc)" '[ "$rc" = 0 ]'

check "live /root/harness/state/board-conformance unchanged" '[ "$(ls -la /root/harness/state/board-conformance 2>/dev/null)" = "$LIVE_BEFORE" ]'

echo "board-conformance-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
