#!/bin/bash
# tests/poll-commands-mergify.bh-2199-test.sh — Mission Control's Merge button
# on a repo whose .mergify.yml has queue_rules ENQUEUES, never PUTs /merge
# (BH-2199, found in the #2220 review).
#
# THE DEFECT. The merge_pr handler in bin/poll-commands.sh merged over REST
# (PUT /pulls/<n>/merge) on every repo that was not behind GitHub's NATIVE
# queue — Mergify repos included — so one click bypassed the queue that keeps
# main green, exactly like the conductor's old degraded direct merge.
#
# WHAT IS DRIVEN. The handler, EXTRACTED VERBATIM between its `# >>> merge_pr
# handler` / `# <<< merge_pr handler` markers (the convention
# tests/poll-commands-merge-pr.bh-892-test.sh uses). The queue edges are
# stubbed: mc_queue_provider answers `mergify`, mc_pr_view the live head, and
# mc_enqueue_mergify records its call and answers the rc under test. gh is a
# stub that logs every call, so a PUT or a `gh pr merge` cannot hide.
#   Q1  the queue acknowledges: no PUT /merge, no gh pr merge, ONE enqueue on the
#       live head, ack OK=true "queued …"
#   Q2  the queue says nothing (rc 3): no PUT, one enqueue, a terminal
#       `refused:` that says it was NOT merged directly
#   Q3  the head moved since the reviewed sha: refused, and the queue is NOT asked
#   Q4  no sha in the payload: the ledger's reviewed sha binds the ask
#   Q5  the enqueue itself fails (rc 1): a retryable `merge failed:`, no PUT
#   Q6  a repo with NO queue still merges over REST (unchanged)
# Red proof: POLL_COMMANDS=<old copy> bash tests/poll-commands-mergify.bh-2199-test.sh
# Run from anywhere: bash tests/poll-commands-mergify.bh-2199-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the merge_pr handler"; exit 1; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV

SLUG="example-org/mgfy-os"
URL="https://github.com/example-org/mgfy-os/pull/31"
HEAD1="aaaaaaaa1111bbbbbbbb2222cccccccc33334444"
MSHA="9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/env" "$T/bin"
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh; do cp "$DIR/bin/lib/$L" "$T/h/bin/lib/"; done
cat > "$T/h/bin/fleet-conf.sh" <<CONF
#!/bin/bash
[ "\$1" = --projects ] && { echo mgfy; exit 0; }
[ "\$2" = repo ] && printf '%s\n' "$SLUG"
exit 0
CONF
chmod +x "$T/h/bin/fleet-conf.sh"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
case "$*" in *"pr merge"*) printf '%s\n' "$*" >> "$CASE/pr-merge.log"; exit 0 ;; esac
case "$1 $2" in "api -i") ;; *) exit 1 ;; esac
KIND=get
for a in "$@"; do case "$a" in PUT) KIND=put ;; DELETE) KIND=del ;; esac; done
[ -f "$CASE/$KIND" ] && { cat "$CASE/$KIND"; exit 0; }
exit 1
STUB
chmod +x "$T/bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
PATH="$T/bin:$PATH"

SRC="${POLL_COMMANDS:-$DIR/bin/poll-commands.sh}"
awk '$0 ~ "^    # >>> merge_pr handler" {f=1; next} $0 ~ "^    # <<< merge_pr handler" {exit} f {print}' "$SRC" \
  | sed -e '1s/^    merge_pr)//' -e '$s/ ;;$//' > "$T/merge_pr.body"
[ -s "$T/merge_pr.body" ] && ok || { echo "FAIL: could not extract the merge_pr handler — markers missing?"; exit 1; }

new_case() { CASE="$T/case-$1"; export CASE; scratch_rm "$CASE"; mkdir -p "$CASE"; : > "$CASE/gh-calls.log"; : > "$CASE/enqueue.log"; }
resp() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"; }
countof() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
nputs()    { countof '-X PUT' "$CASE/gh-calls.log"; }
nmerge()   { countof . "$CASE/pr-merge.log"; }
nenqueue() { countof . "$CASE/enqueue.log"; }
run() { # run <id> <payload> [provider] [enqueue-rc] [ledger-row]
  HARNESS="$T/h" ID="$1" PROJECT="mgfy" PAYLOAD="$2" CASE="$CASE" QPROV="${3:-mergify}" \
  ENQRC="${4:-0}" LEDGER="${5:-}" LIVEHEAD="${LIVEHEAD:-$HEAD1}" \
    bash -c '
      set -uo pipefail
      OK=false; RESULT=""; OUTCOME=""
      mc_queue_provider() { printf %s "${QPROV:-none}"; }
      mc_pr_queued() { return 1; }
      mc_pr_view() { printf %s "$LIVEHEAD"; }
      mc_enqueue_mergify() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$CASE/enqueue.log"
        [ "$ENQRC" = 3 ] && printf "label merge-queue is applied, but Mergify acknowledged nothing"
        [ "$ENQRC" = 1 ] && printf "label merge-queue could not be added"
        return "$ENQRC"; }
      if [ -n "${LEDGER:-}" ]; then job_verdict() { printf "%s\n" "$LEDGER"; }; fi
      . "$HARNESS/bin/lib/gh-pr-merge.sh"
      . "$0"
      printf "OK=%s\nRESULT=%s\nOUTCOME=%s\n" "$OK" "$RESULT" "$OUTCOME"' "$T/merge_pr.body"
}
okof()  { sed -n 's/^OK=//p' <<<"$1"; }
resof() { sed -n 's/^RESULT=//p' <<<"$1"; }
outof() { sed -n 's/^OUTCOME=//p' <<<"$1"; }
# A PUT would land if anything tried one: the stub answers it 200.
arm_put() { resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"; resp get '200 OK' '{"merged":true,"head":{"ref":"t","repo":{"full_name":"example-org/mgfy-os"}},"base":{"ref":"main"}}'; }

# ── Q1: the queue acknowledges ───────────────────────────────────────────────
new_case q1; arm_put
OUT=$(run 1 "{\"pr_url\":\"$URL\",\"sha\":\"${HEAD1:0:12}\"}" mergify 0)
[ "$(nputs)" = 0 ] && ok || bad "Q1: a Mergify repo must NEVER get PUT /merge from the console (calls: $(cat "$CASE/gh-calls.log"))"
[ "$(nmerge)" = 0 ] && ok || bad "Q1: nor a gh pr merge (got: $(cat "$CASE/pr-merge.log" 2>/dev/null))"
[ "$(nenqueue)" = 1 ] && ok || bad "Q1: exactly ONE queue ask (got $(nenqueue): $(cat "$CASE/enqueue.log"))"
grep -qxF "$SLUG $URL $HEAD1" "$CASE/enqueue.log" && ok || bad "Q1: the ask is the recorded url on the live head (got: $(cat "$CASE/enqueue.log"))"
[ "$(okof "$OUT")" = true ] && ok || bad "Q1: an acknowledged enqueue acks ok (got: $OUT)"
grep -q "^queued $URL" <<<"$(resof "$OUT")" && ok || bad "Q1: the ack must say queued, never merged (got: $(resof "$OUT"))"

# ── Q2: the queue says nothing ───────────────────────────────────────────────
new_case q2; arm_put
OUT=$(run 2 "{\"pr_url\":\"$URL\"}" mergify 3)
[ "$(nputs)" = 0 ] && [ "$(nmerge)" = 0 ] && ok || bad "Q2: a silent queue must not be bypassed (calls: $(cat "$CASE/gh-calls.log"))"
[ "$(nenqueue)" = 1 ] && ok || bad "Q2: the queue is asked once (got $(nenqueue))"
[ "$(outof "$OUT")" = refused ] && ok || bad "Q2: a silent queue is a terminal refusal the clicker can read (got: $OUT)"
grep -q 'NOT merged directly' <<<"$(resof "$OUT")" && ok || bad "Q2: the refusal must say it was not merged directly (got: $(resof "$OUT"))"
[ "$(okof "$OUT")" = false ] && ok || bad "Q2: never ok:true — the console would stamp it merged"

# ── Q3: the head moved since the reviewed sha ───────────────────────────────
new_case q3; arm_put
OUT=$(run 3 "{\"pr_url\":\"$URL\",\"sha\":\"1111bbbb1111\"}" mergify 0)
[ "$(nenqueue)" = 0 ] && ok || bad "Q3: a moved head must not be queued (got: $(cat "$CASE/enqueue.log"))"
[ "$(nputs)" = 0 ] && ok || bad "Q3: nor merged (calls: $(cat "$CASE/gh-calls.log"))"
[ "$(outof "$OUT")" = refused ] && grep -q 'head moved' <<<"$(resof "$OUT")" && ok || bad "Q3: refused: head moved (got: $OUT)"

# ── Q4: the ledger's reviewed sha binds the ask ─────────────────────────────
new_case q4; arm_put
OUT=$(run 4 "{\"pr_url\":\"$URL\"}" mergify 0 "APPROVE	x	x	x	x	1111bbbb1111")
[ "$(nenqueue)" = 0 ] && [ "$(outof "$OUT")" = refused ] && ok || bad "Q4: a head that is not the ledger's reviewed sha is refused unqueued (got: $OUT; asks: $(cat "$CASE/enqueue.log"))"

# ── Q5: the ask cannot be made ──────────────────────────────────────────────
new_case q5; arm_put
OUT=$(run 5 "{\"pr_url\":\"$URL\"}" mergify 1)
[ "$(nputs)" = 0 ] && ok || bad "Q5: a failed ask must not fall back to PUT /merge (calls: $(cat "$CASE/gh-calls.log"))"
grep -q '^merge failed:' <<<"$(resof "$OUT")" && [ -z "$(outof "$OUT")" ] && ok || bad "Q5: a failed ask is retryable, not a refusal (got: $OUT)"

# ── Q6: a repo with no queue is unchanged ───────────────────────────────────
new_case q6; arm_put; resp children '200 OK' '[]'; resp del '204 No Content' ''
OUT=$(run 6 "{\"pr_url\":\"$URL\",\"sha\":\"${HEAD1:0:12}\"}" none 0)
[ "$(nputs)" = 1 ] && [ "$(nenqueue)" = 0 ] && ok || bad "Q6: a no-queue repo still merges over REST, one PUT and no ask (calls: $(cat "$CASE/gh-calls.log"))"
[ "$(okof "$OUT")" = true ] && ok || bad "Q6: and acks ok (got: $OUT)"

# ── Q7: a box without the conductor lib cannot tell the provider: it refuses ──
# bin/poll-commands.sh stubs the provider as `unloaded` when
# bin/lib/merge-conductor-lib.sh is missing; that must never become a REST merge.
new_case q7; arm_put
OUT=$(run 7 "{\"pr_url\":\"$URL\",\"sha\":\"${HEAD1:0:12}\"}" unloaded 0)
[ "$(nputs)" = 0 ] && [ "$(nmerge)" = 0 ] && [ "$(nenqueue)" = 0 ] && ok || bad "Q7: no lib, no merge of any kind (calls: $(cat "$CASE/gh-calls.log"))"
grep -q '^merge failed:' <<<"$(resof "$OUT")" && [ "$(okof "$OUT")" = false ] && ok || bad "Q7: a no-lib box acks a retryable merge failed (got: $OUT)"
grep -q 'unloaded' "$SRC" && ok || bad "Q7: bin/poll-commands.sh's no-lib fallback must stub the provider as unloaded, not none"

# ── Q8 (BH-2275): an UNREADABLE .mergify.yml probe is `unknown`, and unknown holds ──
new_case q8; arm_put
OUT=$(run 8 "{\"pr_url\":\"$URL\",\"sha\":\"${HEAD1:0:12}\"}" unknown 0)
[ "$(nputs)" = 0 ] && [ "$(nmerge)" = 0 ] && [ "$(nenqueue)" = 0 ] && ok || bad "Q8: an unknown provider must never PUT /merge or guess a queue (calls: $(cat "$CASE/gh-calls.log"); asks: $(cat "$CASE/enqueue.log"))"
grep -q '^merge failed:' <<<"$(resof "$OUT")" && [ "$(okof "$OUT")" = false ] && [ -z "$(outof "$OUT")" ] && ok || bad "Q8: unknown acks a retryable merge failed (got: $OUT)"
grep -q 'could not be read' <<<"$(resof "$OUT")" && ok || bad "Q8: the ack must say the queue probe could not be read (got: $(resof "$OUT"))"

echo "poll-commands-mergify.bh-2199-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
