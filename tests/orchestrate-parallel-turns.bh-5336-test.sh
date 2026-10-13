#!/bin/bash
# tests/orchestrate-parallel-turns.bh-5336-test.sh — orchestrator turns run in
# parallel (BH-5336). One long turn never holds a new message; a third message
# waits only for a free slot; two turns that edit different STATE.md sections
# both keep their edits; concurrent conversation-log appends never interleave;
# a reply inside an in-flight turn's thread waits for that turn and nothing else
# does; a restarted orchestrate.sh never runs an in-flight command twice; and
# each turn's briefing lists the other turns in flight.
#
# bin/orchestrate.sh pins HARNESS=/root/harness and ORC=/root/orchestrator, so
# each turn is assembled from its production blocks lifted VERBATIM, in the
# order the script runs them: the sidecar read, `# >>> turn exit`,
# `# >>> turn text`, `# >>> turn queue status`, a STUB model call (a separate
# process, so killing the turn's bash leaves it running in the group), then
# `# >>> no reply`, `# >>> turn state merge`, `# >>> reply status` and
# `# >>> turn done`. Every turn is spawned with setsid, as bin/poll-commands.sh
# spawns it. curl and beat.sh are stubs that log what they get.
#
# M1-M3 mutate bin/lib/orc-turns.sh and require the case that pins it to go red.
#
# Run from anywhere: tests/orchestrate-parallel-turns.bh-5336-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

SRC="$DIR/bin/orchestrate.sh"
LIB="$DIR/bin/lib/orc-turns.sh"
MERGE_PY="$DIR/bin/orc-state-merge.py"
META_BLOCK=$(sed -n '/^ORIGIN=""; CMD_ID=""/,/^\[ "\$TG_OK" = 1 \]/p' "$SRC")
EXIT_BLOCK=$(sed -n '/^# >>> turn exit/,/^# <<< turn exit/p' "$SRC")
TEXT_BLOCK=$(sed -n '/^# >>> turn text/,/^# <<< turn text/p' "$SRC")
QUEUE_BLOCK=$(sed -n '/^# >>> turn queue status/,/^# <<< turn queue status/p' "$SRC")
NOREPLY_BLOCK=$(sed -n '/^# >>> no reply/,/^# <<< no reply/p' "$SRC")
MERGEB_BLOCK=$(sed -n '/^# >>> turn state merge/,/^# <<< turn state merge/p' "$SRC")
STATUS_BLOCK=$(sed -n '/^# >>> reply status/,/^# <<< reply status/p' "$SRC")
DONE_BLOCK=$(sed -n '/^# >>> turn done/,/^# <<< turn done/p' "$SRC")
COMPOSE_FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$SRC")
iso='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'
now_ms() { date +%s%3N; }

# --- L0: the lifts are real and sit where the script runs them --------------
_ln() { grep -n -m1 -- "$1" "$SRC" | cut -d: -f1; }
L_CLAIM=$(grep -n 'orct_claim ' <<<"$QUEUE_BLOCK" | head -n1 | cut -d: -f1)
L_GATE=$(grep -n 'orct_gate ' <<<"$QUEUE_BLOCK" | head -n1 | cut -d: -f1)
L_INFL=$(grep -n 'orct_inflight_render ' <<<"$QUEUE_BLOCK" | head -n1 | cut -d: -f1)
L_BEGIN=$(grep -n 'orct_state_begin ' <<<"$QUEUE_BLOCK" | head -n1 | cut -d: -f1)
[ -n "$L_CLAIM" ] && [ -n "$L_GATE" ] && [ -n "$L_INFL" ] && [ -n "$L_BEGIN" ] \
  && [ "$L_CLAIM" -lt "$L_GATE" ] && [ "$L_GATE" -lt "$L_INFL" ] && [ "$L_INFL" -lt "$L_BEGIN" ] \
  && ok || bad "L0 the queue-status block must call orct_claim, orct_gate, orct_inflight_render, orct_state_begin in that order"
eq L0_no_flock6     "$(grep -c 'flock 6\|flock -n 6' "$SRC")" 0
eq L0_no_turn_lock  "$(grep -c '\.turn\.lock' "$SRC")" 0
L_NR=$(_ln '^# <<< no reply'); L_MB=$(_ln '^# >>> turn state merge'); L_DEL=$(_ln '^deliver_reply "\$OUT"')
[ -n "$L_MB" ] && [ "${L_NR:-0}" -lt "$L_MB" ] && [ "$L_MB" -lt "${L_DEL:-0}" ] && ok \
  || bad "L0 # >>> turn state merge must sit after # <<< no reply and before deliver_reply \"\$OUT\" (no reply $L_NR, merge $L_MB, deliver $L_DEL)"
grep -q 'orct_state_merge' <<<"$MERGEB_BLOCK" && ok || bad "L0 the turn-state-merge block must call orct_state_merge"
L_RS=$(_ln '^# <<< reply status'); L_TD=$(_ln '^# >>> turn done')
[ -n "$L_TD" ] && [ "${L_RS:-0}" -lt "$L_TD" ] && grep -q 'orct_done' <<<"$DONE_BLOCK" && ok || bad "L0 # >>> turn done (orct_done) must follow # <<< reply status"
RUN_TURN=$(sed -n '/^run_turn() {/,/^}/p' "$SRC")
sed -n '/if orc_fresh; then/,/RC=\$?/p' <<<"$RUN_TURN" | grep -q -- '--session-id "\$ORC_TURN_SID"' && ok || bad "L0 run_turn's fresh call must carry --session-id"
grep -q 'reply_to_message_id' <<<"$META_BLOCK" && grep -q 'message_ts' <<<"$META_BLOCK" && ok || bad "L0 the sidecar read must take message_id, reply_to_message_id and message_ts"

setup() { # setup <name> -> prints the case dir (a scratch HARNESS)
  local c="$T/$1"
  scratch_rm "$c" || return 1
  mkdir -p "$c/bin" "$c/logs" "$c/flags" "$c/fake" "$c/orc/state" "$c/env" "$c/in"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$c/bin/"
  [ -f "$MERGE_PY" ] && cp "$MERGE_PY" "$c/bin/"
  printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=s3cret-fixture\n' > "$c/env/global.env"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
url=""; body=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case " $* " in *" @- "*) body=$(cat) ;; esac
case "$url" in
  */api/commands/*/ack) id="${url%/ack}"; id="${id##*/}"
    printf 'ACK %s %s\n' "$id" "$(jq -r .result <<<"$body" 2>/dev/null)" >> "$CURL_LOG" ;;
  *) printf 'CURL %s\n' "$url" >> "$CURL_LOG" ;;
esac
FAKE
  # The stub model call: a separate process that records its start, edits the
  # turn's STATE/facts copies when the case asks, and holds until released.
  cat > "$c/fake/claude-stub" <<'STUB'
#!/bin/bash
id="$1"
echo "$id" >> "$HARNESS/claude.calls"
date +%s%3N > "$HARNESS/start-$id.tmp" && mv -f "$HARNESS/start-$id.tmp" "$HARNESS/start-$id"
[ -n "${ORC_TURN_STATE:-}" ] && [ -f "$HARNESS/edit-$id.state" ] && cp "$HARNESS/edit-$id.state" "$ORC_TURN_STATE"
[ -n "${ORC_TURN_FACTS:-}" ] && [ -f "$HARNESS/edit-$id.facts" ] && cp "$HARNESS/edit-$id.facts" "$ORC_TURN_FACTS"
i=0; until [ -f "$HARNESS/release-$id" ] || [ "$i" -ge 600 ]; do sleep 0.1; i=$((i+1)); done
echo "answer $id"
STUB
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEATS"\n' > "$c/bin/beat.sh"
  chmod +x "$c/fake/curl" "$c/fake/claude-stub" "$c/bin/beat.sh"
  for f in bin/lib/env-path.sh bin/lib/orc-reply-ledger.sh bin/lib/orc-dedupe.sh; do
    scratch_install_closure "$f" "$c" >/dev/null || echo "setup: cannot install $f" >&2
  done
  [ -f "$LIB" ] && { scratch_install_closure bin/lib/orc-turns.sh "$c" >/dev/null || echo "setup: cannot install orc-turns" >&2; }
  # The turn, in the order bin/orchestrate.sh runs its blocks.
  {
    printf '%s\n' '#!/bin/bash' 'set -uo pipefail' 'MSGF="$1"' 'TYPER=""' \
      '. "$HARNESS/bin/lib/env-path.sh"; HENV=$(harness_env_dir "$HARNESS")'
    printf '%s\n' "$META_BLOCK" "$EXIT_BLOCK" "$TEXT_BLOCK" "${M_QUEUE-$QUEUE_BLOCK}"
    printf '%s\n' 'printf "%s" "${ORC_INFLIGHT_TEXT:-}" > "$HARNESS/inflight-${CMD_ID:-x}"' \
      'OUT=$("$HARNESS/fake/claude-stub" "${CMD_ID:-x}")'
    printf '%s\n' "$NOREPLY_BLOCK" "$MERGEB_BLOCK" 'trap - EXIT' 'ledger_reply "$OUT" "$REPLY_ERR"' \
      "$STATUS_BLOCK" "$DONE_BLOCK" 'exit 0'
  } > "$c/turn.sh"
  printf '%s' "$c"
}

# spawn <dir> <id> <text> [extra-meta-json] — one message, as the poller spawns it.
spawn() {
  local c="$1" id="$2" m="$1/in/msg-$2" x="${4:-}"
  [ -n "$x" ] || x='{}'
  printf '%s' "$3" > "$m"
  jq -nc --arg id "$id" --argjson x "$x" '{command_id:$id, origin:"dash"} + $x' > "$m.meta"
  now_ms > "$c/spawn-$id"
  env -u HARNESS_ENV_DIR -u CMD_ID -u ORC_TURN_STATE -u ORC_TURN_FACTS -u ORC_TURN_ERR -u ORC_TURN_TMP \
    PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" BEATS="$c/beats.jsonl" \
    HARNESS="$c" ORC="$c/orc" ORC_REPLY_LEDGER_BACKOFF_S=0 ORC_TURN_POLL_S=0.2 \
    ORC_DEDUPE_SECS="${DEDUPE:-120}" ORC_TURN_CONCURRENCY="${CONC:-4}" ORC_TURN_STALE_S="${STALE:-90}" \
    setsid bash "$c/turn.sh" "$m" </dev/null >>"$c/stdout.log" 2>>"$c/stderr.log" &
  echo "$!" > "$c/pid-$id"
  echo "$!" >> "$c/pids"
}
waitf() { # waitf <file> [tenths] — rc 0 once the file exists
  local i=0 n="${2:-100}"
  while [ ! -e "$1" ] && [ "$i" -lt "$n" ]; do sleep 0.1; i=$((i+1)); done
  [ -e "$1" ]
}
waitg() { # waitg <file> <pattern> [tenths] — rc 0 once the file has the pattern
  local i=0 n="${3:-100}"
  while ! grep -q -- "$2" "$1" 2>/dev/null && [ "$i" -lt "$n" ]; do sleep 0.1; i=$((i+1)); done
  grep -q -- "$2" "$1" 2>/dev/null
}
release() { : > "$1/release-$2"; }
finish() { # finish <dir> — release every stub and wait (bounded) for every turn
  local c="$1" p i
  for p in "$c"/spawn-*; do [ -e "$p" ] && release "$c" "${p##*/spawn-}"; done
  for p in $(cat "$c/pids" 2>/dev/null); do
    i=0; while kill -0 "$p" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i+1)); done
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  return 0
}
started_within() { # started_within <dir> <id> <ms> — the stub started that soon after the spawn
  local c="$1" s e
  waitf "$c/start-$2" $(( $3 / 100 + 10 )) || return 1
  s=$(cat "$c/spawn-$2"); e=$(cat "$c/start-$2")
  [ $(( e - s )) -le "$3" ]
}
ackline() { grep -n -m1 -- "^ACK $2 $3" "$1/curl.log" 2>/dev/null | cut -d: -f1; }
cnt() { local n=0; [ -f "$1" ] && n=$(grep -c -- "$2" "$1"); echo "${n:-0}"; }
calls_of() { cnt "$1/claude.calls" "^$2\$"; }

# --- P1: a long turn does not delay a second message -------------------------
p1() {
  local c="$1"
  spawn "$c" 101 "check every box for an hour"
  waitf "$c/start-101" 50
  sleep 0.5
  spawn "$c" 102 "status"
  started_within "$c" 102 2000 && echo yes > "$c/b-fast" || echo no > "$c/b-fast"
  release "$c" 102
  waitg "$c/curl.log" '^ACK 102 answered:' 50
  release "$c" 101
  waitg "$c/curl.log" '^ACK 101 answered:' 50
  finish "$c"
}
C=$(setup p1); p1 "$C"
eq P1_second_starts_within_2s "$(cat "$C/b-fast")" yes
A1=$(ackline "$C" 101 answered:); B1=$(ackline "$C" 102 answered:)
[ -n "$B1" ] && [ -n "$A1" ] && [ "$B1" -lt "$A1" ] && ok || bad "P1 B's answered ack must land before A's (A line ${A1:-none}, B line ${B1:-none})"
grep -Eq "^ACK 102 answered:$iso\$" "$C/curl.log" && ok || bad "P1 B is acked answered:<iso>"
eq P1_b_never_queued "$(grep -c '^ACK 102 queued_behind' "$C/curl.log")" 0

# --- P2: with a cap of 2, the third message waits for a slot, then runs ------
p2() {
  local c="$1"
  CONC=2 spawn "$c" 101 "first long ask"; waitf "$c/start-101" 50
  CONC=2 spawn "$c" 102 "second long ask"; waitf "$c/start-102" 50
  CONC=2 spawn "$c" 103 "third ask"
  waitg "$c/curl.log" '^ACK 103 queued_behind:' 30
  sleep 0.6
  [ -e "$c/start-103" ] && echo early > "$c/c-early"
  release "$c" 101
  waitf "$c/start-103" 50 && echo yes > "$c/c-ran"
  release "$c" 102; release "$c" 103
  waitg "$c/curl.log" '^ACK 103 answered:' 50
  finish "$c"
}
C=$(setup p2); p2 "$C"
eq P2_queued_behind_oldest "$(grep -m1 '^ACK 103 ' "$C/curl.log" | cut -d' ' -f3)" "queued_behind:101"
eq P2_waited_for_slot      "$(cat "$C/c-early" 2>/dev/null)" ""
eq P2_ran_after_slot       "$(cat "$C/c-ran" 2>/dev/null)" yes
eq P2_calls_each_once      "$(sort "$C/claude.calls" 2>/dev/null | tr '\n' ' ')" "101 102 103 "
grep -q '^ACK 103 running:' "$C/curl.log" && grep -q '^ACK 103 answered:' "$C/curl.log" && ok || bad "P2 the third message goes running then answered"

# --- P3: two turns edit STATE.md; neither overwrites the other ---------------
STATE_BASE=$'# Working memory\n\n## Alpha\nold alpha\n\n## Beta\nold beta\n'
p3() { # p3 <dir> <file STATE|facts> <A edit> <B edit>
  local c="$1" f="$2" ext
  ext=state; [ "$f" = facts.md ] && ext=facts
  printf '%s' "$STATE_BASE" > "$c/orc/$f"
  printf '%s' "$3" > "$c/edit-111.$ext"; printf '%s' "$4" > "$c/edit-112.$ext"
  spawn "$c" 111 "turn A edits"; spawn "$c" 112 "turn B edits"
  waitf "$c/start-111" 50; waitf "$c/start-112" 50
  release "$c" 111; waitg "$c/curl.log" '^ACK 111 answered:' 50
  release "$c" 112; waitg "$c/curl.log" '^ACK 112 answered:' 50
  finish "$c"
}
A_ALPHA=$'# Working memory\n\n## Alpha\nalpha by A\n\n## Beta\nold beta\n'
B_BETA=$'# Working memory\n\n## Alpha\nold alpha\n\n## Beta\nbeta by B\n'
B_ALPHA=$'# Working memory\n\n## Alpha\nalpha by B\n\n## Beta\nold beta\n'
C=$(setup p3); p3 "$C" STATE.md "$A_ALPHA" "$B_BETA"
grep -q '^alpha by A$' "$C/orc/STATE.md" 2>/dev/null && ok || bad "P3 A's Alpha edit must survive: $(cat "$C/orc/STATE.md" 2>/dev/null)"
grep -q '^beta by B$' "$C/orc/STATE.md" 2>/dev/null && ok || bad "P3 B's Beta edit must survive: $(cat "$C/orc/STATE.md" 2>/dev/null)"
eq P3_old_text_gone "$(grep -c '^old ' "$C/orc/STATE.md" 2>/dev/null)" 0
C=$(setup p3b); p3 "$C" STATE.md "$A_ALPHA" "$B_ALPHA"
grep -q '^alpha by A$' "$C/orc/STATE.md" 2>/dev/null && grep -q '^alpha by B$' "$C/orc/STATE.md" 2>/dev/null && ok \
  || bad "P3b both Alpha edits must be kept: $(cat "$C/orc/STATE.md" 2>/dev/null)"
eq P3b_concurrent_heading "$(grep -c '^## Alpha (concurrent edit from turn c112)$' "$C/orc/STATE.md" 2>/dev/null)" 1
C=$(setup p3c); p3 "$C" facts.md "$A_ALPHA" "$B_BETA"
grep -q '^alpha by A$' "$C/orc/facts.md" 2>/dev/null && grep -q '^beta by B$' "$C/orc/facts.md" 2>/dev/null && ok \
  || bad "P3c facts.md keeps both turns' sections: $(cat "$C/orc/facts.md" 2>/dev/null)"
# P3d: the merge script fails (its base is unreadable) — the live file is
# untouched and one ALERTS line names the turn's copy.
C=$(setup p3d); printf '%s' "$STATE_BASE" > "$C/orc/STATE.md"; cp "$C/orc/STATE.md" "$C/state.before"
( export HARNESS="$C" ORC="$C/orc" CMD_ID=150
  . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 1
  orct_state_begin c150 && printf '%s' "$A_ALPHA" > "$ORC_TURN_STATE" \
    && rm -f "$ORC_TURN_STATE.base" && mkdir "$ORC_TURN_STATE.base" && orct_state_merge c150 ) 2>>"$C/stderr.log"
cmp -s "$C/orc/STATE.md" "$C/state.before" && ok || bad "P3d a failed merge must leave STATE.md byte-identical"
eq P3d_one_alert "$(grep -c 'STATE.md merge failed.*state/turns/c150/STATE.md' "$C/logs/ALERTS.log" 2>/dev/null)" 1

# --- P4: concurrent conversation-log appends never interleave ---------------
# Each record is a ~60-80 KB message M<n> and reply R<n>, far over a pipe's
# atomic write size, so an unlocked append splits them.
p4() { # p4 <dir> <max-bytes>
  local c="$1" n
  [ -x "$c/bin/orc-context.sh" ] || cp "$DIR/bin/orc-context.sh" "$c/bin/"
  for n in $(seq 1 20); do
    yes "M$n" | head -n 20000 > "$c/m$n"; yes "R$n" | head -n 20000 > "$c/r$n"
  done
  for n in $(seq 1 20); do
    ORC_CONTEXT_LOG="$c/conv.md" ORC_CONTEXT_MAX_BYTES="$2" "$c/bin/orc-context.sh" append "lane$n" "$c/m$n" "$c/r$n" &
  done
  wait
}
p4_check() { # p4_check <log> — "<records> <bad records> <starts on a ### header: yes|no>"
  python3 -I - "$1" <<'PY'
import re, sys
t = open(sys.argv[1], errors="replace").read()
recs = [r for r in re.split(r"(?m)^### ", t)[1:]]
bad = 0
for r in recs:
    m = re.search(r"\nOPERATOR: (.*)\nREPLY: (.*)\n$", r, re.S)
    if not m:
        bad += 1; continue
    ms = set(m.group(1).split()); rs = set(m.group(2).split())
    if len(ms) != 1 or len(rs) != 1 or next(iter(ms))[1:] != next(iter(rs))[1:] or len(m.group(2)) < 60000:
        bad += 1
print(len(recs), bad, "yes" if t.startswith("### ") else "no")
PY
}
if grep -q 'ORC_CONTEXT_LOG' "$DIR/bin/orc-context.sh"; then
  C=$(setup p4); p4 "$C" 10000000
  read -r P4N P4BAD _ <<<"$(p4_check "$C/conv.md")"
  eq P4_records "$P4N" 20
  eq P4_no_interleave "$P4BAD" 0
  C=$(setup p4t); p4 "$C" 300000
  read -r P4N P4BAD P4FIRST <<<"$(p4_check "$C/conv.md")"
  [ "${P4N:-0}" -ge 1 ] && ok || bad "P4t the trimmed log must keep at least one record"
  eq P4t_no_interleave "$P4BAD" 0
  eq P4t_starts_on_header "$P4FIRST" yes
  eq P4t_lock_file "$( [ -e "$C/conv.md.lock" ] && echo yes)" yes
else
  bad "P4 bin/orc-context.sh has no ORC_CONTEXT_LOG seam, so its append cannot be driven in scratch"
fi

# --- P5: a reply in an in-flight turn's thread waits; nothing else does -----
p5() {
  local c="$1"
  spawn "$c" 201 "slack top-level ask" '{"transport":"slack","chat_id":"C1","thread_id":"T1","message_ts":"T1"}'
  waitf "$c/start-201" 50
  spawn "$c" 202 "slack reply in T1" '{"transport":"slack","chat_id":"C1","thread_id":"T1","message_ts":"T2"}'
  spawn "$c" 203 "slack other thread" '{"transport":"slack","chat_id":"C1","thread_id":"T3","message_ts":"T3"}'
  started_within "$c" 203 2000 && echo yes > "$c/c-fast"
  waitg "$c/curl.log" '^ACK 202 queued_behind:' 30
  sleep 0.6
  [ -e "$c/start-202" ] && echo early > "$c/b-early"
  release "$c" 203; release "$c" 201
  waitf "$c/start-202" 50 && echo yes > "$c/b-ran"
  finish "$c"
}
C=$(setup p5); p5 "$C"
eq P5_unrelated_not_held  "$(cat "$C/c-fast" 2>/dev/null)" yes
eq P5_reply_queued        "$(grep -m1 '^ACK 202 ' "$C/curl.log" | cut -d' ' -f3)" "queued_behind:201"
eq P5_reply_waited        "$(cat "$C/b-early" 2>/dev/null)" ""
eq P5_reply_ran_after     "$(cat "$C/b-ran" 2>/dev/null)" yes
p5t() {
  local c="$1"
  spawn "$c" 211 "telegram ask" '{"chat_id":"-1000000000000","thread_id":"9","message_id":55}'
  waitf "$c/start-211" 50
  spawn "$c" 212 "telegram reply to it" '{"chat_id":"-1000000000000","thread_id":"9","message_id":56,"reply_to_message_id":55}'
  spawn "$c" 213 "same topic, no reply" '{"chat_id":"-1000000000000","thread_id":"9","message_id":57}'
  started_within "$c" 213 2000 && echo yes > "$c/d-fast"
  waitg "$c/curl.log" '^ACK 212 queued_behind:' 30
  sleep 0.6
  [ -e "$c/start-212" ] && echo early > "$c/b-early"
  finish "$c"
}
C=$(setup p5t); p5t "$C"
eq P5t_topic_not_held "$(cat "$C/d-fast" 2>/dev/null)" yes
eq P5t_reply_queued   "$(grep -m1 '^ACK 212 ' "$C/curl.log" | cut -d' ' -f3)" "queued_behind:211"
eq P5t_reply_waited   "$(cat "$C/b-early" 2>/dev/null)" ""
p5n() {
  local c="$1"
  spawn "$c" 221 "no ids one" '{"chat_id":"-1000000000000"}'
  waitf "$c/start-221" 50
  spawn "$c" 222 "no ids two" '{"chat_id":"-1000000000000"}'
  started_within "$c" 222 2000 && echo yes > "$c/b-fast"
  finish "$c"
}
C=$(setup p5n); p5n "$C"
eq P5n_no_fields_no_wait "$(cat "$C/b-fast" 2>/dev/null)" yes

# --- P6: kill the turn's bash mid-turn, restart it — no second model call ----
p6() {
  local c="$1" t0 t1 pid i
  STALE=5 DEDUPE=0 spawn "$c" 301 "restart the project-3 box"
  waitf "$c/start-301" 50
  sleep 1.2
  pid=$(cat "$c/pid-301"); kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep 1.2
  cp "$c/curl.log" "$c/curl.before" 2>/dev/null; cp "$c/beats.jsonl" "$c/beats.before" 2>/dev/null || : > "$c/beats.before"
  t0=$(now_ms)
  STALE=5 DEDUPE=0 spawn "$c" 301 "restart the project-3 box"
  pid=$(cat "$c/pid-301"); i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  kill -0 "$pid" 2>/dev/null && echo hung > "$c/rerun-hung"
  wait "$pid" 2>/dev/null; echo "$?" > "$c/rerun-rc"
  t1=$(now_ms); echo $(( t1 - t0 )) > "$c/rerun-ms"
  calls_of "$c" 301 > "$c/calls-after-rerun"
  # P6b: the stub ends; with nothing left in the group the claim goes stale.
  release "$c" 301; sleep 1.5
  cp "$c/orc/state/turns/c301.json" "$c/claim-after-stub" 2>/dev/null
  # Bounded wait for the claim to age past ORC_TURN_STALE_S=5 (up to 12 s).
  ( export HARNESS="$c" ORC="$c/orc" ORC_TURN_STALE_S=5; . "$c/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
    i=0; while orct_live "$c/orc/state/turns/c301.json" && [ "$i" -lt 120 ]; do sleep 0.1; i=$((i+1)); done
    orct_live "$c/orc/state/turns/c301.json" ) && echo live > "$c/claim-state" || echo stale > "$c/claim-state"
  finish "$c"
}
C=$(setup p6); p6 "$C"
eq P6_one_model_call   "$(cat "$C/calls-after-rerun")" 1
eq P6_rerun_exits      "$(cat "$C/rerun-hung" 2>/dev/null)" ""
eq P6_rerun_rc         "$(cat "$C/rerun-rc")" 0
[ "$(cat "$C/rerun-ms")" -le 2000 ] && ok || bad "P6 the second run must exit within 2 s, took $(cat "$C/rerun-ms") ms"
eq P6_no_new_ack       "$(diff <(cat "$C/curl.before" 2>/dev/null) <(cat "$C/curl.log" 2>/dev/null) | grep -c '^> ACK 301')" 0
eq P6_no_noreply_beat  "$(diff "$C/beats.before" <(cat "$C/beats.jsonl" 2>/dev/null) | grep -c '^>')" 0
grep -q 'command 301 already in flight' "$C/logs/agent-rules.log" 2>/dev/null && ok || bad "P6 the second run must log one 'already in flight' line"
eq P6b_claim_stale     "$(cat "$C/claim-state")" stale
# P6c: a command that already has a .done marker never reaches the model.
C=$(setup p6c); mkdir -p "$C/orc/state/turns"; : > "$C/orc/state/turns/c303.done"
spawn "$C" 303 "already answered"; finish "$C"
eq P6c_no_model_call   "$(calls_of "$C" 303)" 0
eq P6c_no_ack          "$(cnt "$C/curl.log" '^ACK 303')" 0

# --- P7: each turn's briefing lists the other turns in flight ---------------
C=$(setup p7)
spawn "$C" 401 "check box project-3 now"; waitf "$C/start-401" 50
spawn "$C" 402 "what is on the board"; waitf "$C/start-402" 50
INFL=$(cat "$C/inflight-402" 2>/dev/null)
finish "$C"
grep -q 'turn 401' <<<"$INFL" && grep -q 'check box project-3 now' <<<"$INFL" && ok || bad "P7 B's in-flight text must name turn 401 and its first line, got [$INFL]"
grep -Eq '^- turn 401 \(running, [0-9]+m\): check box project-3 now$' <<<"$INFL" && ok || bad "P7 the in-flight line shape, got [$INFL]"
grep -q 'turn 402' "$C/inflight-401" 2>/dev/null && bad "P7 A started alone, so its list must not name 402" || ok
compose() { # compose <inflight-text> [turn-state] — the lifted compose_v2_prompt
  local c="$T/p7"
  env -u ORC_TURN_STATE -u ORC_TURN_FACTS ORC_INFLIGHT_TEXT="$1" ${2:+ORC_TURN_STATE="$2"} ${2:+ORC_TURN_FACTS="$2.facts"} \
    HARNESS="$c" ARCHIE_ORC_DIR="$c/orc" bash -c "META_TRANSPORT=telegram; ORIGIN=dash; TEXT='hi'
    $COMPOSE_FN
    compose_v2_prompt" 2>/dev/null
}
PR=$(compose "$INFL")
HL=$(grep -n -m1 '^=== OTHER TURNS IN FLIGHT' <<<"$PR" | cut -d: -f1); RL=$(grep -n -m1 '^=== RECENT CONVERSATION' <<<"$PR" | cut -d: -f1)
[ -n "$HL" ] && [ -n "$RL" ] && [ "$HL" -lt "$RL" ] && ok || bad "P7 the briefing must carry === OTHER TURNS IN FLIGHT before === RECENT CONVERSATION"
grep -q 'check box project-3 now' <<<"$PR" && ok || bad "P7 the briefing must carry the other turn's first line"
eq P7_absent_when_alone "$(compose "" | grep -c 'OTHER TURNS IN FLIGHT')" 0
printf '## Mine\nturn copy\n' > "$C/turn-state.md"
PR=$(compose "" "$C/turn-state.md")
grep -q '^turn copy$' <<<"$PR" && ok || bad "P7 with ORC_TURN_STATE set, the briefing must read the turn's copy"
grep -q "This turn's STATE.md is $C/turn-state.md" <<<"$PR" && ok || bad "P7 the briefing must name the turn's STATE.md copy"

# --- K1/K2: the cap knob ----------------------------------------------------
cap_of() { # cap_of <name> <env assignments...>
  local c="$T/k1-$1"; shift
  scratch_rm "$c"; mkdir -p "$c/flags" "$c/logs"
  [ -f "$LIB" ] || { echo none; return; }
  scratch_install_closure bin/lib/orc-turns.sh "$c" >/dev/null
  [ "${CONT:-0}" = 1 ] && : > "$c/flags/orchestrator-continue"
  printf 'MemAvailable:    3145728 kB\n' > "$c/meminfo"
  env -u ORC_TURN_CONCURRENCY -u ORC_TURN_WORKER_MEM_MB "$@" HARNESS="$c" ORC="$c/orc" ORC_TURN_MEMINFO="$c/meminfo" \
    bash -c '. "$HARNESS/bin/lib/orc-turns.sh"; orct_cap' 2>/dev/null
}
eq K1_garbage_is_default "$(cap_of abc ORC_TURN_CONCURRENCY=abc)" 4
eq K1_unset_is_default   "$(cap_of unset X=1)" 4
eq K1_zero_from_memory   "$(cap_of zero ORC_TURN_CONCURRENCY=0 ORC_TURN_WORKER_MEM_MB=1024)" 3
eq K1_continuation_is_1  "$(CONT=1 cap_of cont ORC_TURN_CONCURRENCY=8)" 1
eq K2_registry "$(jq -r '.knobs[] | select(.env == "ORC_TURN_CONCURRENCY") | "\(.default) \(.min) \(.max)"' "$DIR/catalog/lanes.d/orc-monitor.json")" "4 0 32"
eq K2_stale_knob "$(jq -r '.knobs[] | select(.env == "ORC_TURN_STALE_S") | .default' "$DIR/catalog/lanes.d/orc-monitor.json")" 90

# --- U1: a turn is priced from its own session file only ---------------------
C="$T/u1"; scratch_rm "$C"; mkdir -p "$C/proj"
printf '{"timestamp":"2099-01-01T00:00:00Z","message":{"usage":{"input_tokens":10,"output_tokens":1}}}\n' > "$C/proj/sid-a.jsonl"
printf '{"timestamp":"2099-01-01T00:00:00Z","message":{"usage":{"input_tokens":500,"output_tokens":7}}}\n' > "$C/proj/sid-b.jsonl"
eq U1_session_only "$("$DIR/bin/claude-usage.sh" 0 "$C/proj" --session=sid-a 2>/dev/null)" "10|1|0|0"
eq U1_unscoped_sums "$("$DIR/bin/claude-usage.sh" 0 "$C/proj" 2>/dev/null)" "510|8|0|0"

# --- M1-M3: mutants of bin/lib/orc-turns.sh ----------------------------------
mutant() { # mutant <dir> <sed-expr> — replace the case's lib with a mutant
  sed "$2" "$LIB" > "$1/bin/lib/orc-turns.sh"
}
if [ -f "$LIB" ]; then
  C=$(setup m1); mutant "$C" 's/if \$run < \$cap and \$rank != null and \$rank < (\$cap - \$run)/if $rank != null/'
  p2 "$C"
  [ "$(cat "$C/c-early" 2>/dev/null)" = early ] && ok || bad "M1 a gate with no cap check must turn P2 red"
  C=$(setup m2); mutant "$C" 's|python3 -I "\$py" "\$live" "\$base" "\$mine" "\$key"|cat "$mine"|'
  p3 "$C" STATE.md "$A_ALPHA" "$B_BETA"
  grep -q '^alpha by A$' "$C/orc/STATE.md" 2>/dev/null && bad "M2 a merge that copies the turn's file over live must turn P3 red" || ok
  C=$(setup m3); mutant "$C" '/\[ -e "\$d\/\$key.json" \] && orct_live "\$d\/\$key.json" && exit 3/d'
  p6 "$C"
  [ "$(cat "$C/calls-after-rerun")" != 1 ] || [ -n "$(cat "$C/rerun-hung" 2>/dev/null)" ] && ok || bad "M3 a claim with no live check must turn P6 red"
else
  bad "M1-M3 bin/lib/orc-turns.sh does not exist"
fi

# --- R: the lead review NOTEs at e71a491c8 (fix round, #5980) --------------
# R1: the in-flight list is a READ. orct_inflight_render never renames a claim,
# so it cannot race a reclaim's mv and strip a live claim with no lock held.
C=$(setup r1)
( export HARNESS="$C" ORC="$C/orc" ORC_TURN_STALE_S=5; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  CMD_ID=501 orct_claim c501 "first" chat-1 "" m1 "" "" || exit 3
  CMD_ID=502 orct_claim c502 "second" chat-1 "" m2 "" "" || exit 3
  touch -d '-60 seconds' "$ORC/state/turns/c502.json"
  orct_inflight_render c501 > "$C/r1.render" ) ; eq R1_rc "$?" 0
eq R1_stale_not_listed "$(grep -c 'turn 502' "$C/r1.render" 2>/dev/null)" 0
[ -e "$C/orc/state/turns/c502.json" ] && [ ! -e "$C/orc/state/turns/c502.stale" ] && ok \
  || bad "R1 orct_inflight_render must not rename a claim (it holds no lock): $(ls "$C/orc/state/turns")"
# R2: a turn that exits through the trap after its claim (SIGTERM, an early
# gate exit) releases the claim. It is not answered, so it gets no .done, and a
# re-delivered copy runs at once instead of exiting rc 3 for up to 90 s.
C=$(setup r2)
( export HARNESS="$C" ORC="$C/orc" CMD_ID=601 ORCT_KEY=c601; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  ledger_reply() { :; }; cmd_status() { echo "$1" >> "$C/r2.status"; }
  orct_claim c601 "ask" chat-1 "" m1 "" "" || exit 3
  eval "$EXIT_BLOCK"
  exit 1 ); eq R2_rc "$?" 1
[ ! -e "$C/orc/state/turns/c601.json" ] && ok || bad "R2 a stopped turn must release its claim: $(ls "$C/orc/state/turns")"
[ ! -e "$C/orc/state/turns/c601.done" ] && ok || bad "R2 a stopped turn is not answered: no .done marker"
( export HARNESS="$C" ORC="$C/orc" CMD_ID=601; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  orct_claim c601 "ask" chat-1 "" m1 "" "" ); eq R2_redelivery_claims "$?" 0
# R2b: a duplicate copy (ORCT_SKIP_NOREPLY=1) never releases the owner's claim,
# and a turn never releases a claim another process holds.
C=$(setup r2b)
( export HARNESS="$C" ORC="$C/orc"; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  CMD_ID=602 orct_claim c602 "ask" chat-1 "" m1 "" "" ) || bad "R2b the owner's claim"
( export HARNESS="$C" ORC="$C/orc" CMD_ID=602 ORCT_KEY=c602 ORCT_SKIP_NOREPLY=1; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  ledger_reply() { :; }; cmd_status() { :; }
  eval "$EXIT_BLOCK"; exit 0 )
( export HARNESS="$C" ORC="$C/orc" CMD_ID=602 ORCT_KEY=c602; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  ledger_reply() { :; }; cmd_status() { :; }
  eval "$EXIT_BLOCK"; exit 1 )
[ -e "$C/orc/state/turns/c602.json" ] && ok || bad "R2b another process's live claim must stay: $(ls "$C/orc/state/turns")"
# R4 (lead BLOCK at cecc227a6): a command that runs again after its first turn
# stopped and was released keeps the second turn's STATE.md edits. The first
# turn's .merged marker must not make the second merge a silent no-op.
C=$(setup r4); printf '%s' "$STATE_BASE" > "$C/orc/STATE.md"
( export HARNESS="$C" ORC="$C/orc" CMD_ID=701 ORCT_KEY=c701; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  ledger_reply() { :; }; cmd_status() { :; }
  orct_claim c701 "ask" chat-1 "" m1 "" "" || exit 3
  orct_state_begin c701 || exit 4
  printf '%s' "$A_ALPHA" > "$ORC_TURN_STATE"
  eval "$EXIT_BLOCK"; exit 1 ) 2>>"$C/stderr.log"; eq R4_first_rc "$?" 1
grep -q '^alpha by A$' "$C/orc/STATE.md" && ok || bad "R4 the first turn's edit must merge on its stop: $(cat "$C/orc/STATE.md")"
( export HARNESS="$C" ORC="$C/orc" CMD_ID=701; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  orct_claim c701 "ask" chat-1 "" m1 "" "" || exit 3
  orct_state_begin c701 || exit 4
  sed 's/^old beta$/beta by B/' "$ORC_TURN_STATE.base" > "$ORC_TURN_STATE"
  orct_state_merge c701 ) 2>>"$C/stderr.log"; eq R4_second_rc "$?" 0
grep -q '^beta by B$' "$C/orc/STATE.md" && ok || bad "R4 the re-run turn's edit was lost: $(cat "$C/orc/STATE.md")"
grep -q '^alpha by A$' "$C/orc/STATE.md" && ok || bad "R4 the first turn's edit must stay: $(cat "$C/orc/STATE.md")"
# R4b: a re-run after a FAILED merge keeps the failed copy for the operator.
C=$(setup r4b); printf '%s' "$STATE_BASE" > "$C/orc/STATE.md"; mkdir -p "$C/orc/state/turns/c702"
printf 'kept for the operator\n' > "$C/orc/state/turns/c702/STATE.md"; : > "$C/orc/state/turns/c702/.merge-failed"
( export HARNESS="$C" ORC="$C/orc" CMD_ID=702; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2
  orct_state_begin c702 ) 2>>"$C/stderr.log"
n_keep=$(grep -rlx 'kept for the operator' "$C/orc/state/turns" 2>/dev/null | grep -c 'c702[^/]*/STATE.md')
eq R4b_failed_copy_kept "$n_keep" 1
[ ! -e "$C/orc/state/turns/c702/.merge-failed" ] && ok || bad "R4b the new turn's directory must not carry the old .merge-failed"
# R5: the 24 h prune keeps a .merge-failed copy and the directory of a live
# claim; it removes an old directory nobody owns.
C=$(setup r5); d="$C/orc/state/turns"; mkdir -p "$d/c801" "$d/c802" "$d/c803"
: > "$d/c801/.merge-failed"; printf '{}' > "$d/c802.json"
touch -d '-2 days' "$d/c801" "$d/c802" "$d/c803" "$d/c801/.merge-failed"
( export HARNESS="$C" ORC="$C/orc" CMD_ID=809; . "$C/bin/lib/orc-turns.sh" 2>/dev/null || exit 2; orct_done c809 )
[ -d "$d/c801" ] && ok || bad "R5 the prune deleted a .merge-failed copy the ALERT points to"
[ -d "$d/c802" ] && ok || bad "R5 the prune deleted the directory of a live claim"
[ ! -d "$d/c803" ] && ok || bad "R5 an old directory nobody owns must be pruned"
# R3: the registry tells the truth about 0. It sizes from free memory (1..32);
# it is not "unlimited".
eq R3_zero_means "$(jq -r '.knobs[] | select(.env=="ORC_TURN_CONCURRENCY") | .zero_means' "$DIR/catalog/lanes.d/orc-monitor.json")" null

echo "orchestrate-parallel-turns (BH-5336): $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
