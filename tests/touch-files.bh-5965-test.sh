#!/bin/bash
# tests/touch-files.bh-5965-test.sh — bin/touch-files.sh reads ONLY the plan's
# declared `## Files to touch` section (BH-5965).
#
# The REAL bin/touch-files.sh runs on fixture build dirs. Each case asserts the
# three files it owns: touch-files.txt, touch-files.src and touch-source.
#
#   T1  Modified path claimed; a prose task mention and a Not-touched line are not
#   T2  table: cell 1 is claimed, a path in the change column is not
#   T3  numbered list with Product: / Tests ...: labels
#   T4  `- new: a, b` label item
#   T5  "— not touched; read only" excluded; a not-touched caller after the lead is not claimed
#   T6  ### Not touched sub-heading excludes, the next ### Modified claims again
#   T7  a path both Modified and Not touched stays claimed, two .src rows
#   T8  no heading -> none;  T9 heading with "None." -> none
#   T10 placeholder, glob, URL, line suffix, ./ prefix
#   T11 bin/deploy.sh and a root next.config.js are claimed (no allowlist)
#   T12 kill switch: env, then the settings row
#   T13 a fenced block inside the section does not end it; a deeper heading stays inside
#   T14 no plan.md / no build dir;  T15 a negative counts only where an annotation starts with it
#   T16 a negative list label, and a prose line with the negative after its first word
#
# No network, no gh, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TF="$DIR/bin/touch-files.sh"
[ -x "$TF" ] && ok || bad "setup: bin/touch-files.sh is missing or not executable"
H="$T/h"; mkdir -p "$H/state" "$H/flags" "$H/logs"
B="$T/b"
tf() { # tf <plan-text> [env...] -> runs the real script on $B
  local plan="$1"; shift
  scratch_rm "$B"; mkdir -p "$B"
  printf '%s\n' "$plan" > "$B/plan.md"
  env HARNESS="$H" "$@" bash "$TF" "$B" acme 2>"$T/err.txt"
  RC=$?
}
src()   { cat "$B/touch-source" 2>/dev/null; }
touch_list() { paste -sd, "$B/touch-files.txt" 2>/dev/null; }
row()   { grep -qxF "$(printf '%s\tL%s\t%s' "$1" "$2" "$3")" "$B/touch-files.src" 2>/dev/null; }
line_of() { grep -nF -- "$1" "$B/plan.md" | head -1 | cut -d: -f1; }

# ---------- T1. the ticket's shape --------------------------------------------
tf '# Plan TK-35
## Files to touch
- `src/a.ts` (Modified)

Not touched: `scripts/checks/company-query.mjs`

## Tasks
### Task 1
Add the table. `scripts/checks/company-query.mjs` is the check that covers new tables.'
[ "$RC" = 0 ] && ok || bad "T1: rc must be 0, got $RC"
[ "$(src)" = declared ] && ok || bad "T1: touch-source must be declared, got [$(src)]"
[ "$(touch_list)" = "src/a.ts" ] && ok || bad "T1: touch-files.txt must be exactly src/a.ts, got [$(touch_list)]"
L=$(line_of 'Not touched:')
row scripts/checks/company-query.mjs "$L" excluded && ok \
  || bad "T1: .src must have company-query.mjs L$L excluded: [$(cat "$B/touch-files.src" 2>/dev/null)]"
row src/a.ts 3 touch && ok || bad "T1: .src must have src/a.ts L3 touch"
grep -q "$(printf '\tL9\t')" "$B/touch-files.src" && bad "T1: the task paragraph (L9) is outside the section and must not be read" || ok

# ---------- T2. table: first cell only ------------------------------------------
tf '# Plan
## Files to touch
| file | change |
|---|---|
| `bin/x/y.sh` | edit; the caller `bin/x/z.sh` stays as it is |
| src/b.ts | new |'
[ "$(touch_list)" = "bin/x/y.sh,src/b.ts" ] && ok || bad "T2: want bin/x/y.sh,src/b.ts, got [$(touch_list)]"
grep -q 'bin/x/z.sh' "$B/touch-files.src" && bad "T2: a path in the change column is not an item path" || ok
grep -qi '^file' "$B/touch-files.src" && bad "T2: the header row must not yield a row" || ok

# ---------- T3. numbered list with labels -----------------------------------------
tf '# Plan
## 3. Files to touch
1. Product: `bin/p.sh`, `bin/lib/q.sh`
2. Tests (per-ticket, new files): `tests/r.bh-1-test.sh`
3. Docs:
   - `docs/notes/2026-10-10-X-1-n.md`
Product:
- `bin/s.sh`'
[ "$(touch_list)" = "bin/lib/q.sh,bin/p.sh,bin/s.sh,docs/notes/2026-10-10-X-1-n.md,tests/r.bh-1-test.sh" ] && ok \
  || bad "T3: want all five item paths, got [$(touch_list)]"
[ "$(grep -c excluded "$B/touch-files.src")" = 0 ] && ok || bad "T3: nothing is excluded"

# ---------- T4. "new:" label item ---------------------------------------------------
tf '# Plan
## Files to touch
- new: `a/b/c.sh`, `a/b/d.sh`
- edited (hotspots, call lines only): `bin/lib/rb/plan.sh`'
[ "$(touch_list)" = "a/b/c.sh,a/b/d.sh,bin/lib/rb/plan.sh" ] && ok || bad "T4: want a/b/c.sh,a/b/d.sh,bin/lib/rb/plan.sh, got [$(touch_list)]"

# ---------- T5. a negative after the lead -----------------------------------------
tf '# Plan
## Files to touch
- `x/y/z.sh` — not touched; read only
- `x/y/w.sh` — edit; the caller `x/y/v.sh` is not touched'
[ "$(touch_list)" = "x/y/w.sh" ] && ok || bad "T5: want only x/y/w.sh, got [$(touch_list)]"
row x/y/z.sh 3 excluded && ok || bad "T5: z.sh must be an excluded row: [$(cat "$B/touch-files.src")]"
grep -q 'x/y/v.sh' "$B/touch-files.src" && bad "T5: v.sh is after the lead and never an item path" || ok

# ---------- T6. sub-headings --------------------------------------------------------
tf '# Plan
## Files to touch
### Modified
- `src/m1.ts`
### Not touched
- `src/n1.ts`
### Modified, part 2
- `src/m2.ts`
## Tasks
- `src/t1.ts`'
[ "$(touch_list)" = "src/m1.ts,src/m2.ts" ] && ok || bad "T6: want src/m1.ts,src/m2.ts, got [$(touch_list)]"
row src/n1.ts 6 excluded && ok || bad "T6: n1 must be excluded at L6"
grep -q 'src/t1.ts' "$B/touch-files.src" && bad "T6: a same-level heading ends the section" || ok

# ---------- T7. both sides: kept --------------------------------------------------
tf '# Plan
## Files to touch
**Modified:**
- `src/both.ts`
- `src/only.ts`
**Not touched:**
- `src/both.ts`'
[ "$(touch_list)" = "src/both.ts,src/only.ts" ] && ok || bad "T7: want src/both.ts kept, got [$(touch_list)]"
row src/both.ts 4 touch && row src/both.ts 7 excluded && ok || bad "T7: want both rows for src/both.ts: [$(cat "$B/touch-files.src")]"

# ---------- T8 / T9. fallback ------------------------------------------------------
tf '# Plan
## Tasks
Edit `src/a.ts`.'
[ "$(src)" = none ] && [ ! -e "$B/touch-files.txt" ] && ok || bad "T8: no heading -> none and no txt, got [$(src)]"
tf '# Plan
## Files to touch
None.
## Tasks
Edit `src/a.ts`.'
[ "$(src)" = none ] && [ ! -e "$B/touch-files.txt" ] && ok || bad "T9: None. -> none and no txt, got [$(src)]"
tf '# Plan
## Files to touch
Not touched: `src/a.ts`'
[ "$(src)" = none ] && ok || bad "T9b: a section with only excluded paths -> none, got [$(src)]"

# ---------- T10. normalisation ------------------------------------------------------
tf '# Plan
## Files to touch
- `cron/<box>.cron`
- `tests/*.sh`
- `https://example.com/src/u.ts`
- `bin/x.sh:120`
- `./src/a.ts`
- `../up/x.sh`'
[ "$(touch_list)" = "bin/x.sh,src/a.ts" ] && ok || bad "T10: want bin/x.sh,src/a.ts, got [$(touch_list)]"

# ---------- T11. no allowlist ----------------------------------------------------
tf '# Plan
## Files to touch
- `bin/deploy.sh` — one flag
- `next.config.js` — one line'
[ "$(touch_list)" = "bin/deploy.sh,next.config.js" ] && ok || bad "T11: want bin/deploy.sh,next.config.js, got [$(touch_list)]"

# ---------- T12. kill switch ------------------------------------------------------
PLAN_T12='# Plan
## Files to touch
- `src/a.ts`'
tf "$PLAN_T12"
[ "$(src)" = declared ] && ok || bad "T12: fixture must be declared first"
cp "$B/touch-files.txt" "$T/t12.txt"
scratch_rm "$B"; mkdir -p "$B"; printf '%s\n' "$PLAN_T12" > "$B/plan.md"; cp "$T/t12.txt" "$B/touch-files.txt"
env HARNESS="$H" PLAN_TOUCH_DECLARED=0 bash "$TF" "$B" acme; RC=$?
[ "$RC" = 0 ] && [ "$(src)" = off ] && [ ! -e "$B/touch-files.txt" ] && ok \
  || bad "T12: PLAN_TOUCH_DECLARED=0 -> off and a stale txt removed, got rc=$RC src=[$(src)]"
tf "$PLAN_T12" PLAN_TOUCH_DECLARED=Off
[ "$(src)" = off ] && ok || bad "T12: PLAN_TOUCH_DECLARED=Off -> off, got [$(src)]"
jq -nc '{fetched_at:1760000000, values:{"switch.plan-touch-off":"1"}, seeded:{}}' > "$H/state/settings-cache.json"
tf "$PLAN_T12" LANE_GATE_NOW=1760000010
[ "$(src)" = off ] && [ ! -e "$B/touch-files.txt" ] && ok || bad "T12: settings row switch.plan-touch-off=1 -> off, got [$(src)]"
jq -nc '{fetched_at:1760000000, values:{"switch.plan-touch-off":"0"}, seeded:{}}' > "$H/state/settings-cache.json"
tf "$PLAN_T12" LANE_GATE_NOW=1760000010
[ "$(src)" = declared ] && ok || bad "T12: settings row switch.plan-touch-off=0 -> declared, got [$(src)]"
rm -f "$H/state/settings-cache.json"

# ---------- T13. fences and deeper headings -----------------------------------------
tf '# Plan
## Files to touch
```bash
# a comment that looks like a heading
```
#### Product
- `src/after-fence.ts`
## Tasks'
[ "$(touch_list)" = "src/after-fence.ts" ] && ok || bad "T13: a fenced # line must not end the section, got [$(touch_list)]"

# ---------- T15. a negative inside an annotation does not drop the item --------------
# Line 5 is verbatim from the committed plan .harness/specs/BH-5915/plan.md: no
# lead separator, and its last note says "never edit" about a third file.
tf '# Plan
## Files to touch
- `src/k.ts` — keep `helper()` unchanged, add one arm
- `src/r.ts` (read only)
5. Docs: `docs/notes/2026-10-10-BH-5915-lead-report-transcript.md` (D37 dated note, with a `Doc:` line), `docs/verification-map/entries/BH-5915-lead-report-transcript.md` (new entry, D51; never edit the BH-2532 entry).
| `src/t.ts` | edit; the old caller stays unchanged |
| `src/u.ts` | unchanged |'
[ "$(touch_list)" = "docs/notes/2026-10-10-BH-5915-lead-report-transcript.md,docs/verification-map/entries/BH-5915-lead-report-transcript.md,src/k.ts,src/t.ts" ] && ok \
  || bad "T15: want both docs paths, src/k.ts and src/t.ts, got [$(touch_list)]"
row src/r.ts 4 excluded && row src/u.ts 7 excluded && ok || bad "T15: (read only) and a change cell 'unchanged' are excluded: [$(cat "$B/touch-files.src")]"

# ---------- T16. a negative label item and a "Confirmed, not touched" prose line ----------
tf '# Plan
## Files to touch
- `src/keep.ts`
- Unchanged (callers only): `src/l.ts`
Confirmed, not touched: `src/c.ts`, checked with the graph.'
[ "$(touch_list)" = "src/keep.ts" ] && ok || bad "T16: want only src/keep.ts, got [$(touch_list)]"
row src/l.ts 4 excluded && row src/c.ts 5 excluded && ok || bad "T16: l.ts and c.ts must be excluded rows: [$(cat "$B/touch-files.src")]"

# ---------- T14. missing plan.md / missing build dir ------------------------------------
scratch_rm "$B"; mkdir -p "$B"
env HARNESS="$H" bash "$TF" "$B" acme; RC=$?
[ "$RC" = 0 ] && [ "$(src)" = none ] && ok || bad "T14: no plan.md -> rc 0 none, got rc=$RC [$(src)]"
env HARNESS="$H" bash "$TF" "$T/does-not-exist" acme; RC=$?
[ "$RC" = 0 ] && [ ! -e "$T/does-not-exist" ] && ok || bad "T14: a missing build dir is rc 0 and creates nothing"

echo "touch-files.bh-5965: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
