#!/usr/bin/env bash
# tests/lanes-build-argmax-test.sh: bin/lanes-build.sh composes a libs scope
# larger than one argv argument may be (MAX_ARG_STRLEN, 128 KiB). On 2026-10-08
# merge-queue batches failed with "jq: Argument list too long" at
# lanes-build.sh:130, because the libs scope (about 124 KB on main) went
# through --argjson. The composition must go through files.
#   A1 a fixture with a ~300 KB _lib.*.json composes (--write rc 0)
#   A2 the composed registry carries every lib, the big one included
#   A3 the real catalog composes to the same bytes it did before (no drift)
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/scratch.sh
. "$DIR/tests/lib/scratch.sh" || exit 1   # sets $T and its EXIT cleanup
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Fixture root: the real lane sources plus one oversized lib file.
mkdir -p "$T/root/bin" "$T/root/catalog"
cp "$DIR/bin/lanes-build.sh" "$T/root/bin/"
cp -R "$DIR/catalog/lanes.d" "$T/root/catalog/"
python3 - "$T/root/catalog/lanes.d/_lib.zz-argmax-fixture.json" <<'PY'
import json, sys
knobs = [{"env": "ARGMAX_FIXTURE_KNOB_%04d" % i, "type": "int", "default": i,
          "min": 0, "max": 100000, "note": "fixture knob " + "x" * 200}
         for i in range(1200)]
json.dump({"libs": [{"id": "zz-argmax-fixture", "file": "bin/lib/zz-argmax-fixture.sh",
                     "knobs": knobs}]}, open(sys.argv[1], "w"))
PY
size=$(wc -c < "$T/root/catalog/lanes.d/_lib.zz-argmax-fixture.json" | tr -d ' ')
[ "$size" -gt 200000 ] && ok || bad "fixture lib is only $size bytes"

(cd "$T/root" && bash bin/lanes-build.sh --root "$T/root" --write) > "$T/out" 2>&1 \
  && ok || bad "A1 --write failed on a >128 KiB libs scope: $(tail -3 "$T/out")"
jq -e '.libs | map(.id) | index("zz-argmax-fixture") != null' "$T/root/catalog/lanes.json" >/dev/null 2>&1 \
  && ok || bad "A2 the big lib is missing from the composed registry"
want=$(jq -r '[.libs[]] | length' "$T/root/catalog/lanes.json" 2>/dev/null)
have=$(cat "$T/root/catalog/lanes.d"/_lib*.json | jq -s '[.[].libs[]] | length' 2>/dev/null)
[ -n "$want" ] && [ "$want" = "$have" ] && ok || bad "A2 libs composed=$want sources=$have"

# A3: the real catalog still composes, and twice to identical bytes.
mkdir -p "$T/real/bin" "$T/real/catalog"
cp "$DIR/bin/lanes-build.sh" "$T/real/bin/"
cp -R "$DIR/catalog/lanes.d" "$T/real/catalog/"
(cd "$T/real" && bash bin/lanes-build.sh --root "$T/real" --write) >/dev/null 2>&1 \
  && cp "$T/real/catalog/lanes.json" "$T/first.json" \
  && (cd "$T/real" && bash bin/lanes-build.sh --root "$T/real" --write) >/dev/null 2>&1 \
  && cmp -s "$T/first.json" "$T/real/catalog/lanes.json" \
  && ok || bad "A3 the real catalog did not compose twice to identical bytes"

echo "lanes-build-argmax: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
