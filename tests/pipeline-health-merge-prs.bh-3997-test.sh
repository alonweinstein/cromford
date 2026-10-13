#!/bin/bash
# tests/pipeline-health-merge-prs.bh-3997-test.sh — BH-3997: bin/pipeline-health.sh's
# three merge alerts carry their PRs as a machine-readable `prs=<owner/repo>#<n>[,…]`
# token, keep their dedupe keys, and land on the condition key that
# bin/lib/alert-state.sh's collapse rules give them.
#   P1  stalepr (awaiting merge) — ` prs=o/r#50,o/r#51` at the END of the line
#   P2  lead merge unqueued — `(labels: …); prs=<slug>#31; ` and the URL still last
#   P3  sweep should have landed — `not in the merge queue: prs=<slug>#<n>; `
#   P4  each emitted line keys to its ph-* condition id
# Each block is extracted VERBATIM between its markers and run with alert()
# stubbed to record `ttl|key|line`.
# Run from anywhere: bash tests/pipeline-health-merge-prs.bh-3997-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
PH="$DIR/bin/pipeline-health.sh"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
key() { ( . "$DIR/bin/lib/alert-state.sh"; alert_state_key "[pipeline-health] $1" ); }
block() { awk -v a="$1" -v b="$2" 'index($0,a)==1{f=1;next} index($0,b)==1{exit} f' "$PH"; }
mkdir -p "$T/fakebin" "$T/bin/lib" "$T/logs" "$T/state/merge-conductor" "$T/builds" "$T/s"
export ALERTS_CONF="$T/flags/alerts.conf"

# ── P1 stalepr ─────────────────────────────────────────────────────────────
block '# >>> stalepr detector' '# <<< stalepr detector' > "$T/c1.sh"
[ -s "$T/c1.sh" ] && ok || bad "P1: the stalepr block did not extract"
printf 'ts\to/r\n' > "$T/fleet.conf"
( H="$T"; PROJECTS=ts
  gh_budget_low() { return 1; }
  harness_pr_list() {
    jq -nc --arg old "$(iso $((NOW - 50000)))" --arg new "$(iso $((NOW - 600)))" \
      '[{number:50,createdAt:$old,title:"a",isDraft:false},{number:51,createdAt:$old,title:"b",isDraft:false},
        {number:52,createdAt:$new,title:"c",isDraft:false},{number:53,createdAt:$old,title:"d",isDraft:true}]'
  }
  alert() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$T/a1.txt"; }
  # shellcheck disable=SC1090
  . "$T/c1.sh" ) 2> "$T/e1.txt"
L1=$(cut -d'|' -f3- "$T/a1.txt" 2>/dev/null)
grep -q "^21600|stalepr:ts|ts: harness PR(s) #50,#51 open >12h awaiting merge — " "$T/a1.txt" && ok \
  || bad "P1: key, TTL and prose must be unchanged: $(cat "$T/a1.txt" 2>/dev/null) err=$(head -c 300 "$T/e1.txt")"
grep -q ' prs=o/r#50,o/r#51$' <<<"$L1" && ok || bad "P1: the line must end with ' prs=o/r#50,o/r#51': $L1"
[ "$(key "$L1")" = "ph-awaitmerge-o-r" ] && ok || bad "P4: stalepr line must key ph-awaitmerge-o-r (got '$(key "$L1")')"

# ── P2 lead merge unqueued ─────────────────────────────────────────────────
block '# >>> lead merge unqueued (BH-3778)' '# <<< lead merge unqueued' > "$T/c2.sh"
[ -s "$T/c2.sh" ] && ok || bad "P2: the lead merge unqueued block did not extract"
SLUG=example-org/proj-os
jq -nc '[{number:31, draft:false, head:{sha:"sha310000000000000"}, base:{ref:"main", repo:{default_branch:"main"}}, labels:[{name:"merge-queue"}]}]' > "$T/list.json"
jq -nc --arg u "$(iso $((NOW - 2700)))" '{statuses:[{context:"lead-verdict", state:"success", updated_at:$u}]}' > "$T/s/31"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "api repos/example-org/proj-os/pulls?state=open&per_page=100") cat "$CT/list.json" ;;
  "api repos/example-org/proj-os/commits/sha310000000000000/status") cat "$CT/s/31" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"
touch "$T/active.txt"
( export PATH="$T/fakebin:$PATH" CT="$T" LEAD_REVIEW_AUTO_REPOS="$SLUG"
  H="$T"; ACTIVE="$T/active.txt"; FIRED="$T/fired.txt"
  gh_budget_low() { return 1; }
  alert() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$T/a2.txt"; }
  # shellcheck disable=SC1090
  . "$T/c2.sh" ) 2> "$T/e2.txt"
L2=$(cut -d'|' -f3- "$T/a2.txt" 2>/dev/null)
grep -q "^604800|leadunqueued:$SLUG#31:sha310000000|" "$T/a2.txt" && ok || bad "P2: key/TTL must be unchanged: $(cat "$T/a2.txt" 2>/dev/null) err=$(head -c 300 "$T/e2.txt")"
grep -q "(labels: merge-queue); prs=$SLUG#31; the conductor" <<<"$L2" && grep -q "https://github.com/$SLUG/pull/31\$" <<<"$L2" && ok \
  || bad "P2: want '(labels: merge-queue); prs=$SLUG#31; the conductor' and the URL last: $L2"
[ "$(key "$L2")" = "ph-leadunqueued-example-org-proj-os-31" ] && ok || bad "P4: lead line must key ph-leadunqueued-example-org-proj-os-31 (got '$(key "$L2")')"

# ── P3 sweep should have landed ────────────────────────────────────────────
block '# ── 12. Sweep should have landed' '# <<< sweep should have landed' > "$T/c3.sh"
[ -s "$T/c3.sh" ] && ok || bad "P3: the sweep block did not extract"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/pr-terminal.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  "api repos/o/r -q .id") exit 0 ;;
  *"repos/o/r/pulls/"[0-9]*)
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -nc '{state:"open", merged:false, merged_at:null, mergeable_state:"clean", user:{login:"operator"}, head:{ref:"b", sha:"headsha7aaaa"}}' ;;
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "$((NOW+3600))" "$((NOW+3600))" ;;
  *) echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"
REC="$T/builds/pool-ts-TK-7-202609260001"; mkdir -p "$REC"
echo "PR_CREATED https://github.com/o/r/pull/7" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
: > "$T/state/merge-conductor/pr-state.tsv"; : > "$T/logs/merge-conductor.log"
echo "https://github.com/o/r/pull/7 headsha7aaaa $((NOW - 2400))" > "$T/state/sweep-clean-seen.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" NOW GH_BUDGET_TTL_S=0; unset GH_TOKEN
  bash -c '
    set -uo pipefail
    H="$T"
    alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/a3.txt"; }
    job_verdict() { return 2; }
    . "$T/bin/lib/gh-repo-token.sh"
    . "$T/bin/lib/gh-budget.sh"
    . "$T/bin/lib/pr-terminal.sh"
    . "$0"' "$T/c3.sh" ) 2> "$T/e3.txt"
L3=$(cut -d'|' -f3- "$T/a3.txt" 2>/dev/null)
grep -q "^3600|sweepstall:o/r#7|" "$T/a3.txt" && ok || bad "P3: key/TTL must be unchanged: $(cat "$T/a3.txt" 2>/dev/null) err=$(head -c 300 "$T/e3.txt")"
grep -q "and not in the merge queue: prs=o/r#7; no conductor row" <<<"$L3" && ok || bad "P3: want 'not in the merge queue: prs=o/r#7; ': $L3"
[ "$(key "$L3")" = "ph-approveunqueued-o-r-7" ] && ok || bad "P4: sweep line must key ph-approveunqueued-o-r-7 (got '$(key "$L3")')"

echo "pipeline-health-merge-prs.bh-3997: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
