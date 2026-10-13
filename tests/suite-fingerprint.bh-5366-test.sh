#!/bin/bash
# tests/suite-fingerprint.bh-5366-test.sh — sfp_compute, the suite input
# fingerprint (BH-5354.0 / BH-5366).
#
# A reused suite is a suite that did not run, so a fingerprint that fails to
# move when an input moves is a green nobody earned. Each case edits ONE thing
# in a committed scratch checkout carrying the real bin/test-impact.sh,
# bin/fast-lints.sh and "$DIR/bin/lib/suite-fingerprint.sh", and compares the
# fingerprints before and after:
#
#   F1  editing a file the suite's map row names moves that suite's fp only
#   F2  editing the body of a function the suite names moves its fp
#   F3  deleting that function moves its fp
#   F4  editing the suite file itself moves its fp
#   F5  editing tests/lib/scratch.sh (infra) moves every fp
#   F6  an uncommitted edit: rc 3, `dirty tree` on stderr; a rev that is not
#       HEAD: rc 2
#   F7  never-reasons: RATCHET_BASE and `gh api` -> out-of-tree, a never.tsv row, an
#       always-suite, an unknown suite; each with fp `-`
#   F8  no change: byte-identical output across two calls
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
NOW=2026-10-08T00:00:00Z

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

[ -f "$DIR/bin/lib/suite-fingerprint.sh" ] || { echo "no $DIR/bin/lib/suite-fingerprint.sh"; exit 1; }
R="$T/repo"
mkdir -p "$R"
for s in bin/suite-reuse.sh bin/test-impact.sh bin/fast-lints.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/bin/lib" "$R/catalog"
printf '# scratch lib v1\n' > "$R/tests/lib/scratch.sh"
printf '#!/bin/bash\nlib_a() { echo a1; }\n' > "$R/bin/lib/a.sh"
printf '#!/bin/bash\nfoo_helper() { echo v1; }\nother_fn() { :; }\n' > "$R/bin/b.sh"
cat > "$R/tests/a.sh" <<'EOF'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/a.sh"
EOF
cat > "$R/tests/n.sh" <<'EOF'
#!/bin/bash
out=$(foo_helper)
EOF
printf '#!/bin/bash\necho plain\n' > "$R/tests/p.sh"
printf '#!/bin/bash\necho c\n' > "$R/tests/c.sh"
printf '#!/bin/bash\nRATCHET_BASE=${RATCHET_BASE:-}\n' > "$R/tests/d.sh"
printf '#!/bin/bash\necho e\n' > "$R/tests/e.sh"
printf '#!/bin/bash\nout=$(gh  api repos/x)\n' > "$R/tests/g.sh"
printf 'tests/c.sh\n' > "$R/catalog/test-impact-always.txt"
printf '# <suite>\\t<reason>\ntests/e.sh\treads the live docker host\n' > "$R/catalog/suite-reuse-never.tsv"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm init || { echo "cannot build the scratch checkout"; exit 1; }
printf '%s\n' tests/a.sh tests/n.sh tests/p.sh tests/c.sh tests/d.sh tests/e.sh tests/g.sh tests/zz-missing.sh > "$T/suites"

# fp <out> — run sfp_compute in the checkout (a subshell: the lib is sourced,
# never run, and $PWD is how it finds the root).
fp() { ( cd "$R" && . "$DIR/bin/lib/suite-fingerprint.sh" && sfp_compute HEAD "$T/suites" "$1" ) 2> "$1.err"; }
col() { awk -F'\t' -v s="$2" '$1 == s { print $2 }' "$1"; }
commit() { G commit -qam "$1" || { echo "commit failed: $1"; exit 1; }; }

fp "$T/f0"; rc=$?
[ "$rc" = 0 ] && ok "F0 rc 0" || { bad "F0 rc=$rc: $(cat "$T/f0.err")"; echo "suite-fingerprint: $PASS passed, $FAIL failed"; exit 1; }
[ "$(cut -f1 "$T/f0")" = "$(cat "$T/suites")" ] && ok "F0 one row per suite, input order" || bad "F0 rows: $(cut -f1 "$T/f0" | tr '\n' ' ')"
for s in tests/a.sh tests/n.sh tests/p.sh; do
  col "$T/f0" "$s" | grep -qE '^[0-9a-f]{64}$' && ok "F0 $s has a fingerprint" || bad "F0 $s fp=$(col "$T/f0" "$s")"
done

# F8 determinism.
fp "$T/f0b"
cmp -s "$T/f0" "$T/f0b" && ok "F8 two calls, byte-identical" || bad "F8 output moved with no change"

# F1 a map-row input.
printf '#!/bin/bash\nlib_a() { echo a2; }\n' > "$R/bin/lib/a.sh"; commit f1; fp "$T/f1"
[ "$(col "$T/f0" tests/a.sh)" != "$(col "$T/f1" tests/a.sh)" ] && ok "F1 bin/lib/a.sh moved tests/a.sh" || bad "F1 tests/a.sh fp did not move"
[ "$(col "$T/f0" tests/p.sh)" = "$(col "$T/f1" tests/p.sh)" ] && [ "$(col "$T/f0" tests/n.sh)" = "$(col "$T/f1" tests/n.sh)" ] \
  && ok "F1 the other suites kept their fp" || bad "F1 an unrelated suite moved"

# F2 the body of a named function.
printf '#!/bin/bash\nfoo_helper() { echo v2; }\nother_fn() { :; }\n' > "$R/bin/b.sh"; commit f2; fp "$T/f2"
[ "$(col "$T/f1" tests/n.sh)" != "$(col "$T/f2" tests/n.sh)" ] && ok "F2 foo_helper's body moved tests/n.sh" || bad "F2 tests/n.sh fp did not move"
[ "$(col "$T/f1" tests/p.sh)" = "$(col "$T/f2" tests/p.sh)" ] && ok "F2 tests/p.sh kept its fp" || bad "F2 tests/p.sh moved"

# F3 the function deleted (the script stays).
printf '#!/bin/bash\nother_fn() { :; }\n' > "$R/bin/b.sh"; commit f3; fp "$T/f3"
[ "$(col "$T/f2" tests/n.sh)" != "$(col "$T/f3" tests/n.sh)" ] && ok "F3 deleting foo_helper moved tests/n.sh" || bad "F3 tests/n.sh fp did not move"

# F4 the suite itself.
printf '#!/bin/bash\necho plain2\n' > "$R/tests/p.sh"; commit f4; fp "$T/f4"
[ "$(col "$T/f3" tests/p.sh)" != "$(col "$T/f4" tests/p.sh)" ] && ok "F4 editing tests/p.sh moved it" || bad "F4 tests/p.sh fp did not move"
[ "$(col "$T/f3" tests/a.sh)" = "$(col "$T/f4" tests/a.sh)" ] && ok "F4 tests/a.sh kept its fp" || bad "F4 tests/a.sh moved"

# F5 infra moves everything.
printf '# scratch lib v2\n' > "$R/tests/lib/scratch.sh"; commit f5; fp "$T/f5"
moved=0
for s in tests/a.sh tests/n.sh tests/p.sh; do [ "$(col "$T/f4" "$s")" != "$(col "$T/f5" "$s")" ] && moved=$((moved + 1)); done
[ "$moved" = 3 ] && ok "F5 tests/lib/scratch.sh moved every fingerprint" || bad "F5 only $moved of 3 moved"

# F6 dirty tree, and a rev that is not HEAD.
echo '# dirt' >> "$R/bin/lib/a.sh"
fp "$T/f6"; rc=$?
{ [ "$rc" = 3 ] && grep -q 'dirty tree' "$T/f6.err"; } && ok "F6 uncommitted edit: rc 3, dirty tree" || bad "F6 rc=$rc err=$(cat "$T/f6.err")"
G checkout -q -- bin/lib/a.sh
touch "$R/untracked.txt"
fp "$T/f6u"; rc=$?
[ "$rc" = 3 ] && ok "F6 an untracked file is dirty too" || bad "F6 untracked rc=$rc"
rm -f "$R/untracked.txt"
( cd "$R" && . "$DIR/bin/lib/suite-fingerprint.sh" && sfp_compute HEAD~1 "$T/suites" "$T/f6r" ) 2> "$T/f6r.err"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'rev is not HEAD' "$T/f6r.err"; } && ok "F6 rev not HEAD: rc 2" || bad "F6 rev rc=$rc"

# F7 never-reasons.
row() { awk -F'\t' -v s="$2" '$1 == s { print $2 "|" $3 }' "$1"; }
[ "$(row "$T/f5" tests/d.sh)" = "-|out-of-tree: RATCHET_BASE" ] && ok "F7 RATCHET_BASE is out-of-tree" || bad "F7 d: $(row "$T/f5" tests/d.sh)"
[ "$(row "$T/f5" tests/g.sh)" = "-|out-of-tree: gh  api" ] && ok "F7 a gh api call is out-of-tree" || bad "F7 g: $(row "$T/f5" tests/g.sh)"
[ "$(row "$T/f5" tests/e.sh)" = "-|never.tsv: reads the live docker host" ] && ok "F7 never.tsv row" || bad "F7 e: $(row "$T/f5" tests/e.sh)"
[ "$(row "$T/f5" tests/c.sh)" = "-|always" ] && ok "F7 always-suite" || bad "F7 c: $(row "$T/f5" tests/c.sh)"
[ "$(row "$T/f5" tests/zz-missing.sh)" = "-|unknown suite" ] && ok "F7 unknown suite" || bad "F7 zz: $(row "$T/f5" tests/zz-missing.sh)"
[ "$(row "$T/f5" tests/a.sh | cut -d'|' -f2)" = "-" ] && ok "F7 an ordinary suite has no reason" || bad "F7 a: $(row "$T/f5" tests/a.sh)"

echo "suite-fingerprint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
