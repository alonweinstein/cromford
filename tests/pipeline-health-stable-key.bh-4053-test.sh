#!/bin/bash
# tests/pipeline-health-stable-key.bh-4053-test.sh — a pipeline-health condition
# is ONE console row whatever PRs it names (BH-4053): alert() declares the id
# ph-<key> (folded to [A-Za-z0-9_.-]), so the stalepr alert for a project keeps
# the akey alert:ph-stalepr_<project> while its PR list changes.
#
# Extracted VERBATIM from bin/pipeline-health.sh by their markers: the
# `# >>> alert emit cap` block, the real alert() (the backup-freshness recipe)
# and the `# >>> stalepr detector` block. They run with the real
# bin/alert-line.sh, the real alert-state lib and a recording bin/beat.sh; the
# only fakes are gh (a REST stub serving $T/prs-<repo>.json) and beat.sh.
#
#   K1 two ticks, PR set #50 then #50,#51 -> one akey, alert:ph-stalepr_ts
#   K2 the alert beats carry alertid ph-stalepr_ts
#   K3 the health:stalepr:ts fleet_alert beat is still sent
#   K4 past the tick cap: plain append + alias to ph-stalepr_ts, no stderr
#   K5 a second project stale -> a second akey (one row per condition)
#
# Run from anywhere: tests/pipeline-health-stable-key.bh-4053-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PH="$DIR/bin/pipeline-health.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$PH" > "$T/p0.sh"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$PH" > "$T/p1.sh"
awk '/^# >>> stalepr detector/{f=1;next} /^# <<< stalepr detector/{exit} f' "$PH" > "$T/p2.sh"
[ -s "$T/p0.sh" ] && [ -s "$T/p1.sh" ] && [ -s "$T/p2.sh" ] && ok || bad "could not extract the emit cap / alert() / stalepr blocks"
cat "$T/p0.sh" "$T/p1.sh" "$T/p2.sh" > "$T/block.sh"
bash -n "$T/block.sh" && ok || bad "the extracted block is not valid bash"

mktree() { # mktree <dir>
  local d="$1" s
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/fakebin"
  for s in alert-line.sh alert_family.py project-of.sh fleet-conf.sh box-for.sh; do
    ln -sf "$DIR/bin/$s" "$d/bin/$s"
  done
  for s in alert-state.sh conf-row.sh gh-repo-token.sh gh-budget.sh gh-pr-list.sh gh-rest.sh gh-rest-var.sh; do
    ln -sf "$DIR/bin/lib/$s" "$d/bin/lib/$s"
  done
  cat > "$d/bin/beat.sh" <<'EOF'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$1" >> "$H/beats.jsonl"
exit 0
EOF
  chmod +x "$d/bin/beat.sh"
  cat > "$d/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"repos/o/"*"/pulls?state="*)
    a="$*"; r=${a#*repos/o/}; r=${r%%/*}
    printf 'HTTP/2.0 200\r\n\r\n'; cat "$T/prs-$r.json" 2>/dev/null || echo '[]' ;;
  *"api rate_limit"*)
    now=$(date +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "$((now+3600))" "$((now+3600))" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$d/fakebin/gh"
  printf 'ts\to/r\n' > "$d/fleet.conf"
  echo '{}' > "$d/state/health-alerted.json"
}
pr() { # pr <n> — one REST pull, opened long before the 12h cutoff
  printf '{"number":%s,"created_at":"2026-09-10T00:00:00Z","updated_at":"2026-09-10T00:00:00Z","title":"TK-%s","draft":false,"state":"open","merged_at":null,"closed_at":null,"body":"","labels":[],"html_url":"https://github.com/o/r/pull/%s","head":{"ref":"b","sha":"s%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"}}' "$1" "$1" "$1" "$1"
}
prs() { # prs <dir> <repo> <n...>
  local d="$1" r="$2" n out=""; shift 2
  for n in "$@"; do out="${out:+$out,}$(pr "$n")"; done
  printf '[%s]\n' "$out" > "$d/prs-$r.json"
}
tick() { # tick <dir> <now> <projects> [env...] — one pipeline-health tick of the blocks
  local d="$1" now="$2" projs="$3" blk="$T/block.sh"; shift 3
  : > "$d/fired"
  ( export PATH="$d/fakebin:$PATH" HARNESS="$d" T="$d" GH_BUDGET_TTL_S=0 GH_BUDGET_CORE_REMAINING=4000 \
      ALERTS_CONF="$d/alerts.conf" FLEET_CONF="$d/fleet.conf"; unset GH_TOKEN
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW='"$now"'; PROJECTS="'"$projs"'"; FIRED="$T/fired"; DEDUP="$T/state/health-alerted.json"
      STAMP() { echo "2026-10-02 10:00:00Z"; }
      . "$T/bin/lib/gh-repo-token.sh"
      . "$T/bin/lib/gh-pr-list.sh"
      . "$T/bin/lib/gh-budget.sh"
      . "$0"' "$blk" >/dev/null 2>"$d/err.txt" )
}
akeys() { jq -r 'select(.kind=="alert")|.akey' "$1/beats.jsonl" 2>/dev/null | sort -u; }

NOW=$(date +%s)
echo "--- K1: the PR set changes, the akey does not"
D="$T/k1"; mktree "$D"; : > "$D/alerts.conf"
prs "$D" r 50; tick "$D" "$NOW" ts
prs "$D" r 50 51; tick "$D" "$((NOW + 21601))" ts
N=$(jq -r 'select(.kind=="alert")|.akey' "$D/beats.jsonl" 2>/dev/null | grep -c .)
[ "$N" = 2 ] && ok || bad "K1: want 2 alert beats (one per tick), got $N: $(cat "$D/beats.jsonl" 2>/dev/null) err=$(cat "$D/err.txt")"
[ "$(akeys "$D")" = alert:ph-stalepr_ts ] && ok || bad "K1: distinct akeys: $(akeys "$D" | tr '\n' ' ')"
case "$(jq -r 'select(.kind=="alert")|.line' "$D/beats.jsonl" | tail -1)" in
  *'#50,#51'*) ok ;; *) bad "K1: tick-2 line does not name #51: $(cat "$D/beats.jsonl")" ;; esac
[ ! -s "$D/err.txt" ] && ok || bad "K1: stderr: $(cat "$D/err.txt")"

echo "--- K2: alertid is the folded id"
[ "$(jq -r 'select(.kind=="alert")|.alertid' "$D/beats.jsonl" | sort -u)" = ph-stalepr_ts ] \
  && ok || bad "K2: alertids: $(jq -r 'select(.kind=="alert")|.alertid' "$D/beats.jsonl" | tr '\n' ' ')"

echo "--- K3: the health: fleet_alert beat is unchanged"
[ "$(jq -r 'select(.kind=="fleet_alert")|.akey' "$D/beats.jsonl" | sort -u)" = health:stalepr:ts ] \
  && ok || bad "K3: fleet_alert akeys: $(jq -r 'select(.kind=="fleet_alert")|.akey' "$D/beats.jsonl" | tr '\n' ' ')"

echo "--- K4: past the tick cap the line is appended and aliased to the id"
D="$T/k4"; mktree "$D"; : > "$D/alerts.conf"
prs "$D" r 50 51; tick "$D" "$NOW" ts ALERT_LINE_TICK_MAX=0
[ "$(jq -r 'select(.kind=="alert")' "$D/beats.jsonl" 2>/dev/null | grep -c .)" = 0 ] \
  && ok || bad "K4: an alert-line beat was sent past the cap: $(cat "$D/beats.jsonl")"
L=$(grep -F '#50,#51' "$D/logs/ALERTS.log" 2>/dev/null | head -1)
[ -n "$L" ] && ok || bad "K4: no ALERTS.log line: $(cat "$D/logs/ALERTS.log" 2>/dev/null)"
AK=$(python3 "$DIR/bin/alert_family.py" row_key "${L#????-??-?? ??:??:??Z }")
[ "$(head -1 "$D/state/alerts/alias/auto-$AK" 2>/dev/null)" = ph-stalepr_ts ] \
  && ok || bad "K4: alias auto-$AK holds '$(cat "$D/state/alerts/alias/auto-$AK" 2>/dev/null)'"
[ ! -s "$D/err.txt" ] && ok || bad "K4: stderr: $(cat "$D/err.txt")"

echo "--- K5: two projects stale at once are two conditions, two akeys"
D="$T/k5"; mktree "$D"; : > "$D/alerts.conf"
printf 'ts\to/r\nproject-3\to/m\n' > "$D/fleet.conf"
prs "$D" r 50; prs "$D" m 70; tick "$D" "$NOW" "ts project-3"
[ "$(akeys "$D" | tr '\n' ' ')" = "alert:ph-stalepr_project-3 alert:ph-stalepr_ts " ] \
  && ok || bad "K5: akeys: $(akeys "$D" | tr '\n' ' ') err=$(cat "$D/err.txt")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
