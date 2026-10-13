#!/bin/bash
# tests/share-harness-specs.bh-5055-test.sh — the publisher leaves `.harness/`
# (the per-repo build records) out of the mirror (BH-5055).
#
# Every build writes its plan, review and owed proofs under
# `.harness/specs/<KEY>/`. Those files quote env lines and commands in prose,
# and gitleaks reads a KEY=value line there as a key: batch #5048 went red on
# tests/share-publish-clean.bh-795-test.sh over a `.harness/specs/BH-4918/plan.md`
# line. The records are how this repo was built, not what the mirror runs, so
# bin/share/sanitize.py drops the whole directory. This suite drives the
# sanitizer and both gates over a small scratch tree with a plan line planted,
# plus a control that plants the same line somewhere the mirror DOES ship, and
# runs the two shipped suites the drop would otherwise turn red in the mirror.
#
# NO CREDENTIAL-SHAPED VALUE IS SPELLED IN THIS FILE. It ships in the mirror,
# so the planted value is built at run time.
#
# Run from anywhere: tests/share-harness-specs.bh-5055-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SHARE="$DIR/bin/share"
export PYTHONDONTWRITEBYTECODE=1

if [ ! -f "$SHARE/sanitize.py" ]; then
  # The mirror does not carry bin/share: the publisher is upstream-only.
  echo "SKIP share-harness-specs.bh-5055: no bin/share in this copy"
  exit 0
fi
if [ -n "${GITLEAKS_REQUIRED:-}" ] && ! command -v gitleaks >/dev/null 2>&1; then
  echo "FAIL: GITLEAKS_REQUIRED is set but gitleaks is not on PATH (BH-2059)"
  echo "share-harness-specs.bh-5055: 0 pass, 1 fail, 0 skip"
  exit 1
fi

# ── the planted line ────────────────────────────────────────────────────────
# A 32-char alnum value from a fixed hash: high entropy, never a fixture marker.
VAL=$(python3 -I -c 'import base64,hashlib
v = base64.b64encode(hashlib.sha256(b"bh5055-plant").digest()).decode()
print("".join(c for c in v if c.isalnum())[:32])')
[ "${#VAL}" -eq 32 ] && ok || bad "could not build the planted value"
LINE="Run it as: deploy_api_key = \"$VAL\" WAKE_LAUNCH=1 timeout 240"

# ── scratch source trees the sanitizer will accept ──────────────────────────
# sanitize.py applies its PATCHES after the rewrite and fails if a target is
# missing, so every patched file is copied in from this checkout.
mksrc() { # mksrc <dir>
  local s="$1" rel
  mkdir -p "$s"
  while IFS= read -r rel; do
    mkdir -p "$s/$(dirname "$rel")"
    cp "$DIR/$rel" "$s/$rel"
  done < <(cd "$SHARE" && python3 -B -c '
import sanitize
for rel, _, _ in sanitize.PATCHES: print(rel)' | sort -u)
  mkdir -p "$s/tests/lib" "$s/.harness/specs/BH-9999" "$s/.harness/notes" "$s/notes" "$s/bin"
  # The two suites that read a committed plan are copied by name too, so S8/S9
  # test the patch rather than whether they happen to be PATCHES targets.
  for rel in tests/lib/scratch.sh tests/mc-pr-read-retired.bh-1325-test.sh \
             tests/run-build-rollout-hook.bh-985-test.sh; do
    cp "$DIR/$rel" "$s/$rel"
  done
  printf '# plan\n%s\n' "$LINE" > "$s/.harness/specs/BH-9999/plan.md"
  printf 'another build record\n' > "$s/.harness/notes/other.md"
  printf 'an ordinary file the mirror ships\n' > "$s/notes/keep.md"
  # The mirror's bh-1325 copy requires a bin/ dir, and the sanitizer copies
  # files, not empty dirs.
  printf '#!/bin/bash\n' > "$s/bin/keep.sh"
}
SRC="$T/src"; M="$T/mirror"
mksrc "$SRC"

# S1. sanitize applies every anchor, the new ones included.
python3 -B "$SHARE/sanitize.py" "$SRC" "$M" > "$T/sanitize.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok; else
  bad "S1 sanitize.py exited $rc"
  sed -n '1,30p' "$T/sanitize.out"
  echo "share-harness-specs.bh-5055: $PASS pass, $FAIL fail, $SKIP skip"
  exit 1
fi

# S2. nothing at or under .harness reaches the mirror.
surv=$(find "$M" \( -path "$M/.harness" -o -path "$M/.harness/*" \) 2>/dev/null | head -1)
[ -z "$surv" ] && ok || bad "S2 the mirror carries ${surv#"$M"/} — build records must not ship"

# S3. the walk still copies ordinary files, so S2 is not empty-mirror luck.
[ -f "$M/notes/keep.md" ] && ok || bad "S3 notes/keep.md is missing from the mirror"

# S4. the drop is reported with its own reason, and the rule does not over-match.
grep -qF 'drop .harness/specs/BH-9999/plan.md' "$T/sanitize.out" \
  && grep -F 'drop .harness/specs/BH-9999/plan.md' "$T/sanitize.out" | grep -qF '(internal build record)' \
  && ok || bad "S4 sanitize.out does not report the plan dropped as an internal build record"
D4=$(cd "$SHARE" && python3 -B -c '
import sanitize
for p in (".harness", ".harness/specs/X/plan.md", ".harnessx/a.md", "docs/harness/a.md"):
    print(p, "->", sanitize.dropped(p))')
for want in ".harness -> internal build record" \
            ".harness/specs/X/plan.md -> internal build record" \
            ".harnessx/a.md -> None" "docs/harness/a.md -> None"; do
  grep -qxF -- "$want" <<<"$D4" && ok || bad "S4 dropped(): expected '$want', got: $(echo $D4)"
done

# S5. the publisher's guard reads the mirror clean.
python3 -B "$SHARE/leakcheck.py" "$M" > "$T/leak.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^leakcheck: clean' "$T/leak.out"; then ok; else
  bad "S5 leakcheck refused the mirror (rc=$rc):"; cat "$T/leak.out"
fi

# S6 + S7. gitleaks passes the mirror, and refuses the same line where it ships.
# Counted as a SKIP when the binary is absent, never as a pass.
if command -v gitleaks >/dev/null 2>&1; then
  python3 -B "$SHARE/gitleaks-gate.py" "$M" > "$T/gitleaks.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then ok; else
    bad "S6 gitleaks-gate refused the mirror (rc=$rc):"; cat "$T/gitleaks.out"
  fi
  SRC7="$T/src7"; M7="$T/mirror7"
  mksrc "$SRC7"
  printf '%s\n' "$LINE" > "$SRC7/notes/control.md"
  python3 -B "$SHARE/sanitize.py" "$SRC7" "$M7" > "$T/sanitize7.out" 2>&1 \
    || bad "S7 sanitize.py failed on the control tree"
  python3 -B "$SHARE/gitleaks-gate.py" "$M7" > "$T/gitleaks7.out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qF 'notes/control.md' "$T/gitleaks7.out"; then ok; else
    bad "S7 control: gitleaks-gate must refuse the planted line at notes/control.md (rc=$rc), or S6 proves nothing:"
    cat "$T/gitleaks7.out"
  fi
else
  SKIP=$((SKIP+2))
  echo "SKIP S6/S7: gitleaks not on PATH (CI sets GITLEAKS_REQUIRED)"
fi

# S8. the mirror's bh-1325 copy skips its (d) check instead of failing on it.
M1325="$M/tests/mc-pr-read-retired.bh-1325-test.sh"
if grep -qF 'SKIP (d)' "$M1325" && ! grep -q '^for d in .*\.harness/specs/BH-597' "$M1325"; then ok
else bad "S8a the mirror copy of mc-pr-read-retired.bh-1325 is not patched for the dropped plan"; fi
( cd "$M" && GIT_CONFIG_GLOBAL="$T/gitcfg8" GIT_CONFIG_NOSYSTEM=1 \
    git init --quiet -b main >/dev/null 2>&1 \
    && GIT_CONFIG_GLOBAL="$T/gitcfg8" GIT_CONFIG_NOSYSTEM=1 git add -A >/dev/null 2>&1 )
OUT8=$(cd "$M" && GIT_CONFIG_GLOBAL="$T/gitcfg8" GIT_CONFIG_NOSYSTEM=1 \
    HARNESS_TEST_SANDBOX=1 bash "$M1325" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'SKIP (d)' <<<"$OUT8"; then ok; else
  bad "S8b the mirror's bh-1325 suite must pass with SKIP (d) (rc=$rc):"; echo "$OUT8"
fi
bash -n "$M1325" && ok || bad "S8c the mirror copy of bh-1325 does not parse"

# S9. the mirror's bh-985 copy skips Section G without hiding an earlier failure.
M985="$M/tests/run-build-rollout-hook.bh-985-test.sh"
gl=$(grep -n '^# SHARE MIRROR: .harness/' "$M985" | head -1 | cut -d: -f1)
sl=$(grep -nF 'SPEC="$DIR/.harness/specs/BH-985/plan.md"' "$M985" | head -1 | cut -d: -f1)
if [ -n "$gl" ] && [ -n "$sl" ] && [ "$gl" -lt "$sl" ]; then ok
else bad "S9a the mirror copy of bh-985 has no .harness guard before its SPEC line"; fi
if [ -n "$gl" ]; then
  sed -n "${gl},\$p" "$M985" | sed '/^fi$/q' > "$T/guard985.sh"
  OUT9=$(DIR="$M" PASS=3 FAIL=0 bash "$T/guard985.sh" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && grep -qF 'SKIP G' <<<"$OUT9" && ok \
    || bad "S9b with no plan and FAIL=0 the guard must print SKIP G and exit 0 (rc=$rc): $OUT9"
  DIR="$M" PASS=3 FAIL=1 bash "$T/guard985.sh" >/dev/null 2>&1 \
    && bad "S9b with FAIL=1 the guard must exit non-zero — a skip never hides an earlier failure" || ok
  mkdir -p "$T/has985/.harness/specs/BH-985"; : > "$T/has985/.harness/specs/BH-985/plan.md"
  OUT9=$(DIR="$T/has985" PASS=3 FAIL=0 bash "$T/guard985.sh" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$OUT9" ] && ok \
    || bad "S9b with the plan present the guard must fall through silently (rc=$rc): $OUT9"
else
  bad "S9b no guard block to drive"
fi
bash -n "$M985" && ok || bad "S9c the mirror copy of bh-985 does not parse"

# S10. the skip lives only in the mirror: upstream still checks the BH-597 plan.
grep -q '^for d in .*\.harness/specs/BH-597' "$DIR/tests/mc-pr-read-retired.bh-1325-test.sh" \
  && ok || bad "S10 the upstream bh-1325 suite no longer requires .harness/specs/BH-597"

echo "share-harness-specs.bh-5055: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
