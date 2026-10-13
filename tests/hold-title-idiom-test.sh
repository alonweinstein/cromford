#!/bin/bash
# tests/hold-title-idiom-test.sh — a TITLE holds only in the hold idiom:
# `(HOLD)`, `[HOLD]`, or `HOLD:` opening the title (2026-09-28).
#
# The title used to take HOLD_WORD_RE, the capital word anywhere, and `_` was
# not a word character to its lookarounds. So a ticket whose title DESCRIBES the
# hold feature — "per-PR HOLD / RESUME / DROP", or one naming the knob
# REVIEW_D1_HOLD_MAX_H — was held by its own title and never built: the body
# incident of BH-1461, again, one field over. The idiom forms still hold, and
# COMMENT holds are untouched (the word anywhere, as before).
#
# Both engines read the regex: jq (hold_classify) and python3 `re` (the
# fallbacks in bin/orphan-reconcile.sh and bin/launch-fastpath.sh), so both are
# driven here with the one exported string.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=bin/lib/hold.sh
. "$DIR/bin/lib/hold.sh" || { echo "FAIL: bin/lib/hold.sh did not source"; exit 1; }

ISSUE() { jq -nc --arg t "$1" '{number:9,state:"open",labels:[{name:"ai-build"}],title:$t,body:"## Scope"}'; }
CMT()   { jq -nc --arg b "$1" '[{body:$b,created_at:"2026-09-27T10:00:00Z",user:{type:"User"}}]'; }
verdict() { hold_classify "$1" "$2"; }

# THE CONTRACT, once, for all three readers (jq and both python fallbacks).
# Titles that DESCRIBE holds (a feature, a knob) are not holds:
CLEAR_TITLES=(
  'BH-2600: per-PR HOLD / RESUME / DROP on the merge lanes'
  'per-PR HOLD / RESUME'
  'BH-2611: make REVIEW_D1_HOLD_MAX_H a settings row'
  'REVIEW_D1_HOLD_MAX_H'
  'HOLD_X: rename the knob'
  'TK-9: HOLD_TIMEOUT knob for the pool'
  'BH-2620: show why a HOLD fired'
  'TK-9: honour HOLD on the PR thread'
)
# The idiom forms hold: (HOLD) / (ON HOLD) / [HOLD] anywhere; a leading
# `[ON ]HOLD` followed by `:` or a dash (the body rule's dashes), optionally
# after the ticket key the title leads with.
HELD_TITLES=(
  '(HOLD) foo' 'HOLD: foo' 'HOLD : foo' 'Compliance P7 (HOLD): EU residency'
  '[HOLD] TK-9 wait for the client' 'TK-9 the thing (HOLD)'
  'TK-9: HOLD: wait' 'TK-2416.0: HOLD: wait on the parent' 'TK-9 HOLD - x'
  'HOLD — waiting on client' 'HOLD - x' 'HOLD – x'
  'ON HOLD: x' 'TK-9: ON HOLD — client' 'TK-9 (ON HOLD) x'
)

# ── jq (hold_classify) ───────────────────────────────────────────────────────
for T0 in "${CLEAR_TITLES[@]}"; do
  V=$(verdict "$(ISSUE "$T0")" '[]'); RC=$?
  [ "$RC" = 0 ] && ok || bad "title '$T0' describes a hold and must not hold the ticket (rc $RC: $V)"
done
for T1 in "${HELD_TITLES[@]}"; do
  V=$(verdict "$(ISSUE "$T1")" '[]'); RC=$?
  [ "$RC" = 1 ] && ok || bad "title '$T1' is the hold idiom and must hold (rc $RC: $V)"
  case "$V" in "held	hold:title"*) ok ;; *) bad "title '$T1' must answer hold:title, got '$V'" ;; esac
done

# ── comment holds: the first non-blank line starts with HOLD (BH-6297) ──────
for C1 in 'HOLD — not yet' 'HOLD this until Monday' 'HOLD: REVIEW_D1_HOLD_MAX_H is wrong'; do
  V=$(verdict "$(ISSUE 'TK-9: a thing')" "$(CMT "$C1")"); RC=$?
  [ "$RC" = 1 ] && ok || bad "comment '$C1' opens with HOLD and must hold (rc $RC: $V)"
done
for C0 in 'please HOLD this until Monday' 'REVIEW_D1_HOLD_MAX_H is wrong, HOLD' 'per-PR HOLD / DROP'; do
  V=$(verdict "$(ISSUE 'TK-9: a thing')" "$(CMT "$C0")"); RC=$?
  [ "$RC" = 0 ] && ok || bad "comment '$C0' does not open with HOLD and must not hold (rc $RC: $V)"
done
[ "$HOLD_WORD_RE" = '(?<![A-Za-z])HOLD(?![A-Za-z])' ] && ok \
  || bad "HOLD_WORD_RE (the no-lib python fallback) must be unchanged, got '$HOLD_WORD_RE'"

# ── python3: the exported string AND each script's fallback literal ─────────
# Three readers, one contract: the lib's HOLD_TITLE_RE through the env (what
# python sees when the lib is loaded) and the literal fallback each python
# classifier compiles on a box mid-sync. All must be the same string and give
# the same answers as jq above.
if command -v python3 >/dev/null 2>&1; then
  [ -n "${HOLD_TITLE_RE:-}" ] && ok || bad "bin/lib/hold.sh must export HOLD_TITLE_RE for the python classifiers"
  PY=$(printf '%s\n' "${HELD_TITLES[@]}" > "$T/held.txt"; printf '%s\n' "${CLEAR_TITLES[@]}" > "$T/clear.txt"
       HOLD_TITLE_RE="${HOLD_TITLE_RE:-}" python3 - "$T/held.txt" "$T/clear.txt" \
         "$DIR/bin/orphan-reconcile.sh" "$DIR/bin/launch-fastpath.sh" <<'PYEOF'
import os, re, sys
held = open(sys.argv[1], encoding="utf-8").read().splitlines()
clear = open(sys.argv[2], encoding="utf-8").read().splitlines()
env = os.environ["HOLD_TITLE_RE"]
readers = [("env", env)]
for f in sys.argv[3:]:
    src = open(f, encoding="utf-8").read()
    m = re.search(r'title_re\s*=\s*re\.compile\(os\.environ\.get\("HOLD_TITLE_RE"\)\s*or\s*r"([^"]*)"\)', src)
    if not m:
        print("%s: no title_re fallback literal" % f); continue
    if m.group(1) != env:
        print("%s: fallback literal differs from HOLD_TITLE_RE" % f)
    readers.append((f, m.group(1)))
for name, rx in readers:
    r = re.compile(rx or r"(?!)")
    for t in held:
        if not r.search(t): print("%s: must hold %r" % (name, t))
    for t in clear:
        if r.search(t): print("%s: must NOT hold %r" % (name, t))
PYEOF
)
  [ -z "$PY" ] && ok || bad "python3 disagrees with the title contract: $PY"
fi

echo "hold-title-idiom: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
