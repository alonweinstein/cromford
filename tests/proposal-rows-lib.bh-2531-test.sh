#!/bin/bash
# tests/proposal-rows-lib.bh-2531-test.sh — BH-2531 / BH-2717: bin/lib/proposal-rows.sh,
# the shell client for the product_proposals rows (prow_get / prow_put /
# prow_restore), driven through the REAL bin/jobs-client.sh and its
# bin/lib/jobs/*.sh modules against a stub `curl`.
#
#   L1-L6  restore / put / get and the 0/1/2/3 rc contract
#   B1-B2  the backfill of file-only slugs (if_absent, never over a row)
#   G1     every lane that sources the lib fails open without it (BH-2720),
#          except bin/post-proposal.sh, which refuses to post without it (BH-2719)
#
# The stub worker answers JOBS_URL=http://jobs.test from files under $T/db:
#   GET ?project=p                 -> $T/db/p.json (the list document)
#   GET ?project=p&proposal_id=s   -> {"proposal": $T/db/p/<s>.json}, else a 404
#                                     whose body is $T/db/404.json (default
#                                     {"error":"proposal not found"})
#   PUT                            -> $T/db/put-code (default 200) {"proposal": <body>}
#   $T/db-down                     -> 503 for everything
#   $T/answer-code + answer-body   -> that answer for everything
#   $T/transport-fail              -> curl rc 7
# Every request is logged to $T/reqs as "<METHOD> <path?query> <body>".
#
# Run from anywhere: tests/proposal-rows-lib.bh-2531-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
# Never the live worker: drop anything inherited before setting our own.
unset JOBS_URL HARNESS_SECRET JOBS_BOX JOBS_ALERT

H="$T/harness"
mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$T/stub"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
LIB="$DIR/bin/lib/proposal-rows.sh"
cp "$LIB" "$H/bin/lib/" 2>/dev/null || bad "the lib $LIB is missing"

cat > "$T/stub/curl" <<'CURL'
#!/bin/bash
M=GET; D=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M=$2; shift ;;
    --data-binary|-d) D=$2; shift ;;
    -w|-H|-m|--connect-timeout) shift ;;
    -*) ;;
    *) URL=$1 ;;
  esac
  shift
done
case "$D" in @*) D=$(cat "${D#@}") ;; esac
path=${URL#http://jobs.test}
printf '%s %s %s\n' "$M" "$path" "$D" >> "$STUB_T/reqs"
[ -e "$STUB_T/transport-fail" ] && exit 7
ans() { printf '%s\n%s' "$2" "$1"; exit 0; }
[ -e "$STUB_T/db-down" ] && ans 503 '{"error":"product_proposals unavailable"}'
[ -e "$STUB_T/answer-code" ] && ans "$(cat "$STUB_T/answer-code")" "$(cat "$STUB_T/answer-body" 2>/dev/null)"
q=${path#*\?}; path=${path%%\?*}
[ "$path" = /api/product-proposals ] || ans 404 '{"error":"unknown endpoint"}'
if [ "$M" = PUT ]; then
  ans "$(cat "$STUB_T/db/put-code" 2>/dev/null || echo 200)" "$(jq -c '{proposal: .}' <<<"$D")"
fi
qp() { local v; v=$(printf '%s' "$q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1); printf '%b' "${v//%/\\x}"; }
p=$(qp project); s=$(qp proposal_id)
if [ -n "$s" ]; then
  [ -f "$STUB_T/db/$p/$s.json" ] || ans 404 "$(cat "$STUB_T/db/404.json" 2>/dev/null || echo '{"error":"proposal not found"}')"
  ans 200 "$(jq -c '{proposal: .}' "$STUB_T/db/$p/$s.json")"
fi
ans 200 "$(cat "$STUB_T/db/$p.json" 2>/dev/null || echo '{"proposals":[],"truncated":false,"as_of":"t"}')"
CURL
chmod +x "$T/stub/curl"
export STUB_T="$T" PATH="$T/stub:$PATH"
export HARNESS="$H" JOBS_URL=http://jobs.test HARNESS_SECRET=test JOBS_RETRIES=0 JOBS_ALERT=0
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" || { echo "FAIL: jobs-client did not load"; exit 1; }
# The lib under test, by its rooted repo path.
# shellcheck source=/dev/null
. "$DIR/bin/lib/proposal-rows.sh" 2>/dev/null || bad "could not source $DIR/bin/lib/proposal-rows.sh"

F="$T/ledger.json"; LOGF="$H/logs/p.log"
reset() { local x; for x in "$T/db" "$T/db-down" "$T/answer-code" "$T/answer-body" "$T/transport-fail" "$F" "$LOGF"; do scratch_rm "$x"; done; mkdir -p "$T/db/p"; : > "$T/reqs"; }
row() { # row <slug> <status> <updated_at> — one list element
  jq -nc --arg s "$1" --arg st "$2" --arg u "$3" '{project:"p", proposal_id:$s, status:$st, record:{slug:$s, status:$st, updated_at:$u, from:"row"}, updated_at:$u}'
}
rows() { printf '%s\n' "$@" | jq -sc '{proposals: ., truncated: false, as_of: "t"}' > "$T/db/p.json"; }
sum() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
nreq() { grep -c . "$T/reqs"; }
puts() { grep '^PUT ' "$T/reqs" | cut -d' ' -f3-; }

# ── L1: no file, two rows -> file created with both, one "restored 2" line ──
reset; rows "$(row a posted 2026-09-01T00:00:00Z)" "$(row b vetoed 2026-09-01T00:00:00Z)"
prow_restore p "$F"; rc=$?
[ "$rc" = 0 ] && ok || bad "L1 rc=$rc, want 0"
[ "$(jq -c '[.[] | [.slug, .status]] | sort' "$F" 2>/dev/null)" = '[["a","posted"],["b","vetoed"]]' ] && ok || bad "L1 file: $(cat "$F" 2>/dev/null)"
[ "$(grep -c 'restored 2' "$LOGF" 2>/dev/null)" = 1 ] && ok || bad "L1 want one 'restored 2' line: $(cat "$LOGF" 2>/dev/null)"
[ -z "$(puts)" ] && ok || bad "L1 no backfill PUT expected: $(puts)"

# ── L2: newer file kept, newer row replaces, file-only kept ─────────────────
reset
jq -n '[{slug:"a",status:"gate_pending",updated_at:"2026-09-02T00:00:00Z",from:"file"},
        {slug:"b",status:"candidate",updated_at:"2026-09-01T00:00:00Z",from:"file"},
        {slug:"c",status:"candidate",updated_at:"2026-09-01T00:00:00Z",from:"file"}]' > "$F"
rows "$(row a posted 2026-09-01T00:00:00Z)" "$(row b posted 2026-09-02T00:00:00Z)"
prow_restore p "$F"; rc=$?
[ "$rc" = 0 ] && ok || bad "L2 rc=$rc"
[ "$(jq -r '.[] | select(.slug=="a") | .from' "$F")" = file ] && ok || bad "L2 a must stay the file's (newer) version: $(cat "$F")"
[ "$(jq -r '.[] | select(.slug=="b") | .from+"/"+.status' "$F")" = row/posted ] && ok || bad "L2 b must be the row's (newer) version: $(cat "$F")"
[ "$(jq -r '.[] | select(.slug=="c") | .from' "$F")" = file ] && ok || bad "L2 c (file-only) was deleted: $(cat "$F")"
[ "$(jq length "$F")" = 3 ] && ok || bad "L2 entry count changed: $(jq length "$F")"
[ "$(grep -c 'capped' "$LOGF" 2>/dev/null)" = 0 ] && ok || bad "L2 no capped line when not truncated"
# L2b: truncated list -> exactly one "capped" line
reset; rows "$(row a posted 2026-09-01T00:00:00Z)"; jq '.truncated = true' "$T/db/p.json" > "$T/x" && mv "$T/x" "$T/db/p.json"
prow_restore p "$F"
[ "$(grep -c 'capped' "$LOGF" 2>/dev/null)" = 1 ] && ok || bad "L2b want one 'capped' line: $(cat "$LOGF" 2>/dev/null)"

# ── L3: worker down -> rc 1, file untouched (and still absent when absent) ──
reset; echo '[{"slug":"a","status":"posted"}]' > "$F"; before=$(sum "$F"); touch "$T/db-down"
prow_restore p "$F"; rc=$?
[ "$rc" = 1 ] && ok || bad "L3 rc=$rc, want 1"
[ "$(sum "$F")" = "$before" ] && ok || bad "L3 file changed"
reset; touch "$T/db-down"; prow_restore p "$F"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$F" ] && ok || bad "L3 no file: rc=$rc exists=$([ -e "$F" ] && echo y)"
# a router 404 (route not deployed) is the same: rc 1, untouched
reset; echo '[]' > "$F"; before=$(sum "$F"); echo 404 > "$T/answer-code"; echo '{"error":"unknown endpoint"}' > "$T/answer-body"
prow_restore p "$F"; rc=$?
[ "$rc" = 1 ] && [ "$(sum "$F")" = "$before" ] && ok || bad "L3 unknown endpoint: rc=$rc"
# a file that is not a JSON array: rc 1, untouched, nothing written
reset; rows "$(row a posted 2026-09-01T00:00:00Z)"; echo 'not json' > "$F"; before=$(sum "$F")
prow_restore p "$F"; rc=$?
[ "$rc" = 1 ] && [ "$(sum "$F")" = "$before" ] && ok || bad "L3 malformed file: rc=$rc file=$(cat "$F")"
# JSON, but not an array: jq walks an object's values, so without the guard
# they would be read as ledger entries and backfilled
reset; rows; echo '{"k":{"slug":"x","status":"posted"}}' > "$F"; before=$(sum "$F"); prow_restore p "$F"; rc=$?
[ "$rc" = 1 ] && [ "$(sum "$F")" = "$before" ] && [ -z "$(puts)" ] && ok || bad "L3 object file: rc=$rc puts=$(puts) file=$(cat "$F")"

# ── L4: JOBS_URL empty -> rc 3 from every verb, no request, file untouched ──
reset; echo '[{"slug":"a","status":"posted"}]' > "$F"; before=$(sum "$F")
( JOBS_URL=""; prow_restore p "$F" ); r1=$?
( JOBS_URL=""; prow_get p a >/dev/null ); r2=$?
( JOBS_URL=""; prow_put p a "$F" ); r3=$?
[ "$r1$r2$r3" = 333 ] && ok || bad "L4 restore/get/put rc=$r1/$r2/$r3, want 3/3/3"
[ "$(nreq)" = 0 ] && ok || bad "L4 requests made: $(cat "$T/reqs")"
[ "$(sum "$F")" = "$before" ] && ok || bad "L4 file changed"
# no jobs client loaded at all: still rc 3 (not configured wins)
r=$(env -i PATH="$PATH" JOBS_URL= bash -c '. "$1"; prow_get p a; echo "g$?"; prow_put p a /dev/null; echo "p$?"; prow_restore p /dev/null; echo "r$?"' _ "$LIB" 2>&1 | tr -d '\n')
[ "$r" = g3p3r3 ] && ok || bad "L4 no client: '$r', want g3p3r3"
# configured but no client: rc 1 (unusable)
r=$(env -i PATH="$PATH" JOBS_URL=http://jobs.test bash -c '. "$1"; prow_get p a; echo "g$?"' _ "$LIB" 2>&1 | tr -d '\n')
[ "$r" = g1 ] && ok || bad "L4 configured, no client: '$r', want g1"

# ── L5: prow_put sends the LAST entry; status override honoured ─────────────
reset
jq -n '[{slug:"a",status:"candidate",n:1},{slug:"b",status:"posted",n:9},{slug:"a",status:"gate_pending",n:2}]' > "$F"
prow_put p a "$F"; rc=$?
[ "$rc" = 0 ] && ok || bad "L5 rc=$rc"
[ "$(puts | jq -c '[.project,.proposal_id,.status,.record.n,(.if_absent // false)]')" = '["p","a","gate_pending",2,false]' ] && ok || bad "L5 body: $(puts)"
: > "$T/reqs"; prow_put p a "$F" posting; rc=$?
[ "$rc" = 0 ] && [ "$(puts | jq -c '[.status,.record.status,.record.n]')" = '["posting","gate_pending",2]' ] && ok || bad "L5 override: rc=$rc $(puts)"
: > "$T/reqs"; prow_put p nope "$F"; rc=$?
[ "$rc" = 1 ] && [ "$(nreq)" = 0 ] && ok || bad "L5 missing slug: rc=$rc reqs=$(nreq)"
echo '{"k":{"slug":"a","status":"posted"}}' > "$T/obj.json"; prow_put p a "$T/obj.json"; rc=$?
[ "$rc" = 1 ] && [ "$(nreq)" = 0 ] && ok || bad "L5 non-array ledger: rc=$rc reqs=$(nreq)"
# L5b: a PUT that did not land is never success
touch "$T/db-down"; prow_put p a "$F"; rc=$?
[ "$rc" = 1 ] && ok || bad "L5b put under 503: rc=$rc, want 1"
rm -f "$T/db-down"; echo 404 > "$T/answer-code"; echo '{"error":"unknown endpoint"}' > "$T/answer-body"
prow_put p a "$F"; rc=$?
[ "$rc" = 1 ] && ok || bad "L5b put to unknown endpoint: rc=$rc, want 1"
echo 409 > "$T/answer-code"; echo '{"error":"conflict"}' > "$T/answer-body"
prow_put p a "$F"; rc=$?
[ "$rc" = 1 ] && ok || bad "L5b put answered 409: rc=$rc, want 1"
echo 200 > "$T/answer-code"; echo 'not json' > "$T/answer-body"
prow_put p a "$F"; rc=$?
[ "$rc" = 1 ] && ok || bad "L5b put answered 200 non-JSON: rc=$rc, want 1"

# ── L6: prow_get rc 0/2/1/3, and the negatives that must NOT read as "no row" ─
reset; row a posted t | jq '.' > "$T/db/p/a.json"
out=$(prow_get p a); rc=$?
[ "$rc" = 0 ] && [ "$out" = posted ] && ok || bad "L6 hit: rc=$rc out='$out'"
prow_get p missing >/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "L6 proposal not found: rc=$rc, want 2"
echo '{"error":"unknown endpoint"}' > "$T/db/404.json"; prow_get p missing >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L6 unknown endpoint 404: rc=$rc, want 1"
: > "$T/db/404.json"; prow_get p missing >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L6 empty-body 404: rc=$rc, want 1"
rm -f "$T/db/404.json"; touch "$T/db-down"; prow_get p a >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L6 503: rc=$rc, want 1"
rm -f "$T/db-down"; echo 200 > "$T/answer-code"; echo '{}' > "$T/answer-body"; prow_get p a >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L6 200 {}: rc=$rc, want 1"
rm -f "$T/answer-code" "$T/answer-body"; touch "$T/transport-fail"; prow_get p a >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L6 transport failure: rc=$rc, want 1"
rm -f "$T/transport-fail"
( HARNESS_SECRET=""; prow_get p a >/dev/null ); rc=$?
[ "$rc" = 1 ] && ok || bad "L6 HARNESS_SECRET unset: rc=$rc, want 1"
( JOBS_URL=""; prow_get p a >/dev/null ); rc=$?
[ "$rc" = 3 ] && ok || bad "L6 JOBS_URL empty: rc=$rc, want 3"
: > "$T/reqs"; prow_get p 'a b&c' >/dev/null
grep -q '^GET /api/product-proposals?project=p&proposal_id=a%20b%26c ' "$T/reqs" && ok || bad "L6 slug not URL-encoded: $(cat "$T/reqs")"

# ── B1: file-only slugs are backfilled with if_absent PUTs ──────────────────
reset; rows
jq -n '[{slug:"x",status:"posted",k:1},{slug:"y",status:"vetoed",k:2}]' > "$F"
prow_restore p "$F"; rc=$?
[ "$rc" = 0 ] && ok || bad "B1 rc=$rc"
[ "$(puts | jq -sc 'map([.proposal_id,.status,.record.k,.if_absent]) | sort')" = '[["x","posted",1,true],["y","vetoed",2,true]]' ] && ok || bad "B1 puts: $(puts)"
[ "$(grep -c 'backfilled 2' "$LOGF" 2>/dev/null)" = 1 ] && ok || bad "B1 want one 'backfilled 2' line: $(cat "$LOGF" 2>/dev/null)"
# a backfill put that fails is not counted
reset; rows; jq -n '[{slug:"x",status:"posted"}]' > "$F"; echo 503 > "$T/db/put-code"
prow_restore p "$F"
! grep -q backfilled "$LOGF" 2>/dev/null && ok || bad "B1 a failed backfill put was counted: $(cat "$LOGF")"

# ── B2: a slug with a row is never PUT by the backfill ──────────────────────
reset; rows "$(row a posted 2026-09-02T00:00:00Z)"
jq -n '[{slug:"a",status:"candidate",updated_at:"2026-09-01T00:00:00Z"},{slug:"z",status:"vetoed",updated_at:"2026-09-01T00:00:00Z"}]' > "$F"
prow_restore p "$F"
[ "$(puts | jq -sc 'map(.proposal_id)')" = '["z"]' ] && ok || bad "B2 want a PUT for z only: $(puts)"
[ "$(puts | jq -s 'all(.if_absent == true)')" = true ] && ok || bad "B2 a backfill PUT without if_absent: $(puts)"

# ── G1: every lane that sources the lib guards it; the fallbacks differ ────
# BH-2717 pinned "no lane sources it yet"; BH-2720 wired run-product and
# product-cmd, so the guard is now that each user sources it only when it is
# readable and stubs the verbs to 1 when it is not (a box without the lib
# behaves as before it existed). BH-2719 wired post-proposal, which is the
# exception: a configured box without the lib cannot read its rows, so it
# refuses to post (rc 1) rather than stubbing, and it must never get the stubs.
users=$(grep -rl 'proposal-rows.sh' "$DIR/bin" --include='*.sh' | grep -v "^$DIR/bin/lib/proposal-rows.sh$")
[ -n "$users" ] && ok || bad "G1 no lane sources the lib"
grep -qxF "$DIR/bin/post-proposal.sh" <<<"$users" && ok || bad "G1 $DIR/bin/post-proposal.sh must source the lib"
for u in $users; do
  grep -qF '[ -r "$HARNESS/bin/lib/proposal-rows.sh" ] && . "$HARNESS/bin/lib/proposal-rows.sh"' "$u" \
    && ok || bad "G1 $u sources the lib without the [ -r ] guard"
  if [ "$u" = "$DIR/bin/post-proposal.sh" ]; then
    ! grep -q 'prow_put() { return 1; }' "$u" && grep -q '^if command -v prow_get >/dev/null 2>&1; then' "$u" \
      && ok || bad "G1 $u must refuse without the lib (ask prow_get only when loaded), never stub the verbs"
  else
    grep -qF 'command -v prow_put >/dev/null 2>&1 || { prow_put() { return 1; }; prow_restore() { return 1; }; }' "$u" \
      && ok || bad "G1 $u sources the lib without the fail-open stubs"
  fi
done

echo "proposal-rows-lib: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
