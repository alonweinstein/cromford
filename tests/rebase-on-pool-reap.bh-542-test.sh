#!/bin/bash
# tests/rebase-on-pool-reap.bh-542-test.sh — the POOL REBASE TRANSPORT, driven.
#
# WHAT THIS IS ABOUT (BH-486.2, #542). Under REBASE_ON_POOL the hub stops
# cloning and gating a rebase on its own disk: bin/lib/merge-conductor-lib.sh
# writes a build_queue row with meta.kind=rebase, bin/fly-dispatch.sh
# materialises that row into the queue FILE a pool machine receives, and
# bin/fly-pool.sh reaps the machine's RESULT into mc_pool_rebase_apply instead
# of the build relay. This suite drives both halves whole — the real scripts,
# from their own entry points, with only the machine, the network and the
# queue API stubbed.
#
# WHY DRIVEN AND NOT GREPPED. Nearly every claim here is a NEGATIVE, and each
# one fails silently in production:
#   - a rebase row that loses its `rebase` object arrives at the machine as an
#     ordinary BUILD of "ticket <pr-number>" — a PR and a board comment nobody
#     asked for;
#   - a rebase RESULT that falls through to the build path writes
#     state/remote-results, ssh's into the owning box and can queue a merge;
#   - an apply that REFUSED and was recorded `done` is a rebase nobody will ever
#     retry.
# So the ssh stub, the remote-results directory, the queue PATCH sink and the
# apply sink are the assertions, and the fixtures never inspect source text.
#
# MUTATIONS THAT MUST TURN THIS SUITE RED (checked 2026-09-18):
#   - revert bin/fly-dispatch.sh's nested-meta normalisation to the bare
#     `select(type=="object")`                                    -> §6.4 red
#   - drop the `case "$KEY" in RB-*)` arm from bin/fly-pool.sh's
#     BUILD_DEFERRED branch                                       -> §7.7 red
#   - drop the `case "$KEY" in RB-*)` arm from the dead-machine branch
#                                                                 -> §7.10 red
#   - key either arm on something other than the RB- prefix        -> §7.11 red
#
# Run from anywhere: bash tests/rebase-on-pool-reap.bh-542-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

RSHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RKEY=RB-21-aaaaaaaa
RMETA_OK=$(jq -nc --arg h "$RSHA" \
  '{kind:"rebase",slug:"o/r",url:"https://github.com/o/r/pull/21",pr:21,branch:"ticket/TK-21",head:$h,base:"main"}')

# ════════════════════════════════════════════════════════════════════════════
# §6  bin/fly-dispatch.sh — the row's meta reaches the queue file
# ════════════════════════════════════════════════════════════════════════════
HD="$T/hd"
mkdir -p "$HD/bin" "$HD/logs" "$HD/flags" "$HD/locks" "$HD/env" \
         "$HD/state/build-queue/tproj" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$HD/bin/"
mkdir -p "$HD/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$HD/bin/lib/jobs/"
# The real registry, deliberately: `tproj` is NOT in it, so owner_ip answers
# nothing and the ssh drain stands down before the hop. The ssh/scp stubs below
# are how that is proven rather than assumed.
cp "$DIR/fleet.conf" "$HD/fleet.conf"
: > "$HD/env/global.env"
: > "$HD/env/fly.env"                     # marks this tree as "the hub"
touch "$HD/flags/builder-fly-tproj"

printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n'  > "$T/fakebin/timeout"
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
echo "ssh $*" >> "$SSH_SINK"
exit 0
STUB
cat > "$T/fakebin/scp" <<'STUB'
#!/bin/bash
echo "scp $*" >> "$SSH_SINK"
exit 0
STUB
# base64 DIALECTS — the same shim tests/pool-relay-rowfirst-test.sh carries.
# GNU takes `-d FILE` and `-w0`; BSD takes `-D`, ignores a positional input and
# spells the no-wrap flag `-b 0`. The scripts speak GNU, so the shim probes the
# host once and always feeds input on stdin, which both dialects accept.
cat > "$T/fakebin/base64" <<'STUB'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
STUB

# curl: the queue rows come from $ROWSET, and every request is recorded so the
# claim, the close and the (absent) release can be asserted on.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/queue/claim)
    KEY=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    printf '{"queued":{"project":"tproj","ticket_key":"%s","ticket_id":"x","target":"fly","attempt":0,"status":"claimed"},"claimed":true}\n200\n' "$KEY" ;;
  */api/queue\?*)
    if [ -s "${ROWSET:-/dev/null}" ]; then cat "$ROWSET"; printf '\n200\n'
    else printf '{"queue":[]}\n200\n'; fi ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

rowset() { # rowset <key> <ticket-id> <attempt> <meta-json-or-empty>
  jq -nc --arg k "$1" --arg t "$2" --argjson a "$3" --argjson m "${4:-null}" \
    '{queue:[{project:"tproj",ticket_key:$k,ticket_id:$t,status:"queued",
              target:"fly",attempt:$a,claimed_by:null,
              enqueued_at:"2026-09-17T01:00:00Z",reason:null,meta:$m}]}' > "$T/rowset.json"
}

dispatch() {
  rm -f "$HD/state/build-queue/tproj"/*.json "$HD/logs/ALERTS.log"
  : > "$T/req.txt"; : > "$T/ssh.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HD" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" ROWSET="$T/rowset.json" \
           FLEET_CONF="$HD/fleet.conf"
    bash "$DIR/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}
# The enqueued_at stamp is the one field that cannot be a literal, so it is
# normalised — everything else in the golden is byte-for-byte.
nostamp() { sed 's/"enqueued_at":"[^"]*"/"enqueued_at":"TS"/' "$1"; }

# ── 6.1 a rebase row carries the whole meta object onto the queue file ──────
rowset "$RKEY" 21 0 "$RMETA_OK"
dispatch
QF="$HD/state/build-queue/tproj/$RKEY.json"
[ -f "$QF" ] && ok || bad "6.1 a claimed rebase row must materialise $RKEY.json"
[ "$(jq -r '.rebase.kind // ""' "$QF" 2>/dev/null)" = rebase ] \
  && ok || bad "6.1 THE POINT: the machine reads .rebase.kind — got $(cat "$QF" 2>/dev/null)"
[ "$(jq -r '.rebase.head // ""' "$QF" 2>/dev/null)" = "$RSHA" ] \
  && ok || bad "6.1 .rebase.head is the sha the hub read this tick"
[ "$(jq -r '.rebase.pr // ""' "$QF" 2>/dev/null)" = 21 ] \
  && ok || bad "6.1 .rebase.pr must survive the hop"
[ "$(jq -r '.rebase.branch // ""' "$QF" 2>/dev/null)" = ticket/TK-21 ] \
  && ok || bad "6.1 .rebase.branch must survive the hop"
[ "$(jq -r '.ticket_id // ""' "$QF" 2>/dev/null)" = 21 ] \
  && ok || bad "6.1 the ticket_id still rides the file"
[ "$(jq -r '.key // ""' "$QF" 2>/dev/null)" = "$RKEY" ] \
  && ok || bad "6.1 the key still rides the file"
jq -e 'has("stack_base")' "$QF" >/dev/null 2>&1 \
  && bad "6.1 a rebase row has no stack_base — the field must stay absent" || ok
[ "$(jq -r 'keys_unsorted | last' "$QF" 2>/dev/null)" = rebase ] \
  && ok || bad "6.1 rebase is ADDITIVE — it is appended last, after today's fields"
[ -s "$T/ssh.txt" ] && bad "6.1 the materialise must not ssh: $(cat "$T/ssh.txt")" || ok

# ── 6.2 a row with no meta (and a non-rebase meta) writes TODAY'S file ──────
GOLD9='{"ticket_id":"9","key":"TK-9","attempt":2,"deferrals":0,"enqueued_at":"TS","source":"db"}'
rowset TK-9 9 2 ''
dispatch
[ -f "$HD/state/build-queue/tproj/TK-9.json" ] \
  && ok || bad "6.2 a plain row must still materialise"
[ "$(nostamp "$HD/state/build-queue/tproj/TK-9.json")" = "$GOLD9" ] \
  && ok || bad "6.2 THE POINT: no meta.kind writes byte-for-byte today's file. Got $(nostamp "$HD/state/build-queue/tproj/TK-9.json")"
GOLD10='{"ticket_id":"10","key":"TK-10","attempt":2,"deferrals":0,"enqueued_at":"TS","source":"db"}'
rowset TK-10 10 2 '{"kind":"build"}'
dispatch
[ "$(nostamp "$HD/state/build-queue/tproj/TK-10.json")" = "$GOLD10" ] \
  && ok || bad "6.2 a meta.kind that is not rebase writes today's file too. Got $(nostamp "$HD/state/build-queue/tproj/TK-10.json")"
# `Rebase` is not `rebase`: the classifier is case-sensitive, and a near-miss
# must take the ordinary build path rather than half of the rebase one.
rowset TK-12 12 2 '{"kind":"Rebase"}'
dispatch
jq -e 'has("rebase")' "$HD/state/build-queue/tproj/TK-12.json" >/dev/null 2>&1 \
  && bad "6.2 kind:\"Rebase\" is not kind:\"rebase\"" || ok
# A meta that carries a `rebase` object but no `kind` is not a rebase row either.
rowset TK-13 13 2 '{"rebase":{"pr":21}}'
dispatch
jq -e 'has("rebase")' "$HD/state/build-queue/tproj/TK-13.json" >/dev/null 2>&1 \
  && bad "6.2 a meta.rebase without meta.kind is not a rebase row" || ok
# A meta that is a STRING, not an object (queue_list passes those through).
rowset TK-11 11 2 '"deferrals=1"'
dispatch
[ -f "$HD/state/build-queue/tproj/TK-11.json" ] \
  && ok || bad "6.2 a string meta must still materialise a file"
jq -e 'has("rebase")' "$HD/state/build-queue/tproj/TK-11.json" >/dev/null 2>&1 \
  && bad "6.2 a string meta is not a rebase" || ok

# ── 6.3 an unsanitary rebase object is REFUSED, never dropped to a build ────
# Dropping the field the way `stack_base` drops would leave {ticket_id:"21"} —
# an ordinary BUILD of ticket 21 of this project, with a PR and a board comment
# nobody asked for. So the row is closed `failed` and no file is written.
refused() { # refused <case-name> <meta-json>
  rowset "$RKEY" 21 0 "$2"
  dispatch
  [ -f "$HD/state/build-queue/tproj/$RKEY.json" ] \
    && bad "6.3 ($1) an unsanitary rebase row must NOT become a queue file" || ok
  grep -q "PATCH https://jobs.invalid/api/queue .*\"key\":\"$RKEY\".*\"status\":\"failed\"" "$T/req.txt" \
    && ok || bad "6.3 ($1) the row must be closed failed: $(cat "$T/req.txt")"
  grep -q "\"status\":\"queued\"" "$T/req.txt" \
    && bad "6.3 ($1) a release would re-offer the same bad row every tick" || ok
  N=$(grep -c "$RKEY" "$HD/logs/ALERTS.log" 2>/dev/null | head -1)
  [ "$N" = 1 ] && ok || bad "6.3 ($1) exactly one ALERTS line, got $N"
}
refused "pr not a number"   "$(printf '%s' "$RMETA_OK" | jq -c '.pr="21a"')"
refused "head with a space" "$(printf '%s' "$RMETA_OK" | jq -c '.head="aaaa bbbb"')"
refused "no slug"           "$(printf '%s' "$RMETA_OK" | jq -c 'del(.slug)')"

# ── 6.4 the NESTED meta shape lands as the same queue file ──────────────────
# bin/lib/merge-conductor-lib.sh's comment documents the job as a nested
# `meta.rebase={…}`; the enqueue writes the fields flat. Both shapes are real, so
# the materialise normalises to the flat object BEFORE it validates. Without
# that, a nested row fails the charset loop on a `slug` it does carry and is
# closed `failed` — the rebase silently never happens.
RMETA_NEST=$(jq -nc --argjson r "$RMETA_OK" '{kind:"rebase",rebase:($r|del(.kind))}')
rowset "$RKEY" 21 0 "$RMETA_NEST"
dispatch
QF="$HD/state/build-queue/tproj/$RKEY.json"
[ -f "$QF" ] && ok || bad "6.4 THE POINT: a nested meta.rebase row must materialise $QF — got $(cat "$T/req.txt")"
[ "$(jq -r '.rebase.kind // ""' "$QF" 2>/dev/null)" = rebase ] \
  && ok || bad "6.4 the normalised object still carries kind:rebase — got $(cat "$QF" 2>/dev/null)"
[ "$(jq -r '.rebase.slug // ""' "$QF" 2>/dev/null)" = o/r ] \
  && ok || bad "6.4 .rebase.slug survives the unwrap"
[ "$(jq -r '.rebase.head // ""' "$QF" 2>/dev/null)" = "$RSHA" ] \
  && ok || bad "6.4 .rebase.head survives the unwrap"
[ "$(jq -r '.rebase.pr // ""' "$QF" 2>/dev/null)" = 21 ] \
  && ok || bad "6.4 .rebase.pr survives the unwrap"
[ "$(jq -r '.rebase.branch // ""' "$QF" 2>/dev/null)" = ticket/TK-21 ] \
  && ok || bad "6.4 .rebase.branch survives the unwrap"
jq -e '.rebase|has("rebase")' "$QF" >/dev/null 2>&1 \
  && bad "6.4 the wrapper must be UNWRAPPED — the machine reads .rebase.slug, not .rebase.rebase.slug" || ok
[ "$(jq -r 'keys_unsorted | last' "$QF" 2>/dev/null)" = rebase ] \
  && ok || bad "6.4 rebase is still appended last"
# ...and normalising must not smuggle a bad field past the charset checks.
refused "nested with a bad slug" \
  "$(printf '%s' "$RMETA_NEST" | jq -c '.rebase.slug="o/r;rm -rf"')"
grep -q 'rebase meta rejected (slug)' "$T/req.txt" \
  && ok || bad "6.4 a nested row is validated like a flat one — the slug is the field named: $(cat "$T/req.txt")"

# ════════════════════════════════════════════════════════════════════════════
# §7  bin/fly-pool.sh — the reap routes the five RESULT words to the apply
# ════════════════════════════════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/fly" "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" \
         "$H/state/build-queue/tproj"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
# (BH-781) The PR_CREATED gate reads through bin/lib/gh-rest.sh. Without the
# library on the box the gate makes no read at all and alerts instead, which is
# the fail-safe arm — not the path §7.6 is about.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
cp "$DIR/fleet.conf" "$H/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf '3\n'           > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n'  > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh"

# The machine side, stubbed. Every argv is recorded, so "the machine was
# destroyed" and "no PR was ever verified" are both assertions on files.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "fly $*" >> "$FLY_SINK"
# LOOSE PATTERNS ON SINGLE TOKENS: mexec wraps its command with `printf %q`,
# which escapes each space, so a pattern containing a space never matches and
# the reap silently does nothing — the vacuous pass this suite exists to avoid.
case "$*" in
  *"machine status"*) echo "State: ${MSTATE_FIX:-started}" ;;
  *base64*RESULT*)    [ -s "${RESULT_FIXTURE:-/dev/null}" ] && base64 -w0 "$RESULT_FIXTURE" ;;
  *base64*)           : ;;
  *head*RESULT*)      head -1 "${RESULT_FIXTURE:-/dev/null}" 2>/dev/null ;;
  *ls*builds*)        echo "/data/harness/builds/tproj-x-1" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB
# gh: the PR-verify gate is REST since BH-709 and goes through
# bin/lib/gh-rest.sh since BH-781, so the stub answers a status line first and
# the body after the blank line — which is exactly what that library parses. An
# OPEN PR is the affirmative answer that lets §7.6's build path run to the
# handoff with the RESULT untouched.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_SINK"
case " $* " in
  *" -i "*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n' ;;
  *)        printf '{"state":"open","merged_at":null}\n' ;;
esac
exit 0
STUB
chmod +x "$T/fakebin/fly" "$T/fakebin/gh"

# The apply the reap is supposed to call: records its argv, answers $APPLY_RC.
fixture_lib() {
  cat > "$H/bin/lib/merge-conductor-lib.sh" <<'LIB'
mc_pool_rebase_apply() { printf '%s\n' "$*" >> "$APPLY_SINK"; return "${APPLY_RC:-0}"; }
LIB
}
real_lib() { cp "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/merge-conductor-lib.sh"; mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"; }

REBASED_RESULT="REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PR: https://github.com/o/r/pull/21
HEAD: $RSHA
BRANCH: ticket/TK-21
BASE: main
GATE: typecheck=0 unit=0"

pool() { # pool <key> <ticket-id> <result-text> [apply-rc] [machine-state]
  # $T-rooted literals: the scratch lib hands out $T and checks/tests-scratch-only
  # (R2) is the reason a recursive rm here names it rather than a derived var.
  rm -rf "$T/h/builds"/* "$T/h/state/remote-results/tproj"/* \
         "$T/h/state/build-queue/tproj"/* "$T/h/state/fly-pool/tproj"/*
  rm -f "$H/logs/ALERTS.log" "$H/logs/fly-pool.log"
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"; : > "$T/apply.txt"
  : > "$T/beat.txt"; : > "$T/gh.txt"
  printf '%s' "$3" > "$T/result.txt"
  jq -nc --arg k "$1" --arg t "$2" '{machine:"m1",key:$k,ticket_id:$t,attempt:0}' \
    > "$H/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok POOL_PR_VERIFY_SLEEP=0 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           APPLY_SINK="$T/apply.txt" BEAT_SINK="$T/beat.txt" GH_SINK="$T/gh.txt" \
           RESULT_FIXTURE="$T/result.txt" APPLY_RC="${4:-0}" MSTATE_FIX="${5:-started}"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  LOCALDIR=$(ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1)
}
rr_count() { ls "$H/state/remote-results/tproj" 2>/dev/null | wc -l | tr -d ' '; }

# ── 7.1 REBASED + apply rc 0: the rebase branch, and NONE of the build path ──
fixture_lib
pool "$RKEY" 21 "$REBASED_RESULT" 0
[ -n "$LOCALDIR" ] && ok || bad "7.1 the reap must still assemble a build dir"
[ -f "$LOCALDIR/REBASE" ] && ok || bad "7.1 rc 0 stamps the REBASE sentinel"
[ -f "$LOCALDIR/COMMENTED" ] \
  && ok || bad "7.1 a rebase dir owes no board close-out — COMMENTED keeps pipeline-health, run-triage and orphan-reconcile off it"
[ "$(rr_count)" = 0 ] \
  && ok || bad "7.1 THE POINT: a rebase RESULT is never a remote result — got $(ls "$H/state/remote-results/tproj")"
[ -s "$T/ssh.txt" ] && bad "7.1 the relay ssh must never run for a rebase: $(cat "$T/ssh.txt")" || ok
grep -q "PATCH https://jobs.invalid/api/queue .*\"key\":\"$RKEY\".*\"status\":\"done\"" "$T/req.txt" \
  && ok || bad "7.1 the queue row is closed done: $(cat "$T/req.txt")"
grep -q '/api/merge-queue' "$T/req.txt" \
  && bad "7.1 a rebase never joins the merge queue" || ok
[ "$(wc -l < "$T/apply.txt")" = 1 ] \
  && ok || bad "7.1 mc_pool_rebase_apply is called exactly once: $(cat "$T/apply.txt")"
[ "$(cat "$T/apply.txt")" = "tproj $RKEY $LOCALDIR/RESULT" ] \
  && ok || bad "7.1 the apply gets <project> <key> <result-file>: $(cat "$T/apply.txt")"
[ "$(head -1 "$LOCALDIR/RESULT" 2>/dev/null)" = "REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ] \
  && ok || bad "7.1 the file handed to the apply is the machine's own RESULT"
grep -q 'machine destroy' "$T/fly.txt" && ok || bad "7.1 the machine is still handled"
grep -q '"stage":"pool_rebase"' "$T/beat.txt" \
  && ok || bad "7.1 the console hears a pool_rebase, not a pool_result: $(cat "$T/beat.txt")"
grep -q '"stage":"pool_result"' "$T/beat.txt" \
  && bad "7.1 a rebase must not beat as a finished build" || ok
[ -s "$T/gh.txt" ] && bad "7.1 the PR_CREATED gate must not run for a rebase word" || ok
# ── 7.2 the log says what it did
grep -q "reaped rebase $RKEY" "$H/logs/fly-pool.log" \
  && ok || bad "7.2 fly-pool.log must name the rebase reap: $(cat "$H/logs/fly-pool.log")"

# ── 7.3 apply refused: ONE alert, the row stays CLAIMED, machine still handled ─
pool "$RKEY" 21 "$REBASED_RESULT" 1
N=$(grep -c "$LOCALDIR/RESULT" "$H/logs/ALERTS.log" 2>/dev/null | head -1)
[ "$N" = 1 ] \
  && ok || bad "7.3 exactly one ALERTS line naming the RESULT path, got $N: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "\"key\":\"$RKEY\".*\"status\":\"done\"" "$T/req.txt" \
  && bad "7.3 THE POINT: an apply that refused must never close the row done" || ok
[ -f "$LOCALDIR/REBASE" ] && bad "7.3 no REBASE sentinel when the apply refused" || ok
[ -f "$LOCALDIR/COMMENTED" ] && ok || bad "7.3 the dir still owes no board close-out"
grep -q 'machine destroy' "$T/fly.txt" \
  && ok || bad "7.3 a refused apply must not strand the machine"
# BH-2363: alert-line.sh also beats kind:"alert"
grep -q 'pool_rebase' <<<"$(grep -v '"kind":"alert"' "$T/beat.txt")" \
  && bad "7.3 a rebase that did not apply must not beat as finished" || ok
[ "$(rr_count)" = 0 ] && ok || bad "7.3 still never a remote result"

# ── 7.4 the other four RESULT words take the same branch ────────────────────
for W in "CONFLICT a.txt b.txt" "GATE_RED unit" "REBASE_SETUP_FAILED no repo" "REBASE_LEASE_REJECTED moved"; do
  pool "$RKEY" 21 "$W
PR: https://github.com/o/r/pull/21" 0
  [ -s "$T/apply.txt" ] && ok || bad "7.4 '$W' must reach mc_pool_rebase_apply"
  [ "$(rr_count)" = 0 ] && ok || bad "7.4 '$W' must not write a remote result"
  [ -f "$LOCALDIR/REBASE" ] && ok || bad "7.4 '$W' applied rc 0 stamps REBASE"
done

# ── 7.5 the REAL lib applies a REBASED result and the reap takes rc 0 ─────
# Nothing from the fixture is imported: main's mc_pool_rebase_apply (BH-541,
# PR #913) writes the rebase job record under state/merge-conductor/rebase,
# PUTs the ledger row, and returns 0 — the rebind's own outcome (rc 5 here,
# the stubbed jobs API answers no verdict) rides in the record for the
# conductor's tick, never in the reap. This case is also what proves
# bin/fly-pool.sh sources the REAL lib whole — the fixture is gone, so only a
# genuine source of a 3000-line file gets an apply to call at all.
real_lib
pool "$RKEY" 21 "$REBASED_RESULT" 0
[ -s "$T/apply.txt" ] \
  && bad "7.5 the real lib's apply records nothing in the fixture sink — it must stay empty" || ok
grep -q "$LOCALDIR/RESULT" "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "7.5 a recorded apply is not an alert: $(cat "$H/logs/ALERTS.log")" || ok
grep -q "\"key\":\"$RKEY\".*\"status\":\"done\"" "$T/req.txt" \
  && ok || bad "7.5 the real apply returned 0, so the row is closed done: $(cat "$T/req.txt")"
grep -q 'PUT https://jobs.invalid/api/ledger {"kind":"rebase"' "$T/req.txt" \
  && ok || bad "7.5 the real apply PUTs the rebase ledger row: $(cat "$T/req.txt")"
ls "$H/state/merge-conductor/rebase/"*_21_*.json >/dev/null 2>&1 \
  && ok || bad "7.5 the real apply writes the rebase job record for PR 21"
grep -q 'machine destroy' "$T/fly.txt" && ok || bad "7.5 the machine is still handled"
[ -f "$LOCALDIR/REBASE" ] && ok || bad "7.5 rc 0 from the real apply stamps REBASE"
[ -f "$LOCALDIR/COMMENTED" ] && ok || bad "7.5 the dir still owes no board close-out"
[ "$(rr_count)" = 0 ] && ok || bad "7.5 still never a remote result"
[ -s "$T/ssh.txt" ] && bad "7.5 the relay ssh must never run for a rebase" || ok

# ── 7.8 no lib at all (a half-synced box): a missing apply is a REFUSAL ─────
# The one shape that must never read as success: the function is not there, so
# nothing was applied, so the row cannot be closed.
rm -f "$H/bin/lib/merge-conductor-lib.sh"
pool "$RKEY" 21 "$REBASED_RESULT" 0
grep -q "rc=127" "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "7.8 a missing mc_pool_rebase_apply must alert as rc=127: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "\"key\":\"$RKEY\".*\"status\":\"done\"" "$T/req.txt" \
  && bad "7.8 THE POINT: an apply that is not on the box must never close the row done" || ok
[ -f "$LOCALDIR/REBASE" ] && bad "7.8 no REBASE sentinel when nothing applied" || ok
[ "$(rr_count)" = 0 ] && ok || bad "7.8 and never a fall-through to the build path"
fixture_lib

# ── 7.6 PR_CREATED under the same RB- machine is STILL a build ──────────────
pool "$RKEY" 21 "PR_CREATED https://github.com/o/r/pull/55
TIER: 1" 0
[ -f "$H/state/remote-results/tproj/$RKEY.json" ] \
  && ok || bad "7.6 THE POINT: PR_CREATED is not a rebase word — the build path must be untouched"
[ -s "$T/apply.txt" ] && bad "7.6 a build RESULT must never reach the apply" || ok
[ -f "$LOCALDIR/REBASE" ] && bad "7.6 no REBASE sentinel for a build" || ok
[ -s "$T/gh.txt" ] && ok || bad "7.6 the PR_CREATED gate still verifies against GitHub"

# ── 7.7 BUILD_DEFERRED under an RB- key FAILS the row, never requeues ───────
# A requeue rebuilds the queue file out of the machine json, which carries no
# `rebase` object — so the next machine would receive {ticket_id:"21",key:"RB-…"}
# and run an ordinary BUILD of "ticket 21", with a PR and a board comment nobody
# asked for. That is the exact row bin/fly-dispatch.sh refuses in §6.3.
QD="$H/state/build-queue/tproj"
pool "$RKEY" 21 "BUILD_DEFERRED warm-up failed" 0
[ -s "$T/apply.txt" ] && bad "7.7 a deferral must never reach the apply" || ok
[ -f "$LOCALDIR/DEFERRED" ] && ok || bad "7.7 the DEFERRED sentinel is still stamped"
[ -f "$LOCALDIR/COMMENTED" ] \
  && ok || bad "7.7 a deferred rebase dir owes no board close-out either"
ls "$QD"/RB-*.json >/dev/null 2>&1 \
  && bad "7.7 THE POINT: no requeue file — $(ls "$QD") would build ticket 21" || ok
ls "$QD"/RB-*.failed.json >/dev/null 2>&1 \
  && bad "7.7 no .failed.json either — br_from_queue rebuilds ticket 21 from it" || ok
grep -q "PATCH https://jobs.invalid/api/queue .*\"key\":\"$RKEY\".*\"status\":\"failed\"" "$T/req.txt" \
  && ok || bad "7.7 the row must be closed failed: $(cat "$T/req.txt")"
# A requeue is close-then-enqueue (QROW's `requeue` arm): the `failed` PATCH
# above is only half of it, so the POST is what "not requeued" actually denies.
grep -q "POST https://jobs.invalid/api/queue .*\"key\":\"$RKEY\"" "$T/req.txt" \
  && bad "7.7 THE POINT: nothing may re-enqueue the row: $(cat "$T/req.txt")" || ok
# The resolver's two row triggers (bin/blocked-resolver.sh br_from_queue).
grep -qE '"reason":"[^"]*(died|deferred) [0-9]+ times' "$T/req.txt" \
  && bad "7.7 the reason must not read as a resolver rebuild trigger: $(cat "$T/req.txt")" || ok
grep -q '"stage":"pool_deferred"' "$T/beat.txt" \
  && bad "7.7 a rebase stand-down must not beat as a deferred build" || ok
N=$(grep -c "$LOCALDIR" "$H/logs/ALERTS.log" 2>/dev/null | head -1)
[ "$N" = 1 ] \
  && ok || bad "7.7 exactly one ALERTS line naming the evidence dir, got $N: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ── 7.10 a DEAD RB- machine FAILS the row, never requeues ───────────────────
# Empty RESULT fixture so RES is empty and the liveness path runs; MSTATE_FIX
# makes `fly machine status` answer `stopped`, which is a death.
pool "$RKEY" 21 "" 0 stopped
ls "$QD"/RB-*.json >/dev/null 2>&1 \
  && bad "7.10 THE POINT: a dead rebase must not requeue as a build — $(ls "$QD")" || ok
ls "$QD"/RB-*.failed.json >/dev/null 2>&1 \
  && bad "7.10 no .failed.json — br_from_queue turns every one into a rebuild of ticket 21" || ok
grep -q "PATCH https://jobs.invalid/api/queue .*\"key\":\"$RKEY\".*\"status\":\"failed\"" "$T/req.txt" \
  && ok || bad "7.10 the row must be closed failed: $(cat "$T/req.txt")"
grep -q "POST https://jobs.invalid/api/queue .*\"key\":\"$RKEY\"" "$T/req.txt" \
  && bad "7.10 THE POINT: nothing may re-enqueue the row: $(cat "$T/req.txt")" || ok
grep -qE '"reason":"[^"]*(died|deferred) [0-9]+ times' "$T/req.txt" \
  && bad "7.10 the reason must not read as a resolver rebuild trigger: $(cat "$T/req.txt")" || ok
grep -q 'machine destroy' "$T/fly.txt" \
  && ok || bad "7.10 the dead machine is still destroyed: $(cat "$T/fly.txt")"
[ -f "$H/state/fly-pool/tproj/m1.json" ] \
  && bad "7.10 the machine tracking file is still removed" || ok
N=$(grep -c "$RKEY" "$H/logs/ALERTS.log" 2>/dev/null | head -1)
[ "$N" = 1 ] \
  && ok || bad "7.10 exactly one ALERTS line naming the key, got $N: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "$RKEY.*died" "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "7.10 the ALERTS line says the machine died"
[ -s "$T/apply.txt" ] && bad "7.10 nothing to apply — there was no RESULT" || ok
[ "$(rr_count)" = 0 ] && ok || bad "7.10 and never a remote result"

# ── 7.11 an ORDINARY dead key keeps today's requeue ─────────────────────────
# The fix is keyed on the RB- prefix only. Everything else must take the
# byte-for-byte path it took before BH-542.
pool TK-9 9 "" 0 stopped
[ -f "$QD/TK-9.json" ] \
  && ok || bad "7.11 THE POINT: an ordinary dead key is still requeued — $(ls "$QD")"
[ "$(jq -r '.ticket_id // ""' "$QD/TK-9.json" 2>/dev/null)" = 9 ] \
  && ok || bad "7.11 the requeue still carries the ticket id"
[ "$(jq -r '.deaths // ""' "$QD/TK-9.json" 2>/dev/null)" = 1 ] \
  && ok || bad "7.11 the first observed death is counted, not parked"
[ -f "$QD/TK-9.failed.json" ] \
  && bad "7.11 one death does not park an ordinary key" || ok
grep -q 'POST https://jobs.invalid/api/queue .*"key":"TK-9".*"ticket_id":"9"' "$T/req.txt" \
  && ok || bad "7.11 the requeue still re-enqueues the row: $(cat "$T/req.txt")"
grep -q 'rebase' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "7.11 the RB- arm must not fire for TK-9: $(cat "$H/logs/ALERTS.log" 2>/dev/null)" || ok

# ── 7.9 near-miss first words must not take the rebase branch ──────────────
# `RESULT_MALFORMED` starts with RESULT_, not REBASE_; a PLAN_BLOCKED line that
# merely CONTAINS the word CONFLICT is not a conflict RESULT. Either one routed
# to the apply would be a rebase applied out of a build that never rebased.
for W in "RESULT_MALFORMED PR_CREATED | SIZE: 3" "PLAN_BLOCKED CONFLICT in thread"; do
  pool "$RKEY" 21 "$W" 0
  [ -s "$T/apply.txt" ] && bad "7.9 '$W' must never reach the apply: $(cat "$T/apply.txt")" || ok
  [ -f "$LOCALDIR/REBASE" ] && bad "7.9 '$W' must not stamp REBASE" || ok
done

echo "rebase-on-pool-reap.bh-542-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
