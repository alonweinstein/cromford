#!/bin/bash
# tests/pr-dep-gate-test.sh — BH-629.1: the parser and the resolver inside
# bin/lib/pr-dep-gate.sh. The contract child's suite
# (tests/pr-dep-gate-contract-test.sh) pins the INTERFACE; this one pins the
# ANSWER: which number a body declares, how many reads that costs, and which of
# 0 (hold) / 1 (pass) / 2 (could not read) comes back.
#
# THE INCIDENT. #615 merged while its own body said "Depends on #459 (PR #609)
# for tests/lib/scratch.sh" and #609 was still open. Main then carried a suite
# sourcing a file main did not have and every open PR was red for 7.5 hours.
# That line is this suite's main fixture, verbatim.
#
# WHAT IS ASSERTED. The return code, the gh shim's call log (which reads were
# made, in which order, with which -q expression), and the line count and text
# of logs/pr-dep-gate.log. Nothing here greps the library's source. The
# production entry point is the real one: every case sources
# bin/lib/merge-conductor-lib.sh, the guarded line that arms the gate on all six
# lanes, and nothing is retyped into the fixture.
#
# Every fixture value is a literal. Nothing here reads the wall clock, rolls a
# random number or sleeps.
# Run from anywhere: tests/pr-dep-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LOG="$T/h/logs/pr-dep-gate.log"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/fakebin" "$T/answers"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/" || exit 1
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR/bin/lib/pr-dep-gate.sh"         "$T/h/bin/lib/" || exit 1
: > "$T/gh-calls.txt"; : > "$T/allstderr"; : > "$T/prbody.txt"

# gh: records every call, answers an issues read from $T/answers/<n> (absent =
# a failed read, which is what a 404 or a token that cannot see the repo looks
# like), and a REST pulls read from $T/prbody.txt (or fails if $T/prbody-fail
# exists).
#
# `pr view` NOW FAILS THE WAY THE HUB FAILED (BH-994, 2026-09-19): the body read
# moved off GraphQL, so the shim answers any GraphQL spelling with the message
# an exhausted App installation actually returned. A regression back to
# `gh pr view` does not quietly keep working here — it gets the rate limit.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\${1:-}" in
  api)
    case "\${2:-}" in
      */pulls/*)
        [ -e "$T/prbody-fail" ] && { echo 'HTTP 502: Bad gateway' >&2; exit 1; }
        cat "$T/prbody.txt" 2>/dev/null; exit 0 ;;
    esac
    N=\$(printf '%s' "\${2:-}" | sed -E 's|.*/issues/([0-9]+).*|\1|')
    if [ -f "$T/answers/\$N" ]; then cat "$T/answers/\$N"; exit 0; fi
    echo 'HTTP 404: Not Found' >&2; exit 1 ;;
  pr)
    echo 'GraphQL: API rate limit already exceeded for installation ID 161623167' >&2
    exit 1 ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# run_case <shell-code> [VAR=VAL ...] — source the conductor lib in a fresh
# `bash -u` (every lane runs with -u) against $T/h, then run <shell-code>.
# Sets RC, OUT. Truncates the call log and the gate log first so a case's
# read count and line count are its own.
RC=0; OUT=""
run_case() {
  local code="$1"; shift
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/stderr"
  OUT=$(env HARNESS="$T/h" A="$T/answers" "$@" bash -u -c \
        ". \"\$HARNESS/bin/lib/merge-conductor-lib.sh\"; $code" 2>"$T/stderr")
  RC=$?
  cat "$T/stderr" >> "$T/allstderr"
}

HOLD='pdg_hold o/r 41 https://github.com/o/r/pull/41 "$B"'
logn()   { wc -l < "$LOG" 2>/dev/null | tr -d ' '; }
calls()  { tr '\n' '|' < "$T/gh-calls.txt"; }
reads()  { grep -c 'issues/' "$T/gh-calls.txt"; }
ans()    { printf '%s\n' "$2" > "$T/answers/$1"; }
noans()  { rm -f "$T/answers/$1"; }
onelog() { [ "$(logn)" = 1 ] && ok || bad "$1: pdg_hold writes exactly one log line (got $(logn)): $(cat "$LOG")"; }
noread() { [ ! -s "$T/gh-calls.txt" ] && ok || bad "$1: must cost no GitHub read, got: $(calls)"; }
rcis()   { [ "$RC" = "$2" ] && ok || bad "$1: expected rc $2, got rc $RC"; }

# The incident's own line, and the read it must produce.
LINE='Depends on #609 (PR #612) for tests/lib/scratch.sh.'
BODY_OPEN=$(printf 'Some change.\n%s\n' "$LINE")
READ612='api repos/o/r/issues/612 -q .state + " " + (.pull_request.merged_at // "-")'
READBODY='api repos/o/r/pulls/41 -q .body // ""'

# ══ 1. hold-open — an open dependency HOLDS, at the cost of one read ════════
ans 612 'open -'
run_case "$HOLD" B="$BODY_OPEN"
rcis hold-open 0
[ "$(head -1 "$T/gh-calls.txt")" = "$READ612" ] && ok \
  || bad "hold-open: the resolve call must be [$READ612], got [$(head -1 "$T/gh-calls.txt")]"
[ "$(wc -l < "$T/gh-calls.txt")" = 1 ] && ok || bad "hold-open: exactly one gh call, got: $(calls)"
grep -q 'HOLD' "$LOG" && ok || bad "hold-open: the log line says HOLD: $(cat "$LOG")"
grep -q '612' "$LOG" && ok || bad "hold-open: the log line names the dependency: $(cat "$LOG")"
onelog hold-open

# ══ 2. pass-merged — closed WITH a merged_at is landed ══════════════════════
ans 612 'closed 2026-09-17T03:33:00Z'
run_case "$HOLD" B="$BODY_OPEN"
rcis pass-merged 1
[ "$(reads)" = 1 ] && ok || bad "pass-merged: exactly one issues read, got: $(calls)"
onelog pass-merged

# ══ 3. pass-closed-unmerged — closed WITHOUT one passes, and says so ════════
ans 612 'closed -'
run_case "$HOLD" B="$BODY_OPEN"
rcis pass-closed-unmerged 1
grep -q 'closed unmerged' "$LOG" && ok \
  || bad "pass-closed-unmerged: the log line must say the dependency was closed unmerged: $(cat "$LOG")"
onelog pass-closed-unmerged

# ══ 4. a read that fails HOLDS with rc 2, never passes ══════════════════════
noans 612
run_case "$HOLD" B="$BODY_OPEN"
rcis unreadable-holds 2
grep -q '612' "$LOG" && ok || bad "unreadable-holds: the log line names the number it could not read: $(cat "$LOG")"
onelog unreadable-holds

# ══ 5. an answer that is not a state is a FAILED read, not a pass ═══════════
ans 612 'null'
run_case "$HOLD" B="$BODY_OPEN"
rcis garbage-answer-holds 2
ans 612 ''
run_case "$HOLD" B="$BODY_OPEN"
rcis empty-answer-holds 2

# ══ 6. a failed read is NOT memoised — the next call retries it ═════════════
noans 612
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 "$B"; echo "rc1=$?"
          printf "open -\n" > "$A/612"
          pdg_hold o/r 42 https://github.com/o/r/pull/42 "$B"; echo "rc2=$?"' B="$BODY_OPEN"
grep -q 'rc1=2' <<<"$OUT" && ok || bad "failed-read-not-memoised: the first call holds with rc 2: $OUT"
grep -q 'rc2=0' <<<"$OUT" && ok || bad "failed-read-not-memoised: the retry reads again and holds on the open dep: $OUT"
[ "$(reads)" = 2 ] && ok || bad "failed-read-not-memoised: two reads, got: $(calls)"
noans 612

# ══ 7. the kill switch, before anything else ═══════════════════════════════
ans 612 'open -'
run_case "$HOLD" B="$BODY_OPEN" PR_DEP_GATE=0
rcis killswitch-passes 1
noread killswitch-passes
grep -q 'OFF' "$LOG" && ok || bad "killswitch-passes: the log line says the gate is OFF: $(cat "$LOG")"
onelog killswitch-passes

touch "$T/h/flags/pr-dep-gate-off"
run_case "$HOLD" B="$BODY_OPEN"
rcis killswitch-flag-passes 1
noread killswitch-flag-passes
onelog killswitch-flag-passes
rm -f "$T/h/flags/pr-dep-gate-off"

# ══ 8. one read per <slug>#<n> for the life of the shell ═══════════════════
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 "$B"; echo "rc1=$?"
          pdg_hold o/r 42 https://github.com/o/r/pull/42 "$B"; echo "rc2=$?"' B="$BODY_OPEN"
grep -q 'rc1=0' <<<"$OUT" && ok || bad "memoised-one-read-per-dep: first call holds: $OUT"
grep -q 'rc2=0' <<<"$OUT" && ok || bad "memoised-one-read-per-dep: second call holds: $OUT"
[ "$(reads)" = 1 ] && ok || bad "memoised-one-read-per-dep: the second PR reuses the answer, got: $(calls)"

# The memo is shell-local: no file under the harness root is created for it.
find "$T/h" -type f | LC_ALL=C sort > "$T/files-before"
run_case "$HOLD" B="$BODY_OPEN"
find "$T/h" -type f | LC_ALL=C sort > "$T/files-after"
cmp -s "$T/files-before" "$T/files-after" && ok \
  || bad "no-memo-file: the gate wrote a file besides its log: $(diff "$T/files-before" "$T/files-after")"

# ══ 9. nothing declared costs nothing ══════════════════════════════════════
run_case "$HOLD" B="$(printf 'Some change.\nFixes #629\nPart of #629\n')"
rcis no-declared-dependency-costs-no-read 1
noread no-declared-dependency-costs-no-read
grep -q 'no declared dependency' "$LOG" && ok \
  || bad "no-declared-dependency-costs-no-read: the log line says nothing was declared: $(cat "$LOG")"
onelog no-declared-dependency-costs-no-read

# ══ 10. which number the line names ════════════════════════════════════════
# `PR #M` present → M is the number to check; absent → N. Nothing else on the
# line is read, so a #700 in the prose after the declaration costs no call.
ans 612 'open -'; ans 609 'open -'
parse_case() {  # <name> <body> <expected issues path fragment>
  run_case "$HOLD" B="$2"
  [ "$(reads)" = 1 ] && grep -q "issues/$3 " "$T/gh-calls.txt" && ok \
    || bad "$1: the only read must be issues/$3, got: $(calls)"
}
parse_case parse-pr-form                "$BODY_OPEN" 612
parse_case parse-bare-form              "$(printf 'Depends on #609\n')" 609
parse_case parse-case-insensitive       "$(printf 'DEPENDS ON #609 (pr #612)\n')" 612
parse_case parse-noise-prefix           "$(printf '**Depends on #609** (PR #612)\n')" 612
parse_case parse-prose-after-declaration "$(printf 'Depends on #609 (PR #612) for x, see #700 too.\n')" 612
parse_case parse-crlf-body              "$(printf 'Some change.\r\nDepends on #609 (PR #612)\r\n')" 612
parse_case parse-same-number-twice      "$(printf 'Depends on #612\nDepends on #609 (PR #612)\n')" 612

ans 100 'closed 2026-09-17T03:33:00Z'; ans 200 'open -'
run_case "$HOLD" B="$(printf 'Depends on #100\nDepends on #200\n')"
rcis parse-two-deps-one-read-each 0
[ "$(reads)" = 2 ] && ok || bad "parse-two-deps-one-read-each: one read per distinct number, got: $(calls)"

# ══ 11. the body-less call fetches the body itself, over REST ═══════════
# BH-994: the fetch was `gh pr view --json body` until 2026-09-19, when the App
# installation's GraphQL budget emptied and every READY row on the hub was held
# on rc 2 for four ticks while REST on the same token had 3141/6600 points left.
# The shim above now answers `pr view` with that exact rate-limit message, so
# these three cases only pass over the REST read.
printf '%s\n' "$LINE" > "$T/prbody.txt"
ans 612 'open -'
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 ""'
rcis bodyless-call-fetches-body 0
[ "$(head -1 "$T/gh-calls.txt")" = "$READBODY" ] && ok \
  || bad "bodyless-call-fetches-body: line 1 is the body fetch, got: $(calls)"
[ "$(sed -n 2p "$T/gh-calls.txt")" = "$READ612" ] && ok \
  || bad "bodyless-call-fetches-body: line 2 is the resolve, got: $(calls)"
[ "$(wc -l < "$T/gh-calls.txt")" = 2 ] && ok || bad "bodyless-call-fetches-body: exactly two calls, got: $(calls)"
onelog bodyless-call-fetches-body

touch "$T/prbody-fail"
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 ""'
rcis bodyless-unreadable-holds 2
[ "$(reads)" = 0 ] && ok || bad "bodyless-unreadable-holds: an unreadable body costs no issues read: $(calls)"
onelog bodyless-unreadable-holds
rm -f "$T/prbody-fail"

: > "$T/prbody.txt"
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 ""'
rcis bodyless-empty-body-passes 1
[ "$(reads)" = 0 ] && ok || bad "bodyless-empty-body-passes: a PR with no description costs no issues read: $(calls)"
printf '%s\n' "$LINE" > "$T/prbody.txt"

# ══ 12. several dependencies, and which one wins ═══════════════════════════
ans 100 'closed 2026-09-17T03:33:00Z'; ans 200 'open -'; noans 300
run_case "$HOLD" B="$(printf 'Depends on #100\nDepends on #200\n')"
rcis mixed-merged-and-open-holds 0
onelog mixed-merged-and-open-holds
run_case "$HOLD" B="$(printf 'Depends on #100\nDepends on #300\n')"
rcis mixed-merged-and-unreadable-holds 2
onelog mixed-merged-and-unreadable-holds

# ══ 13. the box queue's wrapper holds too ══════════════════════════════════
ans 612 'open -'
run_case 'pdg_queue_hold 41' SLUG=o/r
rcis queue-wrapper-holds 0
[ "$(head -1 "$T/gh-calls.txt")" = "$READBODY" ] && ok \
  || bad "queue-wrapper-holds: the wrapper fetches the body, got: $(calls)"
grep -q 'o/r#41' "$LOG" && ok || bad "queue-wrapper-holds: the log line names o/r#41: $(cat "$LOG")"
onelog queue-wrapper-holds

# ══ 14. the adversarial negatives — none of these declares a dependency ════
# Each must pass, cost NO read at all, and say so in its one log line.
neg_case() {  # <name> <body>
  run_case "$HOLD" B="$2"
  rcis "$1" 1
  noread "$1"
  grep -q 'no declared dependency' "$LOG" && ok \
    || bad "$1: must read as nothing declared, log says: $(cat "$LOG")"
  onelog "$1"
}
neg_case neg-quoted-line        "$(printf '> Depends on #609 (PR #612)\n')"
neg_case neg-prose-no-number    "$(printf 'This no longer depends on #609.\n')"
neg_case neg-depends-on-nothing "$(printf 'Depends on nothing.\n')"
neg_case neg-trailer-sha        "$(printf 'Depends-on: 3a7fd3a\n')"
neg_case neg-fixes-closes       "$(printf 'Fixes #629\nCloses #629\n')"
neg_case neg-blocked-by-trailer "$(printf 'Blocked-by: #876 (hard)\nPart of #629\n')"
neg_case neg-dependent-on       "$(printf 'Dependent on #609 (PR #612)\n')"
neg_case neg-no-hash            "$(printf 'Depends on PR 612\n')"
# The fence and the span carry REAL backticks: they come in as %s arguments,
# because a backslash-escaped backtick inside these nested quotes reaches printf
# as two characters and the case would then pass on a line the parser never saw.
FENCE='```'; TICK='`'
neg_case neg-fenced-block       "$(printf 'The form is:\n%s\nDepends on #609 (PR #612)\n%s\nand that is all.\n' "$FENCE" "$FENCE")"
neg_case neg-fenced-tilde       "$(printf 'The form is:\n~~~\nDepends on #609 (PR #612)\n~~~\nand that is all.\n')"
neg_case neg-inline-span        "$(printf '%sDepends on #609 (PR #612)%s is the form we use.\n' "$TICK" "$TICK")"

# ══ 15. the gate mints no token of its own ═════════════════════════════════
run_case "$HOLD; echo \"tok=\$GH_TOKEN\"" B="$BODY_OPEN" GH_TOKEN=fixture-token-value
grep -q 'tok=fixture-token-value' <<<"$OUT" && ok \
  || bad "no-token-mint: the gate must leave the lane's GH_TOKEN alone: $OUT"
grep -qE '^(auth|api user)' "$T/gh-calls.txt" && bad "no-token-mint: the gate armed its own identity: $(calls)" || ok

# ══ 16. the contract's constant is untouched ═══════════════════════════════
PDG_RE_CONTRACT='^[[:space:]#*_`]*[Dd][Ee][Pp][Ee][Nn][Dd][Ss][[:space:]]+[Oo][Nn][[:space:]]+[*_`]*#[0-9]+([[:space:]]*\([[:space:]]*[Pp][Rr][[:space:]]*#[0-9]+[[:space:]]*\))?'
run_case '[ "$PDG_DEP_RE" = "$WANT" ]' WANT="$PDG_RE_CONTRACT"
rcis regex-constant-unchanged 0

# ══ 17. nothing in the gate is unbound under set -u ════════════════════════
grep -q 'unbound variable' "$T/allstderr" \
  && bad "set-u-clean: a case tripped set -u: $(grep 'unbound variable' "$T/allstderr" | head -3)" || ok

echo "pr-dep-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
