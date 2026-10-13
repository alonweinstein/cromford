#!/bin/bash
# tests/prebuild-repro-url.bh-2123-test.sh — the repro section's URL line in the
# PR body (BH-2123). pr_pr_section in bin/lib/prebuild-repro/render.sh prints
# REPRO_URL, which is free text from the drive, in an inline code span and
# capped at 500 characters, so `fixes #1` or `@someone` in it can not close an
# issue or ping anyone in the client repo. Format: docs/repro-gate/render.md.
#
# WHAT THIS SUITE PINS:
#   U1 — a hostile URL renders as one padded code span, and nowhere else.
#   U2 — the same through the verbatim `# >>> evidence block` and PR_BODY_FOR.
#   U3 — 500 characters spanned whole; 501 cut to 500 with ` [truncated]`
#        outside the span.
#   U4 — backticks in the URL get a longer delimiter, and the span content is
#        the URL unchanged.
#   U5 — an empty URL is the plain `URL: not recorded`; a multi-line one is one
#        line.
# Records are written through the real pr_record.
#
# RENDER_SH=<file> swaps that file in for the scratch copy of render.sh, so the
# mutation check can run this suite against the render before BH-2123.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-url.bh-2123-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs"
cp -p "$DIR/bin/lib/prebuild-repro.sh" "$H/bin/lib/"
cp -rp "$DIR/bin/lib/prebuild-repro" "$H/bin/lib/"
[ -n "${RENDER_SH:-}" ] && cp "$RENDER_SH" "$H/bin/lib/prebuild-repro/render.sh"

N=0
nb() { N=$((N+1)); B="$T/b$N"; mkdir -p "$B"; }
rec() { ( HARNESS="$H"; . "$H/bin/lib/prebuild-repro.sh"; pr_record "$B" p BH-7 "$1" "$2" - ) || bad "setup: pr_record $1 $2 refused"; }
# url <text> — a detail file whose URL is the text as-is (printf %s, no escapes).
url() { printf 'REPRO_URL: %s\nREPRO_STEPS: s\nREPRO_OBSERVED: o\n' "$1" > "$B/prebuild-repro.md"; }
section() { ( HARNESS="$H"; . "$H/bin/lib/prebuild-repro.sh"; pr_pr_section "$B" ); }
# span <line> — the span content of a `URL: ` line: strip `URL: `, the leading
# delimiter + space and the trailing space + delimiter (and a marker after it).
span() {
  local l="${1#URL: }" d
  d="${l%%[!\`]*}"
  l="${l#"$d" }"; l="${l% [truncated]}"; l="${l% "$d"}"
  printf '%s' "$l"
}

HOSTILE='https://x.test/a fixes #1 @someone'
WANT='URL: ` https://x.test/a fixes #1 @someone `'

# U1: the hostile value is one span line and appears nowhere else.
nb; rec reproduced r; url "$HOSTILE"; out=$(section)
grep -qxF -- "$WANT" <<<"$out" && ok || bad "U1: no line '$WANT': $(grep '^URL' <<<"$out")"
[ "$(grep -c 'fixes #1' <<<"$out")" = 1 ] && [ "$(grep 'fixes #1' <<<"$out")" = "$WANT" ] && ok || bad "U1: 'fixes #1' outside the span: $(grep -n 'fixes #1' <<<"$out")"
[ "$(grep -c '@someone' <<<"$out")" = 1 ] && [ "$(grep '@someone' <<<"$out")" = "$WANT" ] && ok || bad "U1: '@someone' outside the span"

# U2: production wiring — the verbatim evidence block into PR_BODY_FOR.
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk 'index($0,"# >>> evidence block"){f=1;next} index($0,"# <<< evidence block"){f=0} f' "$RB" > "$T/block.sh"
grep -qF '# >>> repro section' "$T/block.sh" && ok || bad "U2: the evidence block no longer holds '# >>> repro section'"
body() {
  ( env HARNESS="$H" BUILD="$B" KEY=BH-7 bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=p; SLUG=o/r; BASE=main; TIER=1; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0; PR_SUBJECT="the subject"
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes; MERGE_NOTE=""
      job_evidence_put() { return 0; }
      . "$HARNESS/bin/lib/prebuild-repro.sh"
      . "$0"
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")"
    ' "$T/block.sh" 2>"$T/body.err" )
}
nb; rec reproduced r; url "$HOSTILE"; out=$(body)
grep -qxF '## Reproduced on prod before build' <<<"$out" && ok || bad "U2: no repro heading in the body: err=$(cat "$T/body.err")"
grep -qxF -- "$WANT" <<<"$out" && ok || bad "U2: body has no line '$WANT': $(grep '^URL' <<<"$out")"
[ "$(grep -c 'fixes #1' <<<"$out")" = 1 ] && [ "$(grep -c '@someone' <<<"$out")" = 1 ] && [ "$(grep 'fixes #1' <<<"$out")" = "$WANT" ] && ok || bad "U2: hostile text outside the span: $(grep -n 'fixes #1\|@someone' <<<"$out")"

# U3: the cap. a = exactly 500 (whole, no marker); b = 501 (500 + marker).
U500="https://x.test/$(printf 'a%.0s' $(seq 485))"
nb; rec reproduced r; url "$U500"; line=$(section | grep '^URL: ')
[ "${#U500}" = 500 ] && [ "$line" = "URL: \` $U500 \`" ] && ok || bad "U3a: 500 chars not spanned whole: '${line:0:60}…${line: -30}'"
U501="${U500}b"
nb; rec reproduced r; url "$U501"; line=$(section | grep '^URL: ')
[ "$line" = "URL: \` $U500 \` [truncated]" ] && ok || bad "U3b: 501 chars not cut to 500 + marker: '${line:0:60}…${line: -30}'"
[ "${#line}" -le 522 ] && ok || bad "U3b: line is ${#line} chars"
nb; rec reproduced r; url "https://x.test/$(printf 'z%.0s' $(seq 5000)) fixes #9"; line=$(section | grep '^URL: ')
[ "${#line}" -le 522 ] && case "$line" in *'fixes #9'*) false ;; *' [truncated]') true ;; *) false ;; esac && ok || bad "U3b: 5000-char URL line is ${#line} chars"

# U4: backticks. a = runs of 1 → `` delimiter; b = trailing run of 2 → ```.
nb; rec reproduced r; url 'https://x.test/`a`b'; line=$(section | grep '^URL: ')
[ "$line" = 'URL: `` https://x.test/`a`b ``' ] && [ "$(span "$line")" = 'https://x.test/`a`b' ] && ok || bad "U4a: '$line'"
nb; rec reproduced r; url 'https://x.test/a``'; line=$(section | grep '^URL: ')
[ "$line" = 'URL: ``` https://x.test/a`` ```' ] && [ "$(span "$line")" = 'https://x.test/a``' ] && ok || bad "U4b: '$line'"
nb; rec reproduced r; url '`x'; line=$(section | grep '^URL: ')
[ "$line" = 'URL: `` `x ``' ] && ok || bad "U4c: leading backtick: '$line'"

# U5: empty / whitespace → plain `URL: not recorded`; multi-line → one line.
nb; rec reproduced r; url ''; out=$(section)
grep -qxF 'URL: not recorded' <<<"$out" && ok || bad "U5: empty URL: $(grep '^URL' <<<"$out")"
nb; rec reproduced r; url '   '; out=$(section)
grep -qxF 'URL: not recorded' <<<"$out" && ok || bad "U5: whitespace URL: $(grep '^URL' <<<"$out")"
nb; rec reproduced r; printf 'REPRO_URL: https://x.test/a\nfixes #2\n@b\nREPRO_STEPS: s\n' > "$B/prebuild-repro.md"; out=$(section)
[ "$(grep -c '^URL: ' <<<"$out")" = 1 ] && grep -qxF 'URL: ` https://x.test/a fixes #2 @b `' <<<"$out" && ! grep -qx 'fixes #2\|@b' <<<"$out" && ok || bad "U5: multi-line URL: $(sed -n '/^URL/,/^Steps/p' <<<"$out")"

echo "prebuild-repro-url: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
