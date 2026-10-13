#!/bin/bash
# tests/daily-digest-pr-health.bh-3929-test.sh — BH-3936 (BH-3929 ask 6): the
# per-repo PR-health rollup and its daily-digest line.
#
#   L2  ph_age_bucket boundaries, and rc 1 on a non-number.
#   H1  po_health_add x4 then po_health_flush: the exact job_ledger_put argv,
#       then a second flush writes zeros (the reset).
#   H3  adds for one repo and a flush for another write nothing; a review
#       outage (ph_review_covered rc 1) counts 0 approved.
#   H2  dd_render prints the ticket's line, with the console link, no em dash.
#   H4  skipped rows, ok:false, and a row from another day.
#   H5  the REAL bin/pr-owner-sweep.sh writes the pr_health row through the
#       jobs API (PUT /api/ledger kind=pr_health key=<project>).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/daily-digest-pr-health.bh-3929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

HEALTH="$DIR/bin/lib/pr-owner/health.sh"
RENDER="$DIR/bin/lib/daily-digest-render.sh"
EMPTYJ="$DIR/tests/fixtures/daily-digest/empty-day.json"

# ---------- L2 ph_age_bucket --------------------------------------------------
L2=$( . "$DIR/bin/lib/pr-health.sh" && . "$HEALTH" || exit 9
  N=1000000000
  for a in 0 86399 86400 259199 259200 604799 604800; do ph_age_bucket $((N - a)) "$N"; done | tr '\n' ' ' )
[ "$L2" = "lt1d lt1d 1to3d 1to3d 3to7d 3to7d gt7d " ] && ok || bad "L2 bucket boundaries: [$L2]"
( . "$HEALTH" || exit 9; out=$(ph_age_bucket x 1); rc=$?; [ "$rc" = 1 ] && [ -z "$out" ] ) \
  && ok || bad "L2 ph_age_bucket x 1 must be rc 1 with no output"

# ---------- H1 add x4, flush --------------------------------------------------
# Stubs stand in for the readers health.sh calls; they are defined AFTER the
# libs are sourced so the real ones are replaced.
h1() { # h1 <outfile> — runs four adds and two flushes, recording each put
  . "$DIR/bin/lib/pr-health.sh" && . "$HEALTH" || exit 9
  PO_TICK_NOW=$(date -u -d 2026-10-03T12:00:00Z +%s)
  ph_review_covered() { [ "$2" = 2 ] && return 0; [ "${REVIEW_OUTAGE:-}" = 1 ] && return 1; return 2; }
  bg_scan_read() { [ "$2" = 3 ] && { printf 'https://x/c/77\tlead\t2026-10-03T00:00:00Z\t77'; return 1; }; return 0; }
  bg_read() {
    case "$1" in
      repos/*/issues/3/comments)
        printf '77\0372026-10-03T00:00:00Z\037lead\037https://x/c/77\037%s\n' \
          "$(printf '%s' '- [BLOCK] CI did not run on this head; the workflow was skipped.' | base64 -w0)" ;;
    esac
    return 0; }
  job_ledger_put() { printf '%s\n' "$*" >> "$OUTF"; return 0; }
  OUTF="$1"
  local n created owned mc
  for spec in "1 2026-10-03T10:00:00Z 1 -" "2 2026-10-01T12:00:00Z 1 -" "3 2026-09-28T12:00:00Z 1 READY" "4 2026-09-24T12:00:00Z 0 -"; do
    read -r n created owned mc <<<"$spec"
    PO_PROJECT=project-4 PO_SLUG=example-org/project-4 PO_NUM=$n PO_HEAD="$(printf '%040d' "$n")" PO_CREATED=$created PO_OWNED=$owned PO_MC_STATE=$mc
    po_health_add
  done
  po_health_flush project-4 example-org/project-4
  po_health_flush project-4 example-org/project-4
}
( h1 "$T/h1.out" ) 2>"$T/h1.err"
EXPECT='pr_health project-4 ok {"day":"2026-10-03","open":4,"age":{"lt1d":1,"1to3d":1,"3to7d":1,"gt7d":1},"ownerless":1,"approved_not_merged":1,"blocked_ci_only":1}'
[ "$(sed -n 1p "$T/h1.out" 2>/dev/null)" = "$EXPECT" ] && ok || bad "H1 the exact pr_health put: [$(sed -n 1p "$T/h1.out" 2>/dev/null)] err=[$(head -3 "$T/h1.err")]"
grep -q '"open":0,' <<<"$(sed -n 2p "$T/h1.out" 2>/dev/null)" && ok || bad "H1 a second flush writes zeros: [$(sed -n 2p "$T/h1.out" 2>/dev/null)]"
[ "$(grep -c . "$T/h1.out" 2>/dev/null)" = 2 ] && ok || bad "H1 two flushes, two puts: $(cat "$T/h1.out" 2>/dev/null)"

# ---------- H3 foreign flush, review outage -----------------------------------
( . "$DIR/bin/lib/pr-health.sh" && . "$HEALTH" || exit 9
  PO_TICK_NOW=1759492800
  job_ledger_put() { echo "PUT $*" >> "$T/h3.out"; }
  ph_review_covered() { return 1; }
  PO_SLUG=example-org/a PO_NUM=1 PO_HEAD=abc PO_CREATED=2026-10-03T00:00:00Z PO_OWNED=1 PO_MC_STATE=-
  po_health_add
  po_health_flush b example-org/b
  PO_SLUG=example-org/b
  po_health_add
  po_health_flush b example-org/b ) 2>/dev/null
[ "$(grep -c . "$T/h3.out" 2>/dev/null)" = 1 ] && ok || bad "H3 a foreign flush writes nothing: $(cat "$T/h3.out" 2>/dev/null)"
grep -q '"open":1,.*"approved_not_merged":0,' "$T/h3.out" 2>/dev/null && ok || bad "H3 a review outage counts 0 approved: $(cat "$T/h3.out" 2>/dev/null)"
( . "$HEALTH" || exit 9; po_health_add; [ $? = 2 ] ) && ok || bad "H3 po_health_add with no PR context declines (rc 2)"

# ---------- H2 / H4 dd_render -------------------------------------------------
render() { bash -c '. "$1" || exit 9; shift; dd_render "$@"' _ "$RENDER" "$1" https://console.test/ - 0 5 - 2>"$T/render.err"; }
ROW='{"project":"project-4","day":"2026-09-29","open":4,"age":{"lt1d":1,"1to3d":1,"3to7d":1,"gt7d":1},"ownerless":1,"approved_not_merged":1,"blocked_ci_only":1,"as_of":"2026-09-29T12:00:00Z"}'
jq --argjson r "$ROW" '.pr_health.rows = [$r] | .empty = false' "$EMPTYJ" > "$T/h2.json"
H2=$(render "$T/h2.json"); RC=$?
[ "$RC" = 0 ] && ok || bad "H2 dd_render rc 0 (got $RC): $(cat "$T/render.err")"
TICKET='project-4: 4 open (1 <1d, 1 1-3d, 1 3-7d, 1 >7d), 1 ownerless, 1 approved not merged, 1 blocked on CI only'
grep -qxF "  $TICKET https://console.test/p/project-4" <<<"$H2" && ok || bad "H2 the per-project line: $(grep 'project-4' <<<"$H2")"
grep -qxF "PR health: 1 repo(s) https://console.test/merge-queue" <<<"$H2" && ok || bad "H2 the header: $(grep 'PR health' <<<"$H2")"
LINE=$(grep -F 'project-4:' <<<"$H2" | sed -E 's#^  ##; s# https://console\.test/[^ ]*$##')
[ "$LINE" = "$TICKET" ] && ok || bad "H2 indent and URL stripped is the ticket's string: [$LINE]"
BLOCK=$(sed -n '/^PR health:/,/^PRs awaiting/p' <<<"$H2")
! grep -q '—' <<<"$BLOCK" && ok || bad "H2 no em dash in the PR health block: $BLOCK"
[ "$(grep -n '^Open work past SLA' <<<"$H2" | cut -d: -f1)" -lt "$(grep -n '^PR health' <<<"$H2" | cut -d: -f1)" ] && ok \
  || bad "H2 PR health prints after Open work past SLA"
H2E=$(render "$EMPTYJ")
grep -qxF "PR health: 0 repo(s) https://console.test/merge-queue" <<<"$H2E" && ok || bad "H2 empty-day prints 0 repos: $(grep 'PR health' <<<"$H2E")"

jq --argjson r "$ROW" '.pr_health.rows = [$r | .day = "2026-09-27" | .project = "a<b>&c"] | .pr_health.skipped = 2' "$EMPTYJ" > "$T/h4.json"
H4=$(render "$T/h4.json")
grep -qxF "  2 unreadable pr_health row(s) https://console.test/merge-queue" <<<"$H4" && ok || bad "H4 skipped rows: $(grep unreadable <<<"$H4")"
grep -qF "1 blocked on CI only (as of 2026-09-27) https://console.test/p/abc" <<<"$H4" && ok || bad "H4 an old row says its day, the project is stripped: $(grep 'blocked on CI' <<<"$H4")"
jq '.pr_health = {ok: false, error: "D1 down"}' "$EMPTYJ" > "$T/h4f.json"
H4F=$(render "$T/h4f.json")
grep -qxF "PR health: n/a (read failed: D1 down) https://console.test/merge-queue" <<<"$H4F" && ok || bad "H4 ok:false: $(grep 'PR health' <<<"$H4F")"

# ---------- H5 the real sweep writes the row ----------------------------------
command -v python3 >/dev/null || { echo "python3 missing — H5 skipped"; echo "daily-digest-pr-health.bh-3929: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners" "$H/flags" "$H/env" "$H/fixture" "$T/fakebin"
cp -R "$DIR/bin" "$H/"
rm -f "$H/bin/lib/gh-rest.sh"   # no REST lib: the superseded hook declines, health still counts
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf 'project-4 example-org/project-4 https://os.test /api/board\n' > "$H/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "api rate_limit") printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$(date +%s)" "$(date +%s)"; exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*)   cat "$HARNESS/fixture/open.json" ;;
  *"pr list"*"--state merged"*) echo '[]' ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; B=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) B="$2"; shift 2 ;; *) shift ;; esac; done
[ "$M" = PUT ] && printf '%s\n' "$B" >> "$HARNESS/puts.log"
case "$M $URL" in
  "GET https://jobs.test/api/jobs"*)  printf '{"jobs":[]}\n200\n' ;;
  "GET https://jobs.test/api/queue"*) printf '{"queue":[]}\n200\n' ;;
  "GET https://jobs.test/api/settings/"*|"GET https://jobs.test/api/ledger"*|"GET https://jobs.test/api/verdict"*) printf '{"error":"none"}\n404\n' ;;
  "GET https://jobs.test/api/verdicts"*) printf '{"standing":null,"rows":[]}\n200\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
NOWISO() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
cat > "$H/fixture/open.json" <<JSON
[{"number":1,"title":"Fix the thing","headRefName":"x/fix","headRefOid":"1111111111111111111111111111111111111111","author":{"login":"someone-else"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO 7200)","createdAt":"$(NOWISO 7200)","url":"https://github.com/example-org/project-4/pull/1","isDraft":false},
 {"number":2,"title":"Fix another","headRefName":"x/other","headRefOid":"2222222222222222222222222222222222222222","author":{"login":"someone-else"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO 900000)","createdAt":"$(NOWISO 900000)","url":"https://github.com/example-org/project-4/pull/2","isDraft":false}]
JSON
env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=x GH_BUDGET_TTL_S=0 GH_ETAG=0 PATH="$T/fakebin:$PATH" \
  bash "$H/bin/pr-owner-sweep.sh" --repo example-org/project-4 >/dev/null 2>"$T/h5.err"
H5=$(jq -c 'select(.kind == "pr_health")' "$H/puts.log" 2>/dev/null)
[ "$(jq -r '.key + " " + .status' <<<"$H5")" = "project-4 ok" ] && ok || bad "H5 the sweep PUTs kind=pr_health key=project-4: [$H5] err=[$(head -3 "$T/h5.err")]"
[ "$(jq -c '.detail | fromjson | [.open, .age.lt1d, .age.gt7d, .ownerless]' <<<"$H5" 2>/dev/null)" = "[2,1,1,2]" ] && ok \
  || bad "H5 the row counts 2 open (one <1d, one >7d), both ownerless: $(jq -r .detail <<<"$H5" 2>/dev/null)"

echo "daily-digest-pr-health.bh-3929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
