#!/bin/bash
# tests/triage-park.bh-3943-test.sh — BH-3949 (BH-3943 item 1): park a ticket
# the call-guard keeps refusing.
#
# project-4 TK-2117 sat in the "to the model" list on every tick for two days: the
# call-guard refused each shard (`repeat`, the world was already paid for) and
# nothing ever told the pre-check to stop offering it. bin/lib/triage-park.sh
# writes a `hold` verdict stamped with the ticket's own input_hash after N
# refusals, so the existing decide answers `skip unchanged:hold` until the board
# moves.
#
#   P1-P7  the REAL bin/triage-shard.sh in a scratch harness: agent-call stubbed
#          to refuse (rc 74 + the mark), the jobs client stubbed from fixtures
#          (each PUT body recorded, a 2xx PUT merged into the row like the
#          worker's partial upsert), lane-alert stubbed to count its calls
#   P8     python3 bin/triage-state.py decide on the row P1 actually PUT
#   P9     triage_park_tick_line, driven through the real hook line, the last line of rt_scope (bin/lib/rt/scope.sh; shards.sh stays unedited, BH-3418)
#   P10    D1/D2: the shard with its `CG_PARK=1` line deleted parks nothing
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-park.bh-3943-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "triage-park: jq missing, cannot run" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "triage-park: python3 missing, cannot run" >&2; exit 1; }

P=project-4
K=TK-2117
FP=0123456789abcdef
S="$T/h"; FX="$T/fx"
mkdir -p "$S/bin/lib/rt" "$S/logs" "$S/locks" "$S/state/triage-shards/$P" "$S/env" "$FX"
scratch_install_closure bin/triage-shard.sh "$S" >/dev/null || exit 1
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$S/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/decision-log.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/beat.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$FX" > "$S/bin/lane-alert.sh"
cat > "$S/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo "called" >> "$FX/agent-calls"
case "${SHARD_AC:-repeat}" in
  repeat)     printf 'AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=%s\n' "${AGENT_CALL_FP:-}" > "$5"; exit 74 ;;
  unreadable) printf 'AGENT_CALL_REFUSED call-guard counter-unreadable metered claude\n' > "$5"; exit 74 ;;
  ctxkill)    printf 'AGENT_CALL_REFUSED context-kill repeat triage-shard kills=3/3 fp=%s\n' "${AGENT_CALL_FP:-}" > "$5"; exit 74 ;;
esac
echo "tickets=1 done" > "$5"
STUB
# The jobs client, answered from $FX. Every function the shard and the lib call.
cat > "$S/bin/jobs-client.sh" <<'STUB'
job_open() { return 1; }
call_guard_list() {
  echo "$*" >> "$FX/cg-calls"
  [ "$(cat "$FX/cg.rc" 2>/dev/null || echo 0)" = 0 ] || return 1
  cat "$FX/cg.json"
}
triage_state_get() {
  local rc; rc=$(cat "$FX/get.rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] || return "$rc"
  cat "$FX/row.json"
}
triage_state_list() {
  [ "$(cat "$FX/list.rc" 2>/dev/null || echo 0)" = 0 ] || return 1
  cat "$FX/list.json"
}
triage_state_put() {
  local n; n=$(( $(ls "$FX/puts" 2>/dev/null | wc -l) + 1 ))
  mkdir -p "$FX/puts"; cp "$1" "$FX/puts/$n.json"
  [ "$(cat "$FX/put.rc" 2>/dev/null || echo 0)" = 0 ] || return 1
  # the worker's partial upsert: only the columns the body carries move
  jq -s '.[0] * (.[1] | del(.project))' "$FX/row.json" "$1" > "$FX/row.new" && mv "$FX/row.new" "$FX/row.json"
}
STUB
chmod +x "$S/bin/"*.sh
printf 'TICK SCOPE (triage shard)\n\nWhat moved for TK-2117:\nOn the board:\nboard: TK-2117 changed\n' > "$S/prompt.txt"
FPF="$S/state/triage-shards/$P/$K.fp"
MARK="$S/state/triage-park/$P/$K.$FP"

cg() { # cg <refused_since_reset> [fp] — the call-guard roll-up for this key
  jq -n --arg fp "${2:-$K:$FP}" --argjson r "$1" \
    '{rows:[{project:"project-4",stage:"triage-shard",fp:"TK-1:ffffffffffffffff",paid:2,refused:9,refused_since_reset:9},
            {project:"project-4",stage:"triage-shard",fp:$fp,paid:2,refused:$r,refused_since_reset:$r}]}' > "$FX/cg.json"
}
fresh() { # a clean world: an unparked row with input_hash H1, no puts, no marker
  scratch_rm "$FX"; scratch_rm "$S/state/triage-park"; mkdir -p "$FX"
  : > "$S/logs/$P.log"; : > "$S/logs/ALERTS.log"
  jq -n '{project:"project-4",ticket_key:"TK-2117",verdict:"triaged",waiting_on:"team",verdict_hash:"H0",input_hash:"H1",reason:"looked at it"}' > "$FX/row.json"
}
shard() { # shard <mode> [script]
  printf '%s\n1\n' "$FP" > "$FPF"
  ( export HARNESS="$S" FX SHARD_AC="$1" TSH_MODEL=claude-fable-5-1 TSH_RUNNER=claude
    bash "${2:-$S/bin/triage-shard.sh}" "$P" "$K" "$S/prompt.txt" >/dev/null 2>&1 )
}
nputs()   { ls "$FX/puts" 2>/dev/null | grep -c . ; }
nalerts() { local n; n=$(grep -c . "$FX/alerts" 2>/dev/null); echo "${n:-0}"; }

# --- P1: 1 and 2 refusals park nothing; the 3rd parks ------------------------
fresh
cg 1; shard repeat
cg 2; shard repeat
[ "$(nputs)" = 0 ] && ok || bad "P1a refusals 1 and 2 must not park ($(nputs) PUTs)"
grep -q 'triage-park:' "$S/logs/$P.log" && bad "P1b a refusal below the threshold wrote a triage-park line" || ok
cg 3; shard repeat
[ "$(nputs)" = 1 ] && ok || bad "P1c the 3rd refusal must PUT exactly once ($(nputs) PUTs)"
B="$FX/puts/1.json"
[ "$(jq -r '.verdict' "$B" 2>/dev/null)" = hold ] && ok || bad "P1d verdict is not hold: $(cat "$B" 2>/dev/null)"
[ "$(jq -r '.waiting_on' "$B" 2>/dev/null)" = team ] && ok || bad "P1e waiting_on is not team"
[ "$(jq -r '.verdict_hash' "$B" 2>/dev/null)" = H1 ] && ok || bad "P1f verdict_hash is not the row's input_hash"
[ "$(jq -r '.project + "/" + .ticket_key' "$B" 2>/dev/null)" = "$P/$K" ] && ok || bad "P1g the PUT names the wrong row"
case "$(jq -r '.reason' "$B" 2>/dev/null)" in
  "call-guard-exhausted: paid 2/2, refused 3"*) ok ;;
  *) bad "P1h reason '$(jq -r '.reason' "$B" 2>/dev/null)'" ;;
esac
D=$(jq -r '((.next_recheck_at|sub("\\.[0-9]+";"")|fromdateiso8601) - (.triaged_at|sub("\\.[0-9]+";"")|fromdateiso8601))' "$B" 2>/dev/null)
[ "$D" = 604800 ] && ok || bad "P1i next_recheck_at - triaged_at = '$D', want 604800"
[ -f "$MARK" ] && ok || bad "P1j no alert-once marker after a 2xx PUT"
[ "$(nalerts)" = 1 ] && ok || bad "P1k one lane-alert expected, got $(nalerts)"
grep -q -- "--severity warn --id triage-park-$P-$K triage-park \[triage-park\] $P $K parked: call-guard refused 3 times" "$FX/alerts" && ok \
  || bad "P1l alert text: $(cat "$FX/alerts" 2>/dev/null)"
grep -q "triage-park: $K parked (refused 3)" "$S/logs/$P.log" && ok || bad "P1m no 'parked' line in the project log"
[ -s "$FPF" ] && ok || bad "P1n the park took the stamp back (the repeat arm keeps it)"
cp "$B" "$T/parked-body.json"

# --- P2: refusals 3, 4, 5 on one fp -> one PUT, one alert ----------------------
fresh
cg 3; shard repeat
cg 4; shard repeat
cg 5; shard repeat
[ "$(nputs)" = 1 ] && ok || bad "P2a an already-parked row was PUT again ($(nputs) PUTs)"
[ "$(nalerts)" = 1 ] && ok || bad "P2b refusals 3,4,5 sent $(nalerts) alerts, want exactly 1"

# --- P3: a failing PUT leaves no marker and no alert; the next run parks ----
fresh; echo 1 > "$FX/put.rc"
cg 3; shard repeat
[ "$(nputs)" = 1 ] && ok || bad "P3a the PUT was not attempted"
[ -e "$MARK" ] && bad "P3b a failed PUT wrote the marker" || ok
[ "$(nalerts)" = 0 ] && ok || bad "P3c a failed PUT alerted"
grep -q "triage-park: $K not parked" "$S/logs/$P.log" && ok || bad "P3d a failed PUT left no log line"
rm -f "$FX/put.rc"; cg 4; shard repeat
[ "$(nputs)" = 2 ] && [ -f "$MARK" ] && [ "$(nalerts)" = 1 ] && ok || bad "P3e the retry after a failed PUT did not park (puts=$(nputs) alerts=$(nalerts))"

# --- P4: counter-unreadable and context-kill repeat never park --------------
fresh; cg 5
shard unreadable
[ "$(nputs)" = 0 ] && ok || bad "P4a counter-unreadable parked"
shard ctxkill
[ "$(nputs)" = 0 ] && ok || bad "P4b context-kill repeat parked"
[ -f "$FX/cg-calls" ] && bad "P4c a non-repeat refusal read the call-guard list" || ok

# --- P5: the row for a different fp of the same key ---------------------------
fresh; cg 5 "$K:fedcba9876543210"; shard repeat
[ "$(nputs)" = 0 ] && ok || bad "P5 a different fp's refusals parked this world"
grep -q "triage-park: $K not parked: no call-guard row" "$S/logs/$P.log" && ok || bad "P5b no fail-open line for a missing row"

# --- P6: fail-open on every unreadable input ---------------------------------
fresh; cg 5; echo 2 > "$FX/get.rc"; shard repeat
[ "$(nputs)" = 0 ] && ok || bad "P6a no triage_state row, still parked"
[ "$(grep -c "triage-park: $K not parked" "$S/logs/$P.log")" = 1 ] && ok || bad "P6b no-row: want exactly one log line"
fresh; cg 5; jq 'del(.input_hash)' "$FX/row.json" > "$FX/r" && mv "$FX/r" "$FX/row.json"; shard repeat
[ "$(nputs)" = 0 ] && ok || bad "P6c a row with no input_hash parked"
grep -q "triage-park: $K not parked" "$S/logs/$P.log" && ok || bad "P6d no input_hash: no log line"
fresh; cg 5; echo 1 > "$FX/cg.rc"; shard repeat
[ "$(nputs)" = 0 ] && ok || bad "P6e an unreadable call-guard list parked"
grep -q "triage-park: $K not parked" "$S/logs/$P.log" && ok || bad "P6f unreadable list: no log line"
fresh; printf 'not json' > "$FX/cg.json"; shard repeat
[ "$(nputs)" = 0 ] && ok || bad "P6g a non-JSON call-guard answer parked"

# --- P7: the knob --------------------------------------------------------------
fresh; cg 5
( export TRIAGE_REFUSED_PARK_AFTER=0; shard repeat )
[ "$(nputs)" = 0 ] && ok || bad "P7a TRIAGE_REFUSED_PARK_AFTER=0 still parked"
[ -f "$FX/cg-calls" ] && bad "P7b knob 0 still read the call-guard list" || ok
fresh; cg 2
( export TRIAGE_REFUSED_PARK_AFTER=2; shard repeat )
[ "$(nputs)" = 1 ] && ok || bad "P7c env TRIAGE_REFUSED_PARK_AFTER=2 with no settings row did not park at 2"
fresh; cg 3
( export TRIAGE_PARK_RECHECK_S=3600; shard repeat )
D=$(jq -r '((.next_recheck_at|sub("\\.[0-9]+";"")|fromdateiso8601) - (.triaged_at|sub("\\.[0-9]+";"")|fromdateiso8601))' "$FX/puts/1.json" 2>/dev/null)
[ "$D" = 3600 ] && ok || bad "P7d TRIAGE_PARK_RECHECK_S=3600 not honoured ($D)"

# --- P8: the existing decide consumes the park; a moved hash unparks ---------
NOW=$(date +%s)
jq -s '.[0] * .[1] | [.]' "$FX/row.json" "$T/parked-body.json" > "$T/rows.json" 2>/dev/null
printf '%s\t%s\tH1\t-\t1\t-\n' "$K" "$K" > "$T/h-same.tsv"
printf '%s\t%s\tH2\t-\t1\t-\n' "$K" "$K" > "$T/h-moved.tsv"
DS=$(python3 "$DIR/bin/triage-state.py" decide --hashes "$T/h-same.tsv" --rows "$T/rows.json" --now "$NOW" --ttl 86400 --project "$P")
DM=$(python3 "$DIR/bin/triage-state.py" decide --hashes "$T/h-moved.tsv" --rows "$T/rows.json" --now "$NOW" --ttl 86400 --project "$P")
[ "$(printf '%s' "$DS" | cut -f3,4)" = "skip	unchanged:hold" ] && ok || bad "P8a parked row on an unchanged board: '$DS'"
[ "$(printf '%s' "$DM" | cut -f3,4)" = "llm	changed" ] && ok || bad "P8b a moved input_hash must go back to the model: '$DM'"

# --- P9: the tick line, through the real hook line in bin/lib/rt/scope.sh ---
# BH-3418 keeps bin/lib/rt/shards.sh unedited, and bin/run-triage.sh is at its
# line ceiling, so the hook is the LAST line of rt_scope (bin/lib/rt/scope.sh).
# The driver calls rt_scope before rt_shards, which exits the tick when it
# dispatches. The suite lifts that real line and runs it, so deleting or
# breaking it fails P9a. The full stage is not run: it needs a board.
HOOK=$(grep -F 'triage_park_tick_line "$HARNESS" "$PROJECT"' "$DIR/bin/lib/rt/scope.sh")
[ "$(printf '%s\n' "$HOOK" | grep -c .)" = 1 ] && ok || bad "P9x want exactly one hook line in bin/lib/rt/scope.sh: [$HOOK]"
LASTLN=$(awk '/^rt_scope\(\)/{f=1} f&&/^}$/{print prev; exit} {prev=$0}' "$DIR/bin/lib/rt/scope.sh")
[ "$LASTLN" = "$HOOK" ] && ok || bad "P9y the hook must be the last line of rt_scope: [$LASTLN]"
SCOPELN=$(grep -nx 'rt_scope' "$DIR/bin/run-triage.sh" | head -1 | cut -d: -f1)
SHARDLN=$(grep -nx 'rt_shards' "$DIR/bin/run-triage.sh" | head -1 | cut -d: -f1)
[ -n "$SCOPELN" ] && [ -n "$SHARDLN" ] && [ "$SCOPELN" -lt "$SHARDLN" ] && ok \
  || bad "P9w bin/run-triage.sh must call rt_scope before rt_shards (${SCOPELN:-none} vs ${SHARDLN:-none})"
grep -q 'triage_park' "$DIR/bin/lib/rt/shards.sh" && bad "P9z bin/lib/rt/shards.sh must not carry the hook (BH-3418)" || ok
tick() {
  : > "$S/logs/$P.log"
  ( set -u; HARNESS="$S"; PROJECT="$P"; export FX; eval "$HOOK" ) >/dev/null 2>&1
}
fresh
jq -n '[{ticket_key:"TK-2117",verdict:"hold",reason:"call-guard-exhausted: paid 2/2, refused 3, last repeat",input_hash:"H1",verdict_hash:"H1"},
        {ticket_key:"TK-2160",verdict:"hold",reason:"call-guard-exhausted: paid 2/2, refused 4, last repeat",input_hash:"H9",verdict_hash:"H8"},
        {ticket_key:"TK-2001",verdict:"hold",reason:"waiting on the client",input_hash:"H3",verdict_hash:"H3"},
        {ticket_key:"TK-2002",verdict:"triaged",reason:"call-guard-exhausted: old",input_hash:"H4",verdict_hash:"H4"}]' > "$FX/list.json"
mkdir -p "$S/state/triage-park/$P"
touch "$S/state/triage-park/$P/TK-2117.$FP" "$S/state/triage-park/$P/TK-2160.$FP"
tick
[ "$(grep -c 'triage-park:' "$S/logs/$P.log")" = 1 ] && ok || bad "P9a want one tick line, log: $(cat "$S/logs/$P.log")"
grep -qE "^[0-9-]+ [0-9:]+Z \[$P\] triage-park: 1 parked \(TK-2117\)$" "$S/logs/$P.log" && ok \
  || bad "P9b tick line: $(cat "$S/logs/$P.log")"
[ -e "$S/state/triage-park/$P/TK-2117.$FP" ] && ok || bad "P9d the parked key's marker was pruned"
[ -e "$S/state/triage-park/$P/TK-2160.$FP" ] && bad "P9e a stale marker (key no longer parked) was not pruned" || ok
echo '[]' > "$FX/list.json"; touch "$S/state/triage-park/$P/TK-2160.$FP"
tick
grep -q 'triage-park:' "$S/logs/$P.log" && bad "P9f zero parked still logged a line" || ok
[ -e "$S/state/triage-park/$P/TK-2160.$FP" ] && bad "P9i a good empty read kept a marker" || ok
touch "$S/state/triage-park/$P/TK-2117.$FP"; echo 1 > "$FX/list.rc"; tick
[ -e "$S/state/triage-park/$P/TK-2117.$FP" ] && ok || bad "P9g an unreadable list pruned markers"
grep -q 'triage-park:' "$S/logs/$P.log" && bad "P9h an unreadable list logged a tick line" || ok

# --- P10: D1/D2 — the suite pins the hook line in the real shard --------------
fresh; cg 3
grep -v 'CG_PARK=1' "$S/bin/triage-shard.sh" > "$S/bin/triage-shard-mut.sh"
if cmp -s "$S/bin/triage-shard.sh" "$S/bin/triage-shard-mut.sh"; then
  bad "P10a triage-shard.sh has no CG_PARK=1 line to delete"
else
  shard repeat "$S/bin/triage-shard-mut.sh"
  [ "$(nputs)" = 0 ] && ok || bad "P10b the shard with its hook line deleted still parked"
fi
fresh; cg 3; shard repeat
[ "$(nputs)" = 1 ] && ok || bad "P10c the unmutated shard did not park"

echo "triage-park: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
