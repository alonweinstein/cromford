#!/usr/bin/env bash
# Verifies bin/orchestrate.sh outbound topic routing block (extracted verbatim).
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -u; cd "$(dirname "$0")/.."
blk=$(awk '/^# Outbound per-project topic routing/,/^fi$/' bin/orchestrate.sh)
cat > "$T/topics.json" <<'J'
{"topics":{"project-1":"4","project-9":"282","alerts":"8","general":null}}
J
pass=0; fail=0
run(){ # $1=name $2=body $3=meta $4=expect
  printf '%s' "$2" > "$T/m"; printf '%s' "$3" > "$T/m.meta"
  # HARNESS is pinned to $T (no bin/jobs-client.sh in it) so the block's own
  # readability guard is true by construction: since BH-437 these lifted lines
  # source "${HARNESS:-}/bin/jobs-client.sh", and `bash -c` inherits the
  # caller's env — on a harness-driven box HARNESS=/root/harness is exported and
  # this unit test would otherwise load the real client and reach the production
  # worker. tests/telegram-topics-sync-test.sh (C7) pins this.
  got=$(MSGF="$T/m" TG_TOPICS_FILE="$T/topics.json" TG_THREAD="" HARNESS="$T" \
        bash -c "$blk; printf '%s' \"\$TG_THREAD\"")
  if [ "$got" = "$4" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: got '$got' want '$4'"; fi
}
run project-9-beat '[project-9] ALERT build stuck' '{"origin":"beat"}' 282
run project-1-beat 'project-1 triage wave done' '{}' 4
run alert-noproj 'ALERTS.log: hub checkout diverged' '{}' 8
run plain-beat 'nightly summary' '{}' ''
run human-general 'which box runs project-9?' '{"from_name":"the operator"}' ''
run human-thread-kept 'x' '{"from_name":"the operator","thread_id":"6"}' ''
echo "tg-outbound-topic: pass=$pass fail=$fail"; [ "$fail" = 0 ]
