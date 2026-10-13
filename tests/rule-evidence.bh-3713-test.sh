#!/bin/bash
# tests/rule-evidence.bh-3713-test.sh — the BH-3692 contract slice: the
# rule-evidence schema lib, the lint-PR branch pattern and the rule-recur stub
# the weekly miner now calls before its empty-week exit.
#
#   1  re_write round-trips every key through re_field; blank and `-` ids drop
#   2  a `-` check is JSON null
#   3  a bad class or a missing list file writes nothing and leaves an
#      existing out file byte-identical
#   4  RE_LINT_HEAD_RE matches the lint branch and none of its neighbours;
#      re_field on unparseable JSON is non-zero
#   5  bin/rule-recur.sh with no evidence dir is silent and exits 0 (BH-3716
#      replaced the stub's one line with the measure)
#   6  the REAL bin/rule-miner.sh on an empty week, with one evidence file and
#      a gh that fails, logs rule-recur's unreadable line BEFORE its
#      `nothing to mine` exit
#   7  under RULE_MINER_DRY=1 that line goes to stdout, not the log
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "rule-evidence.bh-3713-test: SKIPPED — jq missing"; exit 0; }

. "$DIR/bin/lib/rule-evidence.sh" || exit 1
RECUR="$DIR/bin/rule-recur.sh"

# ── 1: round trip ───────────────────────────────────────────────────────────
EV="$T/repo/$RE_DIR"; mkdir -p "$EV"
printf 'TK-1\n\n-\nFR-2\n' > "$T/inc"
printf 'aaaaaaaaaaaa\n' > "$T/fam"
F="$EV/D45.json"
re_write "$F" D45 lint-backed tests/foo-test.sh "a script decides it" 2026-09-30 findings "$T/inc" "$T/fam"
eq "1 re_write rc" "$?" 0
eq "1 path under RE_DIR" "$(basename "$(dirname "$F")")" rule-evidence
eq "1 rule"      "$(re_field "$F" '.rule')"   D45
eq "1 class"     "$(re_field "$F" '.class')"  lint-backed
eq "1 check"     "$(re_field "$F" '.check')"  tests/foo-test.sh
eq "1 reason"    "$(re_field "$F" '.reason')" "a script decides it"
eq "1 mined"     "$(re_field "$F" '.mined')"  2026-09-30
eq "1 source"    "$(re_field "$F" '.source')" findings
eq "1 incidents" "$(re_field "$F" '.incidents|join(",")')" TK-1,TK-2
eq "1 families"  "$(re_field "$F" '.families|join(",")')" aaaaaaaaaaaa
eq "1 no tmp left" "$(find "$EV" -name '*.tmp.*' | wc -l | tr -d ' ')" 0

# ── 2: `-` check is null ────────────────────────────────────────────────────
F2="$EV/D46.json"
re_write "$F2" D46 judgement - "needs a human" 2026-09-30 manual "$T/inc" "$T/fam"
eq "2 re_write rc" "$?" 0
eq "2 check prints null" "$(re_field "$F2" '.check')" null
if jq -e '.check==null' "$F2" >/dev/null 2>&1; then ok; else bad "2 check is not JSON null"; fi
eq "2 class" "$(re_field "$F2" '.class')" judgement
# A list holding only blanks and `-` is an empty array, not a failure.
printf '\n-\n' > "$T/empty"
re_write "$F2" D46 judgement - "needs a human" 2026-09-30 manual "$T/empty" "$T/empty"
eq "2 all-blank list rc" "$?" 0
eq "2 all-blank incidents" "$(re_field "$F2" '.incidents|length')" 0

# ── 3: refusals write nothing ───────────────────────────────────────────────
F3="$EV/D47.json"
re_write "$F3" D47 auto - r 2026-09-30 findings "$T/inc" "$T/fam"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "3 bad class rc was 0"
[ ! -e "$F3" ] && ok || bad "3 bad class created the out file"
before=$(cksum < "$F")
re_write "$F" D45 auto - r 2026-09-30 findings "$T/inc" "$T/fam"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "3 bad class over existing rc was 0"
eq "3 existing file untouched" "$(cksum < "$F")" "$before"
F4="$EV/D48.json"
re_write "$F4" D48 judgement - r 2026-09-30 findings "$T/no-such-inc" "$T/fam"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "3 missing incidents file rc was 0"
[ ! -e "$F4" ] && ok || bad "3 missing incidents file created the out file"
re_write "$F4" D48 judgement - r 2026-09-30 findings "$T/inc" "$T/no-such-fam"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "3 missing families file rc was 0"
[ ! -e "$F4" ] && ok || bad "3 missing families file created the out file"
eq "3 no tmp left" "$(find "$EV" -name '*.tmp.*' | wc -l | tr -d ' ')" 0

# ── 4: branch pattern and bad JSON ──────────────────────────────────────────
[[ rules/mined-20260930-lint =~ $RE_LINT_HEAD_RE ]] && ok || bad "4 lint branch did not match"
for neg in rules/mined-20260930 rules/mined-20260930-lint-extra rules/mined-2026093-lint \
           xrules/mined-20260930-lint ticket/bh-1; do
  [[ $neg =~ $RE_LINT_HEAD_RE ]] && bad "4 '$neg' matched" || ok
done
eq "4 grep -E agrees" "$(printf 'rules/mined-20260930-lint\nrules/mined-20260930\n' | grep -cE "$RE_LINT_HEAD_RE")" 1
printf '{' > "$T/bad.json"
re_field "$T/bad.json" '.rule' >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok || bad "4 re_field on bad JSON rc was 0"

# ── 5: no evidence, nothing to say ──────────────────────────────────────────
out=$(bash "$RECUR" /dev/null /nonexistent); rc=$?
eq "5 no-evidence output" "$out" ""
eq "5 no-evidence rc" "$rc" 0
[ -x "$RECUR" ] && ok || bad "5 rule-recur.sh is not executable"

# ── 6/7: the real miner on an empty week ────────────────────────────────────
H="$T/h"; CO="$T/co"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$H/bin/lib" "$H/catalog" "$CO/bin/lib" "$T/stub"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
: > "$H/fleet.conf"
: > "$H/logs/findings.log"
cp "$DIR/bin/rule-miner.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/rule-miner-digest.sh" "$RECUR" "$CO/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/rule-evidence.sh" "$DIR/bin/lib/gh-rest.sh" "$CO/bin/lib/"
mkdir -p "$H/$RE_DIR"; cp "$F" "$H/$RE_DIR/D45.json"
cp "$DIR/catalog/context-budgets.json" "$H/catalog/"
chmod +x "$CO/bin/"*.sh
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/gh"
chmod +x "$T/stub/"*

miner() { # miner [VAR=value ...] -> the miner's stdout
  scratch_rm "$H/state/rule-mining"; mkdir -p "$H/state/rule-mining"
  : > "$H/logs/rule-miner.log"
  env "$@" PATH="$T/stub:$PATH" HARNESS="$H" bash "$CO/bin/rule-miner.sh" 2>/dev/null
}

miner >/dev/null
L="$H/logs/rule-miner.log"
recur_ln=$(grep -n 'rule-recur: D45 adoption date unreadable' "$L" | head -1 | cut -d: -f1)
empty_ln=$(grep -n 'nothing to mine' "$L" | head -1 | cut -d: -f1)
[ -n "$empty_ln" ] && ok || bad "6 the run never reached the empty-week exit: $(cat "$L")"
[ -n "$recur_ln" ] && ok || bad "6 no rule-recur line in the log: $(cat "$L")"
if [ -n "$recur_ln" ] && [ -n "$empty_ln" ] && [ "$recur_ln" -lt "$empty_ln" ]; then ok
else bad "6 rule-recur line ($recur_ln) is not above nothing-to-mine ($empty_ln)"; fi

out=$(miner RULE_MINER_DRY=1)
case "$out" in *'rule-recur: D45 adoption date unreadable'*) ok ;; *) bad "7 DRY stdout lacks the rule-recur line: $out" ;; esac
grep -q 'rule-recur:' "$L" && bad "7 DRY run wrote rule-recur to the log" || ok

echo "rule-evidence.bh-3713-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
