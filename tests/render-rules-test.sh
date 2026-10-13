#!/bin/bash
# tests/render-rules-test.sh — bin/render-rules.sh renders rules/CLAUDE.md from
# rules/topics/NN-<topic>.md: the first topic verbatim as the preamble, a
# generated `## Contents` list, then every remaining topic in LC_ALL=C order.
#
# Every section drives the REAL script (`bin/render-rules.sh --root <scratch>`),
# never an extracted function (D2), and asserts on printed bytes, return codes
# and the files it wrote — never on the script's source text (D3). B6 runs it
# against THIS checkout, so a topic edit committed without `--write` fails here.
#
# Run: bash tests/render-rules-test.sh   (exit 0 = all pass)
# On a box that has a live /root/harness, scratch.sh wants the sandbox flag:
#   HARNESS_TEST_SANDBOX=1 bash tests/render-rules-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

RR="$DIR/bin/render-rules.sh"
LIB="$DIR/bin/lib/render-fragments.sh"

# mktree <name> — a scratch checkout root with an empty rules/topics/
mktree() { mkdir -p "$T/$1/rules/topics"; }

# ── B0 the script is a script ────────────────────────────────────────────────
[ -r "$RR" ] && ok || bad "B0 $RR is missing or unreadable"
[ -x "$RR" ] && ok || bad "B0 $RR is not executable"
bash -n "$RR" 2> "$T/err"; RC=$?
eq "B0 bash -n" "$RC" "0"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error "$RR" && ok || bad "B0 shellcheck --severity=error"
else
  echo "SKIP: shellcheck not installed on this box (the CI lint job runs it)"
fi

# ── B1 the golden render ─────────────────────────────────────────────────────
mktree g; G="$T/g"
cat > "$G/rules/topics/00-intro.md" <<'EOF'
# Preamble Title
a preamble body line
EOF
cat > "$G/rules/topics/10-alpha.md" <<'EOF'
## Alpha
alpha body 1
alpha body 2
EOF
cat > "$G/rules/topics/20-beta.md" <<'EOF'
## Beta & Gamma (the operator, 2026-09-14 — "quoted")
beta body

EOF
cat > "$T/want" <<'EOF'
# Preamble Title
a preamble body line

## Contents

- [Alpha](#alpha)
- [Beta & Gamma (the operator, 2026-09-14 — "quoted")](#beta--gamma-operator-2026-09-14--quoted)

## Alpha
alpha body 1
alpha body 2

## Beta & Gamma (the operator, 2026-09-14 — "quoted")
beta body
EOF
"$RR" --root "$G" > "$T/out" 2> "$T/err"; RC=$?
eq "B1 a good tree renders rc 0" "$RC" "0"
eq "B1 a good render says nothing on stderr" "$(cat "$T/err")" ""
cmp -s "$T/out" "$T/want" && ok || bad "B1 golden render: $(diff "$T/want" "$T/out" | head -20 | tr '\n' '|')"
eq "B1 the preamble's first line is the file's first line" "$(head -1 "$T/out")" "# Preamble Title"
eq "B1 one TOC line per remaining topic" "$(grep -c '^- \[' "$T/out")" "2"
eq "B1 the preamble is not listed in the TOC" "$(grep -c 'Preamble' "$T/out")" "1"
eq "B1 the TOC is in LC_ALL=C fragment order" "$(grep '^- \[' "$T/out" | cut -c4-9 | tr '\n' '|')" "Alpha]|Beta &|"
eq "B1 the render ends with a newline" "$(tail -c1 "$T/out" | od -An -c | tr -d ' ')" '\n'

# ── B2 --write / --check, and idempotence ────────────────────────────────────
OUT=$("$RR" --root "$G" --write 2> "$T/err"); RC=$?
eq "B2 --write is rc 0" "$RC" "0"
eq "B2 --write prints nothing on stdout" "$OUT" ""
eq "B2 --write prints nothing on stderr" "$(cat "$T/err")" ""
cmp -s "$G/rules/CLAUDE.md" "$T/want" && ok || bad "B2 --write lands the rendered bytes"
eq "B2 the written file ends with a newline" "$(tail -c1 "$G/rules/CLAUDE.md" | od -An -c | tr -d ' ')" '\n'
"$RR" --root "$G" --check > "$T/out" 2> "$T/err"; RC=$?
eq "B2 --check after --write is rc 0" "$RC" "0"
eq "B2 a clean --check prints nothing" "$(cat "$T/out")" ""
cp "$G/rules/CLAUDE.md" "$T/before2nd"
"$RR" --root "$G" --write > "$T/out" 2> "$T/err"; RC=$?
eq "B2 a second --write is rc 0" "$RC" "0"
cmp -s "$G/rules/CLAUDE.md" "$T/before2nd" && ok || bad "B2 --write twice is a no-op"

# ── B3 locality: one topic changed, one block changed ────────────────────────
printf 'alpha body 3\n' >> "$G/rules/topics/10-alpha.md"
"$RR" --root "$G" > "$T/out2" 2> "$T/err"; RC=$?
eq "B3 the edited tree still renders rc 0" "$RC" "0"
eq "B3 appending a body line changes exactly that line" \
   "$(diff "$T/want" "$T/out2" | grep '^[<>]' | tr '\n' '|')" "> alpha body 3|"
sed -i 's/^## Alpha$/## Alpha2/' "$G/rules/topics/10-alpha.md"
"$RR" --root "$G" > "$T/out3" 2> "$T/err"
eq "B3 renaming a heading moves its heading line and its TOC line only" \
   "$(diff "$T/out2" "$T/out3" | grep -c '^[<>]')" "4"
eq "B3 the new anchor follows the new heading" "$(grep -c '^- \[Alpha2\](#alpha2)$' "$T/out3")" "1"

# ── B4 refusals ──────────────────────────────────────────────────────────────
# Each in its own tree: rc, empty stdout, and the offending file named on stderr.
mktree h3; printf '# intro\n' > "$T/h3/rules/topics/00-i.md"
printf '### not a topic heading\nbody\n' > "$T/h3/rules/topics/10-x.md"
"$RR" --root "$T/h3" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a later topic starting with ### is rc 3" "$RC" "3"
eq "B4 a refused render prints nothing on stdout" "$(cat "$T/out")" ""
grep -q '10-x\.md' "$T/err" && ok || bad "B4 the refusal names the file, got [$(cat "$T/err")]"

mktree hns; printf '# intro\n' > "$T/hns/rules/topics/00-i.md"
printf '##NoSpace\nbody\n' > "$T/hns/rules/topics/10-x.md"
"$RR" --root "$T/hns" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a heading with no space after ## is rc 3" "$RC" "3"
grep -q '10-x\.md' "$T/err" && ok || bad "B4 the no-space refusal names the file"

mktree hbl; printf '# intro\n' > "$T/hbl/rules/topics/00-i.md"
printf '\n## Late\nbody\n' > "$T/hbl/rules/topics/10-x.md"
"$RR" --root "$T/hbl" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a topic whose first line is blank is rc 3" "$RC" "3"

mktree dup; printf '# intro\n' > "$T/dup/rules/topics/00-i.md"
printf '## Same\none\n' > "$T/dup/rules/topics/10-a.md"
printf '## Same\ntwo\n' > "$T/dup/rules/topics/20-b.md"
"$RR" --root "$T/dup" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a duplicate heading is rc 3" "$RC" "3"
eq "B4 a duplicate heading prints nothing on stdout" "$(cat "$T/out")" ""
grep -q '20-b\.md' "$T/err" && ok || bad "B4 the duplicate refusal names the second file, got [$(cat "$T/err")]"
grep -q '10-a\.md' "$T/err" && ok || bad "B4 the duplicate refusal also names the first file"

mktree crlf; printf '# intro\n' > "$T/crlf/rules/topics/00-i.md"
printf '## Win\r\nbody\n' > "$T/crlf/rules/topics/10-x.md"
"$RR" --root "$T/crlf" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a CRLF topic is rc 3" "$RC" "3"
grep -q 'render-fragments:' "$T/err" && ok || bad "B4 the CR refusal comes from the shared lib, got [$(cat "$T/err")]"
grep -qi 'CR' "$T/err" && ok || bad "B4 the CR refusal says what it refused"

# Case is NOT folded: `## Foo` and `## foo` are distinct headings (ticket rule).
mktree case; printf '# intro\n' > "$T/case/rules/topics/00-i.md"
printf '## Foo\none\n' > "$T/case/rules/topics/10-a.md"
printf '## foo\ntwo\n' > "$T/case/rules/topics/20-b.md"
"$RR" --root "$T/case" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 headings differing only in case render" "$RC" "0"
eq "B4 both case-distinct headings are listed" "$(grep -c '^- \[[Ff]oo\](#foo)$' "$T/out")" "2"

# A `## ` line inside the PREAMBLE is not a topic heading: kept, never listed.
mktree pre; printf '# intro\n## Inside The Preamble\nbody\n' > "$T/pre/rules/topics/00-i.md"
printf '## Real\nbody\n' > "$T/pre/rules/topics/10-a.md"
"$RR" --root "$T/pre" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a ## line in the preamble renders rc 0" "$RC" "0"
eq "B4 the preamble's ## line is kept verbatim" "$(grep -c '^## Inside The Preamble$' "$T/out")" "1"
eq "B4 the preamble's ## line gets no TOC entry" "$(grep -c '^- \[Inside' "$T/out")" "0"
eq "B4 only the real topic is listed" "$(grep -c '^- \[' "$T/out")" "1"

# One topic file and nothing else: preamble + an empty Contents section, rc 0.
mktree one; printf '# only intro\nbody\n' > "$T/one/rules/topics/00-i.md"
"$RR" --root "$T/one" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a single-topic dir renders rc 0" "$RC" "0"
eq "B4 a single-topic dir still emits the Contents heading" "$(grep -c '^## Contents$' "$T/out")" "1"
eq "B4 a single-topic dir lists nothing" "$(grep -c '^- \[' "$T/out")" "0"

mktree empty
"$RR" --root "$T/empty" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 an empty topics dir is rc 2" "$RC" "2"
eq "B4 an empty topics dir prints nothing on stdout" "$(cat "$T/out")" ""
[ -s "$T/err" ] && ok || bad "B4 an empty topics dir must give a reason on stderr"
"$RR" --root "$T/empty" --check > "$T/out" 2> "$T/err"; RC=$?
eq "B4 --check on an empty topics dir is rc 2, never 0" "$RC" "2"
eq "B4 --check on an empty topics dir prints no DRIFT line" "$(cat "$T/out")" ""

mkdir -p "$T/nodir"
"$RR" --root "$T/nodir" > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a missing rules/topics is rc 2" "$RC" "2"
"$RR" --root "$T/nodir" --check > "$T/out" 2> "$T/err"; RC=$?
eq "B4 --check with no rules/topics is rc 2" "$RC" "2"
"$RR" --root "$T/nope-at-all" --check > "$T/out" 2> "$T/err"; RC=$?
eq "B4 a missing root is rc 2" "$RC" "2"
[ -s "$T/err" ] && ok || bad "B4 a missing root must give a reason on stderr"

# A refused render under --check maps to 2 (the contract), with the reason kept.
"$RR" --root "$T/dup" --check > "$T/out" 2> "$T/err"; RC=$?
eq "B4 --check on a refused tree is rc 2, never 0" "$RC" "2"
eq "B4 --check on a refused tree prints no DRIFT line" "$(cat "$T/out")" ""
grep -q 'duplicate' "$T/err" && ok || bad "B4 --check keeps the refusal reason, got [$(cat "$T/err")]"

# --write on a refused tree must leave the committed file byte-identical.
printf 'previously committed\n' > "$T/dup/rules/CLAUDE.md"
cp "$T/dup/rules/CLAUDE.md" "$T/dupbefore"
"$RR" --root "$T/dup" --write > "$T/out" 2> "$T/err"; RC=$?
eq "B4 --write on a refused tree is rc 3" "$RC" "3"
cmp -s "$T/dup/rules/CLAUDE.md" "$T/dupbefore" && ok || bad "B4 a failed --write must not touch the committed file"

"$RR" --root "$G" --write --check > "$T/out" 2> "$T/err"; RC=$?
eq "B4 --write and --check together is rc 2" "$RC" "2"
eq "B4 a usage error prints nothing on stdout" "$(cat "$T/out")" ""
[ -s "$T/err" ] && ok || bad "B4 a usage error must give a reason on stderr"
"$RR" --root "$G" --bogus > "$T/out" 2> "$T/err"; RC=$?
eq "B4 an unknown flag is rc 2" "$RC" "2"

# ── B5 drift ─────────────────────────────────────────────────────────────────
mktree d; D="$T/d"
printf '# intro\nbody\n' > "$D/rules/topics/00-i.md"
printf '## One\nbody\n' > "$D/rules/topics/10-a.md"
"$RR" --root "$D" --write 2> "$T/err"
printf 'a line nobody rendered\n' >> "$D/rules/CLAUDE.md"
"$RR" --root "$D" --check > "$T/out" 2> "$T/err"; RC=$?
eq "B5 an edited committed file is drift rc 1" "$RC" "1"
eq "B5 drift names the committed path first" "$(head -1 "$T/out")" "DRIFT rules/CLAUDE.md"
LN=$(wc -l < "$T/out")
[ "$LN" -le 26 ] && ok || bad "B5 the drift preview is capped, got $LN lines"
rm -f "$D/rules/CLAUDE.md"
"$RR" --root "$D" --check > "$T/out" 2> "$T/err"; RC=$?
eq "B5 a missing committed file is drift rc 1, never 0" "$RC" "1"
eq "B5 a missing committed file still names itself" "$(head -1 "$T/out")" "DRIFT rules/CLAUDE.md"

# ── B6 this checkout ─────────────────────────────────────────────────────────
# Names $DIR/rules/topics so bin/test-impact.sh's text-based ci-select maps a
# topic-only edit to this suite too (BH-1203): a diff that only touches
# rules/topics/ and never rules/CLAUDE.md or bin/render-rules.sh still needs
# this suite selected, or a forgotten --write merges a stale render.
[ -d "$DIR/rules/topics" ] && ok || bad "B6 rules/topics/ is missing from this checkout"
( cd "$DIR" && "$RR" --check ) > "$T/out" 2> "$T/err"; RC=$?
eq "B6 rules/CLAUDE.md in this checkout has no drift" "$RC" "0"
[ "$RC" -eq 0 ] || echo "  (drift: $(head -6 "$T/out" | tr '\n' '|'))"
( cd "$DIR" && "$RR" ) > "$T/real" 2> "$T/err"; RC=$?
eq "B6 the print mode renders this checkout rc 0" "$RC" "0"
cmp -s "$T/real" "$DIR/rules/CLAUDE.md" && ok || bad "B6 print mode equals the committed file"
C="$DIR/rules/CLAUDE.md"
eq "B6 the @RTK.md include survives, once" "$(grep -c '^@RTK.md$' "$C")" "1"
lineno() { grep -n "$1" "$C" | head -1 | cut -d: -f1; }
RTKI=$(lineno '^@RTK.md$'); RTKH=$(lineno '^## rtk'); TOK=$(lineno '^## Token discipline')
[ -n "$RTKI" ] && [ -n "$RTKH" ] && [ -n "$TOK" ] && [ "$RTKH" -lt "$RTKI" ] && [ "$RTKI" -lt "$TOK" ] \
  && ok || bad "B6 @RTK.md must sit inside the rtk topic (rtk=$RTKH rtk-include=$RTKI token=$TOK)"
CGS=$(lineno 'CODEGRAPH_START'); CGH=$(lineno '^## CodeGraph'); CGE=$(lineno 'CODEGRAPH_END'); LRN=$(lineno '^### Learned 2026-08-13')
[ -n "$CGS" ] && [ -n "$CGH" ] && [ -n "$CGE" ] && [ -n "$LRN" ] && [ -n "$RTKH" ] \
  && [ "$CGS" -lt "$CGH" ] && [ "$CGH" -lt "$CGE" ] && [ "$CGE" -lt "$LRN" ] && [ "$LRN" -lt "$RTKH" ] \
  && ok || bad "B6 CodeGraph block order (start=$CGS head=$CGH end=$CGE learned=$LRN rtk=$RTKH)"
eq "B6 the TOC lists every topic after the preamble" \
   "$(grep -c '^- \[' "$C")" "$(( $(grep -c '^## ' "$C") - 1 ))"
grep '^> ' "$C" > "$T/banner"
grep -q 'rules/topics' "$T/banner" && ok || bad "B6 the banner must point at rules/topics/"
grep -q 'render-rules' "$T/banner" && ok || bad "B6 the banner must name bin/render-rules.sh"

# The one-time migration negative: nothing but the banner and the TOC may differ
# from the pre-split file. It retires itself once main carries rules/topics/.
# origin/main first: a local `main` branch can be stale on a long-lived box or
# dev checkout (it moves only when something fetches+updates it, unlike
# origin/main after any `git fetch`), and a stale ref here means a false red
# against consumer edits main itself already made. origin/main is absent only
# on a shallow single-branch clone, where local main (if any) is the only ref.
REF=$(git -C "$DIR" rev-parse -q --verify origin/main 2>/dev/null || git -C "$DIR" rev-parse -q --verify main 2>/dev/null)
if [ -z "$REF" ]; then
  echo "SKIP: no main ref in this checkout (shallow CI clone)"
elif git -C "$DIR" cat-file -e "$REF:rules/topics" 2>/dev/null; then
  echo "SKIP: main already split (the one-time migration proof has retired)"
else
  git -C "$DIR" show "$REF":rules/CLAUDE.md > "$T/mainrules" 2> "$T/err"
  N=$(diff "$T/mainrules" "$C" | grep '^[<>]' \
      | grep -v -e '^> ## Contents' -e '^> - \[' -e 'REPO-MANAGED' -e 'render-rules' \
                -e 'rules/topics' -e '^[<>] *$' -e '^[<>] > ' | wc -l)
  [ "$N" -eq 0 ] && ok || bad "B6 only the banner and the TOC may differ from main: $(diff "$T/mainrules" "$C" | grep '^[<>]' | grep -v -e '^> ## Contents' -e '^> - \[' -e 'REPO-MANAGED' -e 'render-rules' -e 'rules/topics' -e '^[<>] *$' -e '^[<>] > ' | head -5 | tr '\n' '|')"
  # BH-1261: the consumers arm judges render-rules' OWN slice. It runs on every
  # branch CI builds, so on a branch that edits bin/update-runners.sh for its
  # own ticket it must stay inert rather than go red on someone else's work.
  # (2026-09-21: #1158 and #727 went red on the same ungated shape elsewhere.)
  OWN=$(git -C "$DIR" diff --name-only "$REF" 2>/dev/null; git -C "$DIR" diff --name-only 2>/dev/null)
  if ! grep -qE '^(bin/render-rules\.sh$|bin/lib/render-fragments\.sh$|rules/topics/)' <<<"$(printf '%s\n' "$OWN")"; then  # own-slice: bin/render-rules.sh bin/lib/render-fragments.sh rules/topics/
    echo "note: this branch is not render-rules' slice — the B6 consumers arm judges only its own branch"
  else
  CH=$(git -C "$DIR" diff --name-only "$REF" -- bin/update-runners.sh bin/sync-agent-rules.sh \
       fly/builder-runner.sh bin/rules-drift-check.sh bin/context-signature.sh)
  eq "B6 the five consumers of rules/CLAUDE.md are untouched" "$CH" ""
  fi
fi

# ── B7 the registry row is the command that works ────────────────────────────
mktree reg; R="$T/reg"
mkdir -p "$R/bin/lib"
cp "$RR" "$R/bin/render-rules.sh" 2>/dev/null
cp "$LIB" "$R/bin/lib/render-fragments.sh" 2>/dev/null
printf '# Preamble Title\na preamble body line\n' > "$R/rules/topics/00-intro.md"
printf '## Alpha\nalpha body 1\nalpha body 2\n' > "$R/rules/topics/10-alpha.md"
printf '## Beta & Gamma (the operator, 2026-09-14 — "quoted")\nbeta body\n\n' > "$R/rules/topics/20-beta.md"
CMD=$(bash -c ". '$LIB'; rf_registry" | awk -F'\t' '$1=="rules/CLAUDE.md"{print $3}')
eq "B7 the registry carries one rules/CLAUDE.md row" "$CMD" "bin/render-rules.sh --write"
( cd "$R" && $CMD ) > "$T/out" 2> "$T/err"; RC=$?
eq "B7 the registry command runs from a checkout root, rc 0" "$RC" "0"
eq "B7 the registry command says nothing" "$(cat "$T/out")$(cat "$T/err")" ""
cmp -s "$R/rules/CLAUDE.md" "$T/want" && ok || bad "B7 the registry command writes the same bytes as the golden"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
