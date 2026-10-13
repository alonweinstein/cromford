#!/bin/bash
# tests/model-watch-lib.bh-3422-test.sh — the model-watch CONTRACT (BH-3425,
# BH-3422.0): the id normalizer and the four jobs verbs in bin/lib/model-watch.sh.
#   L1. bash -n and `set -u; .` pass on the lib; the route stub parses as a module.
#   L2. mw_norm_id collapses one fixture model in four shapes (vendor-prefixed
#       dotted slug, dotted `:free` variant, uppercase, dated `-YYYYMMDD`
#       snapshot) into one key; a 4-digit run and a short `-2` are kept; empty
#       input is rc 1 with nothing printed.
#   L3. through a stubbed _jobs_req each verb hits its method and path and
#       prints the body, rc 0.
#   L4. a non-2xx (_jobs_req rc 1, rc 9) is rc 1 and nothing on stdout; a
#       missing required arg is rc 1 and no request.
#   L5. no /root/harness literal on a code line of the lib (D43).
#   L6. bin/jobs-client.sh does not load it (not in JC_MODULES).
# Run from anywhere: tests/model-watch-lib.bh-3422-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

LIB="$DIR/bin/lib/model-watch.sh"
ROUTE="$DIR/worker/jobs/src/routes/model-watch.js"

# --- L1 -----------------------------------------------------------------------
[ -f "$LIB" ] && bash -n "$LIB" && ok || bad "L1 bash -n $LIB"
bash -c 'set -u; . "$1"' _ "$LIB" 2>/dev/null && ok || bad "L1 set -u source $LIB"
if command -v node >/dev/null 2>&1; then
  node --check "$ROUTE" 2>/dev/null && ok || bad "L1 node --check $ROUTE"
fi

# mw <cmd...>: run one lib call in a fresh shell, stdout only.
mw() { bash -c 'set -u; . "$1"; shift; "$@"' _ "$LIB" "$@" 2>/dev/null; }

# --- L2 -----------------------------------------------------------------------
want=$(mw mw_norm_id 'acme-4-5')
[ "$want" = "acme-4-5" ] && ok || bad "L2 base key [$want], want acme-4-5"
for id in 'vendorco/acme-4.5' 'acme-4.5:free' 'ACME-4-5' 'acme-4-5-20250929' 'VendorCo/Acme-4.5:beta' 'acme-4.5-20250929'; do
  got=$(mw mw_norm_id "$id"); rc=$?
  [ "$rc" = 0 ] && [ "$got" = "$want" ] && ok || bad "L2 mw_norm_id $id -> [$got] rc=$rc, want [$want]"
done
for pair in 'acme-4-0613:acme-4-0613' 'acme-2:acme-2' 'a/b/c:c' 'acme-x-20250929-2:acme-x-20250929-2'; do
  got=$(mw mw_norm_id "${pair%%:*}")
  [ "$got" = "${pair#*:}" ] && ok || bad "L2 mw_norm_id ${pair%%:*} -> [$got], want ${pair#*:}"
done
for id in '' 'vendorco/' ':free'; do
  got=$(mw mw_norm_id "$id"); rc=$?
  [ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "L2 mw_norm_id [$id] rc=$rc out=[$got], want rc 1 and nothing"
done
got=$(mw mw_norm_id); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "L2 mw_norm_id with no arg rc=$rc out=[$got]"

# --- L3 -----------------------------------------------------------------------
# STUB_RC: what the stub _jobs_req returns; it records "$1 $2 $3" to $CALLS.
CALLS="$T/calls"
run() {
  : >"$CALLS"
  CALLS="$CALLS" STUB_RC="$1" bash -c 'set -u; . "$1"; shift
    _jobs_req() { printf "%s %s %s\n" "$1" "$2" "${3:-}" >>"$CALLS"; printf "{\"ok\":true}"; return "$STUB_RC"; }
    "$@"' _ "$LIB" "${@:2}" 2>/dev/null
}
check3() { # <want request line> <verb args...>
  local wantreq=$1; shift
  out=$(run 0 "$@"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = '{"ok":true}' ] && [ "$(cat "$CALLS")" = "$wantreq" ] && ok \
    || bad "L3 $* rc=$rc out=[$out] req=[$(cat "$CALLS")], want [$wantreq]"
}
check3 'POST /api/model-watch {"a":1}' mw_record '{"a":1}'
check3 'GET /api/model-watch?status=new&vendor=acme ' mw_get new acme
check3 'GET /api/model-watch?status=&vendor= ' mw_get
check3 'GET /api/model-watch?status=&vendor=a%20b ' mw_get '' 'a b'
check3 'PUT /api/model-watch/state {"vendor":"acme","model_id":"m-1","status":"ignored"}' \
  mw_set_state '{"vendor":"acme","model_id":"m-1","status":"ignored"}'
check3 'GET /api/model-watch/usage?model=m%20x&since=2026-09-01 ' mw_usage 'm x' 2026-09-01

# --- L4 -----------------------------------------------------------------------
for src in 1 9; do
  for call in "mw_record {}" "mw_get" "mw_set_state {}" "mw_usage m 2026-09-01"; do
    # shellcheck disable=SC2086
    out=$(run "$src" $call); rc=$?
    [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L4 $call with _jobs_req rc $src: rc=$rc out=[$out]"
  done
done
for call in "mw_record" "mw_set_state" "mw_usage" "mw_usage m"; do
  # shellcheck disable=SC2086
  out=$(run 0 $call); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && [ ! -s "$CALLS" ] && ok || bad "L4 $call missing args: rc=$rc out=[$out] req=[$(cat "$CALLS")]"
done

# --- L5 / L6 -------------------------------------------------------------------
grep -q '/root/harness' <<<"$(grep -v '^[[:space:]]*#' "$LIB" 2>/dev/null)" && bad "L5 $LIB has a /root/harness literal" || ok
grep -q 'model-watch' "$DIR/bin/jobs-client.sh" && bad "L6 bin/jobs-client.sh names model-watch" || ok

echo "model-watch-lib: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
