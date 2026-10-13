#!/bin/bash
# tests/gitleaks-images.bh-5789-test.sh — BH-5789: the builder, pool and review
# images carry the pinned gitleaks, and the builder's verify step requires it.
#
# WHY. The builder and review images had no gitleaks, so
# tests/share-publish-clean.bh-795-test.sh skipped its leak gate there and a
# fixture leak showed up only in CI or the merge queue (#5700, #5282, and
# #4967's token, which broke merge batch #5770 for 3 PRs).
#
#   G1  fly/Dockerfile (the pool builder image) installs gitleaks at exactly
#       bin/lib/gitleaks-pin.sh's version AND sha256
#   G2  bin/bootstrap-machine.sh (the builder and review boxes) installs the
#       pinned gitleaks through gitleaks_pin_ensure
#   G3  the builder's verify step (HARNESS_IMPACT_GATE_RUN, bin/lib/rb/gates.sh)
#       runs the rules pack and the impact gate with GITLEAKS_REQUIRED=1
#   G4  with GITLEAKS_REQUIRED=1 and no gitleaks on PATH, the leak suite is
#       red, never a skip: in an image without gitleaks the verify step fails
# Run from anywhere: tests/gitleaks-images.bh-5789-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
PIN_V=$(sed -n 's/^GITLEAKS_PIN_VERSION=//p' "$DIR/bin/lib/gitleaks-pin.sh")
PIN_S=$(sed -n 's/^GITLEAKS_PIN_SHA256=//p' "$DIR/bin/lib/gitleaks-pin.sh")
[ -n "$PIN_V" ] && [ -n "$PIN_S" ] && ok || bad "setup: no pin in bin/lib/gitleaks-pin.sh"

# G1 — the pool image
BLK=$(awk '/^# >>> bake-gitleaks/{f=1} f{print} /^# <<< bake-gitleaks/{exit}' "$DIR/fly/Dockerfile")
[ -n "$BLK" ] && ok || bad "G1: fly/Dockerfile has no bake-gitleaks block"
grep -qE "^ARG GITLEAKS_VERSION=$PIN_V\$" <<<"$BLK" && ok || bad "G1: the Dockerfile's GITLEAKS_VERSION must be the pin $PIN_V"
grep -qE "^ARG GITLEAKS_SHA256=$PIN_S\$" <<<"$BLK" && ok || bad "G1: the Dockerfile's GITLEAKS_SHA256 must be the pin"
grep -q 'sha256sum -c' <<<"$BLK" && ok || bad "G1: the Dockerfile must check the tarball's sha256 before unpacking"
grep -q 'bake_verify gitleaks' <<<"$BLK" && ok || bad "G1: the Dockerfile must verify the installed version (bake_verify)"

# G2 — the builder and review boxes
grep -q 'gitleaks_pin_ensure /usr/local/bin' "$DIR/bin/bootstrap-machine.sh" && ok || bad "G2: bin/bootstrap-machine.sh must install the pinned gitleaks"
grep -q 'lib/gitleaks-pin.sh' "$DIR/bin/bootstrap-machine.sh" && ok || bad "G2: bin/bootstrap-machine.sh must read the pin from bin/lib/gitleaks-pin.sh"

# G3 — the verify step passes GITLEAKS_REQUIRED=1 to the rules pack and the gate
awk '/^HARNESS_IMPACT_GATE_RUN\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DIR/bin/lib/rb/gates.sh" > "$T/gate-fn.sh"
grep -q 'HARNESS_IMPACT_GATE_RUN()' "$T/gate-fn.sh" && ok || bad "G3: HARNESS_IMPACT_GATE_RUN not found in bin/lib/rb/gates.sh"
W="$T/wt"; mkdir -p "$W/bin" "$T/build"
printf '#!/bin/bash\necho "REQ=${GITLEAKS_REQUIRED:-unset}" >> %q\nexit 0\n' "$T/rp-env" > "$W/bin/rules-pack.sh"
printf '#!/bin/bash\necho "REQ=${GITLEAKS_REQUIRED:-unset}" >> %q\nexit 0\n' "$T/gate-env" > "$W/bin/test-impact-gate.sh"
chmod +x "$W/bin/rules-pack.sh" "$W/bin/test-impact-gate.sh"
( cd "$W" && unset GITLEAKS_REQUIRED; BUILD="$T/build" BASE=main PROJECT=p KEY=K-1
  STAMP() { echo TS; }
  . "$T/gate-fn.sh"; HARNESS_IMPACT_GATE_RUN suite.txt lenses ) >/dev/null 2>&1
[ "$(cat "$T/rp-env" 2>/dev/null)" = "REQ=1" ] && ok || bad "G3: the rules pack must run with GITLEAKS_REQUIRED=1 (got '$(cat "$T/rp-env" 2>/dev/null)')"
[ "$(cat "$T/gate-env" 2>/dev/null)" = "REQ=1" ] && ok || bad "G3: the impact gate must run with GITLEAKS_REQUIRED=1 (got '$(cat "$T/gate-env" 2>/dev/null)')"

# G4 — no gitleaks on PATH and GITLEAKS_REQUIRED=1: red, never a skip
SH="$T/nogl"; mkdir -p "$SH"
for d in $(printf '%s' "$PATH" | tr ':' ' '); do
  for f in "$d"/*; do
    b=$(basename "$f"); [ "$b" = gitleaks ] && continue
    [ -e "$SH/$b" ] || ln -s "$f" "$SH/$b" 2>/dev/null
  done
done
OUT=$(cd "$DIR" && PATH="$SH" GITLEAKS_REQUIRED=1 bash tests/share-publish-clean.bh-795-test.sh 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "G4: the leak suite must be red with GITLEAKS_REQUIRED=1 and no gitleaks (rc=$RC)"
case "$OUT" in *"GITLEAKS_REQUIRED is set but gitleaks is not on PATH"*) ok ;; *) bad "G4: the failure must name the missing gitleaks: $(printf '%s' "$OUT" | tail -2)" ;; esac
case "$OUT" in *"SKIP gitleaks-gate"*) bad "G4: a required gate must never skip" ;; *) ok ;; esac

echo "gitleaks-images.bh-5789: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
