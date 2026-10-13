#!/bin/bash
# tests/prompt-sections.bh-5235-test.sh — BH-5235.0 (BH-5244): Archie's soul is
# section files. prompts/archie-soul.md was split, byte for byte, into
# prompts/archie-soul.d/NN-<slug>.md, and every reader loads them with
# `cat "$H"/prompts/archie-soul.d/*.md`. A new soul section is a new file, so
# two tickets never edit the same lines. At the split commit the concatenation
# was byte-identical to the single file it replaced (P1), and every reader
# composes the fragments the same as one file holding today's soul (P5, P6).
#
# Sections: P (the fragments and the readers that load them), N (no network).
# The readers are lifted from the SHIPPED scripts, not copied here.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/prompt-sections.bh-5235-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
T="$SCRATCH"
SD="$DIR/prompts/archie-soul.d"
# The sha256 of prompts/archie-soul.md at 645b72ecb, the file this split
# converted: its first 16 hex digits (64 bits), which is ample for a byte-identity
# check. The full 64-hex digest is the shape of a secret, and the public-mirror
# leak check (bin/share/leakcheck.py, "64-hex token") refuses it. A hash of a file
# we wrote is not a third-party release checksum, so KNOWN_PUBLIC_CHECKSUMS does
# not apply; a shorter digest keeps the guard as it is.
SOUL_SHA=dbca3d33c5a8fca6
SOUL_BASE=645b72ecb
# The split commit. Later tickets add and edit sections, so P1 reads the
# fragments as this commit wrote them, not the live tree.
SPLIT=658e3562
SPLIT_NAMES="00-identity 10-authority 20-initiatives 30-follow-ups 40-earned-autonomy 50-memory 60-corrections 70-skill-proposals"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# No network: anything that tries is logged and fails.
mkdir -p "$T/fakebin"
for c in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s/net.log"\nexit 7\n' "$c" "$T" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done
export PATH="$T/fakebin:$PATH"

# concat_sha <dir>: sha256 of the fragments in glob order, first 16 hex digits.
concat_sha() { cat "$1"/*.md 2>/dev/null | sha256sum | cut -c1-16; }

# ═════ P1: the split's concat is the converted soul ══════════════════════════
cat "$SD"/*.md > "$T/concat.md" 2>/dev/null
if git -C "$DIR" cat-file -e "$SPLIT" 2>/dev/null; then
  : > "$T/split.md"
  for f in $(git -C "$DIR" ls-tree --name-only "$SPLIT" prompts/archie-soul.d/); do
    git -C "$DIR" show "$SPLIT:$f" >> "$T/split.md"
  done
  check "P1 the split's concat sha is the converted soul's" '[ "$(sha256sum < "$T/split.md" | cut -c1-16)" = "$SOUL_SHA" ]'
  if git -C "$DIR" cat-file -e "$SOUL_BASE" 2>/dev/null; then
    git -C "$DIR" show "$SOUL_BASE:prompts/archie-soul.md" > "$T/old-soul.md"
    check "P1 the split's concat cmps equal to $SOUL_BASE:prompts/archie-soul.md" 'cmp -s "$T/split.md" "$T/old-soul.md"'
  else
    echo "note: P1 $SOUL_BASE is not in this clone (shallow); the cmp half is skipped, the sha half stands"
    ok
  fi
else
  echo "note: P1 $SPLIT is not in this clone (shallow); the split identity is skipped"
  ok
fi

# ═════ P2: names, count and glob order ═══════════════════════════════════════
for s in $SPLIT_NAMES; do
  check "P2 the split fragment $s.md is still there" '[ -f "$SD/$s.md" ]'
done
badnames=$(for f in "$SD"/*.md; do basename "$f"; done | grep -Ev '^[0-9][0-9]-[a-z0-9-]+\.md$')
check "P2 every name is NN-<slug>.md [${badnames}]" '[ -z "$badnames" ]'
dupn=$(for f in "$SD"/*.md; do basename "$f" | cut -c1-2; done | sort | uniq -d)
check "P2 no two fragments share a prefix [${dupn}]" '[ -z "$dupn" ]'
oc=$(cd "$SD" && LC_ALL=C bash -c 'printf "%s\n" *.md')
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  ou=$(cd "$SD" && LC_ALL=en_US.UTF-8 bash -c 'printf "%s\n" *.md')
  check "P2 glob order is the same under C and en_US.UTF-8" '[ "$oc" = "$ou" ]'
else
  echo "note: P2 en_US.UTF-8 is not installed here; the cross-locale order is skipped"
  ok
fi
check "P2 glob order is the numeric order" '[ "$oc" = "$(printf "%s\n" "$oc" | sort -n)" ]'

# ═════ P3: every fragment ends in a newline and has no CR ════════════════════
for f in "$SD"/*.md; do
  b=$(basename "$f")
  check "P3 $b is non-empty" '[ -s "$f" ]'
  check "P3 $b ends in \\n" '[ "$(tail -c1 "$f" | od -An -c | tr -d " ")" = "\\n" ]'
  check "P3 $b has no CR" '! grep -q $'"'"'\r'"'"' "$f"'
done

# ═════ P4: mutation, P1's comparison is not vacuous ══════════════════════════
cp -r "$SD" "$T/mut"
last=$(ls "$T/mut"/*.md | tail -1)
printf 'x' >> "$last"
check "P4 one appended byte changes the concat sha" '[ "$(concat_sha "$T/mut")" != "$(concat_sha "$SD")" ]'

# ═════ P5: the composed v2 prompt is byte-identical ══════════════════════════
SRC="$DIR/bin/orchestrate.sh"
FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$SRC")
check "P5 compose_v2_prompt was lifted" '[ -n "$FN" ]'
mkdir -p "$T/orc"
for h in a b c; do
  mkdir -p "$T/$h/prompts" "$T/$h/bin" "$T/$h/catalog/prompts"
  printf '#!/bin/bash\necho "(history)"\n' > "$T/$h/bin/orc-context.sh"
  chmod +x "$T/$h/bin/orc-context.sh"
  echo "CHECK-PROMPT" > "$T/$h/catalog/prompts/archie-check.md"
done
cp -r "$SD" "$T/a/prompts/"
mkdir -p "$T/b/prompts/archie-soul.d"
cp "$T/concat.md" "$T/b/prompts/archie-soul.d/00-all.md"
compose() {
  env HARNESS="$1" ARCHIE_ORC_DIR="$T/orc" TEXT=hi META_TRANSPORT=telegram ORIGIN="" \
    bash -c "$FN"$'\n''compose_v2_prompt' 2>/dev/null
}
compose "$T/a" > "$T/pa"; ra=$?
compose "$T/b" > "$T/pb"; rb=$?
check "P5 both composes exit 0 ($ra/$rb)" '[ "$ra" = 0 ] && [ "$rb" = 0 ]'
check "P5 fragments and the single soul compose byte-identical" 'cmp -s "$T/pa" "$T/pb"'
for p in pa pb; do
  check "P5 $p carries the WHO YOU ARE label" 'grep -qF "=== WHO YOU ARE (prompts/archie-soul.md) ===" "$T/$p"'
  check "P5 $p carries the MAY block" 'grep -qF "MAY, without asking:" "$T/$p"'
done

# ═════ P6: bin/archie.sh's check prompt starts with the whole soul ═══════════
BLK=$(sed -n '/cat "\$H"\/prompts\/archie-soul\.d/,/> "\$pf"/p' "$DIR/bin/archie.sh")
check "P6 the check-prompt block was lifted" '[ -n "$BLK" ]'
printf '%s\n' "$BLK" > "$T/blk.sh"
env H="$T/a" pf="$T/pf" row='{}' v= due= NOWISO= ctx= bash -c '. "$1"' _ "$T/blk.sh" 2>/dev/null
check "P6 the check prompt starts with the whole soul, byte for byte" 'cmp -s <(head -c "$(wc -c < "$T/concat.md")" "$T/pf") "$T/concat.md"'
check "P6 the check prompt follows the soul" 'grep -qF "CHECK-PROMPT" "$T/pf"'

# ═════ P7: no soul dir drops only the soul section ═══════════════════════════
compose "$T/c" > "$T/pc"; rc=$?
check "P7 compose exits 0 with no archie-soul.d ($rc)" '[ "$rc" = 0 ]'
check "P7 the prompt has no WHO YOU ARE section" '! grep -qF "WHO YOU ARE" "$T/pc"'
check "P7 the prompt still carries the operator's message" "grep -qF \"=== OPERATOR'S MESSAGE, ANSWER THIS ===\" \"\$T/pc\""

# ═════ P8: nothing in bin/ or catalog/ reads the old single file ═════════════
refs=$(grep -rn 'prompts/archie-soul\.md' "$DIR/bin" "$DIR/catalog" 2>/dev/null)
check "P8 the only bin/catalog mention of archie-soul.md is the WHO YOU ARE label [$refs]" \
  '[ "$(wc -l <<<"$refs")" = 1 ] && grep -qF "bin/orchestrate.sh:" <<<"$refs" && grep -qF "=== WHO YOU ARE (prompts/archie-soul.md) ===" <<<"$refs"'
check "P8 the single file is gone" '[ ! -e "$DIR/prompts/archie-soul.md" ]'

check "N1 nothing reached the network" '[ ! -s "$T/net.log" ]'

echo "prompt-sections: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
