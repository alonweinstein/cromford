#!/bin/bash
# tests/box-chat-routing-test.sh — the `chat` routing block extracted VERBATIM
# from bin/poll-commands.sh, plus the guarantees bin/box-chat.sh has to keep.
#
# The invariants worth locking:
#   * project "orchestrator" (and a chat with no project at all, the shape every
#     chat had before per-box chat existed) still takes the hub inbox path;
#   * any other project goes to that project's box, because claims are not
#     box-scoped: run here through bcx_run when this box owns it, else queued
#     as a box_console_commands row for the owning box (BH-2657, no ssh);
#   * every exit answers the pane exactly once — a chat that is refused or never
#     reaches its box must say so rather than hang;
#   * the box session cannot merge, build, deploy or comment on a board.
# Run from anywhere: tests/box-chat-routing-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/logs" "$T/locks" "$T/state" "$T/fakebin" "$T/orchestrator/inbox"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$T/bin/"
cp -r "$DIR/bin/lib" "$T/bin/lib"; cp "$DIR/bin/jobs-client.sh" "$T/bin/"
# Stub jobs worker: one line per request (method, url, body) into REQ.jsonl,
# answering 200 unless WORKER=down (connection refused).
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
printf '%s' "$BODY" | jq -Rsc --arg m "$METHOD" --arg u "$URL" '{method:$m, url:$u, body:.}' >> "$REQ_SINK"
[ "${WORKER:-}" = down ] && exit 7
printf '{"created":true}\n200\n'
CURL
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/SSH.calls\n' "$T" > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 local
remote-os Org/remote https://r.example /api/board 4 box-remote
EOF
export FLEET_CONF="$T/fleet.conf"
# Run from inside the fixture: the extracted handler builds some paths relative
# to cwd, and a failed mktemp once dropped a stray .meta into the repo root. In
# a checkout shared with another agent, a test that litters is a real nuisance.
cd "$T" || exit 1
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %s/BEATS.jsonl\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# Stand-ins for the two things the block launches, so the test observes the
# handoff without running a model or reaching a real box.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/BOXCHAT.calls\n' "$T" > "$T/bin/box-chat.sh"; chmod +x "$T/bin/box-chat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/ORCH.calls\n' "$T" > "$T/bin/orchestrate.sh"; chmod +x "$T/bin/orchestrate.sh"

# setsid is Linux-only; the boxes have it, a macOS dev machine does not. Without
# a stand-in the detached launch fails into /dev/null and the test would "pass"
# by observing nothing at all.
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The handoff is deliberately detached, so give it a moment to land before
# asserting. Polls rather than sleeps a fixed amount.
settle() { local f="$1" i=0; while [ "$i" -lt 40 ]; do [ -s "$f" ] && return 0; sleep 0.05; i=$((i+1)); done; return 1; }

awk '
  /^    # >>> chat handler/ {f=1; next}
  /^    # <<< chat handler/ {exit}
  f {print}' "$DIR/bin/poll-commands.sh" | sed -e '1s/^    chat)//' -e '$s/ ;;$//' > "$T/chat.body"
[ -s "$T/chat.body" ] || { echo "FAIL: could not extract the chat handler — markers missing?"; exit 1; }
# Since BH-4995.1 the hub path only names its inbox file (ORC_SPAWN) and the
# poller launches the orchestrator after the command ack, so the launch block
# runs right after the handler here, as it does in the loop.
awk '
  /^    # >>> chat spawn after ack/ {f=1; next}
  /^    # <<< chat spawn after ack/ {exit}
  f {print}' "$DIR/bin/poll-commands.sh" > "$T/chat.spawn"
[ -s "$T/chat.spawn" ] || { echo "FAIL: could not extract the chat spawn-after-ack block — markers missing?"; exit 1; }
cat "$T/chat.spawn" >> "$T/chat.body"
# The hub path writes into a hardcoded /root/orchestrator; retarget it the way
# CI's inline fixtures retarget triage-gate.sh.
sed -i.bak "s|/root/orchestrator|$T/orchestrator|g" "$T/chat.body" && rm -f "$T/chat.body.bak"

run() { # run <command-id> <project> <payload-json>
  HARNESS="$T" BEAT="$T/bin/beat.sh" ID="$1" PROJECT="$2" PAYLOAD="$3" OK=false RESULT="" \
    PATH="$T/fakebin:$PATH" REQ_SINK="$T/REQ.jsonl" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
    bash -c 'set -uo pipefail
      . "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/jobs/box-console-commands.sh"
      . "$HARNESS/bin/lib/box-cmd-exec.sh"; . "$HARNESS/bin/lib/cron-lines.sh"
      . "$0"; echo "OK=$OK RESULT=$RESULT"' "$T/chat.body"
}
posts() { jq -c 'select(.url|endswith("/api/box-console-commands"))|.body|fromjson' "$T/REQ.jsonl"; }
beats() { local n=0; [ -f "$T/BEATS.jsonl" ] && n=$(grep -c . "$T/BEATS.jsonl" 2>/dev/null); echo "${n:-0}"; }
last()  { tail -1 "$T/BEATS.jsonl" 2>/dev/null; }
reset() { : > "$T/BEATS.jsonl"; : > "$T/BOXCHAT.calls"; : > "$T/ORCH.calls"; : > "$T/REQ.jsonl"; : > "$T/SSH.calls"; rm -f "$T/orchestrator/inbox"/*; }

# ---------- 1. the hub path is untouched ----------
reset; OUT=$(run h1 orchestrator '{"text":"how is the fleet","origin":"dash"}')
settle "$T/ORCH.calls"
grep -q 'OK=true' <<<"$OUT" && [ -s "$T/ORCH.calls" ] && [ ! -s "$T/BOXCHAT.calls" ] \
  && ok || bad "project=orchestrator must go to the hub orchestrator (out=$OUT)"
# It must NOT beat here: the orchestrator answers for itself, later and once.
[ "$(beats)" -eq 0 ] && ok || bad "the hub path must not beat from the poller (got $(beats))"
[ -s "$T/REQ.jsonl" ] && bad "orchestrator chat must not be queued for a box: $(cat "$T/REQ.jsonl")" || ok

# A chat with no project at all is every chat that existed before this wave.
reset; OUT=$(run h2 null '{"text":"still works","origin":"dash"}')
settle "$T/ORCH.calls"
grep -q 'OK=true' <<<"$OUT" && [ -s "$T/ORCH.calls" ] && [ ! -s "$T/BOXCHAT.calls" ] && [ ! -s "$T/REQ.jsonl" ] \
  && ok || bad "a project-less chat must still reach the hub (out=$OUT req=$(cat "$T/REQ.jsonl"))"

# The hub's sidecar now names itself, so the console can thread on one field.
reset; run h3 orchestrator '{"text":"sidecar","origin":"dash"}' >/dev/null
settle "$T/ORCH.calls"
META=$(cat "$T/orchestrator/inbox"/*.meta 2>/dev/null)
[ "$(jq -r .project <<<"$META")" = orchestrator ] && [ "$(jq -r .command_id <<<"$META")" = h3 ] \
  && ok || bad "hub sidecar must carry project=orchestrator (got: $META)"

# ---------- 2. a project chat for THIS box runs here, through bcx_run ----------
reset; OUT=$(run b1 alpha-os '{"text":"why is the queue stuck","origin":"dash"}')
settle "$T/BOXCHAT.calls"
grep -q 'OK=true' <<<"$OUT" && [ -s "$T/BOXCHAT.calls" ] && [ ! -s "$T/ORCH.calls" ] \
  && ok || bad "a project chat must go to box-chat, not the orchestrator (out=$OUT)"
# The payload rides as base64 JSON carrying all four fields.
B64=$(awk '{print $2}' "$T/BOXCHAT.calls" | head -1)
# The command id travels OUTSIDE the payload too, so a blob that fails to decode
# can still be answered.
[ "$(awk '{print $3}' "$T/BOXCHAT.calls" | head -1)" = b1 ] \
  && ok || bad "the command id must ride alongside the payload (got: $(cat "$T/BOXCHAT.calls"))"
J=$(printf %s "$B64" | base64 -d 2>/dev/null)
[ "$(jq -r .text <<<"$J")" = "why is the queue stuck" ] \
  && [ "$(jq -r .command_id <<<"$J")" = b1 ] \
  && [ "$(jq -r .project <<<"$J")" = alpha-os ] \
  && [ "$(jq -r .origin <<<"$J")" = dash ] \
  && ok || bad "forwarded payload must carry text/command_id/project/origin (got: $J)"
# Handing off is not answering: the box beats its own reply when it has one.
[ "$(beats)" -eq 0 ] && ok || bad "a successful handoff must not beat (got $(beats))"
[ -s "$T/REQ.jsonl" ] && bad "a local project chat must not be queued: $(cat "$T/REQ.jsonl")" || ok

# ---------- 3. a remote project is queued for its box, never ssh'd ----------
reset
OUT=$(run b2 remote-os '{"text":"remote question","origin":"dash"}')
P=$(posts)
grep -q 'OK=true RESULT=queued for box-remote' <<<"$OUT" && [ "$(grep -c . <<<"$P")" = 1 ] \
  && ok || bad "a remote project must be queued once (out=$OUT req=$(cat "$T/REQ.jsonl"))"
[ "$(jq -r .type <<<"$P")" = chat ] && [ "$(jq -r .box <<<"$P")" = remote ] \
  && [ "$(jq -r .project <<<"$P")" = remote-os ] && [ "$(jq -r .command_id <<<"$P")" = b2 ] \
  && [ "$(jq -r .payload <<<"$P" | jq -r .text)" = "remote question" ] \
  && ok || bad "the row must be {type:chat,box:remote,project:remote-os,command_id:b2} carrying the text: $P"
[ -s "$T/SSH.calls" ] && bad "a remote chat must not use ssh: $(cat "$T/SSH.calls")" || ok
[ -s "$T/BOXCHAT.calls" ] && bad "a remote chat must not run box-chat on the hub: $(cat "$T/BOXCHAT.calls")" || ok
[ "$(beats)" -eq 0 ] && ok || bad "a queued chat must not beat (got $(beats))"

# ---------- 4. every failure still answers the pane ----------
reset; OUT=$(run b3 not-a-project '{"text":"hello","origin":"dash"}')
grep -q 'OK=false' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
  && [ "$(jq -r .rkey <<<"$(last)")" = "chat:b3" ] \
  && [ "$(jq -r .error <<<"$(last)")" = routing_failed ] \
  && [ "$(jq -r .kind <<<"$(last)")" = chat_reply ] \
  && ok || bad "an unknown project must still answer the pane (out=$OUT beat=$(last))"

reset; OUT=$(run b4 alpha-os '{"text":"","origin":"dash"}')
grep -q 'OK=false' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
  && [ "$(jq -r .error <<<"$(last)")" = routing_failed ] \
  && ok || bad "an empty chat must still answer the pane (out=$OUT)"

# An unreachable jobs worker: the forward fails, the pane still hears why.
reset; OUT=$(WORKER=down run b5 remote-os '{"text":"anyone home","origin":"dash"}')
grep -q 'OK=false' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
  && [ "$(jq -r .rkey <<<"$(last)")" = "chat:b5" ] \
  && [ "$(jq -r .project <<<"$(last)")" = remote-os ] \
  && [ "$(jq -r .error <<<"$(last)")" = routing_failed ] \
  && grep -q 'forward to box-remote failed (jobs worker unreachable)' <<<"$OUT" \
  && [ ! -s "$T/SSH.calls" ] \
  && ok || bad "an unreachable worker must still answer the pane (out=$OUT beat=$(last))"

# Exactly one beat per command — two would double-render the pane.
reset
run b6 alpha-os '{"text":"ok","origin":"dash"}' >/dev/null
run b7 not-a-project '{"text":"bad","origin":"dash"}' >/dev/null
run b8 orchestrator '{"text":"hub","origin":"dash"}' >/dev/null
[ "$(beats)" -eq 1 ] && ok || bad "only the refused command should beat from the poller (got $(beats))"

# ---------- 5. the box session's reply shape ----------
grep -q "kind:\"chat_reply\"" "$DIR/bin/box-chat.sh" \
  && grep -q 'rkey:("chat:"+$id)' "$DIR/bin/box-chat.sh" \
  && grep -q 'project:\$p' "$DIR/bin/box-chat.sh" \
  && ok || bad "box-chat must reply as chat_reply with rkey chat:<id> and a project field"

# ---------- 6. the preamble names the box and the project ----------
# A session that cannot say which machine it is on gives confidently wrong
# answers about another box's queue.
for NEEDLE in 'fleet box "\$BOX"' 'project' 'force-triage-\$PROJECT'; do
  grep -q "$NEEDLE" "$DIR/bin/box-chat.sh" || bad "preamble is missing: $NEEDLE"
done
ok
grep -q 'state/box-id' "$DIR/bin/box-chat.sh" && ok || bad "box identity must come from state/box-id"

# ---------- 7. the LAUNCHER wires in no write path ----------
# Containment itself is prompt-only: the turn runs as root with the full tool
# set, exactly as bin/orchestrate.sh has on the hub since day one. So this
# asserts the narrower thing that IS enforceable — box-chat.sh hands the session
# no merge, build, deploy or board-API machinery of its own. A future edit that
# wires one in fails here. It does NOT prove the session cannot write.
for FORBIDDEN in 'gh pr merge' 'git push' 'run-build.sh' 'merge-queue.sh' 'product-cmd.sh' 'deploy-train.sh' 'api/board' 'vercel'; do
  if grep -q -- "$FORBIDDEN" "$DIR/bin/box-chat.sh"; then
    bad "box-chat.sh must not reference a write path: $FORBIDDEN"
  fi
done
ok
# ...and the one lever it IS allowed is named, so the whitelist is explicit.
grep -q 'flags/force-triage-' "$DIR/bin/box-chat.sh" && ok || bad "the whitelisted triage lever must be named in the preamble"

# ---------- 8. box-chat itself answers a hand-off it cannot read ----------
# The real script, not the routing block. A malformed or corrupted payload used
# to exit rc 0 with ZERO beats, which leaves the console pane spinning forever on
# a request the box had already thrown away — indistinguishable from a dead box.
BC="$T/bc"; mkdir -p "$BC/bin" "$BC/env" "$BC/logs" "$BC/locks" "$BC/state"
cp "$DIR/bin/fleet-conf.sh" "$BC/bin/"
cp "$T/fleet.conf" "$BC/fleet.conf"
echo 'box-alpha' > "$BC/state/box-id"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %s/BC_BEATS.jsonl\n' "$T" > "$BC/bin/beat.sh"; chmod +x "$BC/bin/beat.sh"
bcbeats() { local n=0; [ -f "$T/BC_BEATS.jsonl" ] && n=$(grep -c . "$T/BC_BEATS.jsonl" 2>/dev/null); echo "${n:-0}"; }
bclast()  { tail -1 "$T/BC_BEATS.jsonl" 2>/dev/null; }

# Corrupted base64: the payload is unreadable, but the id rode alongside it.
: > "$T/BC_BEATS.jsonl"
HARNESS="$BC" FLEET_CONF="$BC/fleet.conf" bash "$DIR/bin/box-chat.sh" --b64 'not!valid!base64!' cmd-x1 >/dev/null 2>&1
[ "$(bcbeats)" -eq 1 ] \
  && [ "$(jq -r .rkey <<<"$(bclast)")" = "chat:cmd-x1" ] \
  && [ "$(jq -r .error <<<"$(bclast)")" = malformed_request ] \
  && ok || bad "a corrupted payload must beat exactly one error reply (got $(bcbeats): $(bclast))"

# Valid base64, valid JSON, but no text — same contract.
: > "$T/BC_BEATS.jsonl"
B=$(printf '%s' '{"project":"alpha-os","command_id":"cmd-x2"}' | base64 | tr -d '\n')
HARNESS="$BC" FLEET_CONF="$BC/fleet.conf" bash "$DIR/bin/box-chat.sh" --b64 "$B" cmd-x2 >/dev/null 2>&1
[ "$(bcbeats)" -eq 1 ] && [ "$(jq -r .rkey <<<"$(bclast)")" = "chat:cmd-x2" ] \
  && ok || bad "an empty-text hand-off must beat exactly one error reply (got $(bcbeats): $(bclast))"

# No command id anywhere: nothing to key a reply on, so the pane cannot be told.
# It must at least become visible where humans look, rather than vanishing.
: > "$T/BC_BEATS.jsonl"; : > "$BC/logs/ALERTS.log"
HARNESS="$BC" FLEET_CONF="$BC/fleet.conf" bash "$DIR/bin/box-chat.sh" --b64 'not!valid!' '' >/dev/null 2>&1
[ "$(bcbeats)" -eq 0 ] && grep -q 'no command id' "$BC/logs/ALERTS.log" \
  && ok || bad "an id-less hand-off must raise an ALERTS line (beats=$(bcbeats) alerts=$(cat "$BC/logs/ALERTS.log"))"

echo "box-chat-routing-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
