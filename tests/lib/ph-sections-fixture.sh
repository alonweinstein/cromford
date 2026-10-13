#!/bin/bash
# tests/lib/ph-sections-fixture.sh — a scratch harness tree the REAL
# bin/pipeline-health.sh runs against (BH-4055). Same shape as the mktree in
# tests/ph-retract-closes-row.bh-4054-test.sh: the real alert-line.sh, beat.sh
# and alert-state.sh, a jobs-client with the worker's note/resolve contract, a
# curl that records every console POST, and a gh that records every call.
# Sourced by tests/ph-sections-filter.bh-4055-test.sh and
# tests/wake-pr-closed-retracts.bh-4055-test.sh; needs $DIR (the repo root).
# Fixture files read by the gh stub, under the tree <d>:
#   prs-r.json   the stalepr list (served with headers, as gh-rest asks -i)
#   lu.json      the leadunqueued list (plain `gh api`, no -i)
#   status.json  any commits/<sha>/status read
#   listfail     present = every pulls list fails
# shellcheck shell=bash

phs_mktree() { # phs_mktree <dir>
  local d="$1" s
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/fakebin" "$d/env" "$d/locks"
  for s in alert-line.sh beat.sh alert_family.py project-of.sh fleet-conf.sh box-for.sh pipeline-health.sh; do
    ln -sf "$DIR/bin/$s" "$d/bin/$s"
  done
  for s in alert-state.sh conf-row.sh env-path.sh gh-repo-token.sh gh-budget.sh gh-pr-list.sh gh-rest.sh gh-rest-var.sh; do
    ln -sf "$DIR/bin/lib/$s" "$d/bin/lib/$s"
  done
  cat > "$d/bin/jobs-client.sh" <<'JC'
alert_note() {
  printf '%s\n' "$1" >> "$_AS_H/note.log"
  if grep -qxF "$1" "$_AS_H/open.ids" 2>/dev/null; then echo "suppress 2"
  else printf '%s\n' "$1" >> "$_AS_H/open.ids"; echo "fire 1"; fi
}
alert_resolve() {
  printf '%s\n' "$1" >> "$_AS_H/resolve.log"
  if grep -qxF "$1" "$_AS_H/open.ids" 2>/dev/null; then
    grep -vxF "$1" "$_AS_H/open.ids" > "$_AS_H/open.ids.tmp"; mv -f "$_AS_H/open.ids.tmp" "$_AS_H/open.ids"
    echo 1
  else echo 0; fi
}
JC
  cat > "$d/fakebin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$HARNESS/gh.calls"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"api rate_limit"*)
    now=$(date +%s)
    printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "${GH_BUDGET_CORE_REMAINING:-4000}" "$((now+3600))" "$((now+3600))" ;;
  *"/commits/"*"/status"*) cat "$HARNESS/status.json" 2>/dev/null || exit 1 ;;
  *"-i "*"repos/"*"/pulls?state="*)
    [ -f "$HARNESS/listfail" ] && exit 1
    printf 'HTTP/2.0 200\r\n\r\n'; cat "$HARNESS/prs-r.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/pulls?state="*)
    [ -f "$HARNESS/listfail" ] && exit 1
    cat "$HARNESS/lu.json" 2>/dev/null || echo '[]' ;;
  *) exit 1 ;;
esac
GH
  cat > "$d/fakebin/curl" <<'CU'
#!/bin/bash
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && { printf '%s\n' "$a" >> "$HARNESS/sent.jsonl"; break; }
  prev="$a"
done
printf '200'
CU
  chmod +x "$d/fakebin/gh" "$d/fakebin/curl"
  printf 'ts\to/r\n' > "$d/fleet.conf"
  printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$d/env/global.env"
  touch "$d/flags/alerts-db" "$d/flags/remediation-disabled"
  : > "$d/alerts.conf"
  echo '{}' > "$d/state/health-alerted.json"
  : > "$d/state/health-active.txt"
}
phs_pr() { # phs_pr <n> — one REST pull, opened long before the 12h cutoff
  printf '{"number":%s,"created_at":"2026-09-10T00:00:00Z","updated_at":"2026-09-10T00:00:00Z","title":"TK-%s","draft":false,"state":"open","merged_at":null,"closed_at":null,"body":"","labels":[],"html_url":"https://github.com/o/r/pull/%s","head":{"ref":"b","sha":"s%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"}}' "$1" "$1" "$1" "$1"
}
# phs_env — the environment one real pipeline-health run gets in tree $HARNESS.
phs_env() {
  export PATH="$HARNESS/fakebin:$PATH" T="$HARNESS" GH_BUDGET_TTL_S=0 \
    ALERTS_CONF="$HARNESS/alerts.conf" FLEET_CONF="$HARNESS/fleet.conf" LANE_GATE_DISABLE=1 \
    HARNESS_ENV_DIR="$HARNESS/env"
  export GH_BUDGET_CORE_REMAINING="${GH_BUDGET_CORE_REMAINING:-4000}"
  unset GH_TOKEN
}
phs_resolved() { # phs_resolved <dir> — the akeys of every resolved:true POST
  jq -r 'select(.resolved==true)|.akey' "$1/sent.jsonl" 2>/dev/null
}
