#!/bin/bash
# tests/flaky-detect-test.sh — bin/flaky-detect.sh and bin/lib/flaky.sh, driven.
#
# WHAT IS UNDER TEST. One claim, and it is the whole feature: a head sha that
# has BOTH a failed and a successful run of the SAME workflow is a flake, and a
# head that only ever went red is a real red. Everything else here exists to
# keep that claim honest — that the two are written to the ledger as different
# kinds so the rate has a denominator, that the failing TEST names come out of
# the run (not the job name) when the log carries them, that a second detector
# run over the same window writes the same keys instead of inflating the count,
# and that two workflows on one sha are never mixed.
#
# gh is stubbed; the metrics client is a recording shim in the scratch HARNESS,
# so what is proven is the shell's own classification and its ledger calls. The
# worker route is proven by worker/jobs/test/index.test.js.
# Run from anywhere: tests/flaky-detect-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

cp "$DIR/bin/flaky-detect.sh" "$T/h/bin/" 2>/dev/null
cp "$DIR/bin/lib/flaky.sh" "$DIR/bin/lib/gh-repo-token.sh" "$T/h/bin/lib/" 2>/dev/null
[ -s "$T/h/bin/flaky-detect.sh" ] && ok || bad "bin/flaky-detect.sh missing"
[ -s "$T/h/bin/lib/flaky.sh" ] && ok || bad "bin/lib/flaky.sh missing"
printf 'demo example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
cat > "$T/h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "demo repo") echo "example-org/demo-os" ;;
  "--projects ") echo "demo" ;;
esac
SH
chmod +x "$T/h/bin/fleet-conf.sh"
# The metrics client, recorded. flaky-detect sources $H/bin/jobs-client.sh the
# way every other lane does, so replacing the file is the seam.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
metric_flake() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-flake}" >> "$FLAKE_SINK"; }
metric_flakes_list() { cat "${FLAKE_LEDGER:-/dev/null}" 2>/dev/null; }
SH

# ---------------------------------------------------------------------------
# gh shim. runs come from $T/runs.json; the per-run jobs from $T/jobs-<id>.json;
# the failed log from $T/log-<id>.txt (absent = the log read fails, which is the
# fall-back-to-job-name path).
# ---------------------------------------------------------------------------
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"actions/runs/"*"/jobs"*)
    ID=$(sed -E 's#.*actions/runs/([0-9]+)/jobs.*#\1#' <<<"$*")
    [ -f "$T/jobs-$ID.json" ] || exit 1
    jq -r '.jobs[] | select(.conclusion=="failure") | .name' "$T/jobs-$ID.json" ;;
  *"actions/runs"*)
    [ -f "$T/runs.json" ] || exit 1
    jq -c '[.workflow_runs[]? | {i:.id, n:.name, p:.path, s:.status, c:.conclusion, h:.head_sha, t:.created_at, u:.html_url}]' "$T/runs.json" ;;
  "run view "*"--log-failed"*)
    ID=$(awk '{print $3}' <<<"$*")
    [ -f "$T/log-$ID.txt" ] || exit 1
    cat "$T/log-$ID.txt" ;;
  *) echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"

# GNU date on the boxes, BSD date when someone runs this on the laptop.
ago() { # ago <days> -> an RFC3339 UTC stamp that many days back
  local n=$(( $(date -u +%s) - ${1:-0} * 86400 ))
  date -u -d "@$n" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$n" +%Y-%m-%dT%H:%M:%SZ
}

# runs <spec>...  spec = id|name|path|conclusion|head|days-ago[|status]
runs() {
  local out='{"workflow_runs":[' first=1 spec i n p c h d s
  for spec in "$@"; do
    IFS='|' read -r i n p c h d s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson i "$i" --arg n "$n" --arg p "$p" --arg c "$c" --arg h "$h" --arg s "$s" \
      --arg t "$(ago "$d")" --arg u "https://x/run/$i" \
      '{id:$i, name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end),
        head_sha:$h, created_at:$t, html_url:$u}')
  done
  printf '%s]}' "$out" > "$T/runs.json"
}
detect() { # detect [args...]
  : > "$T/flakes.tsv"; : > "$T/gh.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" T="$T" GH_SINK="$T/gh.txt" \
           FLAKE_SINK="$T/flakes.tsv" HARNESS_SECRET=x
    bash "$T/h/bin/flaky-detect.sh" "$@" ) > "$T/out.txt" 2> "$T/err.txt"
}
E=".github/workflows/e2e.yml"; C=".github/workflows/ci.yml"
SHA1=aaaaaaaaaaaa1111; SHA2=bbbbbbbbbbbb2222; SHA3=cccccccccccc3333

# ===========================================================================
# 1. The core claim: fail + success on ONE sha of ONE workflow = a flake
# ===========================================================================
cat > "$T/jobs-101.json" <<'J'
{"jobs":[{"name":"unit","conclusion":"failure"},{"name":"lint","conclusion":"success"}]}
J
cat > "$T/log-101.txt" <<'L'
2026-09-12T01:02:03Z  FAIL  src/lib/queue.test.ts > queue > drains under load
2026-09-12T01:02:03Z    × queue > drains under load 42ms
2026-09-12T01:02:04Z    ✓ queue > accepts a job 2ms
L
runs "101|CI|$C|failure|$SHA1|1" "102|CI|$C|success|$SHA1|1"
detect demo
awk -F'\t' -v w="$C" -v s="$SHA1" '$1=="example-org/demo-os" && $2==w && $3=="queue > drains under load" && $4==s' "$T/flakes.tsv" | grep -q . \
  && ok || bad "fail+success on one sha must write a flake row for the failing TEST name: $(cat "$T/flakes.tsv") err=$(cat "$T/err.txt")"
[ "$(awk -F'\t' '{print $6}' "$T/flakes.tsv" | sort -u)" = flake ] \
  && ok || bad "every row of a fail+success sha must be kind=flake (got $(awk -F'\t' '{print $6}' "$T/flakes.tsv" | sort -u))"
grep -q 'accepts a job' "$T/flakes.tsv" && bad "a PASSING test line must never be recorded as a flake" || ok

# ===========================================================================
# 2. Red with no green on the same sha is a REAL red, not a flake
# ===========================================================================
runs "201|CI|$C|failure|$SHA2|1" "202|CI|$C|failure|$SHA2|0"
cat > "$T/jobs-201.json" <<'J'
{"jobs":[{"name":"unit","conclusion":"failure"}]}
J
cp "$T/jobs-201.json" "$T/jobs-202.json"
cp "$T/log-101.txt" "$T/log-201.txt"; cp "$T/log-101.txt" "$T/log-202.txt"
detect demo
[ -s "$T/flakes.tsv" ] && ok || bad "a red head must still be ledgered (the rate needs a denominator)"
[ "$(awk -F'\t' '{print $6}' "$T/flakes.tsv" | sort -u)" = red ] \
  && ok || bad "red twice on the SAME sha with no success is kind=red, never flake (got $(awk -F'\t' '{print $6}' "$T/flakes.tsv" | sort -u))"

# ===========================================================================
# 3. fail on one sha, success on ANOTHER sha is a push, not a flake
# ===========================================================================
runs "301|CI|$C|failure|$SHA2|1" "302|CI|$C|success|$SHA3|0"
cp "$T/jobs-201.json" "$T/jobs-301.json"; cp "$T/log-101.txt" "$T/log-301.txt"
detect demo
grep -q . <<<"$(awk -F'\t' '$6=="flake"' "$T/flakes.tsv")" \
  && bad "green on a DIFFERENT sha is a fix, not a flake: $(cat "$T/flakes.tsv")" || ok

# ===========================================================================
# 4. Two workflows on one sha do not contaminate each other
# ===========================================================================
runs "401|CI|$C|failure|$SHA1|1" "402|CI|$C|success|$SHA1|1" "403|E2E|$E|failure|$SHA1|1"
cp "$T/jobs-101.json" "$T/jobs-401.json"; cp "$T/log-101.txt" "$T/log-401.txt"
cat > "$T/jobs-403.json" <<'J'
{"jobs":[{"name":"playwright","conclusion":"failure"}]}
J
detect demo
[ "$(awk -F'\t' -v w="$C" '$2==w {print $6}' "$T/flakes.tsv" | sort -u)" = flake ] \
  && ok || bad "the CI workflow on that sha is a flake"
[ "$(awk -F'\t' -v w="$E" '$2==w {print $6}' "$T/flakes.tsv" | sort -u)" = red ] \
  && ok || bad "the E2E workflow on the SAME sha, red with no green of its own, must stay a real red"
awk -F'\t' -v w="$E" '$2==w {print $3}' "$T/flakes.tsv" | grep -q '^job:playwright$' \
  && ok || bad "with no parseable test names the row must name the failed JOB (job:<name>), not guess"

# ===========================================================================
# 5. Idempotent: the same window twice writes the same keys, never new ones
# ===========================================================================
runs "101|CI|$C|failure|$SHA1|1" "102|CI|$C|success|$SHA1|1"
detect demo; cp "$T/flakes.tsv" "$T/first.tsv"
detect demo
diff <(sort "$T/first.tsv") <(sort "$T/flakes.tsv") >/dev/null \
  && ok || bad "a second run over the same window must produce identical rows (the PK absorbs them)"

# ===========================================================================
# 6. jest's marker parses too, and the table names the count
# ===========================================================================
cat > "$T/log-101.txt" <<'L'
2026-09-12T01:02:03Z   ● Auth › rejects an expired token
2026-09-12T01:02:03Z   ● Auth › rejects an expired token
L
detect demo
[ "$(awk -F'\t' '$3=="Auth › rejects an expired token"' "$T/flakes.tsv" | wc -l | tr -d ' ')" = 1 ] \
  && ok || bad "a jest ● line must parse once, deduped: $(cat "$T/flakes.tsv")"
grep -q 'Auth › rejects an expired token' "$T/out.txt" \
  && ok || bad "the printed table must name the flaky test: $(cat "$T/out.txt")"

# ===========================================================================
# 7. --dry-run writes nothing
# ===========================================================================
detect demo --dry-run
[ -s "$T/flakes.tsv" ] && bad "--dry-run must not write ledger rows" || ok
grep -q 'Auth' "$T/out.txt" && ok || bad "--dry-run must still print what it found"

echo "flaky-detect-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
