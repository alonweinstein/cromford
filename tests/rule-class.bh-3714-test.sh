#!/bin/bash
# tests/rule-class.bh-3714-test.sh — the mechanical classifier the weekly rule
# miner splits its PRs on (bin/lib/rule-class.sh, BH-3714 / BH-3692.1).
#
#   P1-P2   D42 and D43, verbatim from prompts/build-discipline.md plus a CLASS
#           line naming the check their text already names: lint-backed
#   N1-N15  every adversarial negative of the plan's list (c): judgement, and
#           the reason is the FIRST condition that failed
#   E1-E3   rc_evidence keeps inventory ids only, counts the drops on stderr
#   F1-F4   rc_families: findings:, block:, refuted:, deduped, never `-`
#   X1-X3   rc_next over the checkout plus every origin rules/mined-* ref
#   L1      the lib carries no /root/harness literal (D43)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
. "$DIR/bin/lib/rule-class.sh" || exit 1

# A scratch clone tracking the four checks the cases name.
R="$T/repo"; mkdir -p "$R/bin/lib" "$R/tests" "$R/prompts"
for f in bin/test-tamper-scan.sh tests/lib-root-literal-ratchet.bh-2613-test.sh tests/foo-test.sh bin/x.sh bin/lib/a.sh prompts/build-discipline.md; do
  echo x > "$R/$f"
done
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init
echo y > "$R/bin/untracked.sh"

B="$T/b.md"
cls() { # cls <bullet text> -> rc_class output
  printf '%s\n' "$1" > "$B"; rc_class "$B" "$R"
}
neg() { # neg <case> <bullet text> <expected reason>
  local out; out=$(cls "$2")
  eq "$1 class" "${out%%$'\t'*}" judgement
  eq "$1 reason" "${out#*$'\t'}" "$3"
}

# ── P1/P2: the real rules, verbatim ──────────────────────────────────────────
D42=$(grep '^- \*\*D42 ' "$DIR/prompts/build-discipline.md")
D43=$(grep '^- \*\*D43 ' "$DIR/prompts/build-discipline.md")
[ -n "$D42" ] && [ -n "$D43" ] && ok || bad "P fixture: D42/D43 not found in prompts/build-discipline.md"
eq "P1 D42" "$(cls "$D42
  CLASS: lint bin/test-tamper-scan.sh
  EVIDENCE: findings:x")" "lint-backed	bin/test-tamper-scan.sh"
eq "P2 D43" "$(cls "$D43
  CLASS: lint tests/lib-root-literal-ratchet.bh-2613-test.sh
  EVIDENCE: findings:x")" "lint-backed	tests/lib-root-literal-ratchet.bh-2613-test.sh"
# A sentence-closing period after the path is still a boundary; CRLF is tolerated.
eq "P3 period + CRLF" "$(cls "- **D9 Run it.** Enforced by tests/foo-test.sh."$'\r'"
  CLASS: lint tests/foo-test.sh"$'\r')" "lint-backed	tests/foo-test.sh"

# ── N: the adversarial negatives ─────────────────────────────────────────────
neg N1 "- **D9 X.** Uses bin/does-not-exist.sh.
  CLASS: lint bin/does-not-exist.sh" "check not tracked on main"
neg N2 "- **D9 X.** See prompts/build-discipline.md.
  CLASS: lint prompts/build-discipline.md" "outside check prefixes"
neg N3 "- **D9 X.** See ../bin/x.sh.
  CLASS: lint ../bin/x.sh" "path escapes the repo"
neg N4 "- **D9 X.** See /root/harness/bin/x.sh.
  CLASS: lint /root/harness/bin/x.sh" "absolute path"
neg N5 "- **D9 X.** A rule that never says where its check lives.
  CLASS: lint bin/x.sh" "check not named in rule text"
neg N6 "- **D9 X.** See bin/x.sh.
  CLASS: lint bin/x.sh
  CLASS: judgement" "more than one CLASS line"
neg N7 "- **D9 X.** See bin/x.sh.
  CLASS: lint" "lint with no path"
neg N8 "- **D9 X.** See bin/x.sh.
  EVIDENCE: findings:x" "no CLASS line"
neg N9 "- **D9 X.** Reviewers should check for X.
  CLASS: lint tests/foo-test.sh
  EVIDENCE: findings:x" "check not named in rule text"
neg N10 "- **D9 X.** See bin/*.sh.
  CLASS: lint bin/*.sh" "path has glob or odd characters"
neg N11 "- **D9 X.** See bin/lib.
  CLASS: lint bin/lib" "check not tracked on main"
neg N12 "- **D9 X.** See tests/.
  CLASS: lint tests/" "outside check prefixes"
neg N13 "- **D9 X.** See bin/x.sh.
  CLASS: lint bin/x.sh extra" "malformed CLASS line"
neg N14 "- **D9 X.** Replaced bin/x.sh-old and mybin/x.sh.
  CLASS: lint bin/x.sh" "check not named in rule text"
neg N15 "- **D9 X.** See bin/untracked.sh.
  CLASS: lint bin/untracked.sh" "check not tracked on main"
neg N16 "- **D9 X.** Needs a human.
  CLASS: judgement" "tagged judgement"
neg N17 "- **D9 X.** See bin/x.sh.
  CLASS: auto bin/x.sh" "malformed CLASS line"
eq "N18 unreadable" "$(rc_class "$T/nope.md" "$R")" "judgement	unreadable input"

# ── E: evidence ──────────────────────────────────────────────────────────────
INV="$T/inventory.tsv"
printf '01\tfindings:x\t/b/01.md\ts\n02\tmanual:n1\t/b/02.md\ts\n' > "$INV"
printf -- '- **D9 X.** y\n  EVIDENCE: findings:x, block:invented:review.md findings:x,manual:n1\n' > "$B"
out=$(rc_evidence "$B" "$INV" 2>"$T/err"); rc=$?
eq "E1 kept, deduped, first-seen order" "$out" "findings:x
manual:n1"
eq "E1 rc" "$rc" 0
grep -q 'dropped 1 id(s).*block:invented:review.md' "$T/err" && ok || bad "E1 stderr lacks the drop count: $(cat "$T/err")"
printf -- '- **D9 X.** y\n  EVIDENCE: invented:1, invented:2\n' > "$B"
out=$(rc_evidence "$B" "$INV" 2>"$T/err"); rc=$?
eq "E2 all absent prints nothing" "$out" ""
eq "E2 rc" "$rc" 0
grep -q 'dropped 2 id(s)' "$T/err" && ok || bad "E2 stderr lacks 'dropped 2'"
: > "$T/empty.tsv"
eq "E3 empty inventory keeps nothing" "$(rc_evidence "$B" "$T/empty.tsv" 2>/dev/null)" ""
rc_evidence "$B" "$T/no-such.tsv" >/dev/null 2>&1; eq "E3 unreadable inventory rc" "$?" 1

# ── F: families ──────────────────────────────────────────────────────────────
FL="$T/findings.log"
cat > "$FL" <<'EOF'
2026-09-29 12:00:00Z [cromford] ticket=BH-9 lens=general family=aaa :: x family=zzz
2026-09-29 12:00:00Z [cromford] ticket=BH-9 lens=general family=- :: y
2026-09-29 12:00:00Z [cromford] ticket=BH-10 lens=general family=bbb :: z
2026-09-29 12:00:00Z [cromford] ticket=BH-9 lens=security family=aaa :: again
EOF
printf 'findings:F1\n' > "$T/ids"
eq "F1 findings:" "$(rc_families "$T/ids" "$FL")" F1
printf 'block:cromford-BH-9-202609300000:review.md\n' > "$T/ids"
eq "F2 block: -> its KEY's families" "$(rc_families "$T/ids" "$FL")" aaa
printf 'refuted:cromford-BH-9-202609300000\n' > "$T/ids"
eq "F3 refuted:" "$(rc_families "$T/ids" "$FL")" aaa
printf 'findings:aaa\nrefuted:cromford-BH-9-202609300000\nfindings:-\nmanual:n1\nblock:nostamp:review.md\n' > "$T/ids"
eq "F4 deduped, no '-', citation-only ids map to nothing" "$(rc_families "$T/ids" "$FL")" aaa
eq "F4 unreadable log still maps findings:" "$(printf 'findings:F1\nblock:cromford-BH-9-202609300000:r\n' > "$T/ids"; rc_families "$T/ids" "$T/no-log")" F1

# ── X: rc_next ───────────────────────────────────────────────────────────────
O="$T/origin.git"; S="$T/seed"
git init -q --bare "$O"
git init -q "$S" && mkdir -p "$S/prompts"
printf -- '- **D42 A.** a\n- **D43 B.** b\n' > "$S/prompts/build-discipline.md"
g() { git -C "$S" -c user.name=t -c user.email=t@t "$@"; }
g add -A && g commit -qm main && g branch -M main && g push -q "$O" main
g checkout -qb rules/mined-20260923
printf -- '- **D44 C.** c\n- **D45 D.** d\n' >> "$S/prompts/build-discipline.md"
g commit -qam wk && g push -q "$O" rules/mined-20260923
git clone -q --single-branch -b main "$O" "$T/clone"
eq "X1 main only (no fetch)" "$(rc_next "$T/clone")" 44
git -C "$T/clone" fetch -q origin '+refs/heads/rules/mined-*:refs/remotes/origin/rules/mined-*'
eq "X2 main + open week" "$(rc_next "$T/clone")" 46
mkdir -p "$T/bare-dir"
eq "X3 no D anywhere" "$(rc_next "$T/bare-dir")" 1

# ── L1: D43 ──────────────────────────────────────────────────────────────────
eq "L1 no /root/harness in the lib" "$(grep -c '/root/harness' "$DIR/bin/lib/rule-class.sh")" 0

echo "rule-class.bh-3714-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
