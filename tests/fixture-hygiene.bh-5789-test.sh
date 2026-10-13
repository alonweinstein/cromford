#!/bin/bash
# tests/fixture-hygiene.bh-5789-test.sh — BH-5789: a NEW test line carries no
# real-looking address or secret. bin/fixture-hygiene.sh reads the lines a diff
# ADDS to test files and flags:
#   - a 100.64/10 (tailnet) address           rule tailnet-ip
#   - an RFC1918 address (10/8, 172.16/12, 192.168/16) rule private-ip
#   - a SECRET or TOKEN= literal with no "fixture" in it  rule secret
# Fixtures use RFC 5737 addresses (192.0.2.x, 198.51.100.x, 203.0.113.x) and
# tokens with the word "fixture" in them (prompts/build-discipline.md D64).
#
# WHY. #5700 shipped 11 tailnet addresses in fixtures, #5282 one, and #4967's
# token broke merge batch #5770 for 3 PRs. The builder had no gitleaks, so the
# leak showed up only in CI or the queue.
#
#   F1  a new test file with a tailnet address and a SECRET token: both flagged
#   F2  the same file with 192.0.2.1 and a fixture token: clean
#   F3  RFC1918 addresses and a TOKEN= without fixture: flagged; TOKEN= with a
#       fixture value or a shell variable: clean
#   F4  a line already on the base is not judged (only added lines are)
#   F5  `fixture-hygiene-allow: <reason>` on a line skips it
#   F6  a non-test file is not judged
#   F7  no base to diff against: rc 2, never a pass
#   F8  a CIDR that names a range (`<tailnet base>/10`) is not an address
#   M0  no regex interval {n,m} in the lint (the boxes' mawk panics on one)
#   M1  the same verdicts when `awk` is mawk (no regex interval support on
#       older mawk: "REcompile() - panic"), so the lint never exits 2 there
#   F9  `GH_TOKEN=x`, `dummy`, a short value: clean; a 33-char real-looking token: flagged
# There is no whole-tree case: on a merge batch the tree holds other PRs' lines.
# The rules-pack row judges each PR's own diff (bin/rules-pack.sh, delta).
# The forbidden values are assembled at run time, so this file never holds one.
# Run from anywhere: tests/fixture-hygiene.bh-5789-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LINT="$DIR/bin/fixture-hygiene.sh"
[ -f "$LINT" ] || { echo "FAIL: $LINT is missing"; echo "fixture-hygiene.bh-5789: 0 passed, 1 failed"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# The values, assembled so no literal sits in this file.
TAIL="100.$((64)).0.1"; TEN="10.$((1)).2.3"; SIXTEEN="172.$((16)).0.9"; HOME168="192.$((168)).1.20"
SEC="tok-$(printf 'SEC%s' RET)-1"; TOKV="ghp$(printf '%s' abcdef0123)"

R="$T/repo"; mkdir -p "$R/tests" "$R/bin"
git -C "$R" init -q -b main
printf 'old line with %s\n' "$TEN" > "$R/tests/old-test.sh"
git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" checkout -qb ticket/x
lint() { OUT=$(bash "$LINT" check --tree "$R" --base main 2>&1); RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
reset_branch() { git -C "$R" checkout -q -- . 2>/dev/null; git -C "$R" clean -qfd; git -C "$R" reset -q --hard main; }

# F1 — tailnet + SECRET token in a new test file
reset_branch
printf 'HOST=%s\nAPI=%s\n' "$TAIL" "$SEC" > "$R/tests/new-test.sh"
lint
[ "$RC" = 1 ] && ok || bad "F1: want rc 1, got $RC [$OUT]"
has "tests/new-test.sh:1: tailnet-ip" && ok || bad "F1: the tailnet address must be flagged [$OUT]"
has "tests/new-test.sh:2: secret" && ok || bad "F1: the SECRET token must be flagged [$OUT]"

# F2 — RFC 5737 and a fixture token: clean
reset_branch
printf 'HOST=192.0.2.1\nAPI=tok-fixture-1\nOTHER=198.51.100.7 and 203.0.113.9\n' > "$R/tests/new-test.sh"
lint
[ "$RC" = 0 ] && ok || bad "F2: RFC 5737 and a fixture token must pass (rc=$RC) [$OUT]"

# F3 — RFC1918 and TOKEN=
reset_branch
printf 'A=%s\nB=%s\nC=%s\nGH_TOKEN=%s\nD_TOKEN=fixture-abc\nE_TOKEN="$REAL"\n' "$TEN" "$SIXTEEN" "$HOME168" "$TOKV" > "$R/tests/new-test.sh"
lint
[ "$RC" = 1 ] && ok || bad "F3: want rc 1, got $RC [$OUT]"
for n in 1 2 3; do has "tests/new-test.sh:$n: private-ip" && ok || bad "F3: line $n must be private-ip [$OUT]"; done
has "tests/new-test.sh:4: secret" && ok || bad "F3: TOKEN= without fixture must be flagged [$OUT]"
has "tests/new-test.sh:5:" && bad "F3: a fixture token value must pass [$OUT]" || ok
has "tests/new-test.sh:6:" && bad "F3: a shell variable value must pass [$OUT]" || ok

# F4 — only added lines: the old file's line is not judged, a new line in it is
reset_branch
printf 'new line with 192.0.2.5\n' >> "$R/tests/old-test.sh"
lint
[ "$RC" = 0 ] && ok || bad "F4: a line already on the base must not be judged (rc=$RC) [$OUT]"

# F5 — the allow marker
reset_branch
printf 'HOST=%s  # fixture-hygiene-allow: the parser under test must reject this range\n' "$TAIL" > "$R/tests/new-test.sh"
lint
[ "$RC" = 0 ] && ok || bad "F5: a line with the allow marker must pass (rc=$RC) [$OUT]"

# F6 — a non-test file is not judged
reset_branch
mkdir -p "$R/bin"; printf 'HOST=%s\n' "$TAIL" > "$R/bin/tool.sh"
lint
[ "$RC" = 0 ] && ok || bad "F6: a non-test file must not be judged (rc=$RC) [$OUT]"

# F8 — a CIDR names a range, not an address
reset_branch
printf '# the tailnet range is %s/10 and the RFC1918 one 10.0.0.0/8\n' "100.$((64)).0.0" > "$R/tests/new-test.sh"
lint
[ "$RC" = 0 ] && ok || bad "F8: a CIDR range must not be flagged (rc=$RC) [$OUT]"

# F7 — no base: rc 2
OUT=$(bash "$LINT" check --tree "$R" --base no-such-ref 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "F7: an unresolvable base must be rc 2, got $RC [$OUT]"

# M0 — no regex interval ({n,m}) in the lint: mawk 1.3.4-20240123 (the boxes'
# awk) panics on one ("REcompile() - panic: values still on machine stack"),
# and newer mawk builds, like this image's, do not, so M1 alone can pass here.
grep -nE '\[[^]]*\]\{[0-9]+(,[0-9]*)?\}' "$LINT" > "$T/intervals" && \
  bad "M0: bin/fixture-hygiene.sh uses a regex interval; mawk 20240123 panics on it: $(cat "$T/intervals")" || ok

# M1 — awk is mawk: findings and a clean tree read the same, never rc 2.
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$T/mawk-bin"; ln -sf "$(command -v mawk)" "$T/mawk-bin/awk"
  mlint() { OUT=$(PATH="$T/mawk-bin:$PATH" bash "$LINT" check --tree "$R" --base main 2>&1); RC=$?; }
  reset_branch
  printf 'HOST=%s\nAPI=%s\nNET=%s\n' "$TAIL" "$SEC" "$HOME168" > "$R/tests/new-test.sh"
  mlint
  [ "$RC" = 1 ] && ok || bad "M1: under mawk want rc 1, got $RC [$OUT]"
  has "tests/new-test.sh:1: tailnet-ip" && has "tests/new-test.sh:2: secret" && has "tests/new-test.sh:3: private-ip" && ok \
    || bad "M1: under mawk all three rules must fire [$OUT]"
  reset_branch
  printf 'HOST=192.0.2.1\nAPI=tok-fixture-1\n' > "$R/tests/new-test.sh"
  mlint
  [ "$RC" = 0 ] && ok || bad "M1: under mawk a clean file is rc 0, got $RC [$OUT]"
else
  echo "M1: SKIPPED — mawk is not installed"
fi

# F9 — a stub value is not a secret; a real-looking one still is.
reset_branch
printf 'GH_TOKEN=x\nAPI_TOKEN=dummy\nCI_SECRET=stub-value-long\nMR_TOKEN=abc\n' > "$R/tests/stub-test.sh"
lint
[ "$RC" = 0 ] && ok || bad "F9: short or placeholder token values must pass, got rc $RC [$OUT]"
reset_branch
LONGTOK="ghp$(printf '%s' 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5')"
printf 'GH_TOKEN=%s\n' "$LONGTOK" > "$R/tests/real-test.sh"
lint
[ "$RC" = 1 ] && has "tests/real-test.sh:1: secret" && ok || bad "F9: a 33-char token with no fixture word must be flagged (rc $RC) [$OUT]"

echo "fixture-hygiene.bh-5789: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
