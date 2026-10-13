#!/bin/bash
# tests/lookback-board.bh-1795-test.sh — BH-1795.4: lookback_file_board, the
# filer that puts an app-cause cluster on that project's product board.
#
# The lib is sourced into this shell against a scratch $HARNESS ($T/h): a
# fleet.conf with a board project (acme-os, /api/board) and a board-less one
# (nob-os, -), env files, and a curl recorder on PATH that answers by URL from
# tests/fixtures/lookback/board/. The job_ledger_* functions are file-backed
# recorders. D1 drives the real bin/lookback.sh end to end.
#
#   B1  no ledger row -> one create POST, fingerprint last line, one `filed` put, rc 0
#   B2  row + open ticket -> no create, one comment carrying only the new id, rc 3
#   B2b row + open ticket, nothing new -> no POST at all, rc 3
#   B2e followed_up_recurred row + open ticket + new ids -> comment, status kept
#   B2c row + done ticket -> a new ticket, prior_ticket kept
#   B2d row + ticket GET fails -> rc 1, nothing created
#   B3  board prefix `-`, or no token in the env -> zero curl, rc 4, no ALERTS line
#   B4  ledger read outage -> zero curl, rc 75
#   B5  create answers {} -> no put, rc 1
#   B6  no posted body carries an em or en dash
#   B7  the token never reaches curl's argv
#   D1  bin/lookback.sh files a target:app cluster through the real lib
#   Z1  no `claude-` string in the lib
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-board.bh-1795-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "lookback-board.bh-1795-test: SKIPPED — flock missing"; exit 0; }

NOW=$(date -u +%s)
# determinism: ok the run dir is named by the driver's wall-clock day, derived from the one NOW read
DATE=$(date -u -d "@$NOW" +%Y-%m-%d)
LIB="$DIR/bin/lib/lookback-board.sh"
FIX="$DIR/tests/fixtures/lookback/board"
H="$T/h"
FP=a1b2c3d4e5f60718
TOKEN="tok-SECRET-value-123"

# fresh — a new scratch harness and empty recorders for one case.
fresh() {
  scratch_rm "$H"; rm -rf "$T"/calls.* "$T/bodies" "$T/ledger" "$T/out"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$T/bodies" "$T/ledger" "$T/pbin"
  cat > "$H/fleet.conf" <<'CONF'
# project repo prod board_prefix offset box ip
acme-os  example-org/acme-os  https://os.acme.test  /api/board  2 box-a 10.0.0.1
nob-os   example-org/nob-os   https://nob.test      -           3 box-b 10.0.0.2
CONF
  printf 'ACME_INTERNAL_API_TOKEN=%s\nACME_API_BASE=https://os.acme.test/\n' "$TOKEN" > "$H/env/acme-os.env"
  printf 'NOB_INTERNAL_API_TOKEN=x\nNOB_API_BASE=https://nob.test\n' > "$H/env/nob-os.env"
  mkdir -p "$H/state/lookback/$DATE"; cp "$FIX/bundle.json" "$H/state/lookback/$DATE/bundle.json"
  STUB_GET_FILE="$FIX/ticket-open.json"; STUB_CREATE_FILE="$FIX/create.json"
  STUB_GET_RC=0; STUB_CREATE_RC=0; STUB_LEDGER_RC=""; STUB_PUT_RC=0
  export STUB_GET_FILE STUB_CREATE_FILE STUB_GET_RC STUB_CREATE_RC
}

# The curl recorder: `METHOD URL` per call to calls.curl, argv to calls.argv,
# the -K config from stdin to calls.cfg, the --data-binary body to bodies/<n>.json.
mkdir -p "$T/pbin"
cat > "$T/pbin/curl" <<SH
#!/bin/bash
m=GET; data=""; url=""
printf '%s\n' "\$*" >> "$T/calls.argv"
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) m="\$2"; shift ;;
    --data-binary) data="\${2#@}"; shift ;;
    -H|--max-time|-K) shift ;;
    -*) ;;
    *) url="\$1" ;;
  esac
  shift
done
cat >> "$T/calls.cfg"
n=\$(( \$(cat "$T/calls.curl" 2>/dev/null | wc -l) + 1 ))
printf '%s %s\n' "\$m" "\$url" >> "$T/calls.curl"
[ -n "\$data" ] && cp "\$data" "$T/bodies/\$n.json"
case "\$m \$url" in
  "GET "*/boards) cat "$FIX/boards.json" ;;
  "GET "*/tickets/*) [ "\${STUB_GET_RC:-0}" = 0 ] || exit "\$STUB_GET_RC"; cat "\${STUB_GET_FILE:-$FIX/ticket-open.json}" ;;
  "POST "*/boards/*/tickets) [ "\${STUB_CREATE_RC:-0}" = 0 ] || exit "\$STUB_CREATE_RC"; cat "\${STUB_CREATE_FILE:-$FIX/create.json}" ;;
  "POST "*/tickets/*/comments) echo '{"ok":true}' ;;
  *) exit 22 ;;
esac
SH
chmod +x "$T/pbin/curl"
PATH="$T/pbin:$PATH"

# File-backed ledger recorders (they run inside the lib's subshells too).
job_ledger_row() {
  [ -n "$STUB_LEDGER_RC" ] && return "$STUB_LEDGER_RC"
  printf 'row %s %s\n' "$1" "$2" >> "$T/calls.ledger"
  [ -f "$T/ledger/$2" ] || return 2
  cat "$T/ledger/$2"
}
job_ledger_put() {
  printf 'put %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$T/calls.ledger"
  [ "$STUB_PUT_RC" = 0 ] || return "$STUB_PUT_RC"
  jq -nc --arg s "$3" --arg d "$4" '{status:$s,detail:$d}' > "$T/ledger/$2"
}
seed_row() { # seed_row <detail json> [status]
  jq -nc --arg d "$1" --arg s "${2:-filed}" '{status:$s,detail:$d}' > "$T/ledger/$FP"
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

export HARNESS="$H"
if ! . "$LIB"; then bad "the lib does not source"; fi
declare -F lookback_file_board >/dev/null || bad "lookback_file_board is not defined by $LIB"
C=$(jq -c . "$FIX/cluster.json")
file_it() { OUT=$(lookback_file_board "$1" "$H/state/lookback/$DATE"); RC=$?; }

# --- B1 create --------------------------------------------------------------------
fresh; file_it "$C"
eq "B1 rc" "$RC" 0
eq "B1 one create POST" "$(count "$T/calls.curl" '^POST https://os.acme.test/api/board/boards/product-board/tickets$')" 1
eq "B1 board discovery then create" "$(cut -d' ' -f1 "$T/calls.curl" 2>/dev/null | tr '\n' ,)" "GET,POST,"
B=$(ls "$T/bodies"/*.json 2>/dev/null | head -1)
DESC=$(jq -r '.description // empty' "$B" 2>/dev/null)
eq "B1 title" "$(jq -r '.title' "$B" 2>/dev/null)" "Rebase keeps failing on acme"
eq "B1 fingerprint is the last line" "$(printf "%s\n" "$DESC" | tail -n 1)" "<p>lookback-cluster: $FP</p>"
has "B1 evidence line per item" "$DESC" "alerts:2"
has "B1 evidence carries the ticket" "$DESC" "TK-12"
has "B1 proposed fix" "$DESC" "Release the lock"
eq "B1 ledger read before the create" "$(head -1 "$T/calls.ledger" 2>/dev/null)" "row lookback_cluster $FP"
eq "B1 one put" "$(count "$T/calls.ledger" '^put ')" 1
P=$(grep '^put ' "$T/calls.ledger" 2>/dev/null | cut -d' ' -f5-)
eq "B1 put status" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f2-4)" "lookback_cluster $FP filed"
eq "B1 row board+ticket" "$(printf '%s' "$P" | jq -c '[.board,.ticket_id,.key,.target,.key_kind,.key_value,.project,.items]' 2>/dev/null)" \
  '["acme-os","t-901","TK-901","app","lane","rebase","acme-os",3]'
eq "B1 row item_ids" "$(printf '%s' "$P" | jq -c '.item_ids' 2>/dev/null)" '["alerts:1","alerts:2","builds:3"]'
printf '%s' "$P" | jq -e '.filed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' >/dev/null 2>&1 && ok || bad "B1 filed_at is not an ISO stamp: $P"
has "B1 summary" "$OUT" "Rebase keeps failing on acme on acme-os ticket TK-901"
eq "B1 idempotency key" "$(count "$T/calls.argv" "Idempotency-Key: lookback-$FP")" 1

# --- B2 open ticket: comment with the new ids only ------------------------------
fresh; seed_row '{"board":"acme-os","ticket_id":"t-500","key":"TK-500","item_ids":["alerts:1","alerts:2"],"project":"acme-os"}'
file_it "$C"
eq "B2 rc" "$RC" 3
eq "B2 zero creates" "$(count "$T/calls.curl" '/boards/')" 0
eq "B2 ticket read" "$(count "$T/calls.curl" '^GET https://os.acme.test/api/board/tickets/t-500$')" 1
eq "B2 one comment" "$(count "$T/calls.curl" '^POST https://os.acme.test/api/board/tickets/t-500/comments$')" 1
CB=$(jq -r '.body' "$T/bodies"/*.json 2>/dev/null)
has "B2 comment names the new id" "$CB" "builds:3"
hasnt "B2 comment omits an old id" "$CB" "alerts:1"
has "B2 comment count" "$CB" "1 new"
has "B2 summary" "$OUT" "on acme-os ticket t-500 (1 new items)"
eq "B2 row ids unioned" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f5- | jq -c '.item_ids')" '["alerts:1","alerts:2","builds:3"]'
eq "B2 row stays filed" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f4)" filed

fresh; seed_row '{"board":"acme-os","ticket_id":"t-500","item_ids":["alerts:1","alerts:2","builds:3"],"project":"acme-os"}'
file_it "$C"
eq "B2b rc" "$RC" 3
eq "B2b no POST" "$(count "$T/calls.curl" '^POST')" 0
has "B2b summary" "$OUT" "(0 new items)"

fresh; seed_row '{"board":"acme-os","ticket_id":"t-500","item_ids":["alerts:1"],"project":"acme-os"}'
STUB_GET_FILE="$FIX/ticket-done.json"; file_it "$C"
eq "B2c rc" "$RC" 0
eq "B2c created" "$(count "$T/calls.curl" '/boards/product-board/tickets$')" 1
eq "B2c prior ticket kept" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f5- | jq -r '[.ticket_id,.prior_ticket]|join(",")')" "t-901,t-500"
eq "B2c re-create has its own idempotency key" "$(count "$T/calls.argv" "Idempotency-Key: lookback-$FP-t-500")" 1

# a row the 30-day follow-up already stamped is not re-armed by a weekly comment
fresh; seed_row '{"board":"acme-os","ticket_id":"t-500","item_ids":["alerts:1","alerts:2"],"project":"acme-os","filed_at":"2026-01-01T00:00:00Z"}' followed_up_recurred
file_it "$C"
eq "B2e rc" "$RC" 3
eq "B2e one comment" "$(count "$T/calls.curl" '^POST https://os.acme.test/api/board/tickets/t-500/comments$')" 1
eq "B2e put keeps the follow-up status" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f4)" followed_up_recurred
eq "B2e filed_at unchanged" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f5- | jq -r '.filed_at')" "2026-01-01T00:00:00Z"

fresh; seed_row '{"board":"acme-os","ticket_id":"t-500","item_ids":["alerts:1"],"project":"acme-os"}'
STUB_GET_RC=22; file_it "$C"
eq "B2d rc" "$RC" 1
eq "B2d nothing created" "$(count "$T/calls.curl" '^POST')" 0
has "B2d says why" "$OUT" "failed: ticket t-500 state unreadable"

# --- B3 no board -------------------------------------------------------------------
fresh; file_it "$(jq -c '.project="nob-os"' <<<"$C")"
eq "B3 rc (prefix -)" "$RC" 4
eq "B3 zero curl (prefix -)" "$(lines "$T/calls.curl")" 0
eq "B3 message (prefix -)" "$OUT" "nob-os has no board configured"
eq "B3 no ledger read (prefix -)" "$(lines "$T/calls.ledger")" 0
fresh; printf 'ACME_API_BASE=https://os.acme.test\n' > "$H/env/acme-os.env"; file_it "$C"
eq "B3 rc (no token)" "$RC" 4
eq "B3 zero curl (no token)" "$(lines "$T/calls.curl")" 0
has "B3 message (no token)" "$OUT" "has no board configured"
[ ! -e "$H/logs/ALERTS.log" ] && ok || bad "B3 an ALERTS line was written: $(cat "$H/logs/ALERTS.log")"
fresh; rm -f "$H/env/acme-os.env"; file_it "$C"
eq "B3 rc (no env file)" "$RC" 4
eq "B3 zero curl (no env file)" "$(lines "$T/calls.curl")" 0
[ ! -e "$H/logs/ALERTS.log" ] && ok || bad "B3 an ALERTS line was written for a missing env"
# a DUPLICATE token is a broken env, not a missing board: the existing alert fires
fresh; printf 'ACME_INTERNAL_API_TOKEN=a\nOLD_INTERNAL_API_TOKEN=b\nACME_API_BASE=https://os.acme.test\n' > "$H/env/acme-os.env"
file_it "$C"
eq "B3b rc (duplicate token)" "$RC" 4
eq "B3b zero curl" "$(lines "$T/calls.curl")" 0
eq "B3b one ALERTS line" "$(count "$H/logs/ALERTS.log" 'refusing to guess')" 1

# --- B4 ledger outage -----------------------------------------------------------------
fresh; STUB_LEDGER_RC=1; file_it "$C"
eq "B4 rc" "$RC" 75
eq "B4 zero curl" "$(lines "$T/calls.curl")" 0
has "B4 message" "$OUT" "ledger unreadable: Rebase keeps failing on acme"

# --- B5 create answers no id ------------------------------------------------------------
fresh; printf '{}\n' > "$T/empty.json"; STUB_CREATE_FILE="$T/empty.json"; file_it "$C"
eq "B5 rc" "$RC" 1
eq "B5 no put" "$(count "$T/calls.ledger" '^put ')" 0
has "B5 message" "$OUT" "failed: create on acme-os"
fresh; STUB_CREATE_RC=22; file_it "$C"
eq "B5b rc (http error)" "$RC" 1
eq "B5b no put" "$(count "$T/calls.ledger" '^put ')" 0
# a put that fails after the create is noted, not an error
fresh; STUB_PUT_RC=1; file_it "$C"
eq "B5c rc" "$RC" 0
has "B5c noted" "$OUT" "ledger write failed, next run may duplicate"

# --- B6 no em dashes posted -----------------------------------------------------------
fresh; file_it "$C"
grep -q '—' "$FIX/cluster.json" && ok || bad "B6 the fixture has no em dash to strip"
ALLB=$(cat "$T/bodies"/*.json 2>/dev/null)
hasnt "B6 no em dash" "$ALLB" "—"
hasnt "B6 no en dash" "$ALLB" "–"
has "B6 dash became a comma" "$(jq -r '.description' "$T/bodies"/*.json)" "The rebase lane, on acme-os, hits a held lock"
fresh; seed_row '{"board":"acme-os","ticket_id":"t-500","item_ids":[],"project":"acme-os"}'
jq '.items[0].reason="lock held — again"' "$FIX/bundle.json" > "$H/state/lookback/$DATE/bundle.json"
file_it "$C"
hasnt "B6 no em dash in a comment" "$(cat "$T/bodies"/*.json 2>/dev/null)" "—"

# --- B7 the token is never on argv -------------------------------------------------------
hasnt "B7 token not in argv" "$(cat "$T/calls.argv")" "$TOKEN"
has "B7 token rides the config" "$(cat "$T/calls.cfg")" "Authorization: Bearer $TOKEN"

# --- D1 the driver end to end ---------------------------------------------------------
fresh
cp "$DIR/bin/lookback.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/lookback-common.sh" "$LIB" "$DIR/bin/lib/internal-token.sh" "$DIR/bin/lib/board-creds.sh" "$H/bin/lib/"
: > "$H/env/global.env"
cat > "$H/bin/jobs-client.sh" <<SH
job_lane_open()  { :; }
job_lane_close() { :; }
job_ledger_row() { printf 'row %s %s\n' "\$1" "\$2" >> "$T/calls.ledger"; return 2; }
job_ledger_put() { printf 'put %s %s %s %s\n' "\$1" "\$2" "\$3" "\$4" >> "$T/calls.ledger"; }
# BH-3691: the driver reads the ledger once for its rolling-week cap; empty here.
_jobs_req() { echo '{"ledgers":[]}'; }
SH
cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
a="\$*"; printf '%s\n' "\${a//\$'\n'/ | }" >> "$T/calls.lane-alert"
SH
cat > "$H/bin/lookback-collect.sh" <<SH
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
cp "$FIX/bundle.json" "\$out"
SH
chmod +x "$H/bin/"*.sh
jq -c '[.]' "$FIX/cluster.json" > "$H/state/lookback/$DATE/clusters.json"
# TEST-CHANGE (BH-3691): app-target filing is opt-in (LOOKBACK_APP_FILING=1).
env -i PATH="$PATH" HOME="$T" HARNESS="$H" LANE_GATE_NOW="$NOW" LOOKBACK_APP_FILING=1 bash "$H/bin/lookback.sh" > "$T/out" 2>&1
eq "D1 rc" "$?" 0
eq "D1 one create POST" "$(count "$T/calls.curl" '^POST .*/boards/product-board/tickets$')" 1
AL=$(cat "$T/calls.lane-alert" 2>/dev/null)
has "D1 summary head" "$AL" "1 filed"
has "D1 summary line" "$AL" "filed: Rebase keeps failing on acme on acme-os ticket TK-901"
eq "D1 row written" "$(count "$T/calls.ledger" "^put lookback_cluster $FP filed ")" 1

# --- Z1 no model id --------------------------------------------------------------------
eq "Z1 claude- occurrences" "$(grep -c 'claude-' "$LIB")" 0

echo "lookback-board.bh-1795-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
