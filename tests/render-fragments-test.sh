#!/bin/bash
# tests/render-fragments-test.sh — bin/lib/render-fragments.sh is the ONE
# spelling of what this repo renders from what, and of the exit codes every
# renderer answers with (0 rendered / no drift, 1 drift, 2 cannot render,
# 3 fragment refused).
#
# No sibling renderer exists yet, so this suite IS the consumer: it sources the
# lib the way a renderer will and asserts on return codes, printed bytes and the
# files the lib wrote — never on the lib's source text (D3). A7 runs it under the
# `set -euo pipefail` the renderers themselves use (bin/render-crontab.sh:48).
#
# Run: bash tests/render-fragments-test.sh   (exit 0 = all pass)
# On a box that has a live /root/harness, scratch.sh wants the sandbox flag:
#   HARNESS_TEST_SANDBOX=1 bash tests/render-fragments-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LIB="$DIR/bin/lib/render-fragments.sh"
[ -r "$LIB" ] || { bad "lib missing: $LIB"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# ── A0 sourcing is inert ─────────────────────────────────────────────────────
# A lib that prints or writes at source time corrupts every renderer that
# sources it, so this runs first, in its own process, under `set -u`.
mkdir -p "$T/probe"
OUT=$(cd "$T/probe" && bash -u -c ". '$LIB'" 2>&1); RC=$?
eq "A0 sourcing under set -u prints nothing" "$OUT" ""
eq "A0 sourcing under set -u exits 0" "$RC" "0"
eq "A0 sourcing creates no files" "$(ls -A "$T/probe")" ""

# ── A1 the five functions ────────────────────────────────────────────────────
N=$(bash -u -c ". '$LIB'; declare -F rf_fail rf_registry rf_fragments rf_write_atomic rf_check" 2>/dev/null | wc -l)
eq "A1 all five functions are defined" "$N" "5"

# shellcheck source=../bin/lib/render-fragments.sh
. "$LIB" || { bad "cannot source $LIB"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# ── A2 rf_fragments ──────────────────────────────────────────────────────────
mkdir -p "$T/frag"
: > "$T/frag/9-a.x"; : > "$T/frag/10-b.x"; : > "$T/frag/zz.y"
rf_fragments "$T/frag" '*.x' > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a readable dir renders rc 0" "$RC" "0"
printf '%s\n%s\n' "$T/frag/10-b.x" "$T/frag/9-a.x" > "$T/want"
cmp -s "$T/out" "$T/want" && ok || bad "A2 LC_ALL=C order: got [$(tr '\n' ' ' < "$T/out")]"
eq "A2 a clean listing says nothing on stderr" "$(cat "$T/err")" ""
eq "A2 the glob filters zz.y out" "$(grep -c 'zz\.y' "$T/out")" "0"

mkdir -p "$T/space"; : > "$T/space/a b.x"
rf_fragments "$T/space" '*.x' > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a name with a space survives" "$RC" "0"
eq "A2 a name with a space is one line" "$(cat "$T/out")" "$T/space/a b.x"

rf_fragments "$T/nope" '*.x' > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a missing dir is rc 2" "$RC" "2"
eq "A2 a missing dir prints no paths" "$(cat "$T/out")" ""
[ -s "$T/err" ] && ok || bad "A2 a missing dir must give a reason on stderr"

mkdir -p "$T/empty"
rf_fragments "$T/empty" '*.x' > "$T/out" 2> "$T/err"; RC=$?
eq "A2 an empty dir is rc 2" "$RC" "2"
eq "A2 an empty dir prints no paths" "$(cat "$T/out")" ""
[ -s "$T/err" ] && ok || bad "A2 an empty dir must give a reason on stderr"

rf_fragments "$T/frag" '*.zzz' > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a glob that matches nothing is rc 2" "$RC" "2"
eq "A2 a glob that matches nothing prints no paths" "$(cat "$T/out")" ""
[ -s "$T/err" ] && ok || bad "A2 a glob that matches nothing must give a reason on stderr"

rf_fragments "$T/frag" > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a missing glob argument is rc 2" "$RC" "2"
rf_fragments > "$T/out" 2> "$T/err"; RC=$?
eq "A2 no arguments at all is rc 2" "$RC" "2"

mkdir -p "$T/crlf"
printf 'ok\n' > "$T/crlf/1.x"
printf 'a\r\nb\n' > "$T/crlf/2.x"
rf_fragments "$T/crlf" '*.x' > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a CR byte is refused with rc 3" "$RC" "3"
eq "A2 a refusal prints no paths at all" "$(cat "$T/out")" ""
grep -q '2\.x:1' "$T/err" && ok || bad "A2 a refusal names file:line, got [$(cat "$T/err")]"
case "$(head -1 "$T/err")" in
  render-fragments:*) ok ;;
  *) bad "A2 a refusal reason starts with render-fragments:, got [$(head -1 "$T/err")]" ;;
esac

# A fragment a Windows editor touched carries a CR next to bytes that are not
# valid UTF-8. grep calls such a file binary, prints no line number and says so
# on stderr, so a scan that does not force text mode accepts the CR and renders
# a lane that runs twice forever. Same for a fragment holding a NUL byte, which
# is binary in every locale. Both are refused like any other CR.
mkdir -p "$T/latin1"
printf 'ok\n' > "$T/latin1/1.x"
printf 'caf\xe9 windows edit\r\nsecond\n' > "$T/latin1/2.x"
( export LC_ALL=C.UTF-8; rf_fragments "$T/latin1" '*.x' ) > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a CR beside a non-UTF-8 byte is refused with rc 3" "$RC" "3"
eq "A2 a non-UTF-8 refusal prints no paths at all" "$(cat "$T/out")" ""
grep -q '2\.x:1' "$T/err" && ok || bad "A2 a non-UTF-8 refusal names file:line, got [$(cat "$T/err")]"

mkdir -p "$T/nul"
printf 'ok\n' > "$T/nul/1.x"
printf 'a\0b\r\nsecond\n' > "$T/nul/2.x"
rf_fragments "$T/nul" '*.x' > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a CR in a fragment holding a NUL is refused with rc 3" "$RC" "3"
eq "A2 a NUL refusal prints no paths at all" "$(cat "$T/out")" ""
grep -q '2\.x:1' "$T/err" && ok || bad "A2 a NUL refusal names file:line, got [$(cat "$T/err")]"

# A clean fragment that merely holds a non-UTF-8 byte is still rendered: the
# scan refuses CR bytes, not unusual encodings.
mkdir -p "$T/latin1ok"
printf 'caf\xe9 no carriage return\n' > "$T/latin1ok/1.x"
( export LC_ALL=C.UTF-8; rf_fragments "$T/latin1ok" '*.x' ) > "$T/out" 2> "$T/err"; RC=$?
eq "A2 a non-UTF-8 fragment without a CR renders rc 0" "$RC" "0"
eq "A2 a non-UTF-8 fragment without a CR is listed" "$(cat "$T/out")" "$T/latin1ok/1.x"
eq "A2 a non-UTF-8 fragment without a CR says nothing on stderr" "$(cat "$T/err")" ""

# ── A3 rf_write_atomic ───────────────────────────────────────────────────────
tmp=$(mktemp "$T/tmp.XXXXXX"); printf 'hello\n' > "$tmp"
rf_write_atomic "$T/deep/er/f.txt" "$tmp" 2> "$T/err"; RC=$?
eq "A3 writing through a missing parent is rc 0" "$RC" "0"
eq "A3 the destination holds the temp content" "$(cat "$T/deep/er/f.txt")" "hello"
[ ! -e "$tmp" ] && ok || bad "A3 the temp file is moved, not copied"

rf_write_atomic "$T/deep/er/none.txt" "$T/no-such-temp" 2> "$T/err"; RC=$?
eq "A3 a missing temp file is rc 2" "$RC" "2"
[ ! -e "$T/deep/er/none.txt" ] && ok || bad "A3 a refused call must not create the destination"
[ -s "$T/err" ] && ok || bad "A3 a refused call must give a reason on stderr"

tmp2=$(mktemp "$T/tmp.XXXXXX"); printf 'x\n' > "$tmp2"
rf_write_atomic "" "$tmp2" 2> "$T/err"; RC=$?
eq "A3 an empty destination is rc 2" "$RC" "2"
[ -f "$tmp2" ] && ok || bad "A3 a refused call must leave the temp file alone"

# ── A4 rf_check ──────────────────────────────────────────────────────────────
printf 'one\ntwo\n' > "$T/c.txt"; printf 'one\ntwo\n' > "$T/r.txt"
rf_check "$T/c.txt" "$T/r.txt" > "$T/out" 2> "$T/err"; RC=$?
eq "A4 byte-identical is rc 0" "$RC" "0"
eq "A4 byte-identical prints nothing" "$(cat "$T/out")" ""

printf 'one\nTWO\n' > "$T/r2.txt"
rf_check "$T/c.txt" "$T/r2.txt" > "$T/out" 2> "$T/err"; RC=$?
eq "A4 a difference is rc 1" "$RC" "1"
eq "A4 the first drift line names the committed path" "$(head -1 "$T/out")" "DRIFT $T/c.txt"
grep -qE '^[<>]' "$T/out" && ok || bad "A4 drift must show diff lines, got [$(cat "$T/out")]"

rf_check "$T/missing.txt" "$T/r.txt" > "$T/out" 2> "$T/err"; RC=$?
eq "A4 a missing committed file is drift, not an error" "$RC" "1"
eq "A4 the missing file still names itself" "$(head -1 "$T/out")" "DRIFT $T/missing.txt"
grep -qE '^>' "$T/out" && ok || bad "A4 a missing committed file diffs against /dev/null"

: > "$T/empty.txt"
i=1; : > "$T/sixty.txt"; while [ "$i" -le 60 ]; do printf 'line %s\n' "$i" >> "$T/sixty.txt"; i=$((i+1)); done
rf_check "$T/empty.txt" "$T/sixty.txt" > "$T/out" 2> "$T/err"; RC=$?
eq "A4 a large drift is still rc 1" "$RC" "1"
LN=$(wc -l < "$T/out")
[ "$LN" -le 26 ] && ok || bad "A4 the diff preview is capped at 25 lines, got $LN"

rf_check "$T/c.txt" "$T/no-such-render" > "$T/out" 2> "$T/err"; RC=$?
eq "A4 a missing rendered temp is rc 2" "$RC" "2"
eq "A4 a refused check prints no DRIFT line" "$(cat "$T/out")" ""
rf_check "" "$T/r.txt" > "$T/out" 2> "$T/err"; RC=$?
eq "A4 an empty committed argument is rc 2" "$RC" "2"

# ── A5 rf_registry ───────────────────────────────────────────────────────────
rf_registry > "$T/reg" 2> "$T/err"; RC=$?
eq "A5 the registry prints rc 0" "$RC" "0"
eq "A5 the registry says nothing on stderr" "$(cat "$T/err")" ""
eq "A5 four rows" "$(wc -l < "$T/reg")" "4"
eq "A5 every row has three TAB fields" "$(awk -F'\t' 'NF!=3' "$T/reg" | wc -l)" "0"
eq "A5 rendered targets, in order" "$(cut -f1 "$T/reg" | tr '\n' '|')" 'cron/*.cron|env-templates/global.env.example|rules/CLAUDE.md|docs/PR-OWNERSHIP.md|'
eq "A5 cron inputs"  "$(sed -n 1p "$T/reg" | cut -f2)" "cron/lanes/ cron/boxes/ fleet.conf bin/lib/cron-lines.sh"
eq "A5 env inputs"   "$(sed -n 2p "$T/reg" | cut -f2)" "env-templates/lanes/"
eq "A5 rules inputs" "$(sed -n 3p "$T/reg" | cut -f2)" "rules/topics/"
eq "A5 doc inputs"   "$(sed -n 4p "$T/reg" | cut -f2)" "docs/PR-OWNERSHIP.d/"
eq "A5 cron command"  "$(sed -n 1p "$T/reg" | cut -f3)" "bin/render-crontab.sh --from-fragments --all --write"
eq "A5 env command"   "$(sed -n 2p "$T/reg" | cut -f3)" "bin/render-env-example.sh --write"
eq "A5 rules command" "$(sed -n 3p "$T/reg" | cut -f3)" "bin/render-rules.sh --write"
eq "A5 doc command"   "$(sed -n 4p "$T/reg" | cut -f3)" "bin/render-doc-sections.sh --write"

# ── A6 the lib parses, and shellcheck when this box has it ───────────────────
bash -n "$LIB" 2> "$T/err"; RC=$?
eq "A6 bash -n" "$RC" "0"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error "$LIB" && ok || bad "A6 shellcheck --severity=error"
else
  echo "SKIP: shellcheck not installed on this box (the CI lint job runs it)"
fi

# ── A7 the shell the real callers run in ─────────────────────────────────────
# Every renderer that will source this lib runs `set -euo pipefail`
# (bin/render-crontab.sh:48), so the lib is exercised under those options too: a
# pipeline inside a function that fails on a HAPPY path (grep finding no CR,
# diff finding a difference) kills the caller instead of returning the
# documented code, and the plain-shell cases above cannot see it.
OUT=$(bash -euo pipefail -c '. "$1"; rf_fragments "$2" "*.x"' _ "$LIB" "$T/frag" 2> "$T/err"); RC=$?
eq "A7 a clean listing under set -euo pipefail is rc 0" "$RC" "0"
eq "A7 a clean listing under set -euo pipefail still lists both" "$(echo "$OUT" | tr '\n' '|')" "$T/frag/10-b.x|$T/frag/9-a.x|"
eq "A7 a clean listing under set -euo pipefail says nothing on stderr" "$(cat "$T/err")" ""

# Capturing the render into a variable is how a renderer consumes it, and it is the
# shape where errexit inside the command substitution bites.
OUT=$(bash -euo pipefail -c '. "$1"; FRAGS=$(rf_fragments "$2" "*.x"); printf "%s" "$FRAGS"' _ "$LIB" "$T/frag" 2> "$T/err"); RC=$?
eq "A7 capturing the render under set -euo pipefail is rc 0" "$RC" "0"
eq "A7 the captured render is not empty" "$(printf '%s' "$OUT" | wc -l)" "1"

# A CR is still refused as 3 under the same options, not swallowed by errexit.
bash -euo pipefail -c '. "$1"; rf_fragments "$2" "*.x"' _ "$LIB" "$T/crlf" > "$T/out" 2> "$T/err"; RC=$?
eq "A7 a CR under set -euo pipefail is still rc 3" "$RC" "3"
eq "A7 a CR under set -euo pipefail prints no paths" "$(cat "$T/out")" ""

# A long drift must answer 1, not head's SIGPIPE (141) or diff's own status.
bash -euo pipefail -c '. "$1"; rf_check "$2" "$3"' _ "$LIB" "$T/empty.txt" "$T/sixty.txt" > "$T/out" 2> "$T/err"; RC=$?
eq "A7 a long drift under set -euo pipefail is rc 1" "$RC" "1"
eq "A7 a long drift under set -euo pipefail still names the path" "$(head -1 "$T/out")" "DRIFT $T/empty.txt"
LN=$(wc -l < "$T/out")
[ "$LN" -le 26 ] && ok || bad "A7 the capped preview survives errexit, got $LN lines"

# A drift bigger than the pipe buffer is where the cap and errexit collide: head
# closes the pipe after 25 lines, diff takes SIGPIPE, and an unguarded pipeline
# answers 141 instead of the documented 1 for drift. rules/CLAUDE.md is already
# 300+ lines, so a whole-file drift reaches this size in normal use.
awk 'BEGIN{for(i=1;i<=50000;i++) print "line " i}' > "$T/big.txt"
bash -euo pipefail -c '. "$1"; rf_check "$2" "$3"' _ "$LIB" "$T/empty.txt" "$T/big.txt" > "$T/out" 2> "$T/err"; RC=$?
eq "A7 a drift larger than the pipe buffer is still rc 1" "$RC" "1"
eq "A7 a huge drift still names the committed path" "$(head -1 "$T/out")" "DRIFT $T/empty.txt"
LN=$(wc -l < "$T/out")
[ "$LN" -le 26 ] && ok || bad "A7 a huge drift is still capped at 25 diff lines, got $LN"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
