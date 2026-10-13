#!/bin/bash
# tests/poll-commands-refusal-ack.bh-932-test.sh — a console merge that GitHub
# REFUSED acks as a TERMINAL refusal, and never as a merge.
#
# THE DEFECT (BH-932, 2026-09-24). BH-892 acked a REST-ladder refusal (405 park,
# 409 head moved, 422) as {ok:false, result:"refused: …"}. The console's ack
# handler (example-org/cromford-console src/index.js) keyed on `ok` alone:
# ok:false re-leased the row, re-ran the merge up to three times and then
# dead-lettered it, so a 405 park that cleared would merge a PR on a stale
# click. ok:true is no fix: on any ok merge_pr ack the same handler runs
# `UPDATE builds SET merged=1, stage='pr_merged'`, which marks the still-open
# PR merged and hides its Merge button (review of #1970).
#
# THE FIX spans both repos. The console learned a terminal `refused` status
# (cromford-console tests/command-ack-refused.bh-932-test.mjs); the box
# says so with an explicit `outcome:"refused"` and KEEPS ok:false, so a console
# that predates `refused` reads a retry — never a false merge.
#
# WHAT THIS PINS:
#   A/B/C  rc 4 / 3 / 5 from gh_pr_merge_rest ack OK=false + OUTCOME=refused,
#          with the `refused:` text and GitHub's own reason intact
#   D      an rc that is no GitHub verdict (rc 1: a lib crash, a killed
#          subshell) stays OK=false with no OUTCOME and reads `merge failed: no
#          merge verdict`, never a terminal `refused:`
#   E      the REAL ack POST (`# >>> command ack` block) sends
#          {ok, result, outcome:"refused"} for a refusal and exactly
#          {ok, result} — today's body — for everything else
#   F      a non-whitelisted url keeps its OK=false refusal and spends nothing
#
# POLL_COMMANDS overrides the script the blocks are extracted from (the repro
# runs this suite against origin/main's copy). Missing markers fail loudly.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${POLL_COMMANDS:-$DIR/bin/poll-commands.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

SLUG="example-org/project-4"
PR="https://github.com/example-org/project-4/pull/1598"
RSHA="1111bbbb2222cccc"

mkdir -p "$T/h/bin" "$T/h/logs"
cat > "$T/h/bin/fleet-conf.sh" <<CONF
#!/bin/bash
[ "\$1" = --projects ] && { echo project-4; exit 0; }
[ "\$2" = repo ] && printf '%s\n' "$SLUG"
exit 0
CONF
chmod +x "$T/h/bin/fleet-conf.sh"
# Any gh call at all is a failure of these cases: the ladder is stubbed below.
mkdir -p "$T/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls.log"\nexit 1\n' "$T" > "$T/bin/gh"
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"

extract_handler() {
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$SRC" | sed -e "1s/^    ${1})//" -e '$s/ ;;$//'
}
extract_handler merge_pr > "$T/merge_pr.body"
[ -s "$T/merge_pr.body" ] || { echo "FAIL: could not extract the merge_pr handler from $SRC — markers missing?"; exit 1; }
awk '/^    # >>> command ack/{f=1; next} /^    # <<< command ack/{exit} f{print}' "$SRC" > "$T/ack.body"

run() { # run <rc> <message> <payload-json>
  : > "$T/gh-calls.log"; : > "$T/rest-calls.log"
  HARNESS="$T/h" ID=16001 PROJECT=project-4 PAYLOAD="$3" STUB_RC="$1" STUB_MSG="$2" T="$T" \
    bash -c '
      set -uo pipefail
      OK=false; RESULT=""; OUTCOME=""
      # TEST-CHANGE (BH-2199): `none`, was `mergify`. This suite drives the REST
      # merge ladder; a Mergify queue_rules repo now enqueues instead and never
      # reaches it (tests/poll-commands-mergify.bh-2199-test.sh), so a no-queue
      # repo is the provider that takes the path under test. Assertions unchanged.
      mc_queue_provider() { printf none; }
      mc_pr_queued() { return 1; }
      gh_pr_merge_rest() { printf "%s\n" "$*" >> "$T/rest-calls.log"; printf %s "$STUB_MSG"; return "$STUB_RC"; }
      . "$0"
      printf "OK=%s\nRESULT=%s\nOUTCOME=%s\n" "$OK" "$RESULT" "$OUTCOME"' "$T/merge_pr.body"
}
okof()  { sed -n 's/^OK=//p' <<<"$1"; }
resof() { sed -n 's/^RESULT=//p' <<<"$1"; }
outof() { sed -n 's/^OUTCOME=//p' <<<"$1"; }
nlines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }

# ── A. 409 head moved: terminal, and the person still reads why ─────────────
M409='Head branch was modified. Review and try the merge again.'
OUT=$(run 4 "$M409" "{\"pr_url\":\"$PR\",\"sha\":\"$RSHA\"}")
[ "$(okof "$OUT")" = false ] && ok || bad "A: a 409 refusal must NEVER ack OK=true — the console stamps an ok merge_pr merged, got '$OUT'"
[ "$(outof "$OUT")" = refused ] && ok || bad "A: a 409 refusal must ack OUTCOME=refused so the row is terminal, got '$OUT'"
grep -q "^refused: head moved since sha ${RSHA:0:8}" <<<"$(resof "$OUT")" \
  && ok || bad "A: RESULT must start 'refused: head moved since sha ${RSHA:0:8}', got '$(resof "$OUT")'"
grep -qF "$M409" <<<"$(resof "$OUT")" && ok || bad "A: GitHub's reason must reach the person, got '$(resof "$OUT")'"
[ "$(nlines "$T/rest-calls.log")" = 1 ] && ok || bad "A: exactly one REST ladder call, got $(nlines "$T/rest-calls.log")"
[ "$(nlines "$T/gh-calls.log")" = 0 ] && ok || bad "A: a refusal must never fall back to gh pr merge, got: $(cat "$T/gh-calls.log")"

# ── B. 405 park ─────────────────────────────────────────────────────────────
M405='Base branch was modified. Review and try the merge again.'
OUT=$(run 3 "$M405" "{\"pr_url\":\"$PR\"}")
{ [ "$(okof "$OUT")" = false ] && [ "$(outof "$OUT")" = refused ]; } \
  && ok || bad "B: a 405 park must ack OK=false + OUTCOME=refused, got '$OUT'"
grep -q '^refused: GitHub would not merge' <<<"$(resof "$OUT")" \
  && ok || bad "B: RESULT must start 'refused: GitHub would not merge', got '$(resof "$OUT")'"
grep -qF "$M405" <<<"$(resof "$OUT")" && ok || bad "B: the park reason must reach the person, got '$(resof "$OUT")'"

# ── C. 422 / other 4xx refusal ──────────────────────────────────────────────
M422='Pull Request is not mergeable'
OUT=$(run 5 "$M422" "{\"pr_url\":\"$PR\"}")
{ [ "$(okof "$OUT")" = false ] && [ "$(outof "$OUT")" = refused ]; } \
  && ok || bad "C: a 422 refusal must ack OK=false + OUTCOME=refused, got '$OUT'"
{ grep -q '^refused:' <<<"$(resof "$OUT")" && grep -qF "$M422" <<<"$(resof "$OUT")"; } \
  && ok || bad "C: RESULT must be 'refused: …' with the reason, got '$(resof "$OUT")'"

# ── D. no GitHub verdict: NOT terminal, NOT called a refusal ────────────────
OUT=$(run 1 "" "{\"pr_url\":\"$PR\"}")
[ "$(okof "$OUT")" = false ] && ok || bad "D: an rc with no merge verdict must stay OK=false, got '$OUT'"
[ -z "$(outof "$OUT")" ] && ok || bad "D: an rc with no merge verdict must carry no OUTCOME (it stays retryable), got '$OUT'"
grep -q '^merge failed: no merge verdict (rc 1)' <<<"$(resof "$OUT")" \
  && ok || bad "D: RESULT must start 'merge failed: no merge verdict (rc 1)', got '$(resof "$OUT")'"
grep -q '^refused:' <<<"$(resof "$OUT")" \
  && bad "D: an unknown outcome must never read as a GitHub refusal, got '$(resof "$OUT")'" || ok

# ── E. the real ack POST: outcome only on a refusal, today's body otherwise ─
if [ -s "$T/ack.body" ]; then
  ack_post() { # ack_post <OK> <RESULT> [OUTCOME] -> the captured API args, one per line
    CONSOLE_URL="https://console.example" ID=16001 OK="$1" RESULT="$2" OUTCOME="${3:-}" T="$T" bash -c '
      set -uo pipefail
      API() { printf "%s\n" "$@" > "$T/api-args"; }
      . "$0"' "$T/ack.body"
    cat "$T/api-args"
  }
  body_of() { awk 'p{print; exit} $0=="-d"{p=1}' <<<"$1"; }
  ARGS=$(ack_post false "refused: head moved — x" refused)
  jq -e '. == {ok:false, result:"refused: head moved — x", outcome:"refused"}' \
    <<<"$(body_of "$ARGS")" >/dev/null \
    && ok || bad "E: a refusal's ack body must be {ok:false,result:\"refused: …\",outcome:\"refused\"}, got '$(body_of "$ARGS")'"
  [ "$(tail -n1 <<<"$ARGS")" = "https://console.example/api/commands/16001/ack" ] \
    && ok || bad "E: the ack must POST to /api/commands/<ID>/ack, got '$(tail -n1 <<<"$ARGS")'"
  ARGS=$(ack_post false "merge failed: no merge verdict (rc 1)")
  jq -e '. == {ok:false, result:"merge failed: no merge verdict (rc 1)"}' <<<"$(body_of "$ARGS")" >/dev/null \
    && ok || bad "E: a failure's ack body must be today's {ok:false,result}, no outcome key, got '$(body_of "$ARGS")'"
  ARGS=$(ack_post true "merged https://github.com/example-org/project-4/pull/1598")
  jq -e '. == {ok:true, result:"merged https://github.com/example-org/project-4/pull/1598"}' <<<"$(body_of "$ARGS")" >/dev/null \
    && ok || bad "E: a merge's ack body must be today's {ok:true,result}, no outcome key, got '$(body_of "$ARGS")'"
else
  bad "E: could not extract the '# >>> command ack' block from $SRC — markers missing?"
fi

# ── F. a non-whitelisted url keeps its non-terminal refusal ────────────────
OUT=$(run 4 "should not be called" '{"pr_url":"https://github.com/someone/else/pull/1"}')
[ "$(okof "$OUT")" = false ] && ok || bad "F: a non-whitelisted url must stay OK=false, got '$OUT'"
[ -z "$(outof "$OUT")" ] && ok || bad "F: the whitelist refusal is unchanged (no OUTCOME; the console reads its refused: prefix), got '$OUT'"
grep -q '^refused: not a whitelisted' <<<"$(resof "$OUT")" \
  && ok || bad "F: RESULT must be the whitelist refusal, got '$(resof "$OUT")'"
{ [ "$(nlines "$T/rest-calls.log")" = 0 ] && [ "$(nlines "$T/gh-calls.log")" = 0 ]; } \
  && ok || bad "F: a non-whitelisted url must spend no merge call"

echo "poll-commands-refusal-ack.bh-932-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
