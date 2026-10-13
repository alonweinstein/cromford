#!/bin/bash
# tests/poll-commands-merge-pr.bh-892-test.sh — the console's merge_pr handler,
# EXTRACTED VERBATIM from bin/poll-commands.sh and run against a fixture harness.
#
# THE DEFECT (BH-892, 2026-09-18). Mission Control's merge button posts a
# merge_pr command; the poller ran `gh pr merge`, which is GraphQL. With the
# PAT's GraphQL bucket empty, commands 15934 (project-4 #1598) and 15937 (#1599)
# came back `merge failed: GraphQL: API rate limit already exceeded for user ID
# 2220366` and DEAD-LETTERED — while `PUT /repos/example-org/project-4/pulls/1598/
# merge` landed the same PRs at once.
#
# WHAT THIS PINS:
#   * the request carries the RECORDED pr_url unchanged — the PUT path is that
#     url's slug and number, never a re-derived one
#   * the merge is BOUND to the reviewed sha even though Mission Control's button
#     posts none: the handler reads the ledger's verdict row the way
#     bin/merge-queue.sh's hb_sha does, and only a ledger with no claim ("-")
#     leaves the merge unbound
#   * a 200 acks `merged <url> at <sha>` with OK=true
#   * a 409 acks `refused: …` with GitHub's own reason — a refusal the console
#     shows the requester, NOT the `merge failed:` string that dead-letters
#   * a native-queue repo keeps today's `gh pr merge` (REST has no enqueue), a
#     non-whitelisted url spends no gh call at all, and the kill flag restores
#     the gh line. Since BH-1715 that line carries no `--delete-branch`: the
#     branch goes through the lib's children-first delete after a merge
#
# Extraction is anchored on the `# >>> merge_pr handler` / `# <<< merge_pr
# handler` markers, the same convention tests/poll-commands-handlers-test.sh
# uses — deleting a marker fails this test loudly rather than skipping it.
# Run from anywhere: bash tests/poll-commands-merge-pr.bh-892-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the merge_pr handler"; exit 1; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV

SLUG="example-org/project-4"
PR1598="https://github.com/example-org/project-4/pull/1598"
RSHA="1111bbbb1111"
MSHA="9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f"
M409='Head branch was modified. Review and try the merge again.'

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/env" "$T/bin"
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh; do
  cp "$DIR/bin/lib/$L" "$T/h/bin/lib/" 2>/dev/null || {
    echo "FAIL: bin/lib/$L does not exist — the REST merge ladder has not been built"; exit 1; }
done
# The whitelist the handler builds: every repo registered in fleet.conf.
cat > "$T/h/bin/fleet-conf.sh" <<CONF
#!/bin/bash
[ "\$1" = --projects ] && { echo project-4; exit 0; }
[ "\$2" = repo ] && printf '%s\n' "$SLUG"
exit 0
CONF
chmod +x "$T/h/bin/fleet-conf.sh"

cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
case "$*" in
  *"pr merge"*) printf '%s\n' "$*" >> "$CASE/pr-merge.log"; exit 0 ;;
esac
case "$1 $2" in "api -i") ;; *) exit 1 ;; esac
KIND=get
# The stacked-child list (BH-1483) is a GET like any other, so it gets its own
# fixture: this stub serves every plain GET from one file, and without this arm
# the children list would be handed the pull object and the branch delete would
# fail closed on a body that is not an array.
case "$*" in *"/pulls?state=open&base="*) KIND=children ;; esac
for a in "$@"; do case "$a" in PUT) KIND=put ;; DELETE) KIND=del ;; PATCH) KIND=patch ;; esac; done
[ -f "$CASE/$KIND" ] && { cat "$CASE/$KIND"; exit 0; }
echo "stub gh: no fixture for $KIND" >&2
exit 1
STUB
chmod +x "$T/bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
PATH="$T/bin:$PATH"

extract() { # extract <handler-name> -> a sourceable case body
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$DIR/bin/poll-commands.sh" \
    | sed -e "1s/^    ${1})//" -e '$s/ ;;$//'
}
extract merge_pr > "$T/merge_pr.body"
[ -s "$T/merge_pr.body" ] \
  && ok || { echo "FAIL: could not extract the merge_pr handler — markers missing?"; exit 1; }

new_case() { CASE="$T/case-$1"; export CASE; scratch_rm "$CASE"; mkdir -p "$CASE"; : > "$CASE/gh-calls.log"; }
resp() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"; }
calls()  { cat "$CASE/gh-calls.log" 2>/dev/null; }
# grep -c prints 0 AND exits 1 on no match, so `|| echo 0` would print TWO
# zeroes; a missing file prints nothing at all. Both read as 0 here.
countof() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
nputs()  { countof '-X PUT' "$CASE/gh-calls.log"; }
ncalls() { countof . "$CASE/gh-calls.log"; }
nmerge() { countof . "$CASE/pr-merge.log"; }
merges() { cat "$CASE/pr-merge.log" 2>/dev/null; }

run() { # run <command-id> <payload-json> [queue-provider] [ledger-verdict-row]
  HARNESS="$T/h" ID="$1" PROJECT="project-4" PAYLOAD="$2" CASE="$CASE" QPROV="${3:-none}" \
  LEDGER="${4:-}" \
    bash -c '
      set -uo pipefail
      OK=false; RESULT=""; OUTCOME=""
      mc_queue_provider() { printf %s "${QPROV:-none}"; }
      mc_pr_queued() { [ "${QPROV:-none}" = github ]; }
      # bin/poll-commands.sh sources bin/jobs-client.sh before this block, so
      # job_verdict is in scope on a real box whenever the worker answers. The
      # row is the verdict TSV; field 6 is the sha the review was bound to.
      if [ -n "${LEDGER:-}" ]; then job_verdict() { printf "%s\n" "$LEDGER"; }; fi
      [ -r "$HARNESS/bin/lib/gh-pr-merge.sh" ] && . "$HARNESS/bin/lib/gh-pr-merge.sh"
      . "$0"
      printf "OK=%s\nRESULT=%s\nOUTCOME=%s\n" "$OK" "$RESULT" "$OUTCOME"' "$T/merge_pr.body"
}
okof()  { sed -n 's/^OK=//p' <<<"$1"; }
resof() { sed -n 's/^RESULT=//p' <<<"$1"; }
outof() { sed -n 's/^OUTCOME=//p' <<<"$1"; }   # BH-932: the terminal-refusal marker

# ── 1. the happy path: the RECORDED pr_url, over REST ────────────────────────
new_case merged
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp children '200 OK' '[]'   # BH-1483: nothing is stacked on this head
resp del '204 No Content' ''
OUT=$(run 15934 "{\"pr_url\":\"$PR1598\",\"sha\":\"$RSHA\"}")
[ "$(okof "$OUT")" = true ] && ok || bad "1: a REST merge must ack ok, got '$OUT' calls=$(calls)"
grep -q "^merged $PR1598" <<<"$(resof "$OUT")" \
  && ok || bad "1: the ack must read 'merged $PR1598 …', got '$(resof "$OUT")'"
grep -qF "$MSHA" <<<"$(resof "$OUT")" \
  && ok || bad "1: the ack must carry the merge sha, got '$(resof "$OUT")'"
[ "$(nputs)" = 1 ] && ok || bad "1: exactly one PUT, got $(nputs): $(calls)"
grep -q -- 'api -i -X PUT repos/example-org/project-4/pulls/1598/merge' "$CASE/gh-calls.log" \
  && ok || bad "1: the PUT path must be the RECORDED pr_url's slug and number, got: $(calls)"
grep -q -- "-f sha=$RSHA" "$CASE/gh-calls.log" \
  && ok || bad "1: the payload's sha must ride on the PUT, got: $(calls)"
[ "$(nmerge)" = 0 ] && ok || bad "1: zero gh pr merge, got: $(merges)"
# BH-1483 rides this lane too: the console's merge asks for the branch delete, so
# the REAL handler must reach the stacked-child list and then the DELETE. This is
# the production entry point for that path — the lib's own suite drives the lib.
{ [ "$(countof '/pulls?state=open&base=' "$CASE/gh-calls.log")" = 1 ] \
  && [ "$(countof '-X DELETE' "$CASE/gh-calls.log")" = 1 ]; } \
  && ok || bad "1: the handler's branch delete must list the stacked children and then delete, got: $(calls)"

# ── 1b. THE CONSOLE POSTS NO SHA — the ledger's reviewed sha binds the merge ──
# console-ui/src/screens/PR.js posts {type, project, ticket, pr_url} and nothing
# else, which is the payload EVERY production console merge arrives with. Without
# the ledger lookup this lane would merge unbound, and a head that moved after the
# approval would land code no reviewer read.
LROW=$(printf 'APPROVE\t2\tclaude\t-\tjob-1\t%s' "$RSHA")
new_case ledger-sha
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp children '200 OK' '[]'   # BH-1483: nothing is stacked on this head
resp del '204 No Content' ''
OUT=$(run 15935 "{\"pr_url\":\"$PR1598\"}" none "$LROW")
grep -q -- "-f sha=$RSHA" "$CASE/gh-calls.log" \
  && ok || bad "1b: the console's own payload carries no sha, so the LEDGER's reviewed sha must ride on the PUT, got: $(calls)"
[ "$(nputs)" = 1 ] && ok || bad "1b: exactly one PUT, got $(nputs): $(calls)"
{ [ "$(okof "$OUT")" = true ] && grep -q "^merged $PR1598" <<<"$(resof "$OUT")"; } \
  && ok || bad "1b: a ledger-bound merge acks like any other, got '$(resof "$OUT")'"

# ── 1c. a ledger with NO claim leaves the merge unbound — never a guessed sha ──
LROW_NOCLAIM=$(printf 'APPROVE\t2\tclaude\t-\tjob-1\t-')
new_case ledger-noclaim
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp children '200 OK' '[]'   # BH-1483: nothing is stacked on this head
resp del '204 No Content' ''
OUT=$(run 15936 "{\"pr_url\":\"$PR1598\"}" none "$LROW_NOCLAIM")
grep -q -- '-f sha=' "$CASE/gh-calls.log" \
  && bad "1c: a ledger row that makes no claim ('-') must never become a sha on the PUT, got: $(calls)" || ok
{ [ "$(okof "$OUT")" = true ] && [ "$(nputs)" = 1 ]; } \
  && ok || bad "1c: an unbound console merge is today's behaviour, not a refusal, got '$(resof "$OUT")'"

# ── 2. a 409 is REFUSED with the reason — never the dead-lettering string ────
new_case refused
resp put '409 Conflict' "{\"message\":\"$M409\"}"
OUT=$(run 15937 "{\"pr_url\":\"$PR1598\",\"sha\":\"$RSHA\"}")
[ "$(okof "$OUT")" = false ] && ok || bad "2: a refused merge must not ack ok, got '$OUT'"
[ "$(outof "$OUT")" = refused ] && ok || bad "2: a 409 must ack OUTCOME=refused so the console row is terminal (BH-932), got '$OUT'"
grep -q '^refused:' <<<"$(resof "$OUT")" \
  && ok || bad "2: a 409 must ack 'refused: …', got '$(resof "$OUT")'"
grep -qF "$M409" <<<"$(resof "$OUT")" \
  && ok || bad "2: GitHub's own reason must reach the requester, got '$(resof "$OUT")'"
grep -q 'merge failed:' <<<"$(resof "$OUT")" \
  && bad "2: 'merge failed:' is the string the dead letters carried — a refusal must not use it" || ok
[ "$(nmerge)" = 0 ] && ok || bad "2: a 409 must never fall back to gh pr merge, got: $(merges)"

# ── 2b. a 405 park is a refusal too ─────────────────────────────────────────
new_case park
resp put '405 Method Not Allowed' '{"message":"Base branch was modified. Review and try the merge again."}'
OUT=$(run 15938 "{\"pr_url\":\"$PR1598\"}")
{ [ "$(okof "$OUT")" = false ] && grep -q '^refused:' <<<"$(resof "$OUT")"; } \
  && ok || bad "2b: a 405 must ack 'refused: …', got '$(resof "$OUT")'"
[ "$(outof "$OUT")" = refused ] && ok || bad "2b: a 405 must ack OUTCOME=refused (BH-932), got '$OUT'"
grep -q 'Base branch was modified' <<<"$(resof "$OUT")" \
  && ok || bad "2b: the park reason must reach the requester, got '$(resof "$OUT")'"

# ── 3. a rate-limited REST ladder falls back to today's line ────────────────
new_case capped
resp put '403 Forbidden' '{"message":"API rate limit already exceeded for user ID 2220366"}'
OUT=$(run 15939 "{\"pr_url\":\"$PR1598\",\"sha\":\"$RSHA\"}")
[ "$(nmerge)" = 1 ] \
  && ok || bad "3: with no REST verdict the poller must still run today's gh pr merge, got: $(merges)"
# TEST-CHANGE (BH-1715): this used to pin --delete-branch on the fallback line.
# Real gh deletes the head ref without retargeting stacked PRs, and GitHub
# closes them; the branch now goes through the lib's children-first delete
# (tests/branch-delete-order.bh-1715-test.sh D).
grep -q -- '--delete-branch' "$CASE/pr-merge.log" \
  && bad "3: the fallback must not hand --delete-branch to gh, got: $(merges)" || ok
{ [ "$(okof "$OUT")" = true ] && grep -q "^merged $PR1598" <<<"$(resof "$OUT")"; } \
  && ok || bad "3: the fallback merge must ack exactly as it does today, got '$(resof "$OUT")'"

# ── 4. a native-queue repo: REST cannot enqueue, so today's call stands ─────
new_case queue
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(run 15940 "{\"pr_url\":\"$PR1598\",\"sha\":\"$RSHA\"}" github)
[ "$(nputs)" = 0 ] && ok || bad "4: a merge-queue repo must spend NO REST merge call, got: $(calls)"
[ "$(nmerge)" = 1 ] && ok || bad "4: the enqueue is still gh pr merge, got: $(merges)"
grep -q '^queued ' <<<"$(resof "$OUT")" \
  && ok || bad "4: an enqueue must be reported as queued, not merged, got '$(resof "$OUT")'"

# ── 5. a non-whitelisted url spends no gh call at all ───────────────────────
new_case notours
OUT=$(run 15941 '{"pr_url":"https://github.com/someone/else/pull/1"}')
[ "$(ncalls)" = 0 ] && ok || bad "5: a non-whitelisted url must spend zero gh calls, got: $(calls)"
grep -q '^refused: not a whitelisted' <<<"$(resof "$OUT")" \
  && ok || bad "5: a non-whitelisted url keeps today's refusal, got '$(resof "$OUT")'"

# ── 6. the kill flag: today's behaviour, byte for byte ─────────────────────
new_case killflag
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
touch "$T/h/flags/pr-merge-rest-off"
OUT=$(run 15942 "{\"pr_url\":\"$PR1598\",\"sha\":\"$RSHA\"}")
rm -f "$T/h/flags/pr-merge-rest-off"
[ "$(nputs)" = 0 ] && ok || bad "6: the kill flag must make ZERO REST calls, got: $(calls)"
[ "$(nmerge)" = 1 ] && ok || bad "6: the kill flag must leave today's gh pr merge in place, got: $(merges)"
{ [ "$(okof "$OUT")" = true ] && grep -q "^merged $PR1598" <<<"$(resof "$OUT")"; } \
  && ok || bad "6: the kill flag must ack exactly as today, got '$(resof "$OUT")'"

echo "poll-commands-merge-pr.bh-892-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
