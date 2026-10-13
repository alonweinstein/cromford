#!/bin/bash
# tests/wake-push-prompts-fetch.bh-1351-test.sh — prompts_touched fetches the
# pushed sha before diffing, and the two wake-class cooldown windows are knobs.
#
# WHY. A push wake carries the push's own `after` sha, and it is drained within
# seconds of the delivery. Nothing fetches that sha into /root/harness-checkout
# before wc_push_dispatch asks about it, so the old `cat-file -e` answered
# "unknown sha" on every real push and prompt-eval was never launched — the
# dispatch was inert on the normal path. These cases use REAL git (no fake git
# on PATH) against a real origin, because the thing under test IS the fetch.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-push-prompts-fetch.bh-1351-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

G() { git -c user.email=t@example.invalid -c user.name=harness-test "$@"; }

# --- fixture: an origin with two commits the clone has never seen ------------
mkdir -p "$T/origin"
G init -q "$T/origin"
G -C "$T/origin" commit -q --allow-empty -m base
# Serve a reachable commit by sha to `git fetch origin <sha>` — GitHub does this
# by default (actions/checkout relies on it); a local origin must be told to.
git -C "$T/origin" config uploadpack.allowReachableSHA1InWant true
git clone -q "$T/origin" "$T/checkout"

mkdir -p "$T/origin/prompts"
echo x > "$T/origin/prompts/x.md"
G -C "$T/origin" add prompts
G -C "$T/origin" commit -q -m "prompts push"
SHA_PROMPTS=$(git -C "$T/origin" rev-parse HEAD)

mkdir -p "$T/origin/bin"
echo x > "$T/origin/bin/x.sh"
G -C "$T/origin" add bin
G -C "$T/origin" commit -q -m "bin push"
SHA_BIN=$(git -C "$T/origin" rev-parse HEAD)

HARNESS_CHECKOUT="$T/checkout"
mkdir -p "$T/calls" "$T/bin"
# shellcheck source=/dev/null
. "$DIR/bin/lib/wake-class-push.sh"

calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# F1. a sha the checkout already has is NOT fetched
# ---------------------------------------------------------------------------
mkdir -p "$T/checkout/prompts"
echo y > "$T/checkout/prompts/y.md"
G -C "$T/checkout" add prompts
G -C "$T/checkout" commit -q -m "local prompts commit"
SHA_LOCAL=$(git -C "$T/checkout" rev-parse HEAD)
rm -f "$T/checkout/.git/FETCH_HEAD"
prompts_touched "$SHA_LOCAL" 2>"$T/f1.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "F1 a local prompts sha must answer rc 0 (got $RC, stderr: $(cat "$T/f1.err"))"
[ ! -e "$T/checkout/.git/FETCH_HEAD" ] && ok || bad "F1 a sha already local must not fetch (FETCH_HEAD appeared)"

# ---------------------------------------------------------------------------
# F2. a sha only at origin IS fetched, and the fetch moves no remote-tracking ref
# ---------------------------------------------------------------------------
# bin/fleet-propagate.sh fetches into this same checkout and DOES move
# refs/remotes/origin/main. An object-only sha fetch must not contend with it.
REFS_BEFORE=$(git -C "$T/checkout" for-each-ref refs/remotes)
git -C "$T/checkout" cat-file -e "$SHA_PROMPTS^{commit}" 2>/dev/null \
  && bad "F2 fixture broken: the pushed sha was already local before the call" || ok
prompts_touched "$SHA_PROMPTS" 2>"$T/f2.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "F2 a prompts sha only at origin must answer rc 0 after the fetch (got $RC, stderr: $(cat "$T/f2.err"))"
git -C "$T/checkout" cat-file -e "$SHA_PROMPTS^{commit}" 2>/dev/null \
  && ok || bad "F2 the fetch must leave the commit object in the checkout"
REFS_AFTER=$(git -C "$T/checkout" for-each-ref refs/remotes)
[ "$REFS_BEFORE" = "$REFS_AFTER" ] && ok || bad "F2 the sha fetch moved a remote-tracking ref (before: $REFS_BEFORE / after: $REFS_AFTER)"

# ---------------------------------------------------------------------------
# F3. a fetched sha that touches no prompts/ is a QUIET no
# ---------------------------------------------------------------------------
prompts_touched "$SHA_BIN" 2>"$T/f3.err"; RC=$?
[ "$RC" -ne 0 ] && ok || bad "F3 a bin-only sha must answer nonzero (got $RC)"
[ ! -s "$T/f3.err" ] && ok || bad "F3 a fetched non-prompts sha must log nothing (got: $(cat "$T/f3.err"))"

# ---------------------------------------------------------------------------
# F4. the production dispatch: wc_push_dispatch's launcher argv
# ---------------------------------------------------------------------------
rm -rf "$T/calls"; mkdir -p "$T/calls"
SELF="$T/bin"
cooled() { echo "$*" >> "$T/calls/cooled"; return 0; }
launch() { echo "$*" >> "$T/calls/dispatch-launch"; }
remote_launch() { echo "$*" >> "$T/calls/dispatch-remote"; }
wc_push_row project-3 push k1 push example-org/project-3 1
wc_push_row cromford push "$SHA_PROMPTS" push example-org/cromford 2
wc_push_dispatch
[ "$(calls dispatch-launch)" = 2 ] && ok || bad "F4 a prompts push must launch fleet-propagate and prompt-eval (got $(calls dispatch-launch): $(tr '\n' '|' < "$T/calls/dispatch-launch" 2>/dev/null))"
grep -qx "push\[cromford\] fleet-propagate $T/bin/fleet-propagate.sh" "$T/calls/dispatch-launch" \
  && ok || bad "F4 fleet-propagate launch argv wrong (got '$(tr '\n' '|' < "$T/calls/dispatch-launch" 2>/dev/null)')"
grep -qx "push\[cromford\] prompt-eval $T/bin/prompt-eval.sh --cron" "$T/calls/dispatch-launch" \
  && ok || bad "F4 prompt-eval must be launched as '--cron' with no positional (got '$(tr '\n' '|' < "$T/calls/dispatch-launch" 2>/dev/null)')"
grep -qx 'prompt-eval cromford 86400' "$T/calls/cooled" \
  && ok || bad "F4 the prompt-eval cooldown must default to 86400 (got '$(tr '\n' '|' < "$T/calls/cooled" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# K1. WAKE_PROMPT_EVAL_COOLDOWN_S moves that window
# ---------------------------------------------------------------------------
rm -rf "$T/calls"; mkdir -p "$T/calls"
wc_push_row cromford push "$SHA_PROMPTS" push example-org/cromford 3
WAKE_PROMPT_EVAL_COOLDOWN_S=9 wc_push_dispatch
grep -qx 'prompt-eval cromford 9' "$T/calls/cooled" \
  && ok || bad "K1 WAKE_PROMPT_EVAL_COOLDOWN_S=9 must reach cooled (got '$(tr '\n' '|' < "$T/calls/cooled" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# F5. an unreachable origin fails CLOSED: one line, no launch, bounded
# ---------------------------------------------------------------------------
git -C "$T/checkout" remote set-url origin "$T/nope"
BOGUS=0123456789abcdef0123456789abcdef01234567
SECONDS=0
prompts_touched "$BOGUS" 2>"$T/f5.err"; RC=$?
ELAPSED=$SECONDS
[ "$RC" -ne 0 ] && ok || bad "F5 a sha nothing can serve must answer nonzero (got $RC)"
[ "$(wc -l < "$T/f5.err" | tr -d ' ')" = 1 ] && ok || bad "F5 must log exactly one line (got: $(cat "$T/f5.err"))"
grep -q 'not local after fetch' "$T/f5.err" && ok || bad "F5 the line must say the sha is not local after the fetch (got: $(cat "$T/f5.err"))"
[ "$ELAPSED" -lt 60 ] && ok || bad "F5 the fetch must be bounded (took ${ELAPSED}s)"

# the same failure, through the dispatch: fleet-propagate still runs, prompt-eval does not
rm -rf "$T/calls"; mkdir -p "$T/calls"
wc_push_row cromford push "$BOGUS" push example-org/cromford 4
wc_push_dispatch 2>/dev/null
[ "$(calls dispatch-launch)" = 1 ] && ok || bad "F5 a failed fetch must launch fleet-propagate only (got $(calls dispatch-launch): $(tr '\n' '|' < "$T/calls/dispatch-launch" 2>/dev/null))"
! grep -q 'prompt-eval' "$T/calls/dispatch-launch" && ok || bad "F5 a failed fetch must never launch the metered prompt-eval lane"

# ---------------------------------------------------------------------------
# K2. the flaky class's cooldown is a knob too
# ---------------------------------------------------------------------------
rm -rf "$T/calls"; mkdir -p "$T/calls"
# shellcheck source=/dev/null
. "$DIR/bin/lib/wake-class-flaky.sh"
wc_flaky_row project-3 checks k check_suite.completed example-org/project-3 5
wc_flaky_dispatch
grep -qx 'flaky-detect project-3 21600' "$T/calls/cooled" \
  && ok || bad "K2 the flaky cooldown must default to 21600 (got '$(tr '\n' '|' < "$T/calls/cooled" 2>/dev/null)')"

rm -rf "$T/calls"; mkdir -p "$T/calls"
wc_flaky_row project-3 checks k check_suite.completed example-org/project-3 6
WAKE_FLAKY_COOLDOWN_S=7 wc_flaky_dispatch
grep -qx 'flaky-detect project-3 7' "$T/calls/cooled" \
  && ok || bad "K2 WAKE_FLAKY_COOLDOWN_S=7 must reach cooled (got '$(tr '\n' '|' < "$T/calls/cooled" 2>/dev/null)')"

# ---------------------------------------------------------------------------
echo "wake-push-prompts-fetch.bh-1351-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
