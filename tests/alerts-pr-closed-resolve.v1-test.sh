#!/bin/bash
# tests/alerts-pr-closed-resolve.v1-test.sh — V1 alert hygiene (2026-09-25):
# an alert whose subject is "this PR is open and stuck" closes when the PR does.
#   P1  bin/alerts-resolve-closed-prs.sh, handed the PRs a pull_request.closed
#       wake reported, resolves the mq-<kind>:<project>:<N> rows and the
#       PR-open-subject rows naming those PRs (any repo casing) — and nothing
#       that merely mentions the PR (a migration still owed after the merge),
#       and without asking GitHub anything
#   P2  it fails soft: no args or no console = exit 0, no request
#   P3  mq-headbound / mq-tc rows are NEVER closed by the wake: the webhook does
#       not say merged vs closed, and a MERGE of an unreviewed head or a failing
#       typecheck is the problem getting worse. bin/alerts-groom.sh, which asks
#       GitHub the state, settles those only on a close without merge.
# The groomer's own PR rule (scoped to the same subjects) is pinned in
# tests/alerts-groom-pr-scope.v1-test.sh.
# The wake-class half (the launch with the closed PRs as arguments) is in
# tests/wake-pr-closed-drives-lanes.bh-1034-test.sh, sections 1b-3b.
# Run from anywhere: tests/alerts-pr-closed-resolve.v1-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/env" "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/stub" "$T/bin"
export HARNESS="$T" PATH="$T/stub:$PATH" FLEET_CONF="$T/fleet.conf"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=s\n' > "$T/env/global.env"
cat > "$FLEET_CONF" <<'CONF'
project-4    example-org/project-4    - - 8 box-project-4-1 10.0.0.2
project-9 example-org/project-9 - - 5 box-project-9-1 10.0.0.3
CONF
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""; url=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && printf '%s\n' "\$a" >> "$T/posts.jsonl"
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
echo "\$url" >> "$T/curl.log"
case "\$url" in
  */api/alerts/open) cat "$T/open.json" ;;
  */api/alerts/resolve) echo '{"resolved":1}' ;;
  *) echo '{}' ;;
esac
STUB
cat > "$T/stub/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$T/gh.log"
case "\$*" in
  *project-9/pull/789*|*project-4/pull/1756*) echo MERGED ;;
  *) echo OPEN ;;
esac
STUB
chmod +x "$T/stub/curl" "$T/stub/gh"
reset() { rm -f "$T/posts.jsonl" "$T/gh.log" "$T/curl.log"; : > "$T/logs/alerts-groom.log"; }

cat > "$T/open.json" <<'JSON'
{"alerts":[
 {"id":1,"akey":"mq-hb-lander:project-4:1756","project":"project-4","line":"[UNTRIAGED 45m] Merge queue: #1756 rebase CONFLICTS with main. Needs a hand: https://github.com/example-org/project-4/pull/1756"},
 {"id":2,"akey":"mq-headbound:project-4:1757","project":"project-4","line":"[UNTRIAGED 45m] Merge queue: #1757 head is not the approved sha: https://github.com/example-org/project-4/pull/1757"},
 {"id":3,"akey":"alert:502234827ebc:20260924","project":"project-9","line":"2026-09-24 21:46:18Z [blocked-resolver] ESCALATED project-9/example-org-project-9-789 (review-changes-requested): The PR is OPEN and untouched: https://github.com/example-org/project-9/pull/789. This is an outcome record"},
 {"id":4,"akey":"migration:example-org/project-4#1756","project":"project-4","line":"[UNTRIAGED 45m] PR #1756 shipped migration SQL — confirm it is applied to prod https://github.com/example-org/project-4/pull/1756"},
 {"id":5,"akey":"alert:zz:20260924","project":"project-4","line":"[rebase-train] https://github.com/example-org/project-4/pull/17560 parked after 2 failed rounds"},
 {"id":6,"akey":"","project":"project-4","line":"[rebase-train] https://github.com/example-org/project-4/pull/1756 parked after 2 failed rounds"}
]}
JSON

# ── P1 the wake-driven resolver ────────────────────────────────────────────
reset
"$DIR/bin/alerts-resolve-closed-prs.sh" "example-org/project-4#1756" "example-org/project-9#789"; RC=$?
[ "$RC" = 0 ] && ok || bad "P1: rc=$RC"
IDS=$(jq -c '.ids' "$T/posts.jsonl" 2>/dev/null)
[ "$IDS" = "[1,3,6]" ] && ok || bad "P1: resolved ids $IDS, want [1,3,6] (mq akey, capitalised repo, empty akey) — never #2 (other PR), #4 (migration still owed), #5 (PR 17560)"
jq -r .reason "$T/posts.jsonl" | grep -qx pr-closed-wake && ok || bad "P1: the resolve must record reason pr-closed-wake: $(cat "$T/posts.jsonl")"
[ ! -s "$T/gh.log" ] && ok || bad "P1: the webhook is the evidence — no GitHub call: $(cat "$T/gh.log")"
grep -q 'pr-closed wake: resolved 3' "$T/logs/alerts-groom.log" && ok || bad "P1: no summary line: $(cat "$T/logs/alerts-groom.log")"

# ── P2 fails soft ──────────────────────────────────────────────────────────
reset
"$DIR/bin/alerts-resolve-closed-prs.sh"; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/curl.log" ] && ok || bad "P2: no args must be a quiet no-op (rc=$RC)"
"$DIR/bin/alerts-resolve-closed-prs.sh" "not-a-pr" "example-org/project-4#abc"; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/posts.jsonl" ] && ok || bad "P2: malformed args must resolve nothing"
mv "$T/env/global.env" "$T/env/global.env.off"
"$DIR/bin/alerts-resolve-closed-prs.sh" "example-org/project-4#1756"; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/curl.log" ] && ok || bad "P2: no console must be a quiet no-op (rc=$RC)"
mv "$T/env/global.env.off" "$T/env/global.env"

# ── P3 head-bound / typecheck rows are the groomer's, not the wake's ────────
reset
cat > "$T/open.json" <<'JSON'
{"alerts":[
 {"id":21,"akey":"mq-headbound:project-4:1756","project":"project-4","line":"Merge queue: #1756 head is not the sha the review approved: https://github.com/example-org/project-4/pull/1756"},
 {"id":22,"akey":"mq-tc:project-4:1756","project":"project-4","line":"Merge queue: #1756 rebase typecheck FAILED — needs a hand: https://github.com/example-org/project-4/pull/1756"},
 {"id":23,"akey":"mq-conflict:project-4:1756","project":"project-4","line":"Merge queue: #1756 has a semantic conflict with main: https://github.com/example-org/project-4/pull/1756"}
]}
JSON
"$DIR/bin/alerts-resolve-closed-prs.sh" "example-org/project-4#1756"
IDS=$(jq -c '.ids' "$T/posts.jsonl" 2>/dev/null)
[ "$IDS" = "[23]" ] && ok || bad "P3: the wake must close mq-conflict but never mq-headbound/mq-tc (got $IDS, want [23])"

echo "alerts-pr-closed-resolve.v1: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
