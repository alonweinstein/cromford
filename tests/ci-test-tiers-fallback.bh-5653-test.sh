#!/bin/bash
# tests/ci-test-tiers-fallback.bh-5653-test.sh — bin/ci-test-tiers.sh fetch
# never lets a bad jobs-worker answer reach bin/ci-plan.sh (BH-5653 slice C1).
# Each case is a canned answer (tests/lib/ci-durations-worker.bh-5653.mjs
# canned) over real curl, against a scratch git checkout holding today's
# catalog/test-tiers.tsv and an empty file for every suite.
#
#   F0 a usable set that differs from the committed file is USED: source api,
#      its rows, the cache written, and the batch it gives differs
#   F1 a set whose base_blob is not the checkout's -> the committed file, one
#      ::warning:: naming both blobs
#   F2 HTTP 500 with a cache whose base matches -> the cache
#   F3 HTTP 500 with a cache whose base does not match -> the committed file
#   F4 `{}`, `{"set":{}}`, HTML, no rows, a non-numeric runtime, a tab in a
#      reason -> the committed file; the cache is byte-unchanged
#   F5 sets `check` refuses (a suite missing from the tree, a guard with paths
#      `-`, a tier `skip`) -> the fallback; the cache is byte-unchanged
#   F6 JOBS_URL set but empty, or an empty token -> no request, the committed file
#   F7 `{"set":null}` -> the committed file, one ::notice::
#   F8 every case exits 0; no --out, or an unknown argument, exits 2
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CTT="$DIR/bin/ci-test-tiers.sh"
TTS="$DIR/bin/test-tiers.sh"
SRV="$DIR/tests/lib/ci-durations-worker.bh-5653.mjs"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node/python3/curl missing"; exit 0; }
TOK=fixture-ci-token
mkdir -p "$T/h"
export HARNESS="$T/h"
unset CI_DURATIONS_TOKEN HARNESS_SECRET CI_TEST_TIERS_CACHE
CACHE="$T/cache/api.tsv"
export CI_TEST_TIERS_CACHE="$CACHE"

PIDS=()
srv() {
  local n="$1"; shift
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$1" "$T/$n.log" "${@:2}" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 100); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=(); }
rows_of() { grep -Ev '^[[:space:]]*(#|$)' "$1" | LC_ALL=C sort; }
RCS=""
# fetch_from <name> <status> <body file> [env...] — one canned worker, one fetch.
fetch_from() {
  local n="$1" st="$2" bf="$3"; shift 3
  srv "$n" canned "$st" "$bf"
  env JOBS_URL="http://127.0.0.1:$PORT" CI_DURATIONS_TOKEN=$TOK "$@" \
    "$CTT" fetch --out "$T/$n.tsv" --root "$R" > "$T/$n.out" 2>&1
  local rc=$?; RCS="$RCS $n=$rc"
  return "$rc"
}
src_of() { head -1 "$T/$1.tsv"; }

R="$T/repo"
mkdir -p "$R/catalog" "$R/tests/mc"
cp "$DIR/catalog/test-tiers.tsv" "$DIR/catalog/test-quarantine-protected.txt" "$R/catalog/"
( cd "$DIR" && ls tests/*.sh tests/mc/*.sh ) > "$T/suites"
( cd "$R" && xargs touch < "$T/suites" )
git -C "$R" init -q && git -C "$R" add -A \
  && git -C "$R" -c user.email=fixture@example.invalid -c user.name=fixture commit -qm seed \
  || { echo "FAIL: cannot build the scratch checkout"; exit 1; }
BLOB=$(git -C "$R" rev-parse HEAD:catalog/test-tiers.tsv)
OLD=$(printf 'f%.0s' $(seq 1 40))
COMMITTED="# source: committed $BLOB"
# The first nightly suite, which F0's set moves back into the batch.
NS=$(awk -F'\t' '!/^[[:space:]]*#/ && $2 == "nightly" {print $1; exit}' "$R/catalog/test-tiers.tsv")
printf 'docs/unrelated.md\n' > "$T/changed"

# body <out> <base> <mutation> — a GET answer built from the committed rows.
body() {
  python3 - "$R/catalog/test-tiers.tsv" "$2" "$3" "$NS" > "$1" <<'PY'
import json, sys
path, base, mut, ns = sys.argv[1:5]
rows = []
for line in open(path):
    if not line.strip() or line.lstrip().startswith("#"): continue
    f = line.rstrip("\n").split("\t")
    rows.append({"suite": f[0], "tier": f[1], "runtime_s": int(f[2]), "paths": f[3], "reason": f[4]})
if mut == "move":
    for r in rows:
        if r["suite"] == ns: r["tier"] = "batch"
elif mut == "missing":
    rows.append({"suite": "tests/zz-missing.bh-5653-test.sh", "tier": "nightly", "runtime_s": 1, "paths": "-", "reason": "gone"})
elif mut == "guard-dash":
    for r in rows:
        if r["tier"] == "guard": r["paths"] = "-"; break
elif mut == "skip":
    rows[0]["tier"] = "skip"
elif mut == "nonnum":
    rows[0]["runtime_s"] = "12"
elif mut == "tab":
    rows[0]["reason"] = "a\tb"
elif mut == "norows":
    rows = []
print(json.dumps({"set": {"id": 9, "base_blob": base, "digest": "0" * 64, "source": "operator",
                          "actor": "fixture", "created_at": "2026-10-10T00:00:00Z", "rows": rows}}))
PY
}

echo "F0: a usable set is used"
body "$T/b-move" "$BLOB" move
fetch_from f0 200 "$T/b-move"; rc=$?
[ "$rc" = 0 ] && [ "$(src_of f0)" = "# source: api set 9 base $BLOB" ] && ok "F0 source=api set 9" || bad "F0 rc=$rc $(src_of f0) / $(cat "$T/f0.out")"
python3 - "$T/b-move" > "$T/move-rows" <<'PY'
import json, sys
for r in json.load(open(sys.argv[1]))["set"]["rows"]:
    print("\t".join([r["suite"], r["tier"], str(r["runtime_s"]), r["paths"], r["reason"]]))
PY
[ "$(rows_of "$T/f0.tsv")" = "$(LC_ALL=C sort "$T/move-rows")" ] && ok "F0 the rows are the set's" || bad "F0 rows differ"
cmp -s "$T/f0.tsv" "$CACHE" && ok "F0 the answer is cached" || bad "F0 no cache"
"$TTS" batch --tiers "$T/f0.tsv" --root "$R" --changed "$T/changed" < "$T/suites" > "$T/p-f0" 2>/dev/null
"$TTS" batch --root "$R" --changed "$T/changed" < "$T/suites" > "$T/p-git" 2>/dev/null
grep -qxF "$NS" "$T/p-f0" && ! grep -qxF "$NS" "$T/p-git" && ok "F0 the set's tier decides: $NS is in the batch" \
  || bad "F0 $NS: set batch=$(grep -cxF "$NS" "$T/p-f0") committed batch=$(grep -cxF "$NS" "$T/p-git")"
cp "$CACHE" "$T/cache.good"
stop_all

echo "F1: a stale base_blob"
body "$T/b-stale" "$OLD" move
fetch_from f1 200 "$T/b-stale"
[ "$(src_of f1)" = "$COMMITTED" ] && ok "F1 source=committed" || bad "F1 $(src_of f1) / $(cat "$T/f1.out")"
[ "$(grep -c '^::warning::' "$T/f1.out")" = 1 ] && grep -q "^::warning::.*set 9.*$OLD.*$BLOB" "$T/f1.out" \
  && ok "F1 one ::warning:: names both blobs" || bad "F1 warning: $(cat "$T/f1.out")"
[ "$(rows_of "$T/f1.tsv")" = "$(rows_of "$R/catalog/test-tiers.tsv")" ] && ok "F1 the rows are the committed rows" || bad "F1 rows differ"
cmp -s "$CACHE" "$T/cache.good" && ok "F1 the cache is unchanged" || bad "F1 the cache changed"
stop_all

echo "F2/F3: HTTP 500 and the cache"
printf '{"error":"boom"}' > "$T/b-500"
fetch_from f2 500 "$T/b-500"
[ "$(src_of f2)" = "# source: cache set 9 base $BLOB" ] && ok "F2 a matching cache is used" || bad "F2 $(src_of f2) / $(cat "$T/f2.out")"
[ "$(rows_of "$T/f2.tsv")" = "$(rows_of "$T/cache.good")" ] && ok "F2 the cached rows" || bad "F2 rows differ"
grep -q '^::warning::.*HTTP 500' "$T/f2.out" && ok "F2 one ::warning:: names HTTP 500" || bad "F2 warning: $(cat "$T/f2.out")"
{ echo "# source: api set 4 base $OLD"; rows_of "$T/move-rows"; } > "$CACHE"
cp "$CACHE" "$T/cache.stale"
fetch_from f3 500 "$T/b-500"
[ "$(src_of f3)" = "$COMMITTED" ] && ok "F3 a cache on another base is not used" || bad "F3 $(src_of f3) / $(cat "$T/f3.out")"
stop_all

echo "F4/F5: unusable answers never reach the plan or the cache"
printf '{}' > "$T/b-empty"
printf '{"set":{}}' > "$T/b-setempty"
printf '<html>gateway</html>' > "$T/b-html"
printf '{"set":{"id":9,"base_blob":"%s"}}' "$BLOB" > "$T/b-norowskey"
for m in norows nonnum tab missing guard-dash skip; do body "$T/b-$m" "$BLOB" "$m"; done
for c in empty setempty html norowskey norows nonnum tab missing guard-dash skip; do
  for cache in stale good; do
    cp "$T/cache.$cache" "$CACHE"
    fetch_from "f4-$c-$cache" 200 "$T/b-$c"
    if [ "$cache" = stale ]; then want="$COMMITTED"; else want="# source: cache set 9 base $BLOB"; fi
    [ "$(src_of "f4-$c-$cache")" = "$want" ] && ok "F4 $c (cache $cache) -> ${want#\# source: }" \
      || bad "F4 $c (cache $cache): $(src_of "f4-$c-$cache") / $(cat "$T/f4-$c-$cache.out")"
    cmp -s "$CACHE" "$T/cache.$cache" && ok "F4 $c (cache $cache) left the cache byte-unchanged" || bad "F4 $c changed the cache"
    [ "$(grep -c '^::warning::' "$T/f4-$c-$cache.out")" = 1 ] && ok "F4 $c one ::warning::" || bad "F4 $c warnings: $(cat "$T/f4-$c-$cache.out")"
  done
done
stop_all

echo "F6: not configured sends nothing"
cp "$T/cache.good" "$CACHE"
printf '{"set":null}' > "$T/b-null"
srv f6 canned 200 "$T/b-null"
P6=$PORT
env JOBS_URL= CI_DURATIONS_TOKEN=$TOK "$CTT" fetch --out "$T/f6a.tsv" --root "$R" > "$T/f6a.out" 2>&1; RCS="$RCS f6a=$?"
env JOBS_URL="http://127.0.0.1:$P6" CI_DURATIONS_TOKEN= "$CTT" fetch --out "$T/f6b.tsv" --root "$R" > "$T/f6b.out" 2>&1; RCS="$RCS f6b=$?"
env JOBS_URL="http://127.0.0.1:$P6" "$CTT" fetch --out "$T/f6c.tsv" --root "$R" > "$T/f6c.out" 2>&1; RCS="$RCS f6c=$?"
for n in f6a f6b f6c; do
  [ "$(src_of "$n")" = "$COMMITTED" ] && ok "F6 $n -> committed, not the cache" || bad "F6 $n: $(src_of "$n")"
done
[ ! -s "$T/f6.log" ] && ok "F6 no request was sent" || bad "F6 requests: $(cat "$T/f6.log")"
[ "$(rows_of "$T/f6a.tsv")" = "$(rows_of "$R/catalog/test-tiers.tsv")" ] && ok "F6 the rows are the committed rows" || bad "F6 rows differ"
stop_all

echo "F7: set null"
fetch_from f7 200 "$T/b-null"
[ "$(src_of f7)" = "$COMMITTED" ] && ok "F7 set null -> committed" || bad "F7 $(src_of f7)"
[ "$(grep -c '^::notice::.*no tier set in the worker' "$T/f7.out")" = 1 ] && ! grep -q '^::warning::' "$T/f7.out" \
  && ok "F7 one ::notice::, no warning" || bad "F7 out: $(cat "$T/f7.out")"
stop_all
# The worker gone: nothing listens on the last port.
fetch_from f7d 200 "$T/b-null" >/dev/null; stop_all
env JOBS_URL="http://127.0.0.1:$PORT" CI_DURATIONS_TOKEN=$TOK "$CTT" fetch --out "$T/f7x.tsv" --root "$R" > "$T/f7x.out" 2>&1; RCS="$RCS f7x=$?"
[ "$(src_of f7x)" = "# source: cache set 9 base $BLOB" ] && grep -q '^::warning::.*curl rc' "$T/f7x.out" \
  && ok "F7 a dead worker -> the cache, with a warning" || bad "F7 dead: $(src_of f7x) / $(cat "$T/f7x.out")"

echo "F8: exit codes"
case "$RCS" in *=[!0]*) bad "F8 a fetch exited non-zero:$RCS" ;; *) ok "F8 every fetch exited 0 ($(echo "$RCS" | wc -w) runs)" ;; esac
"$CTT" fetch --root "$R" > "$T/f8a.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "F8 fetch with no --out exits 2" || bad "F8 no --out rc=$rc"
"$CTT" fetch --out "$T/f8.tsv" --bogus > "$T/f8b.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "F8 an unknown argument exits 2" || bad "F8 unknown rc=$rc"
"$CTT" nope > "$T/f8c.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "F8 an unknown command exits 2" || bad "F8 command rc=$rc"
grep -qF "$TOK" "$T"/*.out "$T"/*.tsv && bad "F8 the token leaked" || ok "F8 the token is never printed"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
