#!/bin/bash
# tests/mc/stacked-wait-parent-reason.bh-3777-test.sh — a stacked child of a
# parent that is NEEDS_HUMAN_VERDICT says so in its STACKED_WAIT reason
# (BH-3777, acceptance). #3763-#3766 sat behind #3753/#3758 reading "waiting
# for the parent to merge and retarget" while the parents waited on a person.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, merge mode, over a Mergify
# repo with a fake gh (the BH-2199 fixture). PR 41 is the parent on main; PR 42
# is its child, based on the parent's branch `ticket/mg-41`, and the parent read
# (mc_stack_parent) answers OPEN with PR 41's url. bin/lib/verdict-status.sh is
# a stub whose la_decide answers per PR from $T/la-rc-<n>.
#   S1  parent withheld (rc 1), two ticks: the child row is STACKED_WAIT and
#       its reason names `parent #41 needs a human verdict` and the command
#   S2  parent ordinary (rc 0): the child's reason is today's, byte for byte
# Run from anywhere: tests/mc/stacked-wait-parent-reason.bh-3777-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers it from list.json.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/lib/block-gate.sh" "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/merge-conductor.sh"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done
cat > "$T/h/bin/lib/verdict-status.sh" <<EOF
la_decide() {
  printf '%s\n' "\$*" >> "$T/la-calls.txt"
  LA_REASON=\$(cat "$T/la-reason-\$2" 2>/dev/null)
  return "\$(cat "$T/la-rc-\$2" 2>/dev/null || echo 0)"
}
la_human_needed() { return 0; }
vs_publish() { return 0; }
vs_context() { echo lead-verdict; }
EOF

head_of() { printf 'aaaaaaaa00aaaaaaaaaaaaaaaaaaaaaaaaaaaa%s' "$1"; }
base_of() { if [ "$1" = 42 ]; then echo ticket/mg-41; else echo main; fi; }
for N in 41 42; do
  REC="$T/h/builds/pool-mgfy-MG-$N-2026100100$N"
  mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$N" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  head_of "$N" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')
open_list() {
  local n out=""
  for n in 41 42; do
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/mgfy-os/pull/$n\",\"headRefOid\":\"$(head_of "$n")\",\"headRefName\":\"ticket/mg-$n\",\"baseRefName\":\"$(base_of "$n")\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"isInMergeQueue\":false,\"labels\":[]},"
  done
  printf '[%s]\n' "${out%,}" > "$T/list.json"
}

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*(/pull/|/pulls/|/issues/)([0-9]+).*#\2#p' | head -1)
[ -n "\$N" ] || N=41
HEAD=aaaaaaaa00aaaaaaaaaaaaaaaaaaaaaaaaaaaa\$N
BASE=main; [ "\$N" = 42 ] && BASE=ticket/mg-41
Q=""; prev=""; for a in "\$@"; do [ "\$prev" = -q ] && Q="\$a"; prev="\$a"; done
fx() { if [ -n "\$Q" ]; then printf '%s' "\$1" | jq -r "\$Q"; else printf '%s\n' "\$1"; fi; }
case "\$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*"/reviews"*) fx '[]' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*) fx "{\"number\":\$N,\"base\":{\"ref\":\"\$BASE\"}}" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 '{"check_runs":[]}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) : ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/label-adds.txt" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; exit 0 ;;
  *v3.diff*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*) restpr OPEN "\$HEAD" "ticket/mg-\$N" "\$BASE" "" MERGEABLE CLEAN operator ;;
  *"api -i -X GET repos/"*"/pulls"*"example-org:ticket/mg-41"*)
    restpr --raw 200 '[{"number":41,"state":"open","merged_at":null,"html_url":"https://github.com/example-org/mgfy-os/pull/41"}]' ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open","number":'"\$N"'}' ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
CLOG="$T/h/logs/merge-conductor.log"
field() { awk -F'\t' -v k="example-org/mgfy-os#$1" -v n="$2" '$1==k {print $n}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_PR_PARALLEL=1 MC_MERGIFY_REASK_TICKS=1 \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
reset() {
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/block-gate"
  rm -f "$T/h/state/merge-sweep-done.txt" "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe 2>/dev/null
  for f in gh-calls.txt label-adds.txt merge-calls.txt la-calls.txt; do : > "$T/$f"; done
  : > "$CLOG"; open_list
}
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
TODAY="based on ticket/mg-41, not the project base — waiting for the parent to merge and retarget"

# ── S1: the parent's verdict is withheld ────────────────────────────────────
reset
echo 1 > "$T/la-rc-41"; printf 'touches protected paths: catalog/switches.d/x-off.json' > "$T/la-reason-41"
run_tick; open_list; run_tick
[ "$(field 41 2)" = NEEDS_HUMAN_VERDICT ] && ok || bad "S1 setup: the parent is NEEDS_HUMAN_VERDICT (got '$(field 41 2)'; log: $(grep -F '#41' "$CLOG" | tail -3))"
[ "$(field 42 2)" = STACKED_WAIT ] && ok || bad "S1: the child is STACKED_WAIT (got '$(field 42 2)'; log: $(grep -F '#42' "$CLOG" | tail -3))"
CW=$(field 42 7)
grep -qF "parent #41 needs a human verdict" <<<"$CW" && ok || bad "S1: the child's reason names the waiting parent (reason: '$CW')"
grep -qF -- "--source human" <<<"$CW" && ok || bad "S1: the child's reason carries the parent's command (reason: '$CW')"
grep -qF "catalog/switches.d/x-off.json" <<<"$CW" && ok || bad "S1: the child's reason carries the parent's protected path (reason: '$CW')"
[ ! -s "$T/label-adds.txt" ] && ok || bad "S1: nothing is labelled (POSTs: $(cat "$T/label-adds.txt"))"

# ── S2: an ordinary parent ──────────────────────────────────────────────────
reset
echo 0 > "$T/la-rc-41"; printf 'no protected path' > "$T/la-reason-41"
run_tick; open_list; run_tick
case "$(field 41 2)" in READY|QUEUED) ok ;; *) bad "S2 setup: the parent is READY or QUEUED (got '$(field 41 2)')" ;; esac
[ "$(field 42 2)" = STACKED_WAIT ] && ok || bad "S2: the child is STACKED_WAIT (got '$(field 42 2)')"
[ "$(field 42 7)" = "$TODAY" ] && ok || bad "S2: the child's reason is today's, byte for byte (got '$(field 42 7)')"

echo "stacked-wait-parent-reason.bh-3777-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
