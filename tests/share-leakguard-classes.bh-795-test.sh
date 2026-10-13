#!/bin/bash
# tests/share-leakguard-classes.bh-795-test.sh — one case per class the mirror's leak
# guard has to tell apart, driven through the real bin/share/leakcheck.py.
#
# The guard used to have exactly one exemption: exact membership of the two
# literal lists in mapping.py. Every self-declaring fixture that landed after
# somebody wrote those lists therefore refused the publish until a human hand-
# listed it, and the publish sat red for days at a time. The fix is a rule about
# the VALUE ("a credential-shaped literal whose own text says fixture /
# do-not-ship / example is a fixture"), never about the path — a `tests/`
# exemption would also wave through a real key pasted into a test, which is the
# likeliest way a key actually escapes.
#
# So this file pins both halves. The positives prove the marker rule, the
# `.jsonl` extension and the documentation-placeholder address pass; the
# negatives prove a real-looking key still refuses in exactly those same
# places, including when a marker word sits elsewhere on the line.
#
# Every credential and every address below is ASSEMBLED FROM PIECES at runtime.
# The guard scans this file too (it ships in the mirror), and a test that has to
# be exempted from the thing it tests is the shape the guard exists to stop.
#
# Run from anywhere: tests/share-leakguard-classes.bh-795-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

OAT="sk-ant-""oat01-"
API="sk-ant-""api03-"
ORV="sk-or-""v1-"
# 40 characters of nothing in particular: not on any allowlist, no marker word,
# the shape of a key somebody pasted by accident.
REAL_TAIL="Qm7vT3xLp9RaZ2kW8nHy4sDf1jGc6bVe0uXo5tIq"

mk() { # mk <case> <relpath> — content arrives on stdin
  mkdir -p "$T/$1/$(dirname "$2")"
  cat > "$T/$1/$2"
}

guard() { # guard <case> — run the real guard, leave output in $T/out, print rc
  python3 "$DIR/bin/share/leakcheck.py" "$T/$1" > "$T/out" 2>&1
  echo $?
}

expect_clean() { # expect_clean <case> <what>
  local rc; rc=$(guard "$1")
  if [ "$rc" = 0 ]; then ok; else
    bad "$2: the guard refused a fixture (rc=$rc)"; sed -n '1,20p' "$T/out"
  fi
}

expect_hit() { # expect_hit <case> <relpath> <what>
  local rc; rc=$(guard "$1")
  if [ "$rc" = 1 ] && grep -q "^$2:" "$T/out"; then ok; else
    bad "$3: expected a refusal naming $2, got rc=$rc"; sed -n '1,20p' "$T/out"
  fi
}

# ── positives: these must publish ───────────────────────────────────────────
# 1. a marker inside the literal, on no list at all
printf 'KEY_FOR_THE_TEST=%sFIXTURE-do-not-ship-zzz9\n' "$OAT" | mk case-1 tests/x-test.sh
expect_clean case-1 "case 1 (FIXTURE marker inside the literal)"

# 2. the same rule, the other vendor shape and the other marker word
printf 'provisioning=%sEXAMPLEPROVISIONINGKEY0009\n' "$ORV" | mk case-2 tests/y-test.sh
expect_clean case-2 "case 2 (EXAMPLE marker inside the literal)"

# 3. .jsonl is text, and its contents scan clean
printf '{"jsonrpc":"2.0","result":{"usage":{"inputTokens":1}}}\n' \
  | mk case-3 tests/fixtures/f.jsonl
expect_clean case-3 "case 3 (.jsonl is auditable text)"

# 4. the non-CGNAT stub the doorbell fixture uses
printf 'peer=%s\n' "$(printf '100.%s' 0.0.1)" | mk case-4 tests/z-test.sh
expect_clean case-4 "case 4 (documentation address outside 100.64/10)"

# ── negatives: these must refuse ────────────────────────────────────────────
# 5. a real-looking key, under tests/ — the path buys nothing
printf 'KEY_FOR_THE_TEST=%s%s\n' "$OAT" "$REAL_TAIL" | mk case-5 tests/real-test.sh
expect_hit case-5 tests/real-test.sh "case 5 (real-looking key under tests/)"

# 6. a marker word on the line, but not inside the literal
printf '# FIXTURE: %s%s\n' "$OAT" "$REAL_TAIL" | mk case-6 tests/real-test.sh
expect_hit case-6 tests/real-test.sh "case 6 (marker outside the literal)"

# 7. the other Anthropic shape
printf 'KEY_FOR_THE_TEST=%s%s\n' "$API" "$REAL_TAIL" | mk case-7 tests/real-test.sh
expect_hit case-7 tests/real-test.sh "case 7 (api03 shape)"

# 8. .jsonl is audited, not excused
printf '{"v":"%s%s"}\n' "$OAT" "$REAL_TAIL" | mk case-8 tests/fixtures/g.jsonl
expect_hit case-8 tests/fixtures/g.jsonl "case 8 (.jsonl carrying a real-looking key)"

# 9. the suite's own CGNAT stub, raw, in a spec document. The mapping REWRITES
#    this address, and a rewrite is not an exemption: the guard runs on the
#    sanitized mirror, so the raw address it is handed here must still refuse.
#    (Building the case tree by hand, with no sanitize step, is what makes the
#    difference visible — that is the whole reason the stub was mapped instead
#    of allowlisted.)
printf 'ssh root@%s\n' "$(printf '100.%s' 64.0.9)" | mk case-9 .harness/specs/BH-1/plan.md
expect_hit case-9 .harness/specs/BH-1/plan.md "case 9 (the mapped CGNAT stub, unsanitized, in a spec)"

# 10. a CGNAT address on no list and in no mapping table
printf 'peer=%s\n' "$(printf '100.%s' 99.1.1)" | mk case-10 tests/w-test.sh
expect_hit case-10 tests/w-test.sh "case 10 (unlisted 100. address)"

# 11. a uuid with more than two distinct hex digits
printf 'account=%s\n' "$(printf '%s-%s-%s-%s-%s' 12345678 9abc def0 1234 56789abcdef0)" \
  | mk case-11 tests/v-test.sh
expect_hit case-11 tests/v-test.sh "case 11 (plausible account uuid)"

# 12. a file the guard cannot read is still a refusal
printf 'x' | mk case-12 tests/fixtures/h.bin
expect_hit case-12 tests/fixtures/h.bin "case 12 (un-auditable non-text file)"

# ── the SECOND scanner: bin/share/gitleaks-gate.py learned the same rule ────
# leakcheck and gitleaks-gate are two independent gates in bin/publish-share.sh,
# and a fixture rule in only one of them leaves the publish refusing anyway. The
# gate reads gitleaks' `Secret` field rather than a line of source, so it needs
# its own cases. They run the REAL gate out of bin/share/, so it imports this
# branch's mapping.py — no copy, no stub.
if command -v gitleaks >/dev/null 2>&1; then
  # 13. a value that says fixture: the gate lets it through without the string
  #     ever being hand-listed in KNOWN_FAKE_SECRETS.
  printf 'GH_TOKEN=%s%s\n' "ghs_" "fixture_stale_minute0" | mk case-13 tests/t-test.sh
  python3 "$DIR/bin/share/gitleaks-gate.py" "$T/case-13" > "$T/g13" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then ok; else
    bad "case 13 (gate: marker inside the secret) expected rc 0, got $rc"; sed -n '1,20p' "$T/g13"
  fi

  # 14. the same shape with a real-looking value: still refused, and the
  #     refusal names the file so a human can go and look at it.
  printf 'EXAMPLE_API_TOKEN=%s\n' "$REAL_TAIL" | mk case-14 tests/t-test.sh
  python3 "$DIR/bin/share/gitleaks-gate.py" "$T/case-14" > "$T/g14" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'tests/t-test.sh' "$T/g14"; then ok; else
    bad "case 14 (gate: real value under an EXAMPLE_ name) expected rc 1 naming tests/t-test.sh, got rc=$rc"
    sed -n '1,20p' "$T/g14"
  fi
else
  SKIP=$((SKIP+2))
  echo "SKIP cases 13-14: gitleaks not on PATH (the publish workflow installs 8.30.1)"
fi

# 15. The gate's classifier, called directly — the one case the binary cannot
#     pin. gitleaks 8.30.1 reports the bare value in `Secret`, but older rule
#     sets fold the assignment in (KNOWN_FAKE_SECRETS still carries one such
#     entry, spelled NAME=value), so the gate strips a leading `NAME=` before
#     reading the value. That strip is what stops a marker word in the VARIABLE
#     NAME from exempting a real value, and no scan input available here makes
#     it observable. So it is asserted on the function.
python3 - "$DIR" "$REAL_TAIL" > "$T/g15" 2>&1 <<'PY'
import importlib.util, os, sys
d, real_tail = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "gg", os.path.join(d, "bin", "share", "gitleaks-gate.py"))
gg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gg)
cases = [
    ("marker inside the value", "ghs_" + "fixture_stale_minute0", True),
    ("marker inside the value, assignment folded in",
     "GH_TOKEN=" + "ghs_" + "fixture_stale_minute0", True),
    ("marker only in the variable NAME",
     "EXAMPLE_API_TOKEN=" + real_tail, False),
    ("no marker anywhere", real_tail, False),
    ("empty / missing Secret", None, False),
]
bad = [n for n, s, want in cases if gg.is_fixture_literal(s) is not want]
print("BAD: " + "; ".join(bad) if bad else "OK")
PY
if [ $? -eq 0 ] && grep -qx 'OK' "$T/g15"; then ok; else
  bad "case 15 (gate classifier: NAME= prefix cannot exempt a value)"; sed -n '1,20p' "$T/g15"
fi

echo "share-leakguard-classes.bh-795-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
