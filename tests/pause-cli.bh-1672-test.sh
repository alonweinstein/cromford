#!/bin/bash
# tests/pause-cli.bh-1672-test.sh — bin/pause.sh, the operator CLI for BH-1672
# pauses (BH-1683), driven as a real subprocess.
#
# The worker is a tiny fake written into $T/fake-client.sh and handed to the CLI
# through PAUSE_JOBS_CLIENT (the same path override as CLI_UPDATE_JOBS_CLIENT).
# It keeps the pauses table in a jq state file: PUT creates or renews the live
# row for (scope, what), POST /:id/end ends it, GET lists active or all rows.
# PUT and /end answer {pause: row}, the worker's real envelope
# (worker/jobs/src/routes/pauses.js, BH-1682), not a bare row.
# Its clock is a file, so expiry values are exact and never the wall clock.
# Run from anywhere: tests/pause-cli.bh-1672-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$DIR/bin/pause.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1790000000
export FAKE_DIR="$T/fake"
mkdir -p "$FAKE_DIR" "$T/h"
echo '{"next":1,"rows":[]}' > "$FAKE_DIR/state.json"
echo "$NOW" > "$FAKE_DIR/now"

cat > "$T/fake-client.sh" <<'EOF'
# fake jobs client: _jobs_req over a jq state file
JOBS_HTTP=""; JOBS_BODY=""
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" s="$FAKE_DIR/state.json" now out
  echo "$m $p $b" >> "$FAKE_DIR/calls"
  if [ -e "$FAKE_DIR/fail" ]; then JOBS_HTTP=500; JOBS_BODY='{"error":"boom"}'; return 1; fi
  now=$(cat "$FAKE_DIR/now")
  case "$m $p" in
    "PUT /api/pauses")
      out=$(jq -c --argjson b "$b" --argjson now "$now" '
        ($b.ttl_s // 86400) as $ttl | (($now + $ttl) | todate) as $exp
        | (.rows | map(.scope == $b.scope and .what == $b.what and .ended_at == null) | index(true)) as $i
        | if $i == null then
            .rows += [{id:.next, scope:$b.scope, what:$b.what, reason:$b.reason, actor:$b.actor,
                       created_at:($now|todate), expires_at:$exp, ended_at:null, end_reason:null}]
            | .next += 1 | .last = (.rows | length - 1)
          else .rows[$i].expires_at = $exp | .rows[$i].reason = $b.reason | .last = $i end' "$s") || return 1
      printf '%s' "$out" > "$s"
      JOBS_BODY=$(jq -c '{pause: .rows[.last]}' "$s") ;;
    "POST /api/pauses/"*"/end")
      local id="${p#/api/pauses/}"; id="${id%/end}"
      jq -e --argjson id "$id" '.rows[] | select(.id == $id)' "$s" >/dev/null || { JOBS_HTTP=404; return 2; }
      out=$(jq -c --argjson id "$id" --argjson now "$now" \
        '.rows |= map(if .id == $id then .ended_at = ($now|todate) | .end_reason = "resumed" else . end)' "$s")
      printf '%s' "$out" > "$s"
      JOBS_BODY=$(jq -c --argjson id "$id" '{pause: (.rows[] | select(.id == $id))}' "$s") ;;
    "GET /api/pauses?active=1") JOBS_BODY=$(jq -c '{pauses:[.rows[] | select(.ended_at == null)], truncated:false}' "$s") ;;
    "GET /api/pauses?active=0") JOBS_BODY=$(jq -c '{pauses:.rows, truncated:false}' "$s") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=200; printf '%s' "$JOBS_BODY"; return 0
}
EOF

pz() { HARNESS="$T/h" PAUSE_JOBS_CLIENT="$T/fake-client.sh" bash "$CLI" "$@"; }
puts() { grep -c '^PUT ' "$FAKE_DIR/calls" 2>/dev/null; }

# C1: set, then list --active shows it.
out=$(pz set projA reviews --reason "flaky" --ttl 2h); rc=$?
[ "$rc" = 0 ] && ok || bad "C1 set rc 0 (got $rc)"
ID=$(printf '%s' "$out" | awk '{print $1}')
[ "$out" = "$ID projA reviews until $(jq -nr --argjson n $((NOW+7200)) '$n|todate')" ] && ok || bad "C1 set prints '<id> scope what until <expires_at>' (got: $out)"
jq -e 'select(.ttl_s == 7200)' <<<"$(grep '^PUT ' "$FAKE_DIR/calls" | tail -1 | cut -d' ' -f3-)" >/dev/null && ok || bad "C1 --ttl 2h sends ttl_s 7200"
act=$(pz list --active)
[ "$(printf '%s\n' "$act" | grep -c .)" = 1 ] && printf '%s' "$act" | awk -F'\t' -v id="$ID" '$1==id && $2=="projA" && $3=="reviews" && $7=="flaky"{f=1} END{exit !f}' \
  && ok || bad "C1 list --active shows one projA reviews flaky row (got: $act)"
EXP1=$(printf '%s' "$act" | cut -f4)

# C2: renew keeps the id and moves the expiry later.
out=$(pz renew projA reviews --reason again --ttl 48h); rc=$?
[ "$rc" = 0 ] && ok || bad "C2 renew rc 0"
[ "$out" = "$ID projA reviews until $(jq -nr --argjson n $((NOW+172800)) '$n|todate')" ] && ok || bad "C2 renew prints '<id> scope what until <expires_at>' (got: $out)"
act=$(pz list --active)
[ "$(printf '%s' "$act" | cut -f1)" = "$ID" ] && ok || bad "C2 renew keeps id $ID (got: $act)"
EXP2=$(printf '%s' "$act" | cut -f4)
[[ "$EXP2" > "$EXP1" ]] && ok || bad "C2 expiry moved later ($EXP1 → $EXP2)"

# C3: end removes it from --active; plain list still shows it, ended.
out=$(pz end "$ID"); rc=$?
[ "$rc" = 0 ] && ok || bad "C3 end rc 0"
[ "$out" = "$ID ended $(jq -nr --argjson n "$NOW" '$n|todate')" ] && ok || bad "C3 end prints '<id> ended <ended_at>' (got: $out)"
[ -z "$(pz list --active)" ] && ok || bad "C3 ended row gone from --active"
all=$(pz list)
printf '%s' "$all" | awk -F'\t' -v id="$ID" '$1==id && $5!="" && $5!="null"{f=1} END{exit !f}' && ok || bad "C3 plain list shows the row with ended_at (got: $all)"

# C4: actor defaults to hostname; --actor overrides.
pz set fleet merges --reason r >/dev/null
[ "$(grep '^PUT ' "$FAKE_DIR/calls" | tail -1 | cut -d' ' -f3- | jq -r .actor)" = "$(hostname)" ] && ok || bad "C4 actor defaults to \$(hostname)"
grep '^PUT ' "$FAKE_DIR/calls" | tail -1 | cut -d' ' -f3- | jq -e 'has("ttl_s") | not' >/dev/null && ok || bad "C4 no --ttl sends no ttl_s"
pz set fleet merges --reason r --actor operator >/dev/null
[ "$(grep '^PUT ' "$FAKE_DIR/calls" | tail -1 | cut -d' ' -f3- | jq -r .actor)" = operator ] && ok || bad "C4 --actor overrides"

# C5: missing reason → rc 2, no PUT. Bad ttl → rc 2.
n=$(puts)
pz set projA reviews 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "C5 missing --reason → rc 2 (got $rc)"
pz set projA reviews --reason "" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "C5 empty --reason → rc 2 (got $rc)"
for t in 24x 0 -1 ''; do
  pz set projA reviews --reason r --ttl "$t" 2>/dev/null; rc=$?
  [ "$rc" = 2 ] && ok || bad "C5 --ttl '$t' → rc 2 (got $rc)"
done
pz set projA --reason r 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "C5 missing what → rc 2"
pz set projA reviews --reason r --bogus 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "C5 unknown flag → rc 2"
[ "$(puts)" = "$n" ] && ok || bad "C5 refused calls made no PUT"

# C6: a 500 → nonzero, error on stderr, nothing on stdout.
touch "$FAKE_DIR/fail"
for args in "set projA reviews --reason r" "end 1" "list --active"; do
  # shellcheck disable=SC2086
  out=$(pz $args 2>"$T/err"); rc=$?
  [ "$rc" != 0 ] && ok || bad "C6 '$args' on 500 → nonzero"
  grep -q 500 "$T/err" && grep -q boom "$T/err" && ok || bad "C6 '$args' stderr carries 500 and boom (got: $(cat "$T/err"))"
  [ -z "$out" ] && ok || bad "C6 '$args' stdout empty"
done
rm -f "$FAKE_DIR/fail"

# C7: bad id, unknown verb, no verb → rc 2.
pz end abc 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "C7 end abc → rc 2 (got $rc)"
pz frobnicate 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "C7 unknown verb → rc 2"
pz 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -qi usage "$T/err" && ok || bad "C7 no verb → usage, rc 2"

# A client that cannot be loaded → rc 2.
HARNESS="$T/h" PAUSE_JOBS_CLIENT="$T/nope.sh" bash "$CLI" list 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "unreadable client → rc 2 (got $rc)"

echo "pause-cli: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
