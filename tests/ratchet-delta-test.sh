#!/bin/bash
# tests/ratchet-delta-test.sh — tests/lib/ratchet-delta.sh, the shared
# base-vs-HEAD counting every diff-based ratchet uses.
#
#   M  rd_mode: default delta, RATCHET_MODE=strict, --strict wins, junk is rc 2
#   B  rd_base: the merge-base with origin/main; RATCHET_BASE (else TI_BASE)
#      honoured, and a stale one loses to a newer origin/main HEAD contains; a
#      base that does not resolve, or none at all, is rc 1 with a reason
#   T  rd_tree: extracts only what existed at the ref (a path new in this diff
#      is simply absent), and refuses a ref it cannot read
#   D  rd_delta: raised and new keys are reported with both counts, equal and
#      lower ones are not, and the rc says which
# Hermetic git repos only; no network, no clock.
# Run from anywhere: tests/ratchet-delta-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
unset RATCHET_BASE TI_BASE RATCHET_MODE

# --- M ------------------------------------------------------------------------
eq "M1 default" "$(rd_mode)" delta
eq "M2 env strict" "$(RATCHET_MODE=strict rd_mode)" strict
eq "M3 --strict wins over env" "$(RATCHET_MODE=delta rd_mode x --strict)" strict
out=$(RATCHET_MODE=loose rd_mode); rc=$?
eq "M4 junk mode rc" "$rc" 2
case "$out" in *loose*) ok ;; *) bad "M4 the refusal must name the value: $out" ;; esac

# --- B ------------------------------------------------------------------------
R="$T/repo"; mkdir -p "$R/bin"; echo one > "$R/bin/a"
rd_fixture_repo "$R" || { bad "B0 rd_fixture_repo failed"; echo "ratchet-delta: $PASS passed, $FAIL failed"; exit 1; }
B=$(rd_git "$R" rev-parse HEAD)
eq "B1 a fresh branch's base is B" "$(rd_base "$R")" "$B"
add_main() { echo main >> "$1/bin/m"; }
rd_main_commit "$R" 'main moves' add_main || bad "B2 rd_main_commit failed"
M=$(rd_git "$R" rev-parse refs/remotes/origin/main)
eq "B2 main moved, branch behind: still B" "$(rd_base "$R")" "$B"
eq "B2 rd_main_commit left the branch on work" "$(rd_git "$R" rev-parse --abbrev-ref HEAD)" work
rd_git "$R" merge -q --no-edit refs/remotes/origin/main
eq "B3 after merging main the base is main's tip" "$(rd_base "$R")" "$M"
eq "B4 a stale RATCHET_BASE loses to the newer main HEAD contains" "$(RATCHET_BASE="$B" rd_base "$R")" "$M"
eq "B5 TI_BASE is read when RATCHET_BASE is unset" "$(TI_BASE="$B" rd_base "$R")" "$M"
out=$(RATCHET_BASE=0123456789abcdef0123456789abcdef01234567 rd_base "$R"); rc=$?
eq "B6 a bogus base rc" "$rc" 1
case "$out" in *"does not resolve"*) ok ;; *) bad "B6 reason: $out" ;; esac
rd_git "$R" update-ref -d refs/remotes/origin/main
eq "B7 RATCHET_BASE alone still answers" "$(RATCHET_BASE="$M" rd_base "$R")" "$M"
out=$(rd_base "$R"); rc=$?
eq "B8 no base at all rc" "$rc" 1
case "$out" in *"no base"*) ok ;; *) bad "B8 reason: $out" ;; esac

# --- T ------------------------------------------------------------------------
echo two > "$R/bin/new"; mkdir -p "$R/fly"; echo f > "$R/fly/x"
rd_tree "$R" "$B" "$T/t1" bin fly; rc=$?
eq "T1 rc" "$rc" 0
{ [ "$(cat "$T/t1/bin/a" 2>/dev/null)" = one ] && [ ! -e "$T/t1/bin/new" ] && [ ! -e "$T/t1/fly" ]; } && ok \
  || bad "T1 want bin/a only, got: $(cd "$T/t1" && find . -type f | sort | tr '\n' ' ')"
rd_tree "$R" "$B" "$T/t2" nothing-here; eq "T2 no path at the ref is an empty tree, rc 0" "$?" 0
[ -d "$T/t2" ] && [ -z "$(ls -A "$T/t2")" ] && ok || bad "T2 dest must exist and be empty"
rd_tree "$R" 0123456789abcdef0123456789abcdef01234567 "$T/t3" bin >/dev/null; eq "T3 unreadable ref rc" "$?" 1

# --- D ------------------------------------------------------------------------
printf 'a\t2\nb\t1\nc\t3\n' > "$T/base.tsv"
printf 'a\t3\nb\t1\nc\t2\nd\t1\n' > "$T/head.tsv"
out=$(rd_delta "$T/head.tsv" "$T/base.tsv"); rc=$?
eq "D1 rc" "$rc" 1
eq "D1 rows" "$(printf '%s' "$out" | tr '\t\n' ' |')" "a 3 2|d 1 0"
printf 'a\t2\n' > "$T/h2.tsv"
out=$(rd_delta "$T/h2.tsv" "$T/base.tsv"); rc=$?
eq "D2 equal/lower only rc" "$rc" 0
eq "D2 prints nothing" "$out" ""
: > "$T/empty.tsv"
rd_delta "$T/empty.tsv" "$T/base.tsv" >/dev/null; eq "D3 empty HEAD rc" "$?" 0
rd_delta "$T/head.tsv" "$T/empty.tsv" >/dev/null; eq "D4 empty base: every key is new" "$?" 1

echo "ratchet-delta: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
