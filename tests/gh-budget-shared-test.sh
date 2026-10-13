#!/bin/bash
# tests/gh-budget-shared-test.sh — the GitHub rate-limit budget belongs to the
# TOKEN, so every box drawing on one token reads ONE remaining figure
# (BH-1043, audit §2.4).
#
# THE BUG. bin/lib/gh-budget.sh caches `gh api rate_limit` at
# state/gh-budget/<token-fingerprint>.json — per box. The bucket it describes is
# the token's, and the fleet shares one App/PAT identity. Nine boxes each read
# "4,800 remaining" and each decided it had 4,800 left to spend, so the
# threshold that exists to stop non-essential reads before exhaustion was
# effectively multiplied by the number of boxes. Worse: each box burned one
# rate_limit call per TTL to learn the same number.
#
# THE SHAPE OF THE FIX. The reading is a row in the jobs worker keyed on the
# token fingerprint (`gh_budget`). A refresh asks the row FIRST: a row younger
# than the TTL is the answer and no `gh api rate_limit` call is made at all
# (one read per TTL fleet-wide, not one per box per TTL). Only a box that finds
# nothing fresh reads the API, and it publishes what it read. The upsert is
# monotonic on fetched_at, so a slow box's older reading can never overwrite a
# newer one — "remaining" only ever counts down.
#
# Everything below drives the REAL bin/lib/gh-budget.sh on two scratch boxes
# with separate $HARNESS trees, one shared table file, and a `gh` shim that
# COUNTS the rate_limit calls it is asked for.
#
# Sections:
#   A  box 1 reads and publishes; box 2 sees the same figure without an API call
#   B  the shared figure is what gh_budget_low judges (one box low -> both low)
#   C  a stale row is not an answer: the reader falls through to its own read
#   D  monotonic: an older reading never overwrites a newer one
#   E  fail-open: an unreachable worker behaves exactly as today
#
# Run from anywhere: tests/gh-budget-shared-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# One clock read; every stamp derived. # determinism: ok single anchor
NOW=$(date -u +%s)
RESET=$(( NOW + 2700 ))
TOKEN="ghs_FIXTURE_SHARED_APP_TOKEN"

mkdir -p "$T/db" "$T/fakebin"
DB="$T/db/gh_budget.json"        # one JSON object, fingerprint -> row
echo '{}' > "$DB"
CALLS="$T/db/ratelimit-calls"    # one line per gh api rate_limit the shim served
: > "$CALLS"

# ── the shared table ──────────────────────────────────────────────────────────
# POST /api/gh-budget  {fingerprint, fetched_at, core:{...}, graphql:{...}, box}
#   monotonic on fetched_at; 200 {row, wrote}
# GET  /api/gh-budget?fingerprint=<fp>  -> 200 {row|null, as_of}
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2 ;;
    -H) shift 2 ;;
    -H*|-sS|-s) shift ;;
    -m|--connect-timeout|-w) shift 2 ;;
    *) shift ;;
  esac
done
[ "${CURL_DOWN:-0}" = 1 ] && exit 7
case "$URL" in
  */api/gh-budget)
    [ "$METHOD" = POST ] || { printf '{"error":"unknown endpoint"}\n404'; exit 0; }
    FP=$(jq -r '.fingerprint // ""' <<<"$BODY")
    [ -n "$FP" ] || { printf '{"error":"fingerprint is required"}\n400'; exit 0; }
    NEWF=$(jq -r '.fetched_at // 0' <<<"$BODY")
    OLDF=$(jq -r --arg f "$FP" '.[$f].fetched_at // 0' "$DB")
    if [ "$NEWF" -ge "$OLDF" ]; then
      jq --arg f "$FP" --argjson r "$BODY" '.[$f] = $r' "$DB" > "$DB.new" && mv "$DB.new" "$DB"
      printf '{"wrote":true,"row":%s}\n200' "$(jq -c --arg f "$FP" '.[$f]' "$DB")"
    else
      printf '{"wrote":false,"row":%s}\n200' "$(jq -c --arg f "$FP" '.[$f]' "$DB")"
    fi
    exit 0 ;;
  */api/gh-budget\?*)
    FP="${URL#*fingerprint=}"; FP="${FP%%&*}"
    ROW=$(jq -c --arg f "$FP" '.[$f] // null' "$DB")
    printf '{"row":%s}\n200' "$ROW"
    exit 0 ;;
esac
printf '{"error":"unknown endpoint"}\n404'
CURL
chmod +x "$T/fakebin/curl"

# ── the gh shim: counts every rate_limit read ────────────────────────────────
cat > "$T/fakebin/gh" <<'SHIN'
#!/bin/bash
case "$*" in
  "auth token") [ -n "${GH_TOKEN:-}" ] && { printf '%s\n' "$GH_TOKEN"; exit 0; }; exit 1 ;;
  "api rate_limit"*)
    echo "$RATE_FILE" >> "$CALLS"
    cat "$RATE_FILE" 2>/dev/null && exit 0
    exit 1 ;;
esac
exit 1
SHIN
chmod +x "$T/fakebin/gh"

rate_json() { # rate_json <core-remaining> <graphql-remaining> [fetched-epoch]
  jq -nc --argjson r "$RESET" --argjson c "$1" --argjson g "$2" '{
    resources: {
      core:    {limit:5000, remaining:$c, reset:$r, used:(5000-$c)},
      graphql: {limit:5000, remaining:$g, reset:$r, used:(5000-$g)}
    }}'
}

mkbox() { # mkbox <dir> <box-name>
  local H="$1"
  mkdir -p "$H/bin/lib" "$H/state/gh-budget" "$H/logs" "$H/flags" "$H/env"
  cp "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
  cp "$DIR/bin/jobs-client.sh" "$H/bin/"
  mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  printf '%s\n' "$2" > "$H/state/box-name"
}
H1="$T/h1"; H2="$T/h2"
mkbox "$H1" box-one
mkbox "$H2" box-two

drive() { # drive <harness> <snippet> [extra env...]
  local H="$1" SNIP="$2"; shift 2
  env PATH="$T/fakebin:$PATH" HARNESS="$H" GH_TOKEN="$TOKEN" DB="$DB" CALLS="$CALLS" \
      RATE_FILE="$T/rate_limit.json" HARNESS_SECRET=test-secret \
      JOBS_URL=https://harness-jobs.operator.workers.dev \
      GH_BUDGET_TTL_S=60 GH_BUDGET_DB_TIMEOUT_S=4 GH_BUDGET_MIN_REMAINING=800 "$@" \
    bash -c 'set -uo pipefail
             . "$1/bin/jobs-client.sh"
             . "$1/bin/lib/gh-budget.sh"
             eval "$2"' _ "$H" "$SNIP" 2>/dev/null
}
calls() { grep -c '' "$CALLS"; }
remaining() { # remaining <harness> — what THIS box believes core remaining is
  drive "$1" 'gh_budget_refresh >/dev/null 2>&1; jq -r ".core.remaining // \"none\"" "$(_ghb_cache_path)" 2>/dev/null'
}

# =============================================================================
# A. BOX 1 READS AND PUBLISHES; BOX 2 SEES THE SAME FIGURE, NO API CALL
# =============================================================================
rate_json 4200 4900 > "$T/rate_limit.json"
: > "$CALLS"; echo '{}' > "$DB"
R1=$(remaining "$H1")
[ "$R1" = 4200 ] && ok || bad "A: box 1 did not read its own budget (got '$R1')"
[ "$(calls)" = 1 ] && ok || bad "A: box 1 made $(calls) rate_limit calls, expected 1"
[ "$(jq -r 'keys | length' "$DB")" = 1 ] \
  && ok || bad "A: box 1 published nothing to the shared table: $(cat "$DB")"

# The fingerprint is the TOKEN's, never the box's: both boxes key the same row.
[ "$(jq -r 'to_entries[0].value.core.remaining' "$DB")" = 4200 ] \
  && ok || bad "A: the published row does not carry the reading: $(cat "$DB")"

# Box 2 has never read this token. Its answer must be box 1's, and it must not
# spend a rate_limit call to get it.
R2=$(remaining "$H2")
[ "$R2" = 4200 ] && ok || bad "A: box 2 saw '$R2', not the fleet's 4200"
[ "$(calls)" = 1 ] \
  && ok || bad "A: box 2 spent its own rate_limit call on a figure the fleet already had ($(calls) total)"

# =============================================================================
# B. THE SHARED FIGURE IS WHAT gh_budget_low JUDGES
# =============================================================================
# Box 1 reads a LOW bucket. Box 2, whose own API would answer healthy, must be
# low too — that is the whole point: one token, one budget.
rate_json 100 4900 > "$T/rate_limit.json"
: > "$CALLS"; echo '{}' > "$DB"
rm -f "$H1/state/gh-budget"/* "$H2/state/gh-budget"/*
drive "$H1" 'gh_budget_low lane1 >/dev/null 2>&1' >/dev/null 2>&1
rate_json 4900 4900 > "$T/rate_limit.json"   # box 2's own API would say healthy
RC=$(drive "$H2" 'gh_budget_low lane2 >/dev/null 2>&1; echo $?')
[ "$RC" = 0 ] \
  && ok || bad "B: box 2 reported healthy (rc=$RC) on a token box 1 already found low"
[ "$(remaining "$H2")" = 100 ] \
  && ok || bad "B: box 2's figure is not the fleet's 100"

# =============================================================================
# C. A STALE ROW IS NOT AN ANSWER
# =============================================================================
# A row older than the TTL cannot be handed out as current: the reader falls
# through to its own API read, exactly as it does today with a stale file.
rate_json 4900 4900 > "$T/rate_limit.json"
echo '{}' > "$DB"
rm -f "$H1/state/gh-budget"/* "$H2/state/gh-budget"/*
drive "$H1" 'gh_budget_refresh >/dev/null 2>&1'
jq '.[].fetched_at = '"$(( NOW - 9000 ))" "$DB" > "$DB.new" && mv "$DB.new" "$DB"
rm -f "$H2/state/gh-budget"/*
rate_json 2222 4900 > "$T/rate_limit.json"
: > "$CALLS"
[ "$(remaining "$H2")" = 2222 ] \
  && ok || bad "C: a stale shared row was served as if it were current"
[ "$(calls)" -ge 1 ] \
  && ok || bad "C: box 2 answered from a stale row without reading the API"

# =============================================================================
# D. MONOTONIC — an older reading never overwrites a newer one
# =============================================================================
echo '{}' > "$DB"
rm -f "$H1/state/gh-budget"/* "$H2/state/gh-budget"/*
rate_json 500 4900 > "$T/rate_limit.json"
drive "$H1" 'gh_budget_refresh >/dev/null 2>&1'
FP=$(jq -r 'keys[0]' "$DB")
# A slow box whose reading was taken ten minutes BEFORE box 1's arrives late.
OLD=$(jq -nc --arg f "$FP" --argjson t "$(( NOW - 600 ))" \
  '{fingerprint:$f,fetched_at:$t,
    core:{remaining:4999,limit:5000,reset:0},
    graphql:{remaining:4999,limit:5000,reset:0}}')
drive "$H2" 'gh_budget_row_put "$OLD_JSON" >/dev/null 2>&1' OLD_JSON="$OLD"
[ "$(jq -r --arg f "$FP" '.[$f].core.remaining' "$DB")" = 500 ] \
  && ok || bad "D: an older reading overwrote a newer one: $(cat "$DB")"

# =============================================================================
# E. FAIL-OPEN — an unreachable worker behaves exactly as today
# =============================================================================
echo '{}' > "$DB"
rm -f "$H1/state/gh-budget"/*
rate_json 3333 4900 > "$T/rate_limit.json"
: > "$CALLS"
R=$(drive "$H1" 'gh_budget_refresh >/dev/null 2>&1; jq -r ".core.remaining // \"none\"" "$(_ghb_cache_path)" 2>/dev/null' CURL_DOWN=1)
[ "$R" = 3333 ] \
  && ok || bad "E: with the worker down the box must read and use its own budget (got '$R')"
RC=$(drive "$H1" 'gh_budget_low lane3 >/dev/null 2>&1; echo $?' CURL_DOWN=1)
[ "$RC" = 1 ] \
  && ok || bad "E: with the worker down a healthy bucket must still read healthy (rc=$RC)"

echo "gh-budget-shared: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
