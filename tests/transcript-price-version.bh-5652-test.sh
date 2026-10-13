#!/bin/bash
# tests/transcript-price-version.bh-5652-test.sh — a claude cost row records the
# price version its transcript dollars came from (BH-5652 review F1/F2).
#
# A claude row's dollars are not vendor dollars: bin/transcript-cost.sh prices
# the session from the same versioned table cost_row_price reads
# ($HARNESS/state/model-prices.json first). So the row must say which version,
# exactly as a table-priced codex/grok row does (tests/cost-row-price-version.
# bh-5652-test.sh).
#
#   T1  transcript-cost.sh --price-version: 10th field = the top model's
#       version; empty for an unversioned row, a bad version, or an unpriced
#       model; WITHOUT the flag the line keeps its exact 9 fields
#   T2  cost_row_price rule 1: vendor dollars + version 7 -> `<usd>|price_v:7`;
#       a bad version adds nothing; no 11th arg is today's exact output
#   T3  bin/agent-call.sh DRIVEN with a fake claude that writes a real
#       transcript: the cost.csv row is row_source=transcript and its note
#       carries price_v:7; an unversioned table adds no token
#   T4  bin/claude-cost.sh DRIVEN: the same, on the raw-claude ledger path
#   T5  the hub (no model-prices-sync line): model_prices_versions_merge copies
#       a D1 version onto a model whose rates match, drops one whose rates do
#       not, and leaves the file alone when the API is down
#   T6  MUTATION (D1): transcript-cost.sh with the version field emptied turns
#       T3 red
#
# Run from anywhere: tests/transcript-price-version.bh-5652-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "jq/python3 missing — skipping"; exit 0; }

M=claude-fable-5-1
jq -e --arg m "$M" '.per_token[$m] | objects' "$DIR/catalog/model-prices.json" >/dev/null \
  && ok || { bad "the catalog has no $M row to version"; echo "transcript-price-version.bh-5652-test: $PASS pass, $FAIL fail"; exit 1; }
# The catalog's own row for the model, with and without a version.
jq --arg m "$M" '{per_token: {($m): (.per_token[$m] + {version: 7})}}' "$DIR/catalog/model-prices.json" > "$T/prices-v.json"
jq 'del(.per_token[].version)' "$T/prices-v.json" > "$T/prices-nov.json"

# ── T1: transcript-cost.sh --price-version ───────────────────────────────────
echo "--- T1. transcript-cost.sh --price-version"
mkdir -p "$T/t1"
cat > "$T/t1/s.jsonl" <<EOF
{"type":"assistant","uuid":"u1","timestamp":"2026-10-09T01:00:00Z","message":{"id":"m1","model":"$M","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF
tc() { "$DIR/bin/transcript-cost.sh" "$T/t1/s.jsonl" --no-subagents "$@" 2>/dev/null; }
L=$(tc --prices "$T/prices-v.json" --price-version)
F10=$(printf '%s' "$L" | awk -F'|' '{print NF"|"$10}')
[ "$F10" = "10|7" ] && ok || bad "T1 a versioned row must give a 10th field 7: '$L'"
L=$(tc --prices "$T/prices-v.json")
[ "$(printf '%s' "$L" | awk -F'|' '{print NF}')" = 9 ] && ok || bad "T1 without the flag the line must keep 9 fields: '$L'"
L=$(tc --prices "$T/prices-nov.json" --price-version)
[ "$(printf '%s' "$L" | awk -F'|' '{print NF"|"$10}')" = "10|" ] && ok || bad "T1 an unversioned row must give an empty 10th field: '$L'"
for BADV in 0 -3 '"7"' 2.5 true; do
  jq --argjson v "$BADV" '.per_token[].version = $v' "$T/prices-v.json" > "$T/prices-bad.json"
  L=$(tc --prices "$T/prices-bad.json" --price-version)
  [ "$(printf '%s' "$L" | awk -F'|' '{print $10}')" = "" ] && ok || bad "T1 version=$BADV must give an empty field: '$L'"
done
jq '{per_token: {"other/model": .per_token[]}}' "$T/prices-v.json" > "$T/prices-other.json"
L=$(tc --prices "$T/prices-other.json" --price-version)
[ "$(printf '%s' "$L" | awk -F'|' '{print $9"|"$10}')" = "$M|" ] && ok || bad "T1 an unpriced model must give an empty version: '$L'"

# ── T2: cost_row_price rule 1 ────────────────────────────────────────────────
echo "--- T2. cost_row_price rule 1"
crp() { ( . "$DIR/bin/lib/cost-row.sh"; cost_row_price "$@" ); }
OUT=$(crp claude "$M" 0 100 20 0 0 0.905636 "" "" 7)
[ "$OUT" = "0.905636|price_v:7" ] && ok || bad "T2 transcript dollars at v7 must carry price_v:7: '$OUT'"
OUT=$(crp claude "$M" 0 100 20 0 0 0.905636 "cache_ttl=1h" "1h" 7)
[ "$OUT" = "0.905636|cache_ttl=1h;price_v:7" ] && ok || bad "T2 the existing note keeps its place: '$OUT'"
for BADV in 0 -3 x 2.5 ''; do
  OUT=$(crp claude "$M" 0 100 20 0 0 0.905636 "" "" "$BADV")
  [ "$OUT" = "0.905636|" ] && ok || bad "T2 version '$BADV' must add no token: '$OUT'"
done
OUT=$(crp claude "$M" 0 100 20 0 0 0.905636 "" "")
[ "$OUT" = "0.905636|" ] && ok || bad "T2 no 11th arg must stay today's exact output: '$OUT'"

# ── T3: bin/agent-call.sh driven ─────────────────────────────────────────────
echo "--- T3. bin/agent-call.sh (driven, claude)"
setup_h() { # setup_h <harness-root>
  local h="$1"
  mkdir -p "$h/logs" "$h/locks" "$h/flags" "$h/state/model-routes" "$h/bin/lib" "$h/noenv" "$h/.claude/projects"
  # The real jobs client, so a jobs call rides the transport that ships.
  scratch_install_closure bin/jobs-client.sh "$h" >/dev/null || bad "could not install the jobs client closure"
  printf '#!/bin/bash\necho subscription\n' > "$h/bin/billing-mode.sh"
  printf '#!/bin/bash\nexit 0\n' > "$h/bin/beat.sh"
  chmod +x "$h/bin/billing-mode.sh" "$h/bin/beat.sh"
  for key in claude.ladder claude.ladder@testproj; do
    printf '0\t%s\tclaude\n' "$M" > "$h/state/model-routes/$key.tsv"
  done
}
# The fake claude writes a real two-response session transcript for its
# --session-id, then the result envelope.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJ="$CFG/projects/$(pwd -P | tr '/' '-')"
mkdir -p "$PROJ"
[ -n "$sid" ] || sid="cli-chosen-$$"
for n in 1 2; do
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-10-09T01:00:00Z","message":{"id":"msg_%s","model":"%s","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" "$FAKE_MODEL" >> "$PROJ/$sid.jsonl"
done
cat >/dev/null 2>&1
printf '{"result":"DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/"*
# The fixture worker is unreachable: every jobs call fails closed and fast.
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

drive_ac() { # drive_ac <agent-call.sh> <harness-root>; echoes rc
  local h="$2"
  rm -f "$h/logs/cost.csv"; scratch_rm "$h/.claude/projects"; mkdir -p "$h/.claude/projects" "$h/work"
  ( cd "$h/work" || exit 9
    unset HARNESS_SECRET JOBS_URL MODEL_PRICES CLAUDE_CONFIG_DIR CONTEXT_KILL CONTEXT_KILL_TOKENS \
          AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET CALL_GUARD CALL_GUARD_STAGES
    export PATH="$T/fakebin:$PATH" HARNESS="$h" HOME="$h" FAKE_MODEL="$M" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" COST_TRANSCRIPT_ROWS=1 \
           HARNESS_ENV_DIR="$h/noenv" LADDER_TIER2_GROK=0 LADDER_SAME_RETRIES=0 LADDER_BACKOFF_SECS=0
    bash "$1" eval testproj "$M" 60 "$h/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
csvcol() { python3 -c 'import csv,sys
rows=[r for r in csv.reader(open(sys.argv[1])) if len(r)>5 and r[3]==sys.argv[3]]
print(rows[-1][int(sys.argv[2])-1] if rows and len(rows[-1])>=int(sys.argv[2]) else "")' "$1" "$2" "${3:-eval}" 2>/dev/null; }

H="$T/h3"; setup_h "$H"
cp "$T/prices-v.json" "$H/state/model-prices.json"
RC=$(drive_ac "$DIR/bin/agent-call.sh" "$H")
[ "$RC" = 0 ] && ok || bad "T3 the driven call failed (rc=$RC)"
[ "$(csvcol "$H/logs/cost.csv" 18)" = transcript ] && ok || bad "T3 row_source must be transcript: '$(csvcol "$H/logs/cost.csv" 18)'"
awk -v c="$(csvcol "$H/logs/cost.csv" 13)" 'BEGIN{exit !(c+0 > 0)}' && ok || bad "T3 cost_usd must be > 0: '$(csvcol "$H/logs/cost.csv" 13)'"
case ";$(csvcol "$H/logs/cost.csv" 24);" in
  *";price_v:7;"*) ok ;;
  *) bad "T3 the claude row's note (24) must carry price_v:7: '$(csvcol "$H/logs/cost.csv" 24)'" ;;
esac
cp "$T/prices-nov.json" "$H/state/model-prices.json"
RC=$(drive_ac "$DIR/bin/agent-call.sh" "$H")
[ "$RC" = 0 ] && [ "$(csvcol "$H/logs/cost.csv" 18)" = transcript ] && ok || bad "T3 unversioned drive: rc=$RC src='$(csvcol "$H/logs/cost.csv" 18)'"
case "$(csvcol "$H/logs/cost.csv" 24)" in
  *price_v:*) bad "T3 an unversioned table must add no token: '$(csvcol "$H/logs/cost.csv" 24)'" ;;
  *) ok ;;
esac

# ── T4: bin/claude-cost.sh driven ────────────────────────────────────────────
echo "--- T4. bin/claude-cost.sh (driven)"
H4="$T/h4"; mkdir -p "$H4/logs" "$H4/locks" "$H4/flags" "$H4/state" "$H4/bin/lib" "$H4/work" "$T/cfg4"
scratch_install_closure bin/claude-cost.sh "$H4" >/dev/null || bad "T4 could not install the claude-cost closure"
# claude-cost runs transcript-cost.sh by path, which no source line names.
scratch_install_closure bin/transcript-cost.sh "$H4" >/dev/null || bad "T4 could not install bin/transcript-cost.sh"
printf '#!/bin/bash\necho subscription\n' > "$H4/bin/billing-mode.sh"
printf 'auth_fp_for_runner() { echo fp-test; }\nauth_account_for_fp() { echo acct-test; }\n' > "$H4/bin/auth-fingerprint.sh"
chmod +x "$H4/bin/billing-mode.sh"
cc() {
  rm -f "$H4/logs/cost.csv"; scratch_rm "$T/cfg4"; mkdir -p "$T/cfg4"
  ( cd "$H4/work" && unset MODEL_PRICES && HARNESS="$H4" PATH="$T/fakebin:$PATH" \
      CLAUDE_CONFIG_DIR="$T/cfg4" FAKE_MODEL="$M" COST_STAGE=t4 \
      "$H4/bin/claude-cost.sh" -p --model "$M" "hello" </dev/null >/dev/null 2>&1 )
}
cp "$T/prices-v.json" "$H4/state/model-prices.json"; cc
[ "$(csvcol "$H4/logs/cost.csv" 18 t4)" = transcript ] && ok || bad "T4 row_source must be transcript: '$(tail -1 "$H4/logs/cost.csv" 2>/dev/null)'"
case ";$(csvcol "$H4/logs/cost.csv" 24 t4);" in
  *";price_v:7;"*) ok ;;
  *) bad "T4 the claude-cost row's note (24) must carry price_v:7: '$(tail -1 "$H4/logs/cost.csv" 2>/dev/null)'" ;;
esac
cp "$T/prices-nov.json" "$H4/state/model-prices.json"; cc
case "$(csvcol "$H4/logs/cost.csv" 24 t4)" in
  *price_v:*) bad "T4 an unversioned table must add no token: '$(tail -1 "$H4/logs/cost.csv")'" ;;
  *) ok ;;
esac

# ── T5: the hub's version read-back ──────────────────────────────────────────
echo "--- T5. model_prices_versions_merge (hub)"
cat > "$T/hub.json" <<'EOF'
{"updated_at":"2026-10-09T04:30:00Z","per_token":{
  "a/same":    {"prompt":0.00001,"completion":0.00002,"cache_read":null,"cache_write":null,"slug":"a"},
  "b/moved":   {"prompt":0.00003,"completion":0.00004,"cache_read":null,"cache_write":null,"version":2},
  "c/nodb":    {"prompt":0.00005,"completion":0.00006,"cache_read":null,"cache_write":null}
}}
EOF
cat > "$T/db.json" <<'EOF'
{"per_token":{
  "a/same":  {"prompt":0.00001,"completion":0.00002,"cache_read":null,"cache_write":null,"version":4},
  "b/moved": {"prompt":0.00009,"completion":0.00004,"cache_read":null,"cache_write":null,"version":3}
}}
EOF
merge() { # merge <api-mode: up|down>
  ( . "$DIR/bin/lib/jobs/cost.sh"
    _jobs_req() { [ "$MODE" = up ] && cat "$T/db.json"; }
    MODE="$1" model_prices_versions_merge "$T/hub.json" ); echo $?
}
RC=$(merge up)
[ "$RC" = 0 ] && ok || bad "T5 the merge must answer rc 0 (got $RC)"
[ "$(jq -c '[.per_token["a/same"].version, .per_token["b/moved"].version, .per_token["c/nodb"].version, .per_token["a/same"].slug, .updated_at]' "$T/hub.json")" = '[4,null,null,"a","2026-10-09T04:30:00Z"]' ] \
  && ok || bad "T5 matching rates take the D1 version, moved rates drop theirs: $(jq -c . "$T/hub.json")"
cp "$T/hub.json" "$T/hub.before"
RC=$(merge down)
[ "$RC" = 1 ] && cmp -s "$T/hub.json" "$T/hub.before" && ok || bad "T5 API down: rc 1 and the file unchanged (rc=$RC)"
# The real pricer then reads the merged version on the hub.
OUT=$( ( MODEL_PRICES="$T/hub.json"; . "$DIR/bin/lib/cost-row.sh"; cost_row_price openrouter a/same 0 1000 0 "" "" "" "" ) )
[ "$OUT" = "0.010000|price_v:4" ] && ok || bad "T5 a hub row priced from the merged table must carry price_v:4: '$OUT'"

# ── T6: mutation (D1) ────────────────────────────────────────────────────────
echo "--- T6. mutation"
H6="$T/h6"; setup_h "$H6"
cp "$T/prices-v.json" "$H6/state/model-prices.json"
mkdir -p "$T/mut/bin/lib"
cp -R "$DIR/bin/." "$T/mut/bin/"
grep -q 'line += "|" + (str(v) if ok else "")' "$T/mut/bin/transcript-cost.sh" \
  && ok || bad "T6 transcript-cost.sh no longer has the version field line — nothing to mutate"
sed -i 's/line += "|" + (str(v) if ok else "")/line += "|"/' "$T/mut/bin/transcript-cost.sh"
bash -n "$T/mut/bin/transcript-cost.sh" && ok || bad "T6 the mutant does not parse"
drive_ac "$T/mut/bin/agent-call.sh" "$H6" >/dev/null
[ "$(csvcol "$H6/logs/cost.csv" 18)" = transcript ] && ok || bad "T6 the mutant row must still be a transcript row: '$(csvcol "$H6/logs/cost.csv" 18)'"
case "$(csvcol "$H6/logs/cost.csv" 24)" in
  *price_v:*) bad "T6 with the version field emptied, T3's price_v:7 must go — T3 proves nothing" ;;
  *) ok ;;
esac

echo "transcript-price-version.bh-5652-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
