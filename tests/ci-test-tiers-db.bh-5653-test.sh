#!/bin/bash
# tests/ci-test-tiers-db.bh-5653-test.sh — the test-tier set in the jobs worker
# (BH-5653 slice C1): bin/ci-test-tiers.sh put seeds catalog/test-tiers.tsv
# into the REAL worker (tests/lib/ci-durations-worker.bh-5653.mjs, over real
# curl), and bin/ci-test-tiers.sh fetch reads it back for bin/ci-plan.sh.
#
# The checkout is a scratch git repo: today's catalog/test-tiers.tsv and
# catalog/test-quarantine-protected.txt, plus an empty file for every
# tests/*.sh and tests/mc/*.sh suite, so `bin/test-tiers.sh check` runs.
#
#   P0 put --dry-run prints one JSON body (every row, the blob, source seed)
#      and sends nothing
#   P1 put seeds today's file -> `stored set 1`
#   P2 put again -> `duplicate: set 1`, rc 0
#   P3 put with only CI_DURATIONS_TOKEN -> rc 1, no PUT in the worker log
#   D1 fetch -> `# source: api set 1 base <blob>`, the rows are the committed rows
#   D2 PARITY: bin/test-tiers.sh batch (two changed lists) and nightly over
#      every suite give byte-identical stdout from the fetched file and from
#      catalog/test-tiers.tsv
#   D3 a new suite with no row in the set stays in the batch; check passes
#   D4 a commit that edits catalog/test-tiers.tsv makes set 1 stale: fetch
#      uses the committed file and names both blobs
#   D5 the bearer is never printed; the GET carried one
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
CTT="$DIR/bin/ci-test-tiers.sh"
ROUTE="$DIR/worker/jobs/src/routes/ci-test-tiers.js"
TTS="$DIR/bin/test-tiers.sh"
SRV="$DIR/tests/lib/ci-durations-worker.bh-5653.mjs"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node/python3/curl missing"; exit 0; }
TOK=fixture-ci-token
SEC=fixture-harness-secret
mkdir -p "$T/h"
export HARNESS="$T/h"
unset CI_DURATIONS_TOKEN HARNESS_SECRET CI_TEST_TIERS_CACHE
export CI_TEST_TIERS_CACHE="$T/cache/api.tsv"

PIDS=()
srv() {
  local n="$1"; shift
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$1" "$T/$n.log" "${@:2}" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 100); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
rows_of() { grep -Ev '^[[:space:]]*(#|$)' "$1" | LC_ALL=C sort; }

[ -f "$CTT" ] && [ -f "$ROUTE" ] && ok "the script and the worker route this suite drives exist" \
  || bad "missing: bin/ci-test-tiers.sh or worker/jobs/src/routes/ci-test-tiers.js"

# The scratch checkout.
R="$T/repo"
mkdir -p "$R/catalog" "$R/tests/mc"
cp "$DIR/catalog/test-tiers.tsv" "$DIR/catalog/test-quarantine-protected.txt" "$R/catalog/"
( cd "$DIR" && ls tests/*.sh tests/mc/*.sh ) > "$T/suites"
( cd "$R" && xargs touch < "$T/suites" )
git -C "$R" init -q && git -C "$R" add -A \
  && git -C "$R" -c user.email=fixture@example.invalid -c user.name=fixture commit -qm seed \
  || { echo "FAIL: cannot build the scratch checkout"; exit 1; }
BLOB=$(git -C "$R" rev-parse HEAD:catalog/test-tiers.tsv)
NROWS=$(rows_of "$R/catalog/test-tiers.tsv" | grep -c .)
"$TTS" check --root "$R" > "$T/check0" 2>&1 && ok "the scratch checkout passes check ($NROWS rows)" \
  || { bad "the scratch checkout fails check: $(tail -3 "$T/check0")"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

echo "P0: put --dry-run"
"$CTT" put --dry-run --root "$R" > "$T/dry.json" 2> "$T/dry.err"; rc=$?
[ "$rc" = 0 ] && ok "P0 rc 0" || bad "P0 rc=$rc $(cat "$T/dry.err")"
python3 - "$T/dry.json" "$R/catalog/test-tiers.tsv" "$BLOB" <<'PY' && ok "P0 the body is every committed row, the blob, source seed" || bad "P0 body differs"
import json, sys
b = json.load(open(sys.argv[1]))
want = []
for line in open(sys.argv[2]):
    if not line.strip() or line.lstrip().startswith("#"): continue
    f = line.rstrip("\n").split("\t")
    want.append({"suite": f[0], "tier": f[1], "runtime_s": int(f[2]), "paths": f[3], "reason": f[4]})
assert b["base_blob"] == sys.argv[3], b["base_blob"]
assert b["source"] == "seed"
assert isinstance(b["actor"], str) and b["actor"]
assert sorted(b["rows"], key=lambda r: r["suite"]) == sorted(want, key=lambda r: r["suite"]), (len(b["rows"]), len(want))
PY

srv w1 worker; src=$?
if [ "$src" = 3 ]; then
  echo "SKIP P1-P3, D1-D5: node:sqlite unavailable in this runtime"
  echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]; exit
fi
W1="http://127.0.0.1:$PORT"
[ ! -s "$T/w1.log" ] && ok "P0 --dry-run sent nothing" || bad "P0 dry-run sent: $(cat "$T/w1.log")"

echo "P1-P3: put into the real worker"
JOBS_URL="$W1" HARNESS_SECRET=$SEC "$CTT" put --root "$R" > "$T/put1.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^ci-test-tiers: stored set 1 ' "$T/put1.out" \
  && ok "P1 stored set 1" || bad "P1 rc=$rc $(cat "$T/put1.out")"
JOBS_URL="$W1" HARNESS_SECRET=$SEC "$CTT" put --root "$R" > "$T/put2.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^ci-test-tiers: duplicate: set 1' "$T/put2.out" \
  && ok "P2 a second put is a duplicate of set 1" || bad "P2 rc=$rc $(cat "$T/put2.out")"
grep -q 'stored' "$T/put2.out" && bad "P2 a duplicate said stored" || ok "P2 a duplicate never says stored"
: > "$T/w1.log"
JOBS_URL="$W1" CI_DURATIONS_TOKEN=$TOK "$CTT" put --root "$R" > "$T/put3.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'put needs HARNESS_SECRET' "$T/put3.out" \
  && ok "P3 the CI token alone cannot put (rc 1)" || bad "P3 rc=$rc $(cat "$T/put3.out")"
grep -q '^PUT ' "$T/w1.log" && bad "P3 a PUT reached the worker: $(cat "$T/w1.log")" || ok "P3 no PUT reached the worker"

echo "D1: fetch from the worker"
JOBS_URL="$W1" CI_DURATIONS_TOKEN=$TOK "$CTT" fetch --out "$T/api.tsv" --root "$R" > "$T/api.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "D1 fetch rc 0" || bad "D1 fetch rc=$rc $(cat "$T/api.out")"
[ "$(head -1 "$T/api.tsv")" = "# source: api set 1 base $BLOB" ] && ok "D1 source=api set 1" \
  || bad "D1 first line: $(head -1 "$T/api.tsv") / $(cat "$T/api.out")"
[ "$(rows_of "$T/api.tsv")" = "$(rows_of "$R/catalog/test-tiers.tsv")" ] && ok "D1 the $NROWS rows are the committed rows" \
  || bad "D1 rows differ: $(diff <(rows_of "$R/catalog/test-tiers.tsv") <(rows_of "$T/api.tsv") | head -4)"
cmp -s "$T/api.tsv" "$CI_TEST_TIERS_CACHE" && ok "D1 the answer is cached" || bad "D1 cache: $(head -1 "$CI_TEST_TIERS_CACHE" 2>&1)"

echo "D2: PARITY with the committed file"
# A path one guard row names (its first spec with no glob; a directory gets a
# file under it), so the guard runs in the batch on both paths.
GUARDP=$(awk -F'\t' '!/^[[:space:]]*#/ && $2 == "guard" && $4 !~ /[*?[]/ {split($4, a, " "); print a[1]; exit}' "$R/catalog/test-tiers.tsv")
case "$GUARDP" in */) GUARDP="${GUARDP}zz-fixture.sh" ;; esac
printf 'docs/unrelated.md\n' > "$T/changed-none"
printf '%s\n' "$GUARDP" > "$T/changed-guard"
for mode in batch:none batch:guard nightly:; do
  m=${mode%%:*}; c=${mode#*:}
  args=(); [ -n "$c" ] && args=(--changed "$T/changed-$c")
  "$TTS" "$m" --tiers "$T/api.tsv" --root "$R" "${args[@]}" < "$T/suites" > "$T/p-api-$m$c" 2>/dev/null; r1=$?
  "$TTS" "$m" --tiers "$R/catalog/test-tiers.tsv" --root "$R" "${args[@]}" < "$T/suites" > "$T/p-git-$m$c" 2>/dev/null; r2=$?
  [ "$r1$r2" = 00 ] && [ -s "$T/p-git-$m$c" ] && cmp -s "$T/p-api-$m$c" "$T/p-git-$m$c" \
    && ok "D2 $m ${c:+(changed: $c) }is byte-identical on both paths ($(grep -c . "$T/p-git-$m$c") suites)" \
    || bad "D2 $m $c rc=$r1/$r2 differs: $(diff "$T/p-git-$m$c" "$T/p-api-$m$c" | head -4)"
done
NIN=$(grep -c . "$T/suites"); NB=$(grep -c . "$T/p-git-batchnone")
[ "$NB" -lt "$NIN" ] && ok "D2 the tier set moves suites out of the batch ($NB of $NIN)" || bad "D2 the batch kept all $NIN suites"
cmp -s "$T/p-git-batchnone" "$T/p-git-batchguard" && bad "D2 the guard change did not change the batch" \
  || ok "D2 a diff on a guarded path adds its guard on both paths"

echo "D3: a suite with no row in the set stays in the batch"
NEW=tests/zz-new.bh-5653-test.sh
{ cat "$T/suites"; echo "$NEW"; } > "$T/suites-new"
"$TTS" batch --tiers "$T/api.tsv" --root "$R" --changed "$T/changed-none" < "$T/suites-new" > "$T/p-new" 2>/dev/null
grep -qxF "$NEW" "$T/p-new" && ok "D3 $NEW is in the batch" || bad "D3 $NEW was dropped"
touch "$R/$NEW"
"$TTS" check --tiers "$T/api.tsv" --root "$R" > "$T/check3" 2>&1 && ok "D3 check passes with a suite the set does not name" \
  || bad "D3 check: $(tail -3 "$T/check3")"
rm -f "$R/$NEW"

echo "D4: a commit that edits the tier file makes the stored set stale"
NS=$(awk -F'\t' '!/^[[:space:]]*#/ && $2 == "nightly" {print $1; exit}' "$R/catalog/test-tiers.tsv")
awk -F'\t' -v OFS='\t' -v s="$NS" '$1 == s {$2 = "batch"} {print}' "$R/catalog/test-tiers.tsv" > "$T/edited.tsv"
cp "$T/edited.tsv" "$R/catalog/test-tiers.tsv"
git -C "$R" -c user.email=fixture@example.invalid -c user.name=fixture commit -qam "move $NS to the batch"
BLOB2=$(git -C "$R" rev-parse HEAD:catalog/test-tiers.tsv)
JOBS_URL="$W1" CI_DURATIONS_TOKEN=$TOK "$CTT" fetch --out "$T/stale.tsv" --root "$R" > "$T/stale.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$T/stale.tsv")" = "# source: committed $BLOB2" ] \
  && ok "D4 the PR's edit wins: source=committed" || bad "D4 rc=$rc $(head -1 "$T/stale.tsv") / $(cat "$T/stale.out")"
grep -q "^::warning::.*set 1.*$BLOB.*$BLOB2" "$T/stale.out" && ok "D4 one ::warning:: names both blobs" \
  || bad "D4 warning: $(cat "$T/stale.out")"
"$TTS" batch --tiers "$T/stale.tsv" --root "$R" --changed "$T/changed-none" < "$T/suites" > "$T/p-stale" 2>/dev/null
grep -qxF "$NS" "$T/p-stale" && ok "D4 $NS runs in the batch, as the edit says" || bad "D4 $NS is not in the batch"

echo "D5: the bearer is never printed"
grep -qF -e "$TOK" -e "$SEC" "$T"/*.out "$T/api.tsv" "$T/dry.json" && bad "D5 a bearer leaked" || ok "D5 no bearer in any output"
grep -q '^GET /api/ci/test-tiers auth=yes$' "$T/w1.log" && ok "D5 the GET carried a bearer" || bad "D5 log: $(cat "$T/w1.log")"
stop_all

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
