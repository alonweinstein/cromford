#!/bin/bash
# tests/trigger-actor-gate.bh-4490-test.sh — only a listed human or the harness
# itself can make a ticket buildable (BH-4490, wave 3 of #4475).
#
# The ticket names tests/trigger-actor-gate-test.sh; the repo names per-ticket
# suites <slug>.<key>-test.sh, so this is that suite.
#
# HOW IT DRIVES: the `trigger actor gate (BH-4490)` block is lifted out of the
# pipeline text (tests/lib/rb-all.sh, so it holds at every state of the BH-478
# split) by its markers and run with the REAL bin/lib/trigger-actor.sh, the
# REAL bin/lib/harness-self.sh and the REAL bin/jobs-client.sh (setting_get,
# job_ledger_row, job_ledger_put). Only the wire is stubbed: _jobs_req (settings
# and ledger), gh_rest / gh_rest_comment (GitHub), curl (the in-app board),
# lane_switch, bin/fleet-conf.sh and bin/internal-token-for.sh. Every stub logs
# its calls under $T/calls, and the cases assert on RESULT, the exit code, the
# pipeline.log line, the comment bodies and the ledger PUTs.
#
#   B1-B5   the ticket's five criteria
#   B6-B15  what the design adds (episode reset, fail closed, pages, no trigger,
#           newest wins, in-app arm, kill switch, unconfigured client, position,
#           empty self-app list)
#   L1-L9   ta_decide / ta_allowlist / ta_board_trigger units
#   M1-M2   mutation: no block -> B2 goes green-for-the-wrong-reason (asserted
#           red); no hs_ours self check -> B4 refuses the harness's own label
# Run from anywhere: tests/trigger-actor-gate.bh-4490-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }

awk '/^# >>> trigger actor gate/{f=1} f{print} /^# <<< trigger actor gate/{exit}' "$RB" > "$T/block.sh"
if [ -s "$T/block.sh" ]; then ok; else bad "B14: could not lift the 'trigger actor gate' block out of the pipeline"; fi

# ── B14 position ─────────────────────────────────────────────────────────────
TA=$(grep -n '^# >>> trigger actor gate' "$RB" | head -1 | cut -d: -f1)
AB=$(grep -n '^# <<< abandoned ticket skip' "$RB" | head -1 | cut -d: -f1)
EQ=$(grep -n 'Fly builder trial (Phase 2): enqueue gate' "$RB" | head -1 | cut -d: -f1)
if [ -n "$TA" ] && [ -n "$AB" ] && [ -n "$EQ" ] && [ "$AB" -lt "$TA" ] && [ "$TA" -lt "$EQ" ]; then ok
else bad "B14: the gate (line ${TA:-?}) must sit after the abandoned skip (${AB:-?}) and before the fly enqueue gate (${EQ:-?})"; fi
if [ -s "$T/block.sh" ] && bash -n "$T/block.sh"; then ok; else bad "B14: the lifted block is not valid bash"; fi

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/locks" "$H/logs" "$T/fx" "$T/build"
for s in bin/lib/trigger-actor.sh bin/lib/harness-self.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$CALLS/fleet-conf"
case "$2" in
  board_prefix) printf '%s\n' "${FC_BP:--}" ;;
  repo)         printf '%s\n' "example-org/tproj" ;;
  prod)         printf '%s\n' "https://app.example.test" ;;
  *)            exit 1 ;;
esac
SH
cat > "$H/bin/internal-token-for.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$CALLS/token"
printf 'tok-fixture\n'
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/internal-token-for.sh"

# The stubs every run sources before the block. Only the wire is fake.
cat > "$T/stubs.sh" <<'SH'
STAMP() { echo 2026-10-04T22:30:00Z; }
RESULT() { echo "$*" > "$SINK"; }
. "$REPO_DIR/bin/jobs-client.sh"
_jobs_req() { # settings + ledger, the worker's envelopes
  local m="$1" p="$2" b="${3:-}"
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$CALLS/jobs"
  case "$m $p" in
    "GET /api/settings/"*)
      [ "${p#/api/settings/}" = "trigger.actors.tproj" ] || return 2
      case "${SET_RC:-2}" in
        0) jq -nc --arg v "$SET_VAL" '{setting:{key:"trigger.actors.tproj",value:$v}}'; return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
      esac ;;
    "GET /api/ledger?"*)
      [ "${LEDGER_GET_RC:-0}" = 1 ] && return 1
      [ -s "$LEDGER" ] || return 2
      jq -c '{ledger: .}' "$LEDGER"; return 0 ;;
    "PUT /api/ledger")
      printf '%s\n' "$b" >> "$CALLS/puts"; echo put >> "$CALLS/order"
      [ "${LEDGER_PUT_FAIL:-0}" = 1 ] && return 1
      printf '%s' "$b" | jq -c '{status, detail}' > "$LEDGER"; return 0 ;;
  esac
  return 1
}
gh() { :; }
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$CALLS/gh"
  case "$1 $2" in
    "GET repos/example-org/tproj/issues/77/events?"*)
      [ "${EV_RC:-0}" = 0 ] || { GH_REST_REASON=rate-limit; return "$EV_RC"; }
      local pg; pg=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
      if [ -r "$FX/events-p$pg.json" ]; then cat "$FX/events-p$pg.json"; else echo '[]'; fi
      return 0 ;;
  esac
  return 75
}
gh_rest_comment() {
  printf '%s %s\n' "$1" "$2" >> "$CALLS/gh"
  { echo "--- $1#$2"; cat "$3"; echo; } >> "$CALLS/comments"
  echo "comment" >> "$CALLS/order"
  [ "${COMMENT_FAIL:-0}" = 1 ] && return 75
  return 0
}
curl() {
  local a method=GET data="" out="" url=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -X) method="$1"; shift ;;
      -d|--data|--data-binary) data="$1"; shift ;;
      -o) out="$1"; shift ;;
      -H|-m|--max-time|-w) shift ;;
      http*) url="$a" ;;
    esac
  done
  printf '%s %s\n' "$method" "$url" >> "$CALLS/curl"
  if [ "$method" = POST ]; then
    printf '%s\n' "$data" >> "$CALLS/board-comments"
    echo "comment" >> "$CALLS/order"
    if [ -n "$out" ]; then echo '{"comment":{"id":"c1"}}' > "$out"; else echo '{"comment":{"id":"c1"}}'; fi
    return 0
  fi
  [ "${BOARD_RC:-0}" = 0 ] || return 22
  if [ -n "$out" ]; then cp "$BOARD_JSON" "$out"; else cat "$BOARD_JSON"; fi
}
lane_switch() { echo "$*" >> "$CALLS/switch"; [ "$1" = trigger-actor-off ] && [ "${SW_ON:-0}" = 1 ]; }
SH

export REPO_DIR="$DIR" FX="$T/fx" LEDGER="$T/ledger.json" SINK="$T/result" CALLS="$T/calls"
export HARNESS="$H" BUILD="$T/build" PROJECT=tproj KEY=BH-77 TICKET=77
export HARNESS_SELF_APPS="cromford cromford-board cromford-builders"
export HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.example.test
export -n GH_ISSUES_REPO 2>/dev/null; unset GH_ISSUES_REPO

# ev <id> <login> <type> <created_at> [app-slug] [label] [event]
ev() {
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg c "$4" --arg s "${5:-}" \
    --arg n "${6:-ai-build}" --arg e "${7:-labeled}" \
    '{id:$id, event:$e, actor:{login:$l, type:$t}, label:{name:$n}, created_at:$c,
      performed_via_github_app:(if $s == "" then null else {slug:$s} end)}'
}
# page <n> <event-json>... — write one events page
page() { local n="$1"; shift; printf '%s\n' "$@" | jq -s . > "$FX/events-p$n.json"; }
reset_fx() { rm -f "$FX"/events-p*.json "$LEDGER"; }
reset_calls() { scratch_rm "$CALLS" || exit 1; mkdir -p "$CALLS"; : > "$SINK"; rm -f "$BUILD/COMMENTED" "$BUILD/pipeline.log"; }
# run_block [block-file] — RC and OUT for the case; env carries the fixture
run_block() {
  local blk="${1:-$T/block.sh}"
  OUT=$(bash -c '. "$STUBS"; . "$0"; echo CONTINUED' "$blk" 2>"$T/stderr"); RC=$?
}
export STUBS="$T/stubs.sh"
cnt() { if [ -f "$CALLS/$1" ]; then wc -l < "$CALLS/$1" | tr -d ' '; else echo 0; fi; }
continued() { case "$OUT" in *CONTINUED*) return 0 ;; *) return 1 ;; esac; }
plog() { cat "$BUILD/pipeline.log" 2>/dev/null; }

# ── B1 an allowlisted human's label -> buildable ─────────────────────────────
reset_fx; reset_calls
page 1 "$(ev 1001 alice User 2026-10-04T20:00:00Z)"
SET_RC=0 SET_VAL="operator alice" run_block
if continued && [ ! -s "$SINK" ]; then ok; else bad "B1: a listed human's label must build (rc=$RC, result=$(cat "$SINK"))"; fi
[ "$(cnt comments)" = 0 ] && ok || bad "B1: no comment expected, got $(cnt comments)"
[ "$(cnt puts)" = 0 ] && ok || bad "B1: an allowed build writes no ledger row, got $(cnt puts) PUTs"
plog | grep -q 'TRIGGER-ACTOR allow listed actor=alice event=1001' && ok || bad "B1: pipeline.log must say 'TRIGGER-ACTOR allow listed actor=alice event=1001': $(plog)"

# ── B2 unknown user -> ignored, one comment, outcome record ─────────────────
reset_fx; reset_calls
page 1 "$(ev 1002 mallory User 2026-10-04T20:00:00Z)"
export SET_RC=0 SET_VAL="operator alice"
run_block
[ "$RC" = 3 ] && ! continued && ok || bad "B2: an unlisted user must stop the build with exit 3 (rc=$RC)"
grep -q '^BUILD_REFUSED SKIP_ACTOR BH-77' "$SINK" && ok || bad "B2: RESULT must start BUILD_REFUSED SKIP_ACTOR BH-77, got: $(cat "$SINK")"
[ "$(grep -c '^--- ' "$CALLS/comments" 2>/dev/null)" = 1 ] && ok || bad "B2: exactly one comment expected, got $(grep -c '^--- ' "$CALLS/comments" 2>/dev/null)"
grep -q '`mallory`' "$CALLS/comments" 2>/dev/null && grep -q 'trigger list' "$CALLS/comments" && ok || bad "B2: the comment must name \`mallory\` and the trigger list: $(cat "$CALLS/comments" 2>/dev/null)"
grep -q 'example-org/tproj 77' "$CALLS/gh" 2>/dev/null && ok || bad "B2: the comment must go on example-org/tproj#77"
P1=$(sed -n 1p "$CALLS/puts" 2>/dev/null); P2=$(sed -n 2p "$CALLS/puts" 2>/dev/null)
[ "$(printf '%s' "$P1" | jq -r '.kind + "|" + .key + "|" + .status' 2>/dev/null)" = "trigger-actor|tproj BH-77|ignored" ] && ok || bad "B2: first PUT must be the trigger-actor claim, got $P1"
[ "$(printf '%s' "$P1" | jq -r '.detail | fromjson | .commented + "|" + (.event|tostring) + "|" + .actor + "|" + .source' 2>/dev/null)" = "pending|1002|mallory|gh" ] && ok || bad "B2: the claim must carry commented=pending, event=1002, actor=mallory, source=gh: $P1"
[ "$(printf '%s' "$P2" | jq -r '.detail | fromjson | .commented' 2>/dev/null)" = yes ] && ok || bad "B2: second PUT must mark commented=yes: $P2"
# the claim PUT precedes the comment POST, and the commented=yes PUT follows it
[ "$(tr '\n' ' ' < "$CALLS/order" 2>/dev/null)" = "put comment put " ] && ok || bad "B2: call order must be claim PUT, comment, PUT; got: $(tr '\n' ' ' < "$CALLS/order" 2>/dev/null)"
[ -f "$BUILD/COMMENTED" ] && ok || bad "B2: \$BUILD/COMMENTED must exist so the sweep SOP does not add an ALERTS line"
grep -q 'SKIP_ACTOR' "$H/logs/tproj.log" 2>/dev/null && ok || bad "B2: the project log must carry the SKIP_ACTOR line"

# claim-before-comment, asserted directly: a claim PUT that fails posts nothing
reset_calls; rm -f "$LEDGER"
LEDGER_PUT_FAIL=1 run_block
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable' "$SINK" && ok || bad "B7d: a failed claim PUT must defer (rc=$RC, $(cat "$SINK"))"
[ "$(cnt comments)" = 0 ] && ok || bad "B7d: a failed claim must post no comment, got $(cnt comments)"
[ ! -f "$BUILD/COMMENTED" ] && ok || bad "B7d: a deferral must not touch COMMENTED"

# ── B5 a repeat event -> no second comment ───────────────────────────────────
reset_calls; rm -f "$LEDGER"
run_block                      # the first ignore: comments once
reset_calls                    # keep the ledger the first run wrote
run_block
[ "$RC" = 3 ] && grep -q '^BUILD_REFUSED SKIP_ACTOR' "$SINK" && ok || bad "B5: the repeat must still refuse (rc=$RC, $(cat "$SINK"))"
[ "$(cnt comments)" = 0 ] && ok || bad "B5: a repeat event must post no second comment, got $(cnt comments)"
[ "$(cnt puts)" = 1 ] && ok || bad "B5: the repeat makes one detail-refresh PUT, got $(cnt puts)"
[ "$(jq -r '.detail | fromjson | .commented' "$LEDGER" 2>/dev/null)" = yes ] && ok || bad "B5: the refresh must keep commented=yes: $(cat "$LEDGER")"
# a NEW bot event in the same episode: still no comment
reset_calls
page 1 "$(ev 1002 mallory User 2026-10-04T20:00:00Z)" "$(ev 1003 dependabot[bot] Bot 2026-10-04T20:05:00Z)"
run_block
[ "$RC" = 3 ] && [ "$(cnt comments)" = 0 ] && ok || bad "B5: a new untrusted event in the same episode must not comment again (rc=$RC, comments=$(cnt comments))"
[ "$(jq -r '.detail | fromjson | .event | tostring' "$LEDGER" 2>/dev/null)" = 1003 ] && ok || bad "B5: the refresh must record the newest event id 1003: $(cat "$LEDGER")"

# ── B6 episode reset ─────────────────────────────────────────────────────────
reset_calls
page 1 "$(ev 1003 dependabot[bot] Bot 2026-10-04T20:05:00Z)" "$(ev 1004 alice User 2026-10-04T20:10:00Z)"
run_block
continued && ok || bad "B6: a listed human's newer label must build (rc=$RC, $(cat "$SINK"))"
[ "$(jq -r .status "$LEDGER" 2>/dev/null)" = allowed ] && ok || bad "B6: the allowed trigger must flip the row to allowed: $(cat "$LEDGER")"
reset_calls
page 1 "$(ev 1004 alice User 2026-10-04T20:10:00Z)" "$(ev 1005 renovate[bot] Bot 2026-10-04T20:20:00Z)"
run_block
[ "$RC" = 3 ] && [ "$(grep -c '^--- ' "$CALLS/comments" 2>/dev/null)" = 1 ] && ok || bad "B6: a new ignore episode must comment again (rc=$RC, comments=$(cnt comments))"

# ── B3 a bot -> ignored ─────────────────────────────────────────────────────
reset_fx; reset_calls
page 1 "$(ev 1101 dependabot[bot] Bot 2026-10-04T20:00:00Z)"
run_block
[ "$RC" = 3 ] && grep -q '^BUILD_REFUSED SKIP_ACTOR' "$SINK" && [ "$(grep -c '^--- ' "$CALLS/comments" 2>/dev/null)" = 1 ] && ok \
  || bad "B3a: an armed row must refuse a bot with one comment (rc=$RC, comments=$(cnt comments))"
reset_fx; reset_calls
page 1 "$(ev 1102 some-app[bot] Bot 2026-10-04T20:00:00Z)"
SET_RC=2 run_block
[ "$RC" = 3 ] && grep -q 'SKIP_ACTOR.*bot' "$SINK" && ok || bad "B3b: with no row a bot must be refused 'bot' (rc=$RC, $(cat "$SINK"))"
reset_fx; reset_calls
page 1 "$(ev 1103 alice User 2026-10-04T20:00:00Z)"
SET_RC=2 run_block
continued && plog | grep -q 'TRIGGER-ACTOR allow human-default actor=alice' && ok || bad "B3c: with no row a User builds as human-default (rc=$RC, $(plog))"
[ "$(cnt puts)" = 0 ] && ok || bad "B3c: no ledger write on allow"

# ── B4 the harness's own Archie-approve path -> buildable ───────────────────
# The event is copied from the live #4490 issue: labeled ai-build by
# cromford-builders[bot], type Bot, performed_via_github_app null.
reset_fx; reset_calls
page 1 "$(ev 32462008327 'cromford-builders[bot]' Bot 2026-10-04T21:16:43Z)"
run_block
continued && plog | grep -q 'TRIGGER-ACTOR allow self actor=cromford-builders\[bot\]' && ok || bad "B4: the harness App's own label must build as self (rc=$RC, $(cat "$SINK") $(plog))"
[ "$(cnt comments)" = 0 ] && ok || bad "B4: self posts no comment"
reset_fx; reset_calls
page 1 "$(ev 1201 some-operator User 2026-10-04T21:00:00Z cromford)"
run_block
continued && plog | grep -q 'allow self' && ok || bad "B4: performed_via_github_app=cromford must read as self (rc=$RC, $(plog))"
reset_fx; reset_calls
page 1 "$(ev 1202 operator User 2026-10-04T21:00:00Z)"
run_block
continued && plog | grep -q 'allow listed actor=operator' && ok || bad "B4: a PAT create by operator (any case) must be listed (rc=$RC, $(plog))"

# ── B15 an empty self-app list defers, it never refuses our own label ───────
# harness-self.sh resolves an unresolved registry to `[]`. The scratch harness
# has no lane-gate.sh, so HARNESS_SELF_APPS is exactly what the env says: here,
# nothing. Armed row and no row both: BUILD_DEFERRED, no comment, no ledger row.
for B15_SET in 0 2; do
  reset_fx; reset_calls; rm -f "$LEDGER"
  page 1 "$(ev 32462008327 'cromford-builders[bot]' Bot 2026-10-04T21:16:43Z)"
  HARNESS_SELF_APPS="" SET_RC=$B15_SET SET_VAL="operator" run_block
  [ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable (harness self-app list empty' "$SINK" && ok \
    || bad "B15 (SET_RC=$B15_SET): an empty self-app list must defer, not refuse our own App (rc=$RC, $(cat "$SINK"))"
  [ "$(cnt comments)" = 0 ] && ok || bad "B15 (SET_RC=$B15_SET): no comment expected, got $(cnt comments)"
  [ "$(cnt puts)" = 0 ] && ok || bad "B15 (SET_RC=$B15_SET): no ledger PUT expected, got $(cnt puts)"
  [ ! -f "$BUILD/COMMENTED" ] && ok || bad "B15 (SET_RC=$B15_SET): a deferral must not touch COMMENTED"
done

# ── B7 fail closed, never commented ─────────────────────────────────────────
reset_fx; reset_calls
page 1 "$(ev 1301 mallory User 2026-10-04T20:00:00Z)"
SET_RC=1 run_block
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable' "$SINK" && ok || bad "B7a: an unreadable allowlist must defer (rc=$RC, $(cat "$SINK"))"
[ "$(cnt gh)" = 0 ] && [ "$(cnt comments)" = 0 ] && ok || bad "B7a: an unreadable allowlist reads no events and posts nothing (gh=$(cnt gh))"
reset_calls
EV_RC=75 run_block
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable' "$SINK" && [ "$(cnt comments)" = 0 ] && ok || bad "B7b: a rate-limited events read must defer, uncommented (rc=$RC, $(cat "$SINK"))"
reset_calls
LEDGER_GET_RC=1 run_block
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable' "$SINK" && [ "$(cnt comments)" = 0 ] && ok || bad "B7c: an unreadable ledger on an ignore must defer, uncommented (rc=$RC, $(cat "$SINK"))"
reset_calls
H2="$T/h-nolib"; mkdir -p "$H2/bin/lib"; cp "$H/bin/fleet-conf.sh" "$H2/bin/"
HARNESS="$H2" run_block
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor lib missing' "$SINK" && ok || bad "B7e: a missing lib must defer (rc=$RC, $(cat "$SINK"))"
# a busy same-box lock defers too, without a comment
reset_calls; rm -f "$LEDGER"
( exec 9>"$H/locks/trigger-actor-tproj-BH-77.lock"; flock -n 9; exec sleep 5 ) & LPID=$!
wait_holder "$LPID"
run_block
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable' "$SINK" && [ "$(cnt comments)" = 0 ] && ok || bad "B7f: a held per-key lock must defer, uncommented (rc=$RC, $(cat "$SINK"))"

# ── B8 pagination ───────────────────────────────────────────────────────────
reset_fx; reset_calls
P1=(); for i in $(seq 1 100); do P1+=("$(ev $((5000+i)) alice User 2026-10-04T10:00:00Z bh comment commented)"); done
page 1 "${P1[@]}"
page 2 "$(ev 6001 mallory User 2026-10-04T20:00:00Z)"
run_block
[ "$RC" = 3 ] && grep -q 'SKIP_ACTOR' "$SINK" && ok || bad "B8: page 2's label must be read and refused (rc=$RC, $(cat "$SINK"))"
grep -q 'page=2' "$CALLS/gh" && ok || bad "B8: page 2 must be requested: $(cat "$CALLS/gh")"
reset_fx; reset_calls
for n in $(seq 1 10); do page "$n" "${P1[@]}"; done
run_block
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable' "$SINK" && grep -q cap "$SINK" && ok || bad "B8: ten full pages with no hit must defer 'cap' (rc=$RC, $(cat "$SINK"))"
[ "$(grep -c 'page=' "$CALLS/gh")" = 10 ] && ok || bad "B8: the read must stop at ten pages, made $(grep -c 'page=' "$CALLS/gh")"

# ── B9 no trigger ───────────────────────────────────────────────────────────
reset_fx; reset_calls
page 1 "$(ev 7001 mallory User 2026-10-04T20:00:00Z "" hotfix)" "$(ev 7002 mallory User 2026-10-04T20:01:00Z '' ai-build unlabeled)"
run_block
continued && plog | grep -q 'TRIGGER-ACTOR allow no-trigger' && ok || bad "B9: no labeled ai-build event must allow no-trigger (rc=$RC, $(plog))"

# ── B10 newest wins ─────────────────────────────────────────────────────────
reset_fx; reset_calls
page 1 "$(ev 8002 'dependabot[bot]' Bot 2026-10-04T20:30:00Z)" "$(ev 8001 alice User 2026-10-04T20:00:00Z)"
run_block
[ "$RC" = 3 ] && grep -q 'dependabot' "$SINK" && ok || bad "B10: the bot's later label must win (rc=$RC, $(cat "$SINK"))"
reset_fx; reset_calls; rm -f "$LEDGER"
page 1 "$(ev 8003 alice User 2026-10-04T20:30:00Z)" "$(ev 8004 'dependabot[bot]' Bot 2026-10-04T20:00:00Z)"
run_block
continued && plog | grep -q 'allow listed actor=alice' && ok || bad "B10: alice's later label must win (rc=$RC, $(plog))"

# ── B11 the in-app arm ──────────────────────────────────────────────────────
export FC_BP=/api/board BOARD_JSON="$T/fx/ticket.json"
ticket() { # ticket <userId> <name>  -> a ticket whose newest status_change is by them
  jq -nc --arg u "$1" --arg n "$2" '{id:"t1", key:"BH-77", status:"todo", activity:[
     {id:"a1", type:"status_change", actor:{userId:"u_7", name:"Dana Ruiz"}, createdAt:"2026-10-04T18:00:00Z"},
     {id:"a2", type:"turn", actor:{userId:"u_9", name:"Bot Relay"}, createdAt:"2026-10-04T21:00:00Z"},
     {id:"a3", type:"status_change", actor:{userId:$u, name:$n}, createdAt:"2026-10-04T20:00:00Z"},
     {id:"a4", type:"commented", actor:{userId:"u_9", name:"Bot Relay"}, createdAt:"2026-10-04T21:30:00Z"}]}' > "$BOARD_JSON"
}
reset_calls; rm -f "$LEDGER"
ticket u_9 'Bot <Relay>'
SET_RC=0 SET_VAL="u_7, Dana Ruiz" run_block
[ "$RC" = 3 ] && grep -q '^BUILD_REFUSED SKIP_ACTOR' "$SINK" && ok || bad "B11: an unlisted in-app actor must be refused (rc=$RC, $(cat "$SINK"))"
[ "$(cnt board-comments)" = 1 ] && ok || bad "B11: exactly one board comment, got $(cnt board-comments)"
grep -q 'POST https://app.example.test/api/board/tickets/77/comments' "$CALLS/curl" && ok || bad "B11: the comment goes to <prod><prefix>/tickets/<id>/comments: $(cat "$CALLS/curl")"
grep -q 'Bot &lt;Relay&gt;' "$CALLS/board-comments" && ! grep -q 'Bot <Relay>' "$CALLS/board-comments" && ok || bad "B11: the name must be HTML-escaped: $(cat "$CALLS/board-comments")"
[ "$(jq -r '.detail | fromjson | .source + "|" + .event' "$LEDGER" 2>/dev/null)" = "board|a3" ] && ok || bad "B11: the record must carry source=board, event=a3: $(cat "$LEDGER" 2>/dev/null)"
reset_calls
ticket u_7 'Dana Ruiz'
SET_RC=0 SET_VAL="u_7, Dana Ruiz" run_block
continued && plog | grep -q 'allow listed' && ok || bad "B11: a listed userId must build (rc=$RC, $(plog))"
reset_calls
ticket u_x 'Dana Ruiz'
SET_RC=0 SET_VAL="u_7, Dana Ruiz" run_block
continued && plog | grep -q 'allow listed' && ok || bad "B11: a listed display name (comma form) must build (rc=$RC, $(plog))"
reset_calls
ticket system 'System Harness'
SET_RC=0 SET_VAL="u_7" run_block
continued && plog | grep -q 'allow self' && ok || bad "B11: the project's own harness name must read as self (rc=$RC, $(plog))"
reset_calls
jq -nc '{id:"t1", status:"todo"}' > "$BOARD_JSON"
SET_RC=0 SET_VAL="u_7" run_block
continued && plog | grep -q 'no-activity' && ok || bad "B11: a board with no activity must build with a no-activity note (rc=$RC, $(plog))"
reset_calls
ticket u_9 'Bot Relay'
SET_RC=0 SET_VAL="u_7" BOARD_RC=7 run_block
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED trigger-actor unverifiable' "$SINK" && ok || bad "B11: an armed board that cannot be read must defer (rc=$RC, $(cat "$SINK"))"
reset_calls
SET_RC=2 run_block
continued && [ "$(cnt curl)" = 0 ] && ok || bad "B11: no row on an in-app board builds with no board read (rc=$RC, curl=$(cnt curl))"
unset FC_BP BOARD_JSON

# ── B12 kill switch ─────────────────────────────────────────────────────────
reset_fx; reset_calls
page 1 "$(ev 9001 mallory User 2026-10-04T20:00:00Z)"
SW_ON=1 run_block
continued && [ "$(cnt jobs)" = 0 ] && [ "$(cnt gh)" = 0 ] && ok || bad "B12: the switch must allow with no reads (rc=$RC, jobs=$(cnt jobs), gh=$(cnt gh))"
grep -q 'trigger-actor-off' "$CALLS/switch" && ok || bad "B12: the gate must read lane_switch trigger-actor-off"

# ── B13 unconfigured jobs client ────────────────────────────────────────────
reset_calls
page 1 "$(ev 9101 alice User 2026-10-04T20:00:00Z)"
JOBS_URL="" HARNESS_SECRET="" SET_RC=1 run_block
continued && plog | grep -q 'allow human-default' && ok || bad "B13: with no jobs client a User label must build (rc=$RC, $(cat "$SINK") $(plog))"

# ── L1-L9 lib units ─────────────────────────────────────────────────────────
# dec <row-value|-> <src> <id1> <id2> <type> <slug> <self> — ta_allowlist then ta_decide
dec() {
  local v="$1"; shift
  local rc=0 setrc=0; [ "$v" = - ] && setrc=2
  SET_RC=$setrc SET_VAL="$v" bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; _ta_deps; ta_allowlist tproj; ta_decide tproj "$@"' _ "$@" 2>/dev/null || rc=$?
  return "$rc"
}
[ "$(dec 'alice' gh 'cromford-builders[bot]' '' Bot '' '')" = "allow self" ] && ok || bad "L1: an App [bot] login is self"
[ "$(dec 'alice' gh 'cromford' '' Bot '' '')" = "allow self" ] && ok || bad "L2: a bare slug on a Bot user is self"
[ "$(dec 'alice' gh 'someone' '' User 'cromford-board' '')" = "allow self" ] && ok || bad "L3: performed_via_github_app is self"
[ "$(dec 'Alice' gh 'ALICE' '' User '' '')" = "allow listed" ] && ok || bad "L4: listing is case-insensitive"
[ "$(dec 'operator,alice' gh 'alice' '' User '' '')" = "allow listed" ] && [ "$(dec 'operator  alice' gh 'alice' '' User '' '')" = "allow listed" ] && ok || bad "L5: commas and spaces both separate entries"
[ "$(dec 'off' gh 'mallory' '' User '' '')" = "allow human-default" ] && [ "$(dec 'OFF' gh 'x[bot]' '' Bot '' '')" = "ignore bot" ] && ok || bad "L6: 'off' unarms the row (absent defaults apply)"
R=$(dec 'alice' gh 'mallory' '' User '' ''); RC=$?
[ "$R" = "ignore not-listed" ] && [ "$RC" = 1 ] && ok || bad "L7: an unlisted User on an armed row is ignored rc 1 (got '$R' rc $RC)"
[ "$(dec - gh 'renovate[bot]' '' Bot '' '')" = "ignore bot" ] && [ "$(dec - gh 'x' '' Bot '' '')" = "ignore bot" ] && ok || bad "L8: a Bot with no row is ignored 'bot'"
[ "$(dec - gh 'alice' '' User '' '')" = "allow human-default" ] && [ "$(dec - board 'u_9' 'Bot Relay' '' '' 'System Harness')" = "allow unarmed" ] && ok || bad "L9: a User with no row is human-default; an unarmed board allows"
# a foreign App is not self, even though it is a bot
[ "$(dec 'alice' gh 'intercom[bot]' '' Bot '' '')" = "ignore not-listed" ] && ok || bad "L1b: a foreign App is not the harness"
# ta_board_trigger picks the newest status_change among turn / commented rows
BOARD_JSON="$T/fx/ticket.json" ticket u_3 "Pat Lee"
BT=$(bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; ta_board_trigger "$1" "$2"; cat "$2"' _ "$T/fx/ticket.json" "$T/bt.out" 2>/dev/null)
[ "$BT" = "$(printf 'a3\tu_3\tPat Lee')" ] && ok || bad "L9b: ta_board_trigger must pick a3 (newest status_change), got '$BT'"
jq -c '{ticket: .}' "$T/fx/ticket.json" > "$T/fx/wrapped.json"
BT=$(bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; ta_board_trigger "$1" "$2"; cat "$2"' _ "$T/fx/wrapped.json" "$T/bt.out" 2>/dev/null)
[ "$BT" = "$(printf 'a3\tu_3\tPat Lee')" ] && ok || bad "L9c: the {ticket:…} envelope must be read too, got '$BT'"

# ── M1/M2 mutation (red-first) ──────────────────────────────────────────────
# M1: the pipeline with the block deleted lets B2's unlisted user build.
reset_fx; reset_calls; rm -f "$LEDGER"
page 1 "$(ev 1002 mallory User 2026-10-04T20:00:00Z)"
: > "$T/empty-block.sh"
SET_RC=0 SET_VAL="operator alice" run_block "$T/empty-block.sh"
if [ "$RC" = 3 ] && grep -q SKIP_ACTOR "$SINK"; then bad "M1: with the block deleted B2 still refused — the suite is not driving the block"
else ok; fi
# M2: a lib with the hs_ours self check stripped refuses the harness's own label.
reset_fx; reset_calls; rm -f "$LEDGER"
page 1 "$(ev 32462008327 'cromford-builders[bot]' Bot 2026-10-04T21:16:43Z)"
H3="$T/h-m2"; cp -r "$H" "$H3"
sed -i 's/hs_ours(\$apps)/false/' "$H3/bin/lib/trigger-actor.sh"
if grep -q 'hs_ours(\$apps)' "$H3/bin/lib/trigger-actor.sh" || ! [ -s "$H3/bin/lib/trigger-actor.sh" ]; then bad "M2: the mutation did not apply"
else
  HARNESS="$H3" SET_RC=0 SET_VAL="operator alice" run_block
  if continued && grep -q 'allow self' "$BUILD/pipeline.log" 2>/dev/null; then bad "M2: with the self check stripped B4 still passed as self"
  else ok; fi
fi

echo "trigger-actor-gate.bh-4490: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
