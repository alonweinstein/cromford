#!/bin/bash
# tests/ci-durations-db.bh-5653-test.sh — the shard weights read from the jobs
# worker's ci_suite_durations first (BH-5653): bin/ci-durations.sh fetch asks
# the API, then the box cache of its last good answer, then the BH-5518 chain
# (the green batch's artifact, then the seed in git history).
#
#   DB1 bin/ci-durations.sh seed (no --file: the seed from git history, today's
#       data) -> the REAL worker (tests/lib/ci-durations-worker.bh-5653.mjs) ->
#       GET holds exactly the seed's row count. --dry-run sends nothing. A
#       second seed answers "already posted" for every run, samples unchanged
#   DB2 fetch against that worker -> `# source: api`, the cache is written,
#       and suite_shard_plan 8 and 4 over every suite the seed names plus
#       three it does not give byte-identical plans from the fetched file and
#       from the seed
#   DB3 MUTATION: the same GET body with the heaviest suite doubled -> the
#       8-shard plans differ (DB2 would catch a fetch that dropped values)
#   DB4 fallbacks: a 500 with a cache -> `# source: cache`, cache bytes kept;
#       `{}`, `{"rows":[]}`, truncated, HTML, a non-numeric second, a bad suite
#       path -> cache kept, never overwritten; no cache and the worker down ->
#       the seed; not configured -> no request and no cache read
#   DB5 the token is never printed; the GET carried a bearer
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
CDS="$DIR/bin/ci-durations.sh"
SRV="$DIR/tests/lib/ci-durations-worker.bh-5653.mjs"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "SKIP: node/python3 missing"; exit 0; }
TOK=fixture-ci-token
mkdir -p "$T/h"
export HARNESS="$T/h"
unset CI_DURATIONS_TOKEN HARNESS_SECRET SUITE_DURATIONS_FILE
export CI_DURATIONS_CACHE="$T/cache/api.tsv"
# No gh on purpose: a fetch that falls past the API and the cache must land on
# the seed, never on a live GitHub read.
export CI_DURATIONS_GH="$T/no-gh"

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
samples() { curl -sS "http://127.0.0.1:$1/__samples" | python3 -c 'import json,sys; print(json.load(sys.stdin)["samples"])'; }
fetch() { # <out> [env...] — fetch with --root the real checkout (its seed)
  local out="$1"; shift
  env "$@" "$CDS" fetch --out "$out" --root "$DIR" > "$out.stdout" 2> "$out.stderr"
}
plan() { # <durations file> <n>
  ( . "$DIR/bin/lib/suite-runner.sh" || exit 1
    SUITE_DURATIONS_FILE="$1" suite_shard_plan "$2" "${SUITES[@]}" )
}

# Today's data: the last committed copy of the durations file (BH-5518's seed).
SEEDSHA=$(git -C "$DIR" log -1 --format=%H --diff-filter=D -- catalog/ci-suite-durations.tsv)
git -C "$DIR" show "$SEEDSHA^:catalog/ci-suite-durations.tsv" > "$T/seed.tsv" 2>/dev/null
SEEDN=$(awk -F'\t' '!/^[[:space:]]*#/ && $2 ~ /^[0-9]+(\.[0-9]+)?$/ {n++} END {print n+0}' "$T/seed.tsv")
[ "$SEEDN" -gt 1000 ] && ok "the seed in git history has $SEEDN rows" || { bad "no seed in git history ($SEEDN rows)"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
# The suites planned: every suite today's data names, plus three it does not
# (they weigh the median on both paths).
SUITES=()
while IFS= read -r s; do SUITES+=("$DIR/$s"); done < <(awk -F'\t' '!/^[[:space:]]*#/ && NF {print $1}' "$T/seed.tsv")
SUITES+=("$DIR/tests/zz-new-a.bh-5653-fixture-test.sh" "$DIR/tests/zz-new-b.bh-5653-fixture-test.sh" "$DIR/tests/mc/zz-new-c.bh-5653-fixture-test.sh")

echo "DB1: seed today's data into the real worker"
"$CDS" seed --dry-run --root "$DIR" > "$T/bodies.jsonl" 2> "$T/dry.err"; rc=$?
[ "$rc" = 0 ] && ok "DB1 seed --dry-run rc 0" || bad "DB1 dry-run rc=$rc $(cat "$T/dry.err")"
python3 - "$T/bodies.jsonl" "$T/seed.tsv" <<'PY' && ok "DB1 the dry-run bodies are the seed, one body per source run" || bad "DB1 bodies differ from the seed"
import json, sys
rows = {}
for line in open(sys.argv[2]):
    if line.startswith("#") or not line.strip(): continue
    f = line.rstrip("\n").split("\t")
    rows[f[0]] = (float(f[1]), int(f[2]))
got, runs = {}, set()
for line in open(sys.argv[1]):
    b = json.loads(line)
    assert b["source"] == "seed" and b["run_id"] not in runs
    runs.add(b["run_id"])
    for r in b["rows"]:
        assert r["suite"] not in got
        got[r["suite"]] = (r["seconds"], b["run_id"])
assert got == rows, (len(got), len(rows))
assert runs == {v[1] for v in rows.values()}
PY
srv w1 worker; src=$?
if [ "$src" = 3 ]; then
  echo "SKIP DB1-DB3, DB5: node:sqlite unavailable in this runtime"
else
  W1="$PORT"
  [ ! -s "$T/w1.log" ] && ok "DB1 --dry-run sent nothing" || bad "DB1 dry-run sent: $(cat "$T/w1.log")"
  JOBS_URL="http://127.0.0.1:$W1" CI_DURATIONS_TOKEN=$TOK "$CDS" seed --root "$DIR" > "$T/seed1.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "DB1 seed rc 0" || bad "DB1 seed rc=$rc $(tail -5 "$T/seed1.out")"
  NRUNS=$(grep -c . "$T/bodies.jsonl")
  grep -qxF "ci-durations: seed: $NRUNS runs, $SEEDN rows: $NRUNS posted, 0 already posted, 0 refused" "$T/seed1.out" \
    && ok "DB1 seed posted $NRUNS runs" || bad "DB1 seed out: $(tail -3 "$T/seed1.out")"
  [ "$(samples "$W1")" = "$SEEDN" ] && ok "DB1 the worker holds $SEEDN samples" || bad "DB1 samples=$(samples "$W1") want $SEEDN"
  JOBS_URL="http://127.0.0.1:$W1" CI_DURATIONS_TOKEN=$TOK "$CDS" seed --root "$DIR" > "$T/seed2.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -qxF "ci-durations: seed: $NRUNS runs, $SEEDN rows: 0 posted, $NRUNS already posted, 0 refused" "$T/seed2.out" \
    && ok "DB1 a second seed is a no-op" || bad "DB1 re-seed rc=$rc $(tail -3 "$T/seed2.out")"
  [ "$(samples "$W1")" = "$SEEDN" ] && ok "DB1 samples unchanged" || bad "DB1 re-seed samples=$(samples "$W1")"

  echo "DB2: fetch from the worker, and the plan matches the seed's"
  fetch "$T/api.tsv" JOBS_URL="http://127.0.0.1:$W1" CI_DURATIONS_TOKEN=$TOK; rc=$?
  [ "$rc" = 0 ] && ok "DB2 fetch rc 0" || bad "DB2 fetch rc=$rc $(cat "$T/api.tsv.stderr")"
  [ "$(head -1 "$T/api.tsv")" = "# source: api" ] && ok "DB2 source=api" || bad "DB2 first line: $(head -1 "$T/api.tsv") $(cat "$T/api.tsv.stdout")"
  [ "$(grep -vc '^#' "$T/api.tsv")" = "$SEEDN" ] && ok "DB2 $SEEDN rows" || bad "DB2 rows=$(grep -vc '^#' "$T/api.tsv")"
  cmp -s "$T/api.tsv" "$CI_DURATIONS_CACHE" && ok "DB2 the answer is cached" || bad "DB2 cache: $(head -2 "$CI_DURATIONS_CACHE" 2>&1)"
  for n in 8 4; do
    plan "$T/api.tsv" "$n" > "$T/plan-api-$n"; plan "$T/seed.tsv" "$n" > "$T/plan-seed-$n"
    [ -s "$T/plan-api-$n" ] && cmp -s "$T/plan-api-$n" "$T/plan-seed-$n" \
      && ok "DB2 the $n-shard plan over ${#SUITES[@]} suites is the same on both paths" \
      || bad "DB2 $n-shard plans differ: $(diff "$T/plan-seed-$n" "$T/plan-api-$n" | head -4)"
  done

  echo "DB5: the token is never printed"
  grep -qF "$TOK" "$T/api.tsv" "$T/api.tsv.stdout" "$T/api.tsv.stderr" "$T/seed1.out" && bad "DB5 the token leaked" || ok "DB5 no token in any output"
  grep -q '^GET /api/ci/suite-durations auth=yes$' "$T/w1.log" && ok "DB5 the GET carried a bearer" || bad "DB5 log: $(grep GET "$T/w1.log")"

  echo "DB3: MUTATION — the heaviest suite doubled changes the plan"
  curl -sS -H "authorization: Bearer $TOK" "http://127.0.0.1:$W1/api/ci/suite-durations" > "$T/get.json"
  python3 - "$T/get.json" > "$T/get-mut.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
top = max(b["rows"], key=lambda r: (r["seconds"], r["suite"]))
top["seconds"] = top["seconds"] * 2
print(json.dumps(b))
PY
  srv c3 canned 200 "$T/get-mut.json"
  rm -f "$CI_DURATIONS_CACHE"
  fetch "$T/mut.tsv" JOBS_URL="http://127.0.0.1:$PORT" CI_DURATIONS_TOKEN=$TOK
  [ "$(head -1 "$T/mut.tsv")" = "# source: api" ] && ok "DB3 the mutated body is read" || bad "DB3 $(head -1 "$T/mut.tsv")"
  plan "$T/mut.tsv" 8 > "$T/plan-mut-8"
  cmp -s "$T/plan-mut-8" "$T/plan-seed-8" && bad "DB3 a doubled weight left the plan unchanged" || ok "DB3 the 8-shard plan differs"
fi

echo "DB4: an unusable answer never replaces the cache"
mkdir -p "$(dirname "$CI_DURATIONS_CACHE")"
printf '# source: api\ntests/cached-a-test.sh\t3\t11\ntests/cached-b-test.sh\t5.5\t12\n' > "$CI_DURATIONS_CACHE"
cp "$CI_DURATIONS_CACHE" "$T/cache.orig"
printf '{"error":"boom"}' > "$T/b-500"
printf '{}' > "$T/b-empty"
printf '{"rows":[]}' > "$T/b-norows"
printf '{"rows":[{"suite":"tests/x-test.sh","seconds":1,"source_run":1}],"truncated":true}' > "$T/b-trunc"
printf '<html>gateway</html>' > "$T/b-html"
printf '{"rows":[{"suite":"tests/x-test.sh","seconds":"12s","source_run":1}]}' > "$T/b-nonnum"
printf '{"rows":[{"suite":"../x-test.sh","seconds":1,"source_run":1}]}' > "$T/b-path"
printf '{"rows":[{"suite":"tests/x-test.sh","seconds":1e9,"source_run":1}]}' > "$T/b-huge"
for c in 500:b-500 200:b-empty 200:b-norows 200:b-trunc 200:b-html 200:b-nonnum 200:b-path 200:b-huge; do
  st=${c%%:*}; f=${c#*:}
  srv "c-$f" canned "$st" "$T/$f"
  fetch "$T/fb-$f.tsv" JOBS_URL="http://127.0.0.1:$PORT" CI_DURATIONS_TOKEN=$TOK; rc=$?
  [ "$rc" = 0 ] && [ "$(head -1 "$T/fb-$f.tsv")" = "# source: cache" ] \
    && ok "DB4 $f ($st) -> source=cache" || bad "DB4 $f rc=$rc first line: $(head -1 "$T/fb-$f.tsv") $(cat "$T/fb-$f.tsv.stdout")"
  cmp -s "$CI_DURATIONS_CACHE" "$T/cache.orig" && ok "DB4 $f left the cache untouched" || bad "DB4 $f changed the cache"
  [ "$(grep -v '^#' "$T/fb-$f.tsv")" = "$(grep -v '^#' "$T/cache.orig")" ] && ok "DB4 $f serves the cached rows" || bad "DB4 $f rows: $(cat "$T/fb-$f.tsv")"
  grep -q '^::warning::ci-durations: the jobs worker answer is unusable' "$T/fb-$f.tsv.stdout" \
    && ok "DB4 $f prints one ::warning::" || bad "DB4 $f no warning: $(cat "$T/fb-$f.tsv.stdout")"
done
stop_all
rm -f "$CI_DURATIONS_CACHE"
fetch "$T/fb-down.tsv" JOBS_URL="http://127.0.0.1:$PORT" CI_DURATIONS_TOKEN=$TOK; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$T/fb-down.tsv")" = "# source: seed $SEEDSHA" ] \
  && ok "DB4 no cache and the worker down -> the seed" || bad "DB4 down rc=$rc $(head -1 "$T/fb-down.tsv")"
[ ! -e "$CI_DURATIONS_CACHE" ] && ok "DB4 a failed answer writes no cache" || bad "DB4 a cache appeared"
cp "$T/cache.orig" "$CI_DURATIONS_CACHE"
printf '{}' > "$T/b-any"; srv c-nc canned 200 "$T/b-any"
fetch "$T/fb-nc.tsv" JOBS_URL= CI_DURATIONS_TOKEN=$TOK; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$T/fb-nc.tsv")" = "# source: seed $SEEDSHA" ] \
  && ok "DB4 not configured -> the chain, not the cache" || bad "DB4 not configured: $(head -1 "$T/fb-nc.tsv")"
fetch "$T/fb-nt.tsv" JOBS_URL="http://127.0.0.1:$PORT"; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$T/fb-nt.tsv")" = "# source: seed $SEEDSHA" ] \
  && ok "DB4 no token -> the chain" || bad "DB4 no token: $(head -1 "$T/fb-nt.tsv")"
[ ! -s "$T/c-nc.log" ] && ok "DB4 not configured sent no request" || bad "DB4 requests: $(cat "$T/c-nc.log")"
stop_all

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
