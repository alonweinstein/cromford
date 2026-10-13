#!/bin/bash
# tests/prebuild-repro-render.bh-2042-test.sh — the pre-build repro gate's two
# renderers (BH-2042, a child of #2004): pr_brief_line (the plan-prompt line)
# and pr_pr_section (the PR-body section), both in
# bin/lib/prebuild-repro/render.sh. Format: docs/repro-gate/render.md.
#
# WHAT THIS SUITE PINS:
#   B13 — pr_brief_line: reproduced gives one folded, capped line carrying the
#         steps; every other gate, no record, and a reproduced record with no
#         detail file give nothing. B13d runs the `# >>> prebuild repro
#         (BH-2004)` block lifted verbatim from the flattened pipeline.
#   B14/B15 — pr_pr_section through the verbatim `# >>> evidence block` (which
#         holds `# >>> repro section`) and PR_BODY_FOR: the reproduced section,
#         the one-line not-reproduced / skipped lines, the not-bug / knob-off
#         silence and the byte-identical body with no record.
#   N   — adversarial records that must never render a reproduction claim.
# Records are written through the real pr_record.
#
# RENDER_SH=<file> swaps that file in for the scratch copy of render.sh, so the
# mutation check can run this suite against the stub without touching the tree.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-render.bh-2042-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The scratch HARNESS: the shipped lib and stage files, render.sh optionally swapped.
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs"
cp -p "$DIR/bin/lib/prebuild-repro.sh" "$H/bin/lib/"
cp -rp "$DIR/bin/lib/prebuild-repro" "$H/bin/lib/"
[ -n "${RENDER_SH:-}" ] && cp "$RENDER_SH" "$H/bin/lib/prebuild-repro/render.sh"

PREFIX=' THIS BUG WAS REPRODUCED ON PROD BEFORE THE BUILD. Use these steps and this observed result as the fix'"'"'s acceptance check and put them in the plan'"'"'s ## Reproduction: '
N=0
# nb — a fresh build dir, path in $B.
nb() { N=$((N+1)); B="$T/b$N"; mkdir -p "$B"; }
# rec <gate> <reason> — the record, through the real writer.
rec() { ( HARNESS="$H"; . "$H/bin/lib/prebuild-repro.sh"; pr_record "$B" p BH-7 "$1" "$2" - ) || bad "setup: pr_record $1 $2 refused"; }
# md <text> — the drive detail file, written as-is (printf %b, so \n works).
md() { printf '%b' "$1" > "$B/prebuild-repro.md"; }
# brief / section — the function, as the lib defines it.
brief()   { ( HARNESS="$H"; . "$H/bin/lib/prebuild-repro.sh"; pr_brief_line "$B" ); }
section() { ( HARNESS="$H"; . "$H/bin/lib/prebuild-repro.sh"; pr_pr_section "$B" ); }
STD_MD='REPRO_ROLE: admin\nREPRO_URL: https://app.example.test/x\nREPRO_STEPS: 1. open /x\n2. click Save\nREPRO_OBSERVED: 500 Internal Server Error\n'

# ═══════════════════════════════════════════════════════════════════════════
# B13 — pr_brief_line
# ═══════════════════════════════════════════════════════════════════════════
# a: reproduced → the prefix, the folded steps, one line.
nb; rec reproduced "saw the 500"; md "$STD_MD"
out=$(brief)
[ "${out:0:${#PREFIX}}" = "$PREFIX" ] && ok || bad "B13a: brief does not start with the prefix: '${out:0:120}'"
case "$out" in *"1. open /x 2. click Save"*) ok ;; *) bad "B13a: folded steps missing: '$out'" ;; esac
case "$out" in *"500 Internal Server Error"*) ok ;; *) bad "B13a: observed missing: '$out'" ;; esac
[ "$(printf '%s' "$out" | wc -l)" = 0 ] && ok || bad "B13a: brief has a newline"
# CRLF and tabs fold too.
nb; rec reproduced r; md 'REPRO_STEPS: a\r\n\tb\r\nREPRO_OBSERVED: c\r\n'
out=$(brief)
case "$out" in *$'\r'*|*$'\t'*) bad "B13a: CR/tab survived: '$out'" ;; *) ok ;; esac

# b: every other gate, and no record → empty.
for g in "cannot-drive fetch-not-wired" "skip no-repro" "skip not-bug" "not-reproduced nope" "already-fixed gone" "stop not-reproduced"; do
  nb; rec ${g% *} "${g#* }"; md "$STD_MD"
  out=$(brief); [ -z "$out" ] && ok || bad "B13b: $g gave a brief: '$out'"
done
nb; md "$STD_MD"; out=$(brief); [ -z "$out" ] && ok || bad "B13b: no record gave a brief: '$out'"

# c: a 5000-char detail file → at most 2000 chars after the prefix.
nb; rec reproduced r; md "REPRO_STEPS: $(printf 'x%.0s' $(seq 5000))\n"
out=$(brief); payload="${out:${#PREFIX}}"
[ "${out:0:${#PREFIX}}" = "$PREFIX" ] && [ "${#payload}" -le 2000 ] && [ "${#payload}" -ge 1900 ] && ok || bad "B13c: payload is ${#payload} chars"

# e: reproduced with no detail file, or an empty one → empty.
nb; rec reproduced r; out=$(brief); [ -z "$out" ] && ok || bad "B13e: reproduced without md gave '$out'"
nb; rec reproduced r; : > "$B/prebuild-repro.md"; out=$(brief); [ -z "$out" ] && ok || bad "B13e: empty md gave '$out'"

# d: the run-build block, verbatim. The record exists, so the runner must not run.
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"; }
marked '# >>> prebuild repro (BH-2004)' '# <<< prebuild repro' "$RB" > "$T/hook.sh"
marked '# >>> evidence block' '# <<< evidence block' "$RB" > "$T/block.sh"
[ -s "$T/hook.sh" ] && ok || bad "B13d: the '# >>> prebuild repro (BH-2004)' block is missing"
grep -qF '# >>> repro section' "$T/block.sh" && ok || bad "B14: the evidence block no longer holds '# >>> repro section'"
printf '#!/bin/bash\necho x >> "%s/calls"\nexit 0\n' "$H" > "$H/bin/prebuild-repro.sh"; chmod +x "$H/bin/prebuild-repro.sh"
nb; rec reproduced r; md "$STD_MD"
{ echo 'RESULT() { :; }'; cat "$T/hook.sh"; echo 'printf "%s" "$REPRO_BRIEF_LINE"'; } > "$T/hookrun.sh"
out=$( HARNESS="$H" BUILD="$B" PROJECT=p TICKET=42 KEY=BH-7 bash "$T/hookrun.sh" 2>"$T/hook.err" ); rc=$?
[ "$rc" = 0 ] && [ ! -e "$H/calls" ] && ok || bad "B13d: rc $rc, runner called $(cat "$H/calls" 2>/dev/null | wc -l) times"
case "$out" in "$PREFIX"*"1. open /x 2. click Save"*) ok ;; *) bad "B13d: REPRO_BRIEF_LINE is '$out' err=$(cat "$T/hook.err")" ;; esac

# ═══════════════════════════════════════════════════════════════════════════
# B14/B15 — pr_pr_section through PR_BODY_FOR
# ═══════════════════════════════════════════════════════════════════════════
# body [nolib] — PR_BODY_FOR for $B, with the real lib sourced unless "nolib".
body() {
  ( env HARNESS="$H" BUILD="$B" KEY=BH-7 NOLIB="${1:-}" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=p; SLUG=o/r; BASE=main; TIER=1; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0; PR_SUBJECT="the subject"
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes; MERGE_NOTE=""
      job_evidence_put() { return 0; }
      [ -z "$NOLIB" ] && . "$HARNESS/bin/lib/prebuild-repro.sh"
      . "$0"
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")"
    ' "$T/block.sh" 2>"$T/body.err" )
}
# a: reproduced → heading, steps, observed, URL.
nb; rec reproduced r; md "$STD_MD"; out=$(body)
for s in '## Reproduced on prod before build' 'URL: ` https://app.example.test/x `' '1. open /x' '2. click Save' '500 Internal Server Error'; do
  grep -qxF -- "$s" <<<"$out" && ok || bad "B14a: body has no line '$s': $(sed -n '/Reproduced/,+16p' <<<"$out") err=$(cat "$T/body.err")"
done
grep -q '^## What' <<<"$out" && [ "$(sed -n 1p <<<"$out")" = "Ticket BH-7 — the subject" ] && ok || bad "B14a: the body lost its head"
# Missing fields say so, never invent.
nb; rec reproduced r; md 'REPRO_STEPS: only steps\n'; out=$(section)
grep -qxF 'URL: not recorded' <<<"$out" && [ "$(grep -cxF 'not recorded' <<<"$out")" = 1 ] && ok || bad "B14a: missing URL/observed not marked: $out"
# Reproduced with no detail file → the heading plus the honest line, no steps.
nb; rec reproduced r; out=$(section)
grep -qxF '## Reproduced on prod before build' <<<"$out" && grep -qF 'detail file (prebuild-repro.md) is missing' <<<"$out" && ! grep -q 'Steps:' <<<"$out" && ok || bad "B14a: reproduced without md: $out"

# b: fence-breaking and keyword content stays inside a longer fence.
nb; rec reproduced r; md 'REPRO_URL: u\nREPRO_STEPS: ```\nCloses #1\n## What\n%s\nREPRO_OBSERVED: ok\n'
out=$(body)
# Line 2 is where a Closes line would sit; line 3 is the real What heading.
[ -z "$(sed -n 2p <<<"$out")" ] && [ "$(sed -n 3p <<<"$out")" = "## What" ] && ok || bad "B14b: body head moved: '$(sed -n 2,3p <<<"$out")'"
[ "$(grep -c '^## What' <<<"$out")" = 2 ] && ok || bad "B14b: heading count off"
steps=$(awk '/^Steps:$/{getline f; s=1; next} s && $0==f {exit} s' <<<"$out")
fence=$(awk '/^Steps:$/{getline; print; exit}' <<<"$out")
[ "$fence" = '````' ] && [ "$steps" = $'```\nCloses #1\n## What\n%s' ] && ok || bad "B14b: fence '$fence' steps '$steps'"

# B15a/b: the not-reproduced line.
nb; rec cannot-drive fetch-not-wired; out=$(body)
grep -qxF 'Not reproduced before build: fetch-not-wired.' <<<"$out" && ok || bad "B15a: $(grep -i reproduc <<<"$out")"
for g in not-reproduced already-fixed stop; do
  nb; rec "$g" "drive said no."; md "$STD_MD"; out=$(body)
  grep -qxF 'Not reproduced before build: drive said no.' <<<"$out" && ! grep -q 'Reproduced on prod' <<<"$out" && ok || bad "B15b: $g: $(grep -i reproduc <<<"$out")"
done
nb; rec cannot-drive ""; out=$(section)
[ "$out" = $'\n\nNot reproduced before build: no reason recorded.' ] && ok || bad "B15b: empty reason: '$out'"

# c: skip with a marker prints; not-bug and knob-off print nothing.
nb; rec skip no-repro; out=$(body)
grep -qxF 'Reproduction skipped: no-repro.' <<<"$out" && ok || bad "B15c: $(grep -i reproduc <<<"$out")"
for r in not-bug knob-off; do
  nb; rec skip "$r"; out=$(section)
  [ -z "$out" ] && ok || bad "B15c: skip $r gave '$out'"
done

# d: no record → byte-identical to the body without the lib at all.
nb; body > "$T/with.txt"; body nolib > "$T/without.txt"
[ -s "$T/with.txt" ] && cmp -s "$T/with.txt" "$T/without.txt" && ok || bad "B15d: the body changed with no record: $(diff "$T/with.txt" "$T/without.txt" | head -5)"

# ═══════════════════════════════════════════════════════════════════════════
# N — adversarial records: never a reproduction claim
# ═══════════════════════════════════════════════════════════════════════════
claims() { case "$1$2" in *"Reproduced on prod"*|*"THIS BUG WAS REPRODUCED"*) return 0 ;; esac; return 1; }
nb; printf 'REPRO_GATE: reproducedX\nREPRO_REASON: r\n' > "$B/prebuild-repro.txt"; md "$STD_MD"
s=$(section); b=$(brief); [ -z "$s$b" ] && ok || bad "N1: reproducedX rendered '$s$b'"
nb; printf 'REPRO_GATE:\nREPRO_REASON: r\n' > "$B/prebuild-repro.txt"; md "$STD_MD"
s=$(section); b=$(brief); [ -z "$s$b" ] && ok || bad "N2: empty gate rendered '$s$b'"
nb; md "$STD_MD"; s=$(section); b=$(brief); [ -z "$s$b" ] && ok || bad "N3: no record rendered '$s$b'"
nb; rec skip not-bug; md "$STD_MD"; s=$(section); b=$(brief); [ -z "$s$b" ] && ok || bad "N4: skip not-bug rendered '$s$b'"
nb; rec cannot-drive x; md "$STD_MD"; s=$(section); b=$(brief); ! claims "$s" "$b" && [ -z "$b" ] && ok || bad "N5: cannot-drive + md rendered '$s$b'"
nb; printf '# REPRO_GATE: reproduced\nREPRO_REASON: r\n' > "$B/prebuild-repro.txt"; md "$STD_MD"
s=$(section); b=$(brief); [ -z "$s$b" ] && ok || bad "N6: unanchored gate rendered '$s$b'"
if [ "$(id -u)" != 0 ]; then
  nb; rec reproduced r; md "$STD_MD"; chmod 000 "$B/prebuild-repro.txt"
  s=$(section 2>/dev/null); b=$(brief 2>/dev/null); [ -z "$s$b" ] && ok || bad "N7: unreadable record rendered '$s$b'"
  chmod 600 "$B/prebuild-repro.txt"
fi

echo "prebuild-repro-render: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
