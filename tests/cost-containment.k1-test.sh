#!/bin/bash
# tests/cost-containment.k1-test.sh — K1 containment quick wins in the
# `cost budget` block of bin/pipeline-health.sh, extracted VERBATIM by its
# markers and driven against a scratch tree (fixture summary.json, cost.csv,
# fleet.conf; stubbed ssh, fleet-conf.sh, flag_set and page_critical; the REAL
# bin/lib/lane-gate.sh for the settings-row cases).
#
# WHAT IT PINS (2026-09-24 runaway / silent-stop analysis, and its review):
#   A  autohalt is ON by default: a project at >= COST_AUTOHALT_MULTIPLE x its
#      $/PR budget is paused with NO opt-in flag, pages on the critical path,
#      and the page says how to resume (console / flag row, never "remove the
#      file" — flag_sync re-creates it from the row).
#   B  the kill switches: flags/cost-autohalt-off, COST_AUTOHALT=0, and the REAL
#      settings row `lane.pipeline-health.cost_autohalt` read through the real
#      lane_knob (a `lanes.`-prefixed row is ignored, as the lib ignores it).
#   C  re-arm: a project an operator resumed inside COST_AUTOHALT_REARM_S of its
#      halt is not paused again; and a project ALREADY paused is left alone —
#      no second halt, no reason overwritten, no page.
#   D  spend with ZERO merges:
#      - 24h rule pauses only when the 7d merges are ALSO under the minimum; a
#        project that merged this week but not today (a fleet-wide merge stop)
#        is paged, not paused
#      - 7d rule; a PR merged today counts toward 7d even if the rollup's 7d
#        count missed it (max of the two)
#      - after a halt stamp only post-stamp windows are judged
#      - uncountable repos and the `fleet` bucket are never judged
#      - per-project thresholds through the real lane_knob
#   E  unpriced rows count against the fleet ceiling, priced pessimistically:
#      the model's own rates, the table's top rate for an unknown model, $2 for
#      an rc-0 call with no usage, nothing for a failed call, nothing for a
#      subscription row.
#   F  more than COST_UNPRICED_RUNNER_HOUR_MAX (60) unpriced rows in the last
#      hour from one runner pages critical once a day; 60 does not.
#   G  the ceiling reads cost_rows; with the table down it reaches NO box
#      (BH-2527) and brakes on this box's ledger, labelled LOCAL ONLY.
#   H  bin/cost-rollup.sh counts the 7d merged PRs by MERGE date.
#
# Run from anywhere: tests/cost-containment.k1-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }
NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }   # iso <seconds-ago>
REG=$(rendered_registry)

mkdir -p "$T/bin/lib" "$T/lib" "$T/logs" "$T/state/cost" "$T/flags" "$T/stub"
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the cost budget block — markers missing?"
cp "$DIR/bin/lib/cost-budget.sh" "$T/lib/"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cap.sh"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"

# fleet-conf.sh: --tailnet-ips answers the topology fixture; nothing else is
# answered. A halt lands through drive()'s flag_set stub (the file the test reads).
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --tailnet-ips) [ -r "$HARNESS/ips.txt" ] && cat "$HARNESS/ips.txt"; exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"
cat > "$T/stub/ssh" <<'SH'
#!/bin/bash
for a in "$@"; do case "$a" in root@*) h="${a#root@}" ;; esac; done
echo "$h" >> "$HARNESS/ssh-hosts.txt"
cat "$HARNESS/remote-$h.csv" 2>/dev/null
exit 0
SH
chmod +x "$T/stub/ssh"

cat > "$T/fleet.conf" <<'CONF'
# fixture registry
busy     Acme/busy   - - 1 box-a 10.0.0.1
zm       Acme/zm     - - 2 box-b 10.0.0.2
zmstop   Acme/zmstop - - 2 box-b 10.0.0.2
zm7      Acme/zm7    - - 3 box-b 10.0.0.2
zm7late  Acme/zm7l   - - 3 box-b 10.0.0.2
zmhigh   Acme/zmhigh - - 4 box-c 10.0.0.3
blind    Acme/blind  - - 5 box-c 10.0.0.3
quiet    Acme/quiet  - - 6 box-c 10.0.0.3
CONF

CONF="$T/caps.conf"
cat > "$CONF" <<'CONF'
default 80 5
budget busy 40 10
ceiling 1000
CONF

# summary.json — one project per shape (defaults: 24h $300, 7d $400, min 1).
#   busy    — $80/PR on 90 PRs vs a $40 budget: 2x, the autohalt line
#   zm      — $400/24h, 0 merged in 24h AND 7d: the 24h rule, paused
#   zmstop  — $400/24h, 0 merged today but 5 this week: a merge stop — paged, NOT paused
#   zm7     — $50/24h, $500/7d, 0 merged ever: the 7d rule
#   zm7late — $500/7d, merged_prs_7d 0 but 2 merged TODAY (PRs created >7d ago): not paused
#   zmhigh  — like zm, but per-project rows raise both thresholds
#   blind   — a merged count nobody could take: never paused
#   quiet   — $20/24h: under the threshold
#   fleet   — orchestrator spend, a ledger bucket and NOT a project: never paused
summary() {
cat > "$T/state/cost/summary.json" <<'JSON'
{ "projects": {
  "busy":    {"delivery_cost_24h": 7200, "merged_prs_24h": 90, "cost_7d": 30000, "product_7d": 0,
              "merged_prs_7d": 400, "merged_prs_status": "ok", "stages_24h": {"execute": 7200}},
  "zm":      {"delivery_cost_24h": 400, "merged_prs_24h": 0, "cost_7d": 350, "product_7d": 0,
              "merged_prs_7d": 0, "merged_prs_status": "ok", "stages_24h": {"execute": 300, "preplan": 100}},
  "zmstop":  {"delivery_cost_24h": 400, "merged_prs_24h": 0, "cost_7d": 350, "product_7d": 0,
              "merged_prs_7d": 5, "merged_prs_status": "ok"},
  "zm7":     {"delivery_cost_24h": 50, "merged_prs_24h": 0, "cost_7d": 500, "product_7d": 0,
              "merged_prs_7d": 0, "merged_prs_status": "ok", "stages_7d": {"execute": 400, "triage": 100}},
  "zm7late": {"delivery_cost_24h": 50, "merged_prs_24h": 2, "cost_7d": 500, "product_7d": 0,
              "merged_prs_7d": 0, "merged_prs_status": "ok"},
  "zmhigh":  {"delivery_cost_24h": 400, "merged_prs_24h": 0, "cost_7d": 450, "product_7d": 0,
              "merged_prs_7d": 0, "merged_prs_status": "ok"},
  "blind":   {"delivery_cost_24h": 5000, "merged_prs_24h": null, "cost_7d": 9000, "product_7d": 0,
              "merged_prs_7d": null, "merged_prs_status": "unknown"},
  "quiet":   {"delivery_cost_24h": 20, "merged_prs_24h": 0, "cost_7d": 30, "product_7d": 0,
              "merged_prs_7d": 0, "merged_prs_status": "ok"},
  "fleet":   {"delivery_cost_24h": 900, "merged_prs_24h": 0, "cost_7d": 5000, "product_7d": 0,
              "merged_prs_7d": 0, "merged_prs_status": "ok"}
} }
JSON
}

cat > "$T/prices.json" <<'JSON'
{ "per_token": {
  "known":  {"prompt": 0.001, "completion": 0.002, "cache_read": 0.0001, "cache_write": 0.0005},
  "pricey": {"prompt": 0.01,  "completion": 0.05,  "cache_read": 0.001,  "cache_write": 0.02}
} }
JSON

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"
ledger() { printf '%s\n' "$HDR" > "$T/logs/cost.csv"; }
row() {   # row <file> <secs-ago> <project> <runner> <model> <rc> <in> <out> <cost> [billing_mode]
  echo "$(iso "$2"),hub,$3,execute,$4,$5,$6,1,$7,$8,,,$9,${10:-metered},,,,,,,,,," >> "$1"
}
# settings <json-values> — the settings cache the REAL lane_knob reads.
settings() {
  jq -n --argjson v "$1" --argjson t "$NOW" '{fetched_at: $t, values: $v}' > "$T/state/settings-cache.json"
}

drive() { # drive [extra env assignments...]   -> $T/alerts.txt, $T/pages.txt
  : > "$T/alerts.txt"; : > "$T/pages.txt"; rm -f "$T/ssh-hosts.txt"
  echo 0 > "$T/state/costbreaker.stamp"
  ( export T NOW DIR REG
    export HARNESS="$T" COST_CAPS_CONF="$CONF" MODEL_PRICES="$T/prices.json" PATH="$T/stub:$PATH"
    [ $# -gt 0 ] && export "${@?}"
    bash -c '
      set -uo pipefail
      H="$T"
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      page_critical() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/pages.txt"; }
      # The pause is a flag ROW (BH-2529: with no client the halt fails
      # closed and writes nothing). This stands in for the jobs client the
      # way flag_set behaves: file first, then an answered PUT.
      flag_set() { [ "$2" = on ] && : > "$T/flags/$1"; return 0; }
      if [ -n "${REAL_LANE_GATE:-}" ]; then
        # the real library, pointed at this tree: the rendered registry and
        # the settings cache; no worker (the cache is fresh, so none is asked)
        export LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL= HARNESS_JOBS_URL=
        . "$DIR/bin/lib/lane-gate.sh" || exit 1
      fi
      if [ -n "${STUB_DB:-}" ]; then
        cost_rows_db_enabled() { return 0; }
        cost_rows_fetch() { cp "$T/db.csv" "$1"; printf "box-db\t3\tx\n" > "$1.boxes"; }
      fi
      . "$T/cap.sh"; . "$0"' "$T/blk.sh" >"$T/out.txt" 2>"$T/err.txt" )
}
pline() { grep "^[0-9]*|$1|" "$T/pages.txt" 2>/dev/null | head -1; }
aline() { grep "^[0-9]*|$1|" "$T/alerts.txt" 2>/dev/null | head -1; }
reset_flags() { rm -f "$T/flags/"* "$T/state/settings-cache.json"; rm -rf "$T/state/costhalt"; }

summary; ledger

# ============================================================================
# A. autohalt ON by default — no opt-in flag exists anywhere in this tree
# ============================================================================
reset_flags; drive
[ ! -e "$T/flags/cost-autohalt-optin" ] && [ -e "$T/flags/spend-hold-busy" ] && ok \
  || bad "A: busy at 2x its budget must be paused with no opt-in flag ($(cat "$T/pages.txt" "$T/err.txt"))"
L=$(pline "costhalt:busy")
grep -q 'NEW BUILDS HELD' <<<"$L" && grep -q '\$80.00/PR over 24h' <<<"$L" && ! grep -q 'TRIAGE PAUSED' <<<"$L" \
  && ok || bad "A: the halt must page on the CRITICAL path with the rate: $L"
grep -q 'flag_set spend-hold-busy off' <<<"$L" && ! grep -qi 'remove the flag to resume' <<<"$L" \
  && ok || bad "A: the page must say how lifting the hold really works (the flag row), not 'remove the flag': $L"
grep -q 'lane.pipeline-health.cost_autohalt' <<<"$L" && ! grep -q 'lanes\.pipeline-health' <<<"$L" \
  && ok || bad "A: the page must name the real settings key (lane. prefix): $L"
grep -q '|costhalt:busy|' "$T/alerts.txt" \
  && bad "A: the halt must not ride the triaged-by-LLM alert() path: $(aline costhalt:busy)" || ok
[ -n "$(aline costrate:busy)" ] && ok || bad "A: the rate alert itself must still fire"

# ============================================================================
# B. the kill switches — the file, the env, and the REAL settings row
# ============================================================================
reset_flags; touch "$T/flags/cost-autohalt-off"; drive
[ ! -e "$T/flags/spend-hold-busy" ] && ok || bad "B: flags/cost-autohalt-off must stop the pause"
[ -n "$(aline costrate:busy)" ] && ok || bad "B: the kill switch must not silence the rate alert"
[ -z "$(pline costhalt:busy)" ] && ok || bad "B: no hold, no 'NEW BUILDS HELD' page: $(pline costhalt:busy)"
reset_flags; drive COST_AUTOHALT=0
[ ! -e "$T/flags/spend-hold-busy" ] && ok || bad "B: COST_AUTOHALT=0 must stop the pause"
reset_flags; settings '{"lane.pipeline-health.cost_autohalt":"0"}'; drive REAL_LANE_GATE=1
[ ! -e "$T/flags/spend-hold-busy" ] && [ ! -e "$T/flags/spend-hold-zm" ] && ok \
  || bad "B: the settings row lane.pipeline-health.cost_autohalt=0, read by the REAL lane_knob, must stop every pause ($(cat "$T/err.txt"))"
reset_flags; settings '{"lanes.pipeline-health.cost_autohalt":"0"}'; drive REAL_LANE_GATE=1
[ -e "$T/flags/spend-hold-busy" ] && ok \
  || bad "B: control — a 'lanes.'-prefixed row is not a key the lib reads, so the pause still happens"

# ============================================================================
# C. re-arm, and a project that is ALREADY paused
# ============================================================================
reset_flags; drive
[ -e "$T/flags/spend-hold-busy" ] && ok || bad "C: setup — busy must be paused first"
rm -f "$T/flags/spend-hold-busy"            # the operator resumes it
drive
[ ! -e "$T/flags/spend-hold-busy" ] && ok \
  || bad "C: a project resumed inside COST_AUTOHALT_REARM_S must not be re-paused by the same window"
drive COST_AUTOHALT_REARM_S=0
[ -e "$T/flags/spend-hold-busy" ] && ok || bad "C: past the re-arm window the halt applies again"
reset_flags
echo "operator: holding for a migration" > "$T/flags/paused-busy"
echo "operator: holding" > "$T/flags/paused-zm"
drive
[ "$(cat "$T/flags/paused-busy")" = "operator: holding for a migration" ] && [ ! -e "$T/state/costhalt/busy" ] \
  && [ -z "$(pline costhalt:busy)" ] && [ -z "$(pline costzeromerge:zm)" ] && [ ! -e "$T/state/costhalt/zm" ] && ok \
  || bad "C: an already-paused project gets no second halt, no stamp and no page ($(cat "$T/pages.txt"))"

# ============================================================================
# D. spend with zero merges
# ============================================================================
reset_flags; drive
[ -e "$T/flags/spend-hold-zm" ] && ok || bad "D: zm (\$400/24h, 0 merged in 24h and 7d) must be paused ($(cat "$T/pages.txt"))"
L=$(pline "costzeromerge:zm")
grep -q '\$400 delivery spend in 24h' <<<"$L" && grep -q '0 merged' <<<"$L" && grep -q 'NEW BUILDS HELD' <<<"$L" \
  && grep -q 'flag_set spend-hold-zm off' <<<"$L" && ok || bad "D: the zero-merge page must quote spend, window, merges, the hold and how to lift it: $L"
[ "$(grep -c '|costzeromerge:zm|' "$T/pages.txt")" = 1 ] && ok || bad "D: exactly one zero-merge page for zm"
L=$(pline "costzeromerge:zmstop")
[ ! -e "$T/flags/spend-hold-zmstop" ] && grep -q 'NOT paused' <<<"$L" && grep -q '5 merged in 7d' <<<"$L" && ok \
  || bad "D: 0 merged today but 5 this week is a merge STOP, not a runaway — page, never pause: $L"
[ -e "$T/flags/spend-hold-zm7" ] && grep -q '\$500 delivery spend in 7d' <<<"$(pline costzeromerge:zm7)" \
  && ok || bad "D: zm7 (\$500/7d, 0 merged) must trip the 7d rule: $(pline costzeromerge:zm7)"
[ ! -e "$T/flags/spend-hold-zm7late" ] && [ -z "$(pline costzeromerge:zm7late)" ] && ok \
  || bad "D: 2 PRs merged today are merges this week even when the 7d count (created-in-window) says 0"
[ ! -e "$T/flags/spend-hold-blind" ] && ok || bad "D: an uncountable repo is not a zero-merge repo"
[ ! -e "$T/flags/spend-hold-quiet" ] && ok || bad "D: \$20/24h is under the threshold"
[ ! -e "$T/flags/spend-hold-fleet" ] && [ -z "$(pline costzeromerge:fleet)" ] && ok \
  || bad "D: the 'fleet' ledger bucket is not a fleet.conf project and must never be paused"
[ -e "$T/flags/spend-hold-zmhigh" ] && ok || bad "D: setup — with no per-project row zmhigh trips like zm"
reset_flags
settings '{"lane.pipeline-health.zmhigh.cost_zm_24h_usd":"10000","lane.pipeline-health.zmhigh.cost_zm_7d_usd":"10000"}'
drive REAL_LANE_GATE=1
[ ! -e "$T/flags/spend-hold-zmhigh" ] && [ -e "$T/flags/spend-hold-zm" ] && ok \
  || bad "D: per-project rows (lane.pipeline-health.zmhigh.*) read by the REAL lane_knob must raise only zmhigh ($(cat "$T/err.txt"))"
reset_flags; drive COST_ZM_24H_USD=1000 COST_ZM_7D_USD=1000
[ ! -e "$T/flags/spend-hold-zm" ] && [ ! -e "$T/flags/spend-hold-zm7" ] && ok \
  || bad "D: the fleet-wide knobs must move the thresholds"
reset_flags; touch "$T/flags/cost-autohalt-off"; drive
[ ! -e "$T/flags/spend-hold-zm" ] && grep -q 'NOT paused' <<<"$(pline costzeromerge:zm)" && ok \
  || bad "D: with autohalt off the zero-merge rule still pages, saying it did not pause: $(pline costzeromerge:zm)"
# only spend SINCE a halt is judged: zm7 was halted 2 days ago and resumed; its
# 7d window still holds the pre-halt spend and must not re-pause it daily
reset_flags; mkdir -p "$T/state/costhalt"; echo $(( NOW - 2 * 86400 )) > "$T/state/costhalt/zm7"
drive
[ ! -e "$T/flags/spend-hold-zm7" ] && [ -z "$(pline costzeromerge:zm7)" ] && ok \
  || bad "D: a 7d window that reaches back before the last halt must not re-pause a resumed project"
echo $(( NOW - 8 * 86400 )) > "$T/state/costhalt/zm7"; drive
[ -e "$T/flags/spend-hold-zm7" ] && ok || bad "D: once the whole 7d window is after the halt, the rule applies again"
reset_flags; mkdir -p "$T/state/costhalt"; echo $(( NOW - 25 * 3600 )) > "$T/state/costhalt/zm"
drive
[ -e "$T/flags/spend-hold-zm" ] && ok || bad "D: a 24h window entirely after the halt is judged again"

# ============================================================================
# E. unpriced rows count against the ceiling, pessimistically
# ============================================================================
reset_flags
ledger
row "$T/logs/cost.csv" 60   busy claude known   0 1000 1000 900      # priced: $900
row "$T/logs/cost.csv" 7200 zm   grok   known   0 100000 0 ""        # known model: $100
row "$T/logs/cost.csv" 7200 zm   grok   mystery 0 1000 1000 ""       # unknown: max rates = $60
row "$T/logs/cost.csv" 7200 zm   grok   known   0 "" "" ""           # no usage, rc 0: default $2
row "$T/logs/cost.csv" 7200 zm   grok   known   1 "" "" ""           # failed, no usage: $0
row "$T/logs/cost.csv" 7200 zm   claude known   0 900000 0 "" subscription   # subscription: $0
drive
L=$(pline "costceiling:fleet")
grep -q 'spent \$1062.00 in 24h against a HARD CEILING of \$1000' <<<"$L" \
  && ok || bad "E: 900 + 100 + 60 + 2 (a subscription row adds nothing) = 1062: $L $(cat "$T/err.txt")"
grep -q '\$162.00 of it is 3 unpriced row' <<<"$L" \
  && ok || bad "E: the ceiling line must say how much of the total was priced pessimistically: $L"
drive COST_UNPRICED_ROW_USD=7 MODEL_PRICES="$T/no-such-table.json"
[ -z "$(pline costceiling:fleet)" ] && ok \
  || bad "E: no price table: each unpriced row is the flat \$7 (900+21=921), under the ceiling: $(pline costceiling:fleet)"

# ============================================================================
# F. an unpriced flood from one runner pages critical
# ============================================================================
reset_flags; ledger
for _ in $(seq 1 61); do row "$T/logs/cost.csv" 600 zm grok known 0 "" "" ""; done
for _ in $(seq 1 60); do row "$T/logs/cost.csv" 600 zm codex known 0 "" "" ""; done
for _ in $(seq 1 90); do row "$T/logs/cost.csv" 7200 zm fireworks known 0 "" "" ""; done
drive COST_UNPRICED_ROW_USD=0.01
L=$(pline "costunpriced:grok")
grep -q 'grok wrote 61 unpriced' <<<"$L" && grep -q '^86400|' <<<"$L" && ok \
  || bad "F: 61 unpriced grok rows in an hour must page critical, once a day: $L"
[ -z "$(pline costunpriced:codex)" ] && ok || bad "F: exactly the default max (60) must not page"
[ -z "$(pline costunpriced:fireworks)" ] && ok || bad "F: rows older than an hour are not this hour's flood"

# ============================================================================
# G. cost_rows is the source; with it down, no box is reached (BH-2527)
# ============================================================================
reset_flags; ledger
printf '10.0.0.1\n10.0.0.2\n10.0.0.3\n10.0.0.2\n' > "$T/ips.txt"
printf '%s\n' "$HDR" > "$T/remote-10.0.0.3.csv"
row "$T/remote-10.0.0.3.csv" 60 zmhigh claude known 0 1 1 1500
row "$T/logs/cost.csv" 60 busy claude known 0 1 1 1100
rm -f "$T/logs/ALERTS.log"
drive
[ ! -s "$T/ssh-hosts.txt" ] && ok \
  || bad "G: with cost_rows down, no box in the topology is ssh'd (got: $(tr '\n' ' ' < "$T/ssh-hosts.txt" 2>/dev/null))"
L=$(pline "costceiling:fleet")
grep -q 'spent \$1100.00' <<<"$L" && grep -q 'LOCAL ONLY' <<<"$L" && ok \
  || bad "G: the table down, the ceiling brakes on this box's ledger alone and says LOCAL ONLY: $L"
grep -q 'fleet cost ceiling is LOCAL ONLY' "$T/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "G: a partial brake must leave one ALERTS line: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
printf '%s\n' "$HDR" > "$T/db.csv"
row "$T/db.csv" 60 zm claude known 0 1 1 1200
drive STUB_DB=1
[ ! -s "$T/ssh-hosts.txt" ] && ok || bad "G: with cost_rows answering, no box is ssh'd ($(cat "$T/ssh-hosts.txt"))"
L=$(pline "costceiling:fleet")
grep -q 'spent \$1200.00' <<<"$L" && grep -q 'cost_rows' <<<"$L" && ok \
  || bad "G: the table's rows are the total, and the line says where the figure came from: $L"

# ============================================================================
# H. bin/cost-rollup.sh: the 7d merged count is by MERGE date
# ============================================================================
awk '/^# >>> merged pr counts/{f=1;next} /^# <<< merged pr counts/{exit} f' "$DIR/bin/cost-rollup.sh" > "$T/merged.sh"
[ -s "$T/merged.sh" ] && ok || bad "H: could not extract the merged pr counts block"
mkdir -p "$T/h/cd" "$T/hstub"
printf 'p1 Acme/p1 - - 1\n' > "$T/h/fleet.conf"
cat > "$T/hstub/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$QLOG"; echo '{"total_count": 3}'
SH
chmod +x "$T/hstub/gh"
( export QLOG="$T/queries.txt" PATH="$T/hstub:$PATH" H="$T/h" CD="$T/h/cd" HARNESS_PR_AUTHORS_RESOLVED=operator
  bash -c '. "$0"' "$T/merged.sh" ) >/dev/null 2>&1
[ "$(wc -l < "$T/queries.txt" 2>/dev/null | tr -d ' ')" = 2 ] && ! grep -q 'created:' "$T/queries.txt" \
  && [ "$(grep -c 'is:merged+merged:>=' "$T/queries.txt")" = 2 ] && ok \
  || bad "H: both windows must count PRs by merge date, never creation date ($(cat "$T/queries.txt" 2>/dev/null))"

echo "cost-containment.k1-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
