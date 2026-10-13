#!/bin/bash
# tests/lead-review-context-hotspots.bh-5271-test.sh — BH-5271: the lead review
# prompt carries the project's measured conflict hotspots, as a
# `## Conflict hotspots` section between the host suite tail and the diff, read
# through bin/lib/hotspot-context.sh hc_section. Drives the REAL
# bin/lead-review.sh tick against a scratch harness (scratch_install_closure),
# with these stubbed:
#   * curl  — the jobs worker, including GET /api/conflict-hotspots
#   * gh    — the REST read of pulls/<n>
#   * bin/agent-call.sh — counts calls and keeps each prompt
#
#   H1  rows: the section sits after ## Host suite and before ## Diff, with the
#       cited header and each fixture file with its counts.
#   H2  the request names the request's project and limit=10; a request for
#       other-os asks for project=other-os.
#   H3  never measured (run: null): ABSENT, never "no hotspots"; the review
#       completes.
#   H4  the route answers 502: COULD NOT READ; tick rc 0; the verdict is posted.
#   H5  bin/lib/hotspot-context.sh is not on the box: the section says the lib
#       is not loaded, the log says so, the review completes.
#   H6  PLAN_CONTEXT_HOTSPOT_TOP=0: ABSENT ... off, and no hotspot request.
#   H7  the BH-3546 section pairs stay adjacent; the report says the checklist
#       version line 1 of the checklist names (v2 or later).
#   M1  mutation: drop the section heading from bin/lead-review.sh; H1 goes red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-context-hotspots.bh-5271-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/hotspot-context.sh prompts/lead-review-checklist.md; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PLAN_CONTEXT_HOTSPOT_TOP AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_MAX_PER_TICK

HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log"
# Stubs first: scratch_install_closure never clobbers.
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
cp "\${6#@}" "$T/log/prompt.\$(wc -l < "$T/log/agent-count" | tr -d ' ')"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
[ -f "$HB/bin/lib/hotspot-context.sh" ] && ok || bad "the closure of bin/lead-review.sh does not carry bin/lib/hotspot-context.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
echo box-demo > "$HB/state/box-name"
cat > "$HB/fleet.conf" <<'EOF'
cromford example-org/cromford https://bh.test    /api/board 1 box-demo
other-os      example-org/other         https://other.test /api/board 2 box-demo
EOF

mk_repo() { # mk_repo <project> <pr> -> prints the PR head sha
  local p="$1" pr="$2" o="$T/origin/$1.git" w="$T/work/$1"
  git init -q --bare -b main "$o"; git init -q -b main "$w"
  printf '# %s\n' "$p" > "$w/CLAUDE.md"; echo one > "$w/a.txt"
  git -C "$w" add -A; git -C "$w" commit -qm base; git -C "$w" push -q "$o" main
  echo pr-line-marker >> "$w/a.txt"; git -C "$w" commit -qam "pr change"
  git -C "$w" push -q "$o" "HEAD:refs/pull/$pr/head"
  git clone -q "$o" "$T/repos/$p"
  git -C "$w" rev-parse HEAD
}
SHA=$(mk_repo cromford 41)
OSHA=$(mk_repo other-os 5)

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/conflict-hotspots"*)
    case "\$(cat "$T/hsmode")" in
      fail) code=502; out='{"error":"bad gateway"}' ;;
      *) out=\$(cat "$T/hotspots.json") ;;
    esac ;;
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

ROWS='{"hotspots":[
  {"file":"worker/jobs/schema.sql","conflicts":17,"rebases":9,"window_days":30},
  {"file":"bin/blocked-resolver.sh","conflicts":11,"rebases":4,"window_days":30}],
  "run":{"last_ok_at":"2026-10-05T03:00:00Z","window_days":30},"total":2,"limit":10,"truncated":false}'
LLOG="$HB/logs/lead-review.log"
# setup <hsmode> [repo pr sha] — one request; a clean slate
setup() {
  rm -f "$T/log"/* "$LLOG"
  scratch_rm "$HB/state/lead-reviews"
  cp "$SRC/bin/lead-review.sh" "$HB/bin/"
  [ -f "$T/hc.aside" ] && mv "$T/hc.aside" "$HB/bin/lib/hotspot-context.sh"
  echo "$1" > "$T/hsmode"
  case "$1" in
    never) echo '{"hotspots":[],"run":null,"total":0,"limit":10,"truncated":false}' > "$T/hotspots.json" ;;
    *) printf '%s\n' "$ROWS" > "$T/hotspots.json" ;;
  esac
  local repo="${2:-example-org/cromford}" pr="${3:-41}" sha="${4:-$SHA}"
  echo "$sha" > "$T/livehead"
  jq -nc --arg r "$repo" --argjson p "$pr" --arg s "$sha" '{requests:[{id:"lr-1",repo:$r,pr:$p,head_sha:$s,scope_notes:"only the lane",
    prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
}
tick() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HB/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
}
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
P1="$T/log/prompt.1"
# section <heading> <next heading> — the prompt's lines strictly between the two
section() { awk -v a="$1" -v b="$2" '$0 == a {f=1; next} $0 == b {f=0} f' "$P1" 2>/dev/null; }
lno() { grep -nx -- "$1" "$P1" 2>/dev/null | head -n 1 | cut -d: -f1; }
done_posted() { wlog | grep -qE '^POST /api/lead-reviews/lr-1/result .*"outcome":"done".*"verdict":"MERGE"'; }

# ── H1: rows reach the prompt, between the host suite and the diff ──
setup ok; tick
[ "$RC" -eq 0 ] && ok || bad "H1 rc=$RC out=$(cat "$T/out")"
[ "$(agents)" = 1 ] && ok || bad "H1 agent called $(agents) time(s): $(cat "$LLOG" 2>/dev/null)"
hs=$(lno '## Host suite'); ch=$(lno '## Conflict hotspots'); df=$(lno '## Diff')
[ -n "$hs" ] && [ -n "$ch" ] && [ -n "$df" ] && [ "$ch" -gt "$hs" ] && [ "$df" -gt "$ch" ] \
  && ok || bad "H1 order: ## Host suite=$hs ## Conflict hotspots=$ch ## Diff=$df"
S=$(section '## Conflict hotspots' '## Diff')
grep -qxF -- '--- CONFLICT HOTSPOTS (source: conflict_hotspots rows for cromford, GET /api/conflict-hotspots, measured 2026-10-05T03:00:00Z, 30-day window) ---' <<<"$S" \
  && ok || bad "H1 no cited header: $S"
grep -qxF '  1. worker/jobs/schema.sql — 17 conflicts, 9 rebases' <<<"$S" && ok || bad "H1 row 1 missing: $S"
grep -qxF '  2. bin/blocked-resolver.sh — 11 conflicts, 4 rebases' <<<"$S" && ok || bad "H1 row 2 missing: $S"
grep -q '^+pr-line-marker$' "$P1" 2>/dev/null && ok || bad "H1 the diff is not in the prompt"
grep -q 'lr-41-[0-9a-f]*: conflict hotspots yes$' "$LLOG" 2>/dev/null && ok || bad "H1 no state log line: $(cat "$LLOG" 2>/dev/null)"
done_posted && ok || bad "H1 no done result: $(wlog | grep result)"

# ── H2: the request's project and the default limit ──
[ "$(wlog | grep -c '^GET /api/conflict-hotspots')" = 1 ] && ok || bad "H2 hotspot reads: $(wlog | grep conflict-hotspots)"
wlog | grep -qF 'GET /api/conflict-hotspots?project=cromford&limit=10 ' && ok || bad "H2 request: $(wlog | grep conflict-hotspots)"
setup ok example-org/other 5 "$OSHA"; tick
wlog | grep -qF 'GET /api/conflict-hotspots?project=other-os&limit=10 ' && ok || bad "H2 other-os request: $(wlog | grep conflict-hotspots)"
grep -qF 'conflict_hotspots rows for other-os,' "$P1" 2>/dev/null && ok || bad "H2 other-os section: $(section '## Conflict hotspots' '## Diff')"

# ── H3: never measured: ABSENT, not "no hotspots" ──
setup never; tick
S=$(section '## Conflict hotspots' '## Diff')
grep -q '^ABSENT: no conflict_hotspots measurement for cromford yet' <<<"$S" && ok || bad "H3 section: $S"
grep -qi 'no hotspots\|found no file' <<<"$S" && bad "H3 never-measured reads as no hotspots: $S" || ok
[ "$(agents)" = 1 ] && done_posted && [ -s "$HB/state/lead-reviews/lr-41-${SHA:0:12}.md" ] && ok || bad "H3 review did not complete"

# ── H4: outage: COULD NOT READ, the review still completes ──
setup fail; tick
[ "$RC" -eq 0 ] && ok || bad "H4 rc=$RC"
S=$(section '## Conflict hotspots' '## Diff')
grep -q '^COULD NOT READ: conflict_hotspots for cromford' <<<"$S" && ok || bad "H4 section: $S"
[ "$(agents)" = 1 ] && done_posted && ok || bad "H4 review did not complete: $(wlog | grep result)"
grep -q 'conflict hotspots unknown$' "$LLOG" 2>/dev/null && ok || bad "H4 state log: $(cat "$LLOG" 2>/dev/null)"

# ── H5: the lib is not on this box ──
setup ok; mv "$HB/bin/lib/hotspot-context.sh" "$T/hc.aside"; tick
[ "$RC" -eq 0 ] && ok || bad "H5 rc=$RC"
S=$(section '## Conflict hotspots' '## Diff')
grep -q '^COULD NOT READ: bin/lib/hotspot-context.sh is not loaded' <<<"$S" && ok || bad "H5 section: $S"
grep -q 'bin/lib/hotspot-context.sh missing' "$LLOG" 2>/dev/null && ok || bad "H5 no missing-lib log line: $(cat "$LLOG" 2>/dev/null)"
grep -q '^GET /api/conflict-hotspots' "$T/log/worker" 2>/dev/null && bad "H5 a hotspot read happened with no lib" || ok
[ "$(agents)" = 1 ] && done_posted && ok || bad "H5 review did not complete"

# ── H6: knob 0 = off, no request ──
setup ok; PLAN_CONTEXT_HOTSPOT_TOP=0 tick
S=$(section '## Conflict hotspots' '## Diff')
grep -q '^ABSENT: hotspot section off for cromford' <<<"$S" && ok || bad "H6 section: $S"
grep -q '^GET /api/conflict-hotspots' "$T/log/worker" 2>/dev/null && bad "H6 a request was made with the knob at 0" || ok
[ "$(agents)" = 1 ] && done_posted && ok || bad "H6 review did not complete"

# ── H7: BH-3546 pairs stay adjacent; the report names the checklist version ──
setup ok; tick
CKV=$(sed -n '1s/^Checklist-Version: *\([0-9][0-9]*\)$/\1/p' "$SRC/prompts/lead-review-checklist.md")
[ -n "$CKV" ] && [ "$CKV" -ge 2 ] && ok || bad "H7 checklist version is '$CKV', want 2 or later"
rp=$(lno '## Rules pack'); hs=$(lno '## Host suite')
[ -n "$rp" ] && [ -n "$hs" ] && [ -z "$(awk -v a="$rp" -v b="$hs" 'NR > a && NR < b && /^## /' "$P1")" ] \
  && ok || bad "H7 a heading sits between ## Rules pack and ## Host suite"
tt=$(lno '## Ticket thread'); sn=$(lno '## Scope notes')
[ -n "$tt" ] && [ -n "$sn" ] && [ -z "$(awk -v a="$tt" -v b="$sn" 'NR > a && NR < b && /^## /' "$P1")" ] \
  && ok || bad "H7 a heading sits between ## Ticket thread and ## Scope notes"
grep -qx -- "- checklist: v$CKV" "$HB/state/lead-reviews/lr-41-${SHA:0:12}.md" 2>/dev/null && ok || bad "H7 report lacks '- checklist: v$CKV'"

# ── M1: no section heading = H1 red ──
setup ok
sed "/printf '\\\\n## Conflict hotspots\\\\n'/d" "$SRC/bin/lead-review.sh" > "$T/mut.sh"
if cmp -s "$T/mut.sh" "$SRC/bin/lead-review.sh"; then
  bad "M1 the mutation anchor printf '\\n## Conflict hotspots\\n' is missing"
else
  cp "$T/mut.sh" "$HB/bin/lead-review.sh"; tick
  [ -z "$(lno '## Conflict hotspots')" ] && ok || bad "M1 the heading survived the mutation"
fi
cp "$SRC/bin/lead-review.sh" "$HB/bin/"

echo "lead-review-context-hotspots.bh-5271: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
