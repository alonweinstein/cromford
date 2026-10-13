#!/bin/bash
# tests/rule-adopt.bh-3715-test.sh — BH-3715 (BH-3692.2): the hub lane that
# lands the rule miner's lint-backed rules PR, bin/rule-adopt.sh, run WHOLE
# (`tick`) against a scratch harness. Real: the lane script, the contract lib
# "$DIR/bin/lib/rule-evidence.sh" (its RE_LINT_HEAD_RE, and re_write builds
# every evidence fixture), lane-gate, env-path and hub-box. Stubbed in the
# scratch tree, each recording its calls under $T/log:
#   * bin/lib/gh-rest.sh      gh_rest answers pulls/<n>, compare/main...<head>,
#                             contents/<path>?ref=<ref> and pulls/<n>/files from
#                             $T/gh fixtures (a missing fixture = a failed read)
#   * bin/lib/gh-pr-list.sh   harness_pr_list answers $T/open.json / $T/closed.json
#   * bin/lib/verdicts.sh     vd_standing answers $T/vd/<n>-<sha> (TSV; "rc2" =
#                             rc 2; missing = rc 1, nothing stands)
#   * bin/lib/merge-conductor-lib.sh  mc_enqueue logs "<url> <head>", rc $T/mc_rc
#   * bin/lead-verdict.sh     logs argv, stderr $T/req_err, rc $T/req_rc
#   * bin/lane-alert.sh       logs argv, rc $T/alert_rc
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/rule-adopt.bh-3715-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

LANE="$DIR/bin/rule-adopt.sh"
[ -f "$LANE" ] && ok || bad "bin/rule-adopt.sh does not exist"

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/state" "$H/logs" "$H/flags" "$T/log" "$T/tmp"
: > "$H/env/global.env"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/rule-evidence.sh" "$H/bin/lib/"
printf 'cromford example-org/cromford - - 3 box-small 10.0.0.1\n' > "$H/fleet.conf"

# The jobs client: no worker. flag_sync rc 2 = "no row", so the gate reads flags/ as it stands.
printf 'flag_sync() { return 2; }\n' > "$H/bin/jobs-client.sh"
: > "$H/bin/lib/jobs/req.sh"
cat > "$H/bin/lib/gh-rest.sh" <<EOF
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/log/gh"
  local p="\${2#repos/example-org/cromford/}" f
  case "\$p" in
    pulls/*/files) f="$T/gh/files-\$(cut -d/ -f2 <<<"\$p").json" ;;
    pulls/*)       f="$T/gh/pull-\${p#pulls/}.json" ;;
    compare/main...*) f="$T/gh/cmp-\${p#compare/main...}.json" ;;
    contents/*)    f="\${p#contents/}"; f="$T/gh/ct-\${f##*ref=}-\$(basename "\${f%%\?*}")" ;;
    *) return 1 ;;
  esac
  [ -f "\$f" ] || return 1
  cat "\$f"
}
EOF
cat > "$H/bin/lib/gh-pr-list.sh" <<EOF
harness_pr_list() {
  printf '%s\n' "\$*" >> "$T/log/list"
  cat "$T/\$2.json" 2>/dev/null
}
EOF
cat > "$H/bin/lib/verdicts.sh" <<EOF
vd_standing() {
  printf '%s\n' "\$*" >> "$T/log/vd"
  local f="$T/vd/\$2-\$3"
  [ -f "\$f" ] || return 1
  [ "\$(cat "\$f")" = rc2 ] && return 2
  cat "\$f"
}
EOF
cat > "$H/bin/lib/merge-conductor-lib.sh" <<EOF
mc_enqueue() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/log/mc"
  local rc; rc=\$(cat "$T/mc_rc" 2>/dev/null || echo 0)
  [ "\$rc" = 0 ] || echo "queue said no (rc \$rc)"
  return "\$rc"
}
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/req"
[ -f "$T/req_err" ] && cat "$T/req_err" >&2
exit "\$(cat "$T/req_rc" 2>/dev/null || echo 0)"
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alert"
exit "\$(cat "$T/alert_rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$H/bin/lead-verdict.sh" "$H/bin/lane-alert.sh"

REG=$(rendered_registry)
export HARNESS="$H" TMPDIR="$T/tmp" FLEET_CONF="$H/fleet.conf" LANE_REGISTRY="$REG" RULE_ADOPT_MAX_REQUESTS_PER_TICK=3
unset BOX_NAME JOBS_BOX HUB_BOX_NAME LANE_GATE_DISABLE

SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
OLD=$(printf 'c%.0s' {1..40})
S2=$(printf 'b%.0s' {1..40}); S2_12=${S2:0:12}
URL=https://github.com/example-org/cromford/pull/900
REQNOTE="--notes rule-miner lint-backed rules; each rule names the check that enforces it (prompts/rule-evidence/*.json)"

. "$H/bin/lib/rule-evidence.sh"
# ev <out-json> <rule> <class> <check|-> <incidents...> — a contents answer whose
# content is an evidence record written by the REAL re_write.
ev() {
  local out=$1 rule=$2 class=$3 check=$4; shift 4
  printf '%s\n' "$@" > "$T/inc"; printf 'aaaaaaaaaaaa\n' > "$T/fam"
  re_write "$T/rec.json" "$rule" "$class" "$check" "mined from findings" 2026-09-30 findings "$T/inc" "$T/fam" || bad "re_write failed for $rule"
  jq -nc --arg c "$(base64 < "$T/rec.json")" '{encoding:"base64", content:$c}' > "$out"
}
# lintpr <n> <head> [headRef] — an open PR at <head> whose compare is one
# harness commit, build-discipline.md modified and D45.json added (lint-backed).
lintpr() {
  local n=$1 head=$2 ref=${3:-rules/mined-20260930-lint}
  jq -c --argjson n "$n" --arg r "$ref" '. + [{number:$n, url:("https://github.com/example-org/cromford/pull/"+($n|tostring)), isDraft:false, headRefName:$r}]' \
    "$T/open.json" > "$T/o.tmp" && mv "$T/o.tmp" "$T/open.json"
  jq -nc --arg s "$head" '{head:{sha:$s}, mergeable_state:"clean"}' > "$T/gh/pull-$n.json"
  jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{author:{email:"harness@box"}}}],
    files:[{filename:"prompts/build-discipline.md", status:"modified"}, {filename:"prompts/rule-evidence/D45.json", status:"added"}]}' > "$T/gh/cmp-$head.json"
  ev "$T/gh/ct-$head-D45.json" D45 lint-backed tests/x-test.sh TK-1 TK-2
}
merge() { printf '%s\tlead\t7\t2026-09-30T00:00:00Z\thttps://r.test/%s\tbox:x\n' "${3:-MERGE}" "$1" > "$T/vd/$1-$2"; }
reset() {
  rm -f "$T/log"/* "$T"/{mc_rc,req_rc,req_err,alert_rc} "$H/logs"/* "$H/flags"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in gh vd; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/open.json"; echo '[]' > "$T/closed.json"
}
RUN="$LANE"
tick() { ( cd "$T" && bash "$RUN" tick ) > "$T/out" 2>&1; RC=$?; }
lines() { [ -f "$T/log/$1" ] && wc -l < "$T/log/$1" | tr -d ' ' || echo 0; }
alines() { cat "$T/log/alert" 2>/dev/null; }
acount() { alines | grep -c -- "--id $1 " ; }
summ() { grep ' tick prs=' "$H/logs/rule-adopt.log" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
ST="$H/state/rule-adopt"

# ── install the lane into the scratch tree (a mutant run swaps RUN) ──
cp "$LANE" "$H/bin/rule-adopt.sh" 2>/dev/null; RUN="$H/bin/rule-adopt.sh"

# ── (a) MERGE on the live head -> one mc_enqueue + one queued warn; tick 2 no second call ──
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; tick
[ "$RC" -eq 0 ] && ok || bad "(a) rc=$RC out=$(cat "$T/out")"
[ "$(cat "$T/log/mc" 2>/dev/null)" = "$URL $SHA" ] && ok || bad "(a) mc log: '$(cat "$T/log/mc" 2>/dev/null)'"
[ "$(acount rule-adopt-queued-900)" = 1 ] && ok || bad "(a) want one queued alert: $(alines)"
alines | grep -- '--id rule-adopt-queued-900 ' | grep -q -- '--severity warn' && ok || bad "(a) queued alert not warn"
alines | grep -- 'rule-adopt-queued-900' | grep -q 'queued to merge' && ok || bad "(a) queued text lacks 'queued to merge'"
alines | grep -- 'rule-adopt-queued-900' | grep -q 'D45' && ok || bad "(a) queued text lacks the rule"
grep -qi 'adopted' <<<"$(alines | grep -- 'rule-adopt-queued-900')" && bad "(a) queued text says adopted" || ok
[ -e "$ST/enqueued-900-$SHA12" ] && ok || bad "(a) no enqueued marker"
[ "$(lines req)" = 0 ] && ok || bad "(a) a request was made over a standing MERGE"
has queued=1 && has lint=1 && ok || bad "(a) summary: $(summ)"
tick
[ "$(lines mc)" = 1 ] && ok || bad "(a) tick 2 made a second mc_enqueue: $(cat "$T/log/mc")"
[ "$(acount rule-adopt-queued-900)" = 1 ] && ok || bad "(a) tick 2 re-sent the queued alert"

# ── (a2) dirty -> dirty warn, no enqueue ──
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; jq -c '.mergeable_state="dirty"' "$T/gh/pull-900.json" > "$T/x" && mv "$T/x" "$T/gh/pull-900.json"; tick
[ "$(lines mc)" = 0 ] && ok || bad "(a2) enqueued a dirty PR"
[ "$(acount "rule-adopt-dirty-900-$SHA12")" = 1 ] && ok || bad "(a2) want one dirty alert: $(alines)"

# ── (a3) mc rc 1 -> enqueue warn, no marker, the next tick calls again ──
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; echo 1 > "$T/mc_rc"; tick
[ "$(acount "rule-adopt-enqueue-900-$SHA12")" = 1 ] && ok || bad "(a3) want one enqueue alert: $(alines)"
alines | grep -- "rule-adopt-enqueue-900" | grep -q 'queue said no' && ok || bad "(a3) the alert does not quote mc_enqueue's output"
[ -e "$ST/enqueued-900-$SHA12" ] && bad "(a3) a failed enqueue wrote the marker" || ok
[ "$(acount rule-adopt-queued-900)" = 0 ] && ok || bad "(a3) said queued on rc 1"
tick
[ "$(lines mc)" = 2 ] && ok || bad "(a3) the next tick did not retry: $(lines mc) mc calls"

# ── (b) no verdict -> one request with the notes, no enqueue ──
reset; lintpr 900 "$SHA"; tick
[ "$(cat "$T/log/req" 2>/dev/null)" = "request example-org/cromford 900 $SHA $REQNOTE" ] && ok || bad "(b) req argv: '$(cat "$T/log/req" 2>/dev/null)'"
[ "$(lines mc)" = 0 ] && ok || bad "(b) enqueued with no verdict"
[ -e "$ST/requested-900-$SHA12" ] && ok || bad "(b) no requested marker"
has requested=1 && ok || bad "(b) summary: $(summ)"

# ── (b-409) request rc 1 with HTTP 409 -> success, marker, no warn ──
reset; lintpr 900 "$SHA"; echo 1 > "$T/req_rc"; echo 'lead-reviews: HTTP 409' > "$T/req_err"; tick
[ -e "$ST/requested-900-$SHA12" ] && ok || bad "(b-409) a 409 wrote no marker"
[ "$(acount "rule-adopt-req-900-$SHA12")" = 0 ] && ok || bad "(b-409) a 409 warned: $(alines)"

# ── (b2) request fails otherwise -> one req warn naming harness-ctl review, no marker ──
reset; lintpr 900 "$SHA"; echo 1 > "$T/req_rc"; echo 'lead-verdict: no lead token' > "$T/req_err"; tick
[ "$(acount "rule-adopt-req-900-$SHA12")" = 1 ] && ok || bad "(b2) want one req alert: $(alines)"
alines | grep -- "rule-adopt-req-900" | grep -qF "bin/harness-ctl.sh review example-org/cromford 900 $SHA" && ok || bad "(b2) the alert lacks the by-hand command: $(alines)"
[ -e "$ST/requested-900-$SHA12" ] && bad "(b2) a failed request wrote the marker" || ok

# ── (b3) cap 1, two PRs -> 1 request, 1 deferred; tick 2 asks the second + re-confirms the first ──
reset; lintpr 900 "$SHA"; lintpr 903 "$S2" rules/mined-20260929-lint
RULE_ADOPT_MAX_REQUESTS_PER_TICK=1 tick
[ "$(lines req)" = 1 ] && ok || bad "(b3) want 1 request under cap 1, got $(lines req)"
has deferred=1 && ok || bad "(b3) summary: $(summ)"
RULE_ADOPT_MAX_REQUESTS_PER_TICK=1 tick
grep -q "request example-org/cromford 903 $S2 " "$T/log/req" && ok || bad "(b3) tick 2 never asked for the deferred PR: $(cat "$T/log/req")"
[ "$(lines req)" = 3 ] && has deferred=0 && ok || bad "(b3) tick 2 want 3 req lines total and nothing deferred: $(lines req) $(summ)"
# an unreadable cap is never "go"
reset; lintpr 900 "$SHA"; RULE_ADOPT_MAX_REQUESTS_PER_TICK=abc tick
[ "$(lines req)" = 0 ] && [ "$(lines gh)" = 0 ] && ok || bad "(b3) a garbage cap still ran"

# ── (c) BLOCK -> no enqueue, no request, one block warn ──
reset; lintpr 900 "$SHA"; merge 900 "$SHA" BLOCK; tick; tick
[ "$(lines mc)" = 0 ] && [ "$(lines req)" = 0 ] && ok || bad "(c) mc=$(lines mc) req=$(lines req)"
[ "$(acount "rule-adopt-block-900-$SHA12")" = 1 ] && ok || bad "(c) want one block alert over two ticks: $(alines)"
alines | grep -- "rule-adopt-block-900" | grep -q 'https://r.test/900' && ok || bad "(c) the alert lacks the report url"

# ── (d) MERGE bound to an older sha, live head SHA -> no enqueue, a request for SHA ──
reset; lintpr 900 "$SHA"; merge 900 "$OLD"; tick
[ "$(lines mc)" = 0 ] && ok || bad "(d) enqueued on a MERGE for another head: $(cat "$T/log/mc")"
[ "$(lines req)" = 1 ] && grep -q "request example-org/cromford 900 $SHA " "$T/log/req" && ok || bad "(d) want one request for the live head: $(cat "$T/log/req" 2>/dev/null)"

# ── (e) the judgement PR rules/mined-20260928, complete and MERGE'd -> nothing ──
reset; lintpr 901 "$SHA" rules/mined-20260928; merge 901 "$SHA"; tick
[ "$(lines mc)" = 0 ] && [ "$(lines req)" = 0 ] && ok || bad "(e) the judgement PR: mc=$(lines mc) req=$(lines req)"
[ "$(lines gh)" = 0 ] && ok || bad "(e) the judgement PR was read: $(cat "$T/log/gh")"

# ── (f) the guard: each -> no enqueue, no verdict read, one foreign warn ──
foreign() {
  tick
  [ "$(lines mc)" = 0 ] && [ "$(lines vd)" = 0 ] && [ "$(lines req)" = 0 ] && ok || bad "($1) mc=$(lines mc) vd=$(lines vd) req=$(lines req)"
  [ "$(acount "rule-adopt-foreign-900-$SHA12")" = 1 ] && ok || bad "($1) want one foreign alert: $(alines)"
}
reset; lintpr 900 "$SHA"; merge 900 "$SHA"
jq -c '.commits += [{parents:[{sha:"p"}], commit:{author:{email:"someone@else.test"}}}] | .total_commits = 2' "$T/gh/cmp-$SHA.json" > "$T/x" && mv "$T/x" "$T/gh/cmp-$SHA.json"; foreign f1
reset; lintpr 900 "$SHA"; merge 900 "$SHA"
jq -c '.files += [{filename:"bin/x.sh", status:"modified"}]' "$T/gh/cmp-$SHA.json" > "$T/x" && mv "$T/x" "$T/gh/cmp-$SHA.json"; foreign f2
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; ev "$T/gh/ct-$SHA-D45.json" D45 judgement - TK-1; foreign f3
reset; lintpr 900 "$SHA"; merge 900 "$SHA"
jq -c '.files = [.files[0]]' "$T/gh/cmp-$SHA.json" > "$T/x" && mv "$T/x" "$T/gh/cmp-$SHA.json"; foreign f4
# a merge commit by anyone is not a foreign commit
reset; lintpr 900 "$SHA"; merge 900 "$SHA"
jq -c '.commits += [{parents:[{sha:"p"},{sha:"q"}], commit:{author:{email:"someone@else.test"}}}] | .total_commits = 2' "$T/gh/cmp-$SHA.json" > "$T/x" && mv "$T/x" "$T/gh/cmp-$SHA.json"; tick
[ "$(lines mc)" = 1 ] && ok || bad "(f5) a merge commit was read as foreign: $(alines)"
# a truncated compare or an unreadable evidence file is unreadable, not foreign, not clean
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; jq -c '.total_commits = 300' "$T/gh/cmp-$SHA.json" > "$T/x" && mv "$T/x" "$T/gh/cmp-$SHA.json"; tick
[ "$(lines mc)" = 0 ] && [ ! -s "$T/log/alert" ] && has unreadable=1 && ok || bad "(f6) truncated compare: mc=$(lines mc) $(alines) $(summ)"
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; rm -f "$T/gh/ct-$SHA-D45.json"; tick
[ "$(lines mc)" = 0 ] && [ ! -s "$T/log/alert" ] && has unreadable=1 && ok || bad "(f7) unreadable evidence: mc=$(lines mc) $(alines) $(summ)"

# ── (g) merged sweep: one rule-adopted warn with rule, check, ids; once; not after 7 days ──
closed() {
  jq -nc --arg m "$(date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    '[{number:902, url:"https://github.com/example-org/cromford/pull/902", headRefName:"rules/mined-20260923-lint", mergedAt:$m},
      {number:904, url:"https://github.com/example-org/cromford/pull/904", headRefName:"rules/mined-20260923", mergedAt:$m}]' > "$T/closed.json"
  jq -nc '[{filename:"prompts/build-discipline.md", status:"modified"}, {filename:"prompts/rule-evidence/D45.json", status:"added"}]' > "$T/gh/files-902.json"
  cp "$T/gh/files-902.json" "$T/gh/files-904.json"
  ev "$T/gh/ct-main-D45.json" D45 lint-backed tests/x-test.sh TK-1 TK-2
}
reset; closed 86400; tick
[ "$(acount rule-adopted-902)" = 1 ] && ok || bad "(g) want one rule-adopted-902 alert: $(alines)"
A=$(alines | grep -- '--id rule-adopted-902 ')
for w in D45 tests/x-test.sh TK-1 TK-2 'adopted (merged' pull/902 '--severity warn'; do
  grep -qF -- "$w" <<<"$A" && ok || bad "(g) the adopted note lacks '$w': $A"
done
[ "$(acount rule-adopted-904)" = 0 ] && ok || bad "(g) the judgement PR was noted"
[ -e "$ST/noted-902" ] && ok || bad "(g) no noted marker"
tick
[ "$(acount rule-adopted-902)" = 1 ] && ok || bad "(g) tick 2 re-noted"
reset; closed 86400; echo 1 > "$T/alert_rc"; tick
[ -e "$ST/noted-902" ] && bad "(g) a failed lane-alert wrote noted-902" || ok
reset; closed $((8 * 86400)); tick
[ ! -s "$T/log/alert" ] && ok || bad "(g) an 8-day-old merge was noted: $(alines)"

# ── (h) vd_standing rc 2 -> nothing ──
reset; lintpr 900 "$SHA"; echo rc2 > "$T/vd/900-$SHA"; tick
[ "$(lines mc)" = 0 ] && [ "$(lines req)" = 0 ] && [ ! -s "$T/log/alert" ] && ok || bad "(h) mc=$(lines mc) req=$(lines req) alerts: $(alines)"
has unreadable=1 && ok || bad "(h) summary: $(summ)"

# ── (i) the lane-off flag -> no call at all ──
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; closed 86400; : > "$H/flags/lane-off-rule-adopt"; tick
[ "$RC" -eq 0 ] && ok || bad "(i) rc=$RC"
for l in list gh vd mc req alert; do [ -s "$T/log/$l" ] && bad "(i) a $l call with the lane off: $(cat "$T/log/$l")" || ok; done

# ── (j) rules/mined-20260930-lint-extra -> nothing past the list ──
reset; lintpr 905 "$SHA" rules/mined-20260930-lint-extra; merge 905 "$SHA"; tick
for l in gh vd mc req alert; do [ -s "$T/log/$l" ] && bad "(j) a $l call for -lint-extra: $(cat "$T/log/$l")" || ok; done

# ── (k) a held tick.lock -> skipped, no calls ──
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; mkdir -p "$ST"
exec 8>"$ST/tick.lock"; flock -n 8 || bad "(k) could not take the lock"
tick; exec 8>&-
for l in list gh vd mc req alert; do [ -s "$T/log/$l" ] && bad "(k) a $l call under a held lock" || ok; done
grep -q 'skipped' "$H/logs/rule-adopt.log" 2>/dev/null && ok || bad "(k) the log does not say skipped"
# not the hub -> nothing
reset; lintpr 900 "$SHA"; merge 900 "$SHA"; echo box-demo > "$H/state/box-name"; tick
[ ! -s "$T/log/list" ] && grep -q 'runs on the hub only' "$H/logs/rule-adopt.log" && ok || bad "(k) ran off the hub"

# ── D1 mutations: each must turn its own case red ──
# M1 drops the head-ref filter of the open loop -> (e) must show a call.
sed '0,/\[\[ "\$HEADREF" =~ \$RE_LINT_HEAD_RE \]\] || continue/{/\[\[ "\$HEADREF" =~ \$RE_LINT_HEAD_RE \]\] || continue/d}' "$LANE" > "$H/bin/rule-adopt-m1.sh"
cmp -s "$LANE" "$H/bin/rule-adopt-m1.sh" && bad "M1 sed changed nothing"
RUN="$H/bin/rule-adopt-m1.sh"; reset; lintpr 901 "$SHA" rules/mined-20260928; merge 901 "$SHA"; tick
[ "$(lines mc)" -gt 0 ] && ok || bad "M1 (no head-ref filter) left (e) green: mc=$(lines mc) req=$(lines req)"
# M2 decides on the verdict's reviewed sha instead of the live head -> (d) must show an enqueue.
sed 's|H12=\${HEAD:0:12}|HEAD=$(cat "$H/reviewed-sha"); H12=${HEAD:0:12}|' "$LANE" > "$H/bin/rule-adopt-m2.sh"
cmp -s "$LANE" "$H/bin/rule-adopt-m2.sh" && bad "M2 sed changed nothing"
RUN="$H/bin/rule-adopt-m2.sh"; reset; lintpr 900 "$SHA"; merge 900 "$OLD"; echo "$OLD" > "$H/reviewed-sha"
jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{author:{email:"harness@box"}}}],
  files:[{filename:"prompts/rule-evidence/D45.json", status:"added"}]}' > "$T/gh/cmp-$OLD.json"; cp "$T/gh/ct-$SHA-D45.json" "$T/gh/ct-$OLD-D45.json"; tick
[ "$(lines mc)" -gt 0 ] && ok || bad "M2 (reviewed sha for the live head) left (d) green: mc=$(lines mc)"
RUN="$H/bin/rule-adopt.sh"; rm -f "$H/reviewed-sha"

# ── the registry and the hub cron ──
LJ="$DIR/catalog/lanes.d/rule-adopt.json"
[ "$(jq -r .script "$LJ" 2>/dev/null)" = bin/rule-adopt.sh ] && ok || bad "lanes.d .script: $(jq -r .script "$LJ" 2>/dev/null)"
[ "$(jq -r '[.scope,.cadence,(.boxes|join(",")),.switch.name,.wired]|join("|")' "$LJ" 2>/dev/null)" = 'hub|*/15 * * * *|hub|lane-off-rule-adopt|true' ] && ok || bad "lanes.d fields"
K=$(jq -c '[.knobs[] | select(.env=="RULE_ADOPT_MAX_REQUESTS_PER_TICK") | [.type,.default,.min,.max,.required]]' "$LJ" 2>/dev/null)
[ "$K" = '[["int",3,1,20,true]]' ] && ok || bad "knob: '$K'"
grep -v '^[[:space:]]*#' "$DIR/cron/lanes/461-rule-adopt.cron" | grep -qF 'hub-lease.sh check && /root/harness/bin/rule-adopt.sh tick' && ok || bad "the cron fragment lacks the hub-lease-gated tick"
[ "$(jq -r '.lanes[] | select(.id=="rule-adopt") | .script' "$REG" 2>/dev/null)" = bin/rule-adopt.sh ] && ok || bad "the rendered registry has no rule-adopt lane"
grep -qF '*/15 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/rule-adopt.sh tick' "$(rendered_cron hub)" && ok || bad "the hub cron render does not run the lane"
# the knob's registry default reaches the lane when the env does not set it
reset; lintpr 900 "$SHA"; lintpr 903 "$S2" rules/mined-20260929-lint; ( unset RULE_ADOPT_MAX_REQUESTS_PER_TICK; tick; exit "$RC" )
[ "$(lines req)" = 2 ] && ok || bad "registry default: want 2 requests (default 3), got $(lines req): $(tail -2 "$H/logs/rule-adopt.log")"

# ── O3 (BH-3806): a lead MERGE stands, but BH-3683 withholds the status ──
# The REAL merge-conductor lib this time (so the real mc_enqueue_mergify),
# over a fake gh that logs label and comment POSTs; la_decide answers rc 1.
cp "$H/bin/lib/merge-conductor-lib.sh" "$T/mc-stub.sh"
mkdir -p "$T/o3bin"
cat > "$T/o3bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/o3gh"
case "\$*" in
  *"api -X POST repos/"*"/labels"*) printf '%s\n' "\$*" >> "$T/log/o3labels" ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "\$*" >> "$T/log/o3comments" ;;
esac
exit 0
EOF
chmod +x "$T/o3bin/gh"
cat > "$H/bin/lib/merge-conductor-lib.sh" <<EOF
. "$DIR/bin/lib/merge-conductor-lib.sh"
. "$H/bin/lib/verdicts.sh"; . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"
la_decide() { printf '%s\n' "\$*" >> "$T/log/o3la"; LA_REASON="touches protected paths: prompts/build-discipline.md"; return 1; }
la_human_needed() { return 0; }
vs_publish() { printf '%s\n' "\$*" >> "$T/log/o3vs"; return 0; }
mc_queue_provider() { printf mergify; }
mc_queue_state() { printf queued; }
mc_mergify_witness() { return 1; }
EOF
RUN="$H/bin/rule-adopt.sh"; reset; lintpr 900 "$SHA"; merge 900 "$SHA"
( export PATH="$T/o3bin:$PATH" MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0; tick; exit "$RC" ); RC=$?
[ "$(lines o3la)" -ge 1 ] && ok || bad "O3 setup: the real enqueue asked la_decide (out: $(cat "$T/out"))"
[ "$(lines o3labels)" = 0 ] && ok || bad "O3: no merge-queue label POST on a withheld verdict ($(cat "$T/log/o3labels" 2>/dev/null))"
[ "$(lines o3comments)" = 0 ] && ok || bad "O3: no @mergifyio comment on a withheld verdict ($(cat "$T/log/o3comments" 2>/dev/null))"
[ "$(lines o3vs)" = 0 ] && ok || bad "O3: no status published"
[ -e "$ST/enqueued-900-$SHA12" ] && bad "O3: a refused enqueue writes no enqueued mark" || ok
[ "$(acount "rule-adopt-nhv-900-$SHA12")" = 1 ] && ok || bad "O3: one rule-adopt-nhv alert: $(alines)"
alines | grep -- "rule-adopt-nhv-900" | grep -qF "bin/lead-verdict.sh post example-org/cromford 900 $SHA MERGE --source human" && ok \
  || bad "O3: the alert names the human command: $(alines)"
[ "$(acount rule-adopt-queued-900)" = 0 ] && [ "$(acount "rule-adopt-enqueue-900-$SHA12")" = 0 ] && ok || bad "O3: neither queued nor enqueue-failed: $(alines)"
has needhv=1 && ok || bad "O3 summary counts it: $(summ)"
cp "$T/mc-stub.sh" "$H/bin/lib/merge-conductor-lib.sh"

echo "rule-adopt.bh-3715: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
