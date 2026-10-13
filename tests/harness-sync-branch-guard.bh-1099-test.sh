#!/bin/bash
# tests/harness-sync-branch-guard.bh-1099-test.sh — bin/harness-sync.sh refuses
# a non-main checkout and installs a post-checkout hook that logs moves off main.
#
# WHY (BH-1099). bin/harness-sync.sh deploys whatever branch is checked out, and
# bin/fleet-propagate.sh's ff-only pull silently aborts on a side branch. The
# branch guard fails closed before any rsync, and the hook records the moment a
# checkout leaves main so an operator can see when it happened.
#
# Run from anywhere: tests/harness-sync-branch-guard.bh-1099-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null && command -v flock >/dev/null \
  && command -v rsync >/dev/null || { echo "jq/git/flock/rsync missing — skipping"; exit 0; }

# HARNESS is read by the post-checkout hook the test exercises.
export HARNESS="$T"

# ── a real bare origin and a real clone ──────────────────────────────────────
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf 'fleet\n' > "$T/ck/fleet.conf"
printf '{"lanes":[{"lane":"plan","stage":"plan","ceiling_tokens":100000}]}\n' \
  > "$T/ck/catalog/context-budgets.json"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main 2>/dev/null

sync() { # sync [--check] -> rc in $RC
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}

REF="$T/state/harness-sync-last-refused"
MOVES="$T/logs/checkout-moves.log"

# ── 1. clean main deploys and installs the hook ──────────────────────────────
sync
[ "$RC" = 0 ] && ok || bad "clean main deploy must exit 0 (rc=$RC): $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ -x "$T/ck/.git/hooks/post-checkout" ] && ok || bad "post-checkout hook must be installed"
[ ! -f "$REF" ] && ok || bad "clean deploy must not write a refusal stamp"

# ── 2. clean side branch deploy is refused and names the branch ───────────────
git -C "$T/ck" checkout -q -b pr908
# --check first: rc 30 and the branch name, but NO stamp and NO ALERTS line —
# context-gate runs --check before every build on every box, and a --check that
# stamped would make the whole fleet look like a refusing hub.
sync --check
[ "$RC" = 30 ] && ok || bad "--check on a side branch must refuse rc 30 (rc=$RC): $(cat "$T/out.txt") $(cat "$T/err.txt")"
grep -q 'branch=pr908' "$T/out.txt" && ok || bad "--check refusal must name the branch: $(cat "$T/out.txt")"
[ ! -f "$REF" ] && ok || bad "--check must NOT write a refusal stamp: $(cat "$REF")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "--check must NOT write an ALERTS line: $(cat "$T/logs/ALERTS.log")"
# then the deploy path, which is the one place the refusal is recorded
sync
[ "$RC" = 30 ] && ok || bad "clean side branch must refuse rc 30 (rc=$RC): $(cat "$T/out.txt") $(cat "$T/err.txt")"
grep -q 'branch=pr908' "$T/out.txt" && ok || bad "refusal output must contain branch=pr908: $(cat "$T/out.txt")"
[ -f "$REF" ] && ok || bad "side branch refusal must write a stamp"
grep -q 'branch=pr908' "$REF" && ok || bad "stamp must contain branch=pr908: $(cat "$REF")"
grep -q 'checkout on pr908' "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "deploy refusal must write the ALERTS line"

# ── 3. dirty side branch deploy is also refused ─────────────────────────────
git -C "$T/ck" checkout -q main
git -C "$T/ck" branch -D pr908 2>/dev/null || true
git -C "$T/ck" checkout -q -b pr909
echo dirty > "$T/ck/dirty"
sync
[ "$RC" = 30 ] && ok || bad "dirty side branch must refuse rc 30 (rc=$RC): $(cat "$T/out.txt") $(cat "$T/err.txt")"
grep -q 'branch=pr909' "$T/out.txt" && ok || bad "dirty refusal must still name the branch: $(cat "$T/out.txt")"

# ── 4. the hook logs moves off main, not moves to main ───────────────────────
: > "$MOVES"
git -C "$T/ck" checkout -q main
git -C "$T/ck" branch -D pr909 2>/dev/null || true
git -C "$T/ck" checkout -q -b pr910
[ "$(wc -l < "$MOVES" 2>/dev/null | tr -d ' ')" = 1 ] \
  && ok || bad "moving off main must log exactly one line (got: $(cat "$MOVES"))"
grep -q 'pr910' "$MOVES" && ok || bad "checkout-moves.log must name pr910: $(cat "$MOVES")"
# attribution: who moved it (pid + cmdline) and from/to which shas
grep -Eq 'pid=[0-9]+ cmd=.*checkout.* from=[0-9a-f]{7} to=[0-9a-f]{7}' "$MOVES" \
  && ok || bad "the move line must carry pid=, cmd=, from= and to= (got: $(cat "$MOVES"))"
git -C "$T/ck" checkout -q main
[ "$(wc -l < "$MOVES" 2>/dev/null | tr -d ' ')" = 1 ] \
  && ok || bad "moving back to main must not add a line (got: $(cat "$MOVES"))"

echo "harness-sync-branch-guard.bh-1099-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
