#!/bin/bash
# tests/harness-sync-hook.bh-1128-test.sh — the post-checkout hook that
# bin/harness-sync.sh installs never changes `git checkout`'s exit status, and
# never logs a file checkout.
#
# WHY (BH-1128). The BH-1099 hook ends on an `echo >> "$h/logs/checkout-moves.log"`
# and nothing after it, so the hook's rc IS the append's rc: with $HARNESS/logs
# absent, `git checkout -b side` returns 1 and every caller that reads that rc —
# bin/fleet-propagate.sh's forced-back-to-main step among them, whose rc decides
# hub=ok vs hub=fail — records a failure that did not happen. The hook is
# attribution, not a gate. It also ignored git's third argument, so
# `git checkout -- file` on a side branch logged a spurious "moved off main"
# line. And because the installer returned early on ANY executable hook, a hub
# that already carried the v1 hook would never have received either fix.
#
# Run from anywhere: tests/harness-sync-hook.bh-1128-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# rsync is deliberately NOT in this guard, unlike the BH-1099 sibling's: the
# hook is installed before the first rsync and nothing asserted below reads a
# deployed file, so requiring rsync would make this suite skip on exactly the
# machines the ticket is about (the Mac drain, the pre-rsync container).
command -v jq >/dev/null && command -v git >/dev/null && command -v flock >/dev/null \
  || { echo "jq/git/flock missing — skipping"; exit 0; }

# HARNESS is read by the post-checkout hook under test.
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

HOOK="$T/ck/.git/hooks/post-checkout"
MOVES="$T/logs/checkout-moves.log"
nmoves() { wc -l < "$MOVES" 2>/dev/null | tr -d ' '; }

# ── 1. a clean deploy installs the v2 hook ───────────────────────────────────
sync
[ "$RC" = 0 ] && ok || bad "1: clean main deploy must exit 0 (rc=$RC): $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ -x "$HOOK" ] && ok || bad "1: post-checkout hook must be installed and executable"
grep -q 'installed by bin/harness-sync.sh' "$HOOK" 2>/dev/null \
  && ok || bad "1: the installed hook must carry our marker line"
grep -q 'v2' "$HOOK" 2>/dev/null \
  && ok || bad "1: the installed hook must carry the v2 version marker"
[ "$(tail -n 1 "$HOOK" 2>/dev/null)" = "exit 0" ] \
  && ok || bad "1: the hook's last line must be 'exit 0' (got: $(tail -n 1 "$HOOK" 2>/dev/null))"

# ── 2. a failed log append never fails `git checkout` ────────────────────────
# The production entry point: real `git checkout -b`, with $HARNESS pointing at
# a directory that has no logs/ (a fresh box, or a lane with HARNESS unset on a
# machine without /root/harness).
( cd "$T/ck" && HARNESS="$T/nologs" git checkout -q -b side1 ) 2>"$T/hook-err.txt"
RC2=$?
[ "$RC2" = 0 ] && ok || bad "2: git checkout -b with logs/ absent must exit 0 (rc=$RC2): $(cat "$T/hook-err.txt")"
[ "$(git -C "$T/ck" branch --show-current)" = side1 ] \
  && ok || bad "2: the checkout must still have moved to side1 (on $(git -C "$T/ck" branch --show-current))"
( cd "$T/ck" && HARNESS="$T/nologs" .git/hooks/post-checkout 0000000000 1111111111 1 ) >/dev/null 2>&1
RC2B=$?
[ "$RC2B" = 0 ] && ok || bad "2: a direct hook call with logs/ absent must exit 0 (rc=$RC2B)"
[ ! -d "$T/nologs/logs" ] && ok || bad "2: the hook must not create a logs dir under an absent HARNESS"

# ── 3. branch checkouts log, file checkouts ($3 = 0) do not ──────────────────
git -C "$T/ck" checkout -q main
: > "$MOVES"
git -C "$T/ck" checkout -q -b side2
RC3=$?
[ "$RC3" = 0 ] && ok || bad "3: moving off main must exit 0 (rc=$RC3)"
[ "$(nmoves)" = 1 ] && ok || bad "3: moving off main must log exactly one line (got: $(cat "$MOVES"))"
grep -q 'side2' "$MOVES" && ok || bad "3: the move line must name side2: $(cat "$MOVES")"
# a file checkout on a side branch is not a move off main
echo changed >> "$T/ck/fleet.conf"
git -C "$T/ck" checkout -q -- fleet.conf
RC3B=$?
[ "$RC3B" = 0 ] && ok || bad "3: a file checkout must exit 0 (rc=$RC3B)"
[ "$(nmoves)" = 1 ] \
  && ok || bad "3: a file checkout must not log a move off main (got $(nmoves) lines: $(cat "$MOVES"))"
git -C "$T/ck" checkout -q main
[ "$(nmoves)" = 1 ] && ok || bad "3: moving back to main must not log (got: $(cat "$MOVES"))"

# ── 4. a deploy re-installs an OLD hook of ours ──────────────────────────────
# This is what makes the fix reach the hub: its hook is already installed and
# executable, so an installer that returns early on -x would ship the fix to
# nothing.
git -C "$T/ck" branch -D side1 >/dev/null 2>&1
git -C "$T/ck" branch -D side2 >/dev/null 2>&1
cat > "$HOOK" <<'OLDHOOK'
#!/bin/bash
# log moves off main; installed by bin/harness-sync.sh
new_branch=$(git symbolic-ref --short HEAD 2>/dev/null)
[ "$new_branch" = main ] && exit 0
h=${HARNESS:-/root/harness}
echo "v1 line $new_branch" >> "$h/logs/checkout-moves.log"
OLDHOOK
chmod +x "$HOOK"
sync
[ "$RC" = 0 ] && ok || bad "4: deploy over an old own hook must exit 0 (rc=$RC): $(cat "$T/out.txt") $(cat "$T/err.txt")"
grep -q 'v2' "$HOOK" 2>/dev/null \
  && ok || bad "4: an old hook of ours must be re-installed at v2 (got: $(cat "$HOOK"))"
[ "$(tail -n 1 "$HOOK" 2>/dev/null)" = "exit 0" ] \
  && ok || bad "4: the re-installed hook must end with 'exit 0'"
# and the re-installed hook behaves: rc 0 with logs/ absent
( cd "$T/ck" && HARNESS="$T/nologs" git checkout -q -b side3 ) >/dev/null 2>&1
RC4=$?
[ "$RC4" = 0 ] && ok || bad "4: the re-installed hook must not fail git checkout (rc=$RC4)"
git -C "$T/ck" checkout -q main; git -C "$T/ck" branch -D side3 >/dev/null 2>&1

# ── 5. a second deploy leaves an up-to-date hook alone, and a foreign hook
#      is never overwritten (the BH-1099 promise) ─────────────────────────────
cp "$HOOK" "$T/hook-v2.copy"
sync
cmp -s "$HOOK" "$T/hook-v2.copy" \
  && ok || bad "5: a v2 hook must not be rewritten by a later deploy"
printf '#!/bin/bash\n# mine\nexit 0\n' > "$HOOK"
chmod +x "$HOOK"
cp "$HOOK" "$T/hook-foreign.copy"
sync
[ "$RC" = 0 ] && ok || bad "5: deploy with a foreign hook must exit 0 (rc=$RC)"
cmp -s "$HOOK" "$T/hook-foreign.copy" \
  && ok || bad "5: a hand-written hook must be left byte-identical (got: $(cat "$HOOK"))"

echo "harness-sync-hook.bh-1128-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
