#!/bin/bash
# tests/lead-review-enqueue-no-silent-skip.bh-5779-test.sh — BH-5779: every
# PR the hub trigger lane does not request writes ONE log line that names the
# PR, the head and the reason, ending ` [skip <class>]`.
# "$DIR/bin/lead-review-enqueue.sh" runs WHOLE (`tick`) against a scratch
# harness carrying its real bin closure (scratch_install_closure). Stubbed:
#   * curl — the tests/lead-review-enqueue.bh-3545-test.sh STATEFUL jobs worker,
#            plus a status/detail on every lead row, a 500 for GET /api/verdict
#            on $T/jv500/<n>, the verdict history rows from $T/rows/<n>,
#            GET /api/settings/<key> from $T/set/<key> (the
#            tests/lead-review-enqueue-risk.bh-5022-test.sh B15 lead_pr_authors
#            fixture), and the /reset and /reclaim-stale arms.
#   * gh   — the PR list, the head read (the author from $T/author/<n>, a 500 on
#            $T/head500/<n>), the compare ($T/cmp/<head>.json) and rate_limit.
#   * bin/lane-alert.sh, bin/agent-call.sh and bin/lead-verdict.sh — record argv.
# S1-S14 are one fixture per skip path: exactly one `[skip ` line for the PR,
# with the head. S15 runs S1-S13 in ONE tick and checks the skip lines against
# the PRs not requested and against the summary counts.
#   S16 (lead NOTE on 8c69a822) the rebase hold's exit writes one
#       `[skip rebase]` line too, deduped like the rest, and skipped_rebase
#       is in the summary sum
#   D1-D4 a skip is written once per (PR, head, class): a repeat tick is
#       counted (skips=, skips_logged=) and not written; a new class or a new
#       head is written; the summary still ends with rung=
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-no-silent-skip.bh-5779-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lead-review-enqueue.sh" ] || { echo "FAIL: no bin/lead-review-enqueue.sh"; exit 1; }

H="$T/h"; mkdir -p "$H/bin" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
# The stubs go first: scratch_install_closure never clobbers a file already there.
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/agent"
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit 0
EOF
chmod +x "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh" "$H/bin/lead-verdict.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"

NOW=$(date +%s)
SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
OLD=$(printf 'c%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -e "$T/jv500/\$n" ]; then code=500; out='{"error":"boom"}'
    elif [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    if [ -f "$T/rows/\$n" ]; then rw=\$(cat "$T/rows/\$n"); else rw='[]'; fi
    out=\$(jq -nc --argjson s "\$st" --argjson r "\$rw" '{standing:\$s, rows:\$r, truncated:false}') ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/lead-reviews/reclaim-stale")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"reclaimed":[],"deadline_s":3600,"as_of":"2026-10-09T00:00:00Z","truncated":false}'; fi ;;
  "POST /api/lead-reviews/"*"/reset")
    id="\${p#/api/lead-reviews/}"; id="\${id%/reset}"
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      jq -c --arg i "\$id" 'map(if .id == \$i then .status = "requested" | .detail = null | .reset_count = ((.reset_count // 0) + 1) else . end)' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
      row=\$(jq -c --arg i "\$id" '[.[] | select(.id == \$i)] | first // empty' "$T/lrrows.json")
      if [ -n "\$row" ]; then out=\$(jq -c '{request:.}' <<<"\$row"); else code=404; out='{"error":"no such lead review"}'; fi
    fi ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "$T/lrrows.json")
      if [ -n "\$have" ]; then
        if [ "\$(jq -r '.scope_notes // ""' <<<"\$have")" = "\$nt" ]; then out=\$(jq -c '{request:., existing:true}' <<<"\$have")
        else code=409; out=\$(jq -c '{error:"a request for this head exists with other notes", request:.}' <<<"\$have"); fi
      else
        n=\$(jq length "$T/lrrows.json")
        row=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested"}' <<<"\$body")
        jq -c --argjson r "\$row" '. + [\$r]' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
        code=201; out=\$(jq -c '{request:.}' <<<"\$row")
      fi
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/demo-os/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    if [ -e "$T/head500/\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" --arg u "\$(cat "$T/author/\$n" 2>/dev/null || echo "cromford[bot]")" \
      '{head:{sha:\$s},base:{ref:"main"},user:{login:\$u}}'; fi ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    if [ -f "$T/cmp/\$h.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}]}\n'; fi ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 REPOS_ROOT="$T/norepos"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME LEAD_REVIEW_FAILED_RETRY_MAX LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

# sha <n> — a distinct full head per PR number
sha() { printf '%s%038d' "$1" 0; }
# pr <n> <head> [draft] — an open PR on example-org/demo-os at <head>
pr() {
  jq -c --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" '. + [{number:$n, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),
    title:"t", draft:$d, state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
# verdict <n> <word> <reviewed_sha> — the builder's ledger verdict row
verdict() {
  jq -nc --arg v "$2" --arg s "$3" '{verdict:$v, tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
approve() { verdict "$1" APPROVE "$2"; }
standing_merge() { jq -nc '{verdict:"MERGE",source:"lead",id:7,created_at:"2026-10-09T00:00:00Z",report_url:null,reviewer:"box:x"}' > "$T/standing/$1"; }
lead_row() { jq -nc --arg h "$2" '[{id:8, verdict:"MERGE", source:"lead", head_sha:$h, note:"", created_at:"2026-10-09T00:00:00Z"}]' > "$T/rows/$1"; }
selfc() { jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"fix: x\n\nLead-Lane: mac"}}]}' > "$T/cmp/$1.json"; }
# seeded <n> <head> <status> <detail> — a lead row the hub already asked for
seeded() {
  [ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
  jq -c --argjson n "$1" --arg h "$2" --arg s "$3" --arg d "$4" --arg nt "auto: builder APPROVE on ${2:0:12}" \
    '. + [{id:("lr-s"+($n|tostring)), repo:"example-org/demo-os", pr:$n, head_sha:$h, scope_notes:$nt, requested_by:"lead-review-enqueue:box-hub",
      status:$s, detail:(if $d == "" then null else $d end)}]' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
  mkdir -p "${LEDGER%/*}"; printf '%s\texample-org/demo-os\t%s\t%s\tlr-s%s\n' "$((NOW - 600))" "$1" "$2" "$1" >> "$LEDGER"
}
reset() {
  rm -f "$T/log"/* "$T/lrrows.json" "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv jv500 standing rows head head500 cmp set author; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  printf 'operator' > "$T/set/lead_pr_authors"
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
LOGF="$H/logs/lead-review-enqueue.log"
LEDGER="$H/state/lead-review-enqueue/requested.tsv"
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/lead-reviews ' ; }
summ() { grep ' tick repos=' "$LOGF" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
alines() { cat "$T/log/alerts" 2>/dev/null; }
# skips <n> — the [skip lines for PR #<n>; skipn <n> — how many
skips() { grep -E "example-org/demo-os#$1( |:).*\[skip " "$LOGF" 2>/dev/null; }
skipn() { skips "$1" | grep -c .; }
# one <label> <n> <head12> <class> — exactly one skip line for #n, with the head and the class
one() {
  [ "$(skipn "$2")" = 1 ] && ok || bad "$1 want exactly one [skip line for #$2, got $(skipn "$2"): $(cat "$LOGF" 2>/dev/null)"
  grep -q "#$2 @$3" <<<"$(skips "$2")" && ok || bad "$1 the skip line lacks the head $3: $(skips "$2")"
  grep -q "\[skip $4\]\$" <<<"$(skips "$2")" && ok || bad "$1 want class [skip $4]: $(skips "$2")"
}

# ── S1 (red): a draft PR ──
reset; pr 41 "$SHA" true; approve 41 "$SHA"; tick
[ "$RC" -eq 0 ] && ok || bad "S1 rc=$RC out=$(cat "$T/out")"
one S1 41 "$SHA12" draft

# ── S2 (red): the builder's REQUEST_CHANGES on the head, a non-lead author ──
reset; pr 41 "$SHA"; verdict 41 REQUEST_CHANGES "$SHA"; tick
one S2 41 "$SHA12" no-approve
grep -q 'REQUEST_CHANGES' <<<"$(skips 41)" && grep -q 'the fix round owns it' <<<"$(skips 41)" && ok || bad "S2 reason: $(skips 41)"
grep -q 'lead-authored' <<<"$(skips 41)" && bad "S2 a non-lead PR called lead-authored: $(skips 41)" || ok

# ── S3 (red): the builder ledger is unreadable (500) ──
reset; pr 41 "$SHA"; : > "$T/jv500/41"; tick
one S3 41 "$SHA12" no-approve
grep -q 'unreadable' <<<"$(skips 41)" && ok || bad "S3 reason: $(skips 41)"

# ── S4 (red): REQUEST_CHANGES on a lead-authored PR names its owner ──
reset; pr 41 "$SHA"; verdict 41 REQUEST_CHANGES "$SHA"; echo operator > "$T/author/41"; tick
one S4 41 "$SHA12" no-approve
grep -qF 'lead-authored (operator)' <<<"$(skips 41)" && ok || bad "S4 no lead-authored (operator): $(skips 41)"
grep -qF 'the author must push a fix' <<<"$(skips 41)" && ok || bad "S4 no owner sentence: $(skips 41)"
grep -qF "bin/lead-verdict.sh request example-org/demo-os 41 $SHA" <<<"$(skips 41)" && ok || bad "S4 no request command: $(skips 41)"
# ...and an unreadable lead_pr_authors row never says lead-authored
reset; pr 41 "$SHA"; verdict 41 REQUEST_CHANGES "$SHA"; echo operator > "$T/author/41"; rm -f "$T/set/lead_pr_authors"; tick
one S4b 41 "$SHA12" no-approve
grep -q 'lead-authored' <<<"$(skips 41)" && bad "S4b lead-authored without the row: $(skips 41)" || ok

# ── S5 (red): APPROVE on the head and a standing lead MERGE ──
reset; pr 41 "$SHA"; approve 41 "$SHA"; standing_merge 41; tick
one S5 41 "$SHA12" verdict
grep -qF 'MERGE by lead' <<<"$(skips 41)" && ok || bad "S5 reason: $(skips 41)"
has skipped_verdict=1 && ok || bad "S5 summary: $(summ)"

# ── S6 (red): no builder row, a lead row on the head in the history ──
reset; pr 41 "$SHA"; lead_row 41 "$SHA"; tick
one S6 41 "$SHA12" verdict

# ── S7: no builder row, CI not known green -> the existing line, suffix only ──
reset; pr 41 "$SHA"; tick
one S7 41 "$SHA12" ci
grep -q 'not requested yet' <<<"$(skips 41)" && ok || bad "S7 the existing words changed: $(skips 41)"

# ── S8 (red): cap 1 and two new heads -> the second is deferred ──
reset; pr 41 "$SHA"; approve 41 "$SHA"; pr 42 "$(sha 42)"; approve 42 "$(sha 42)"; LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
[ "$(posts)" = 1 ] && ok || bad "S8 want one request, got $(posts)"
[ "$(skipn 41)" = 0 ] && ok || bad "S8 the requested PR has a skip line: $(skips 41)"
one S8 42 "$(sha 42 | cut -c1-12)" deferred

# ── S9 (red): a Lead-Lane: commit -> one skip line and still one alert ──
reset; pr 41 "$SHA"; approve 41 "$SHA"; selfc "$SHA"; tick
one S9 41 "$SHA12" self
[ "$(alines | grep -c "lead-self-example-org_demo-os-41-$SHA12")" = 1 ] && ok || bad "S9 want one lead-self alert: $(alines)"

# ── S10: the per-PR tripwire ──
reset; pr 41 "$SHA"; approve 41 "$SHA"
mkdir -p "${LEDGER%/*}"; printf '%s\texample-org/demo-os\t41\t%s\tlr-x\n' "$((NOW - 3600))" "$OLD" > "$LEDGER"
LEAD_REVIEW_MAX_PER_PR_DAY=1 tick
one S10 41 "$SHA12" tripped

# ── S11 (red): the second tick on a requested head ──
reset; pr 41 "$SHA"; approve 41 "$SHA"; tick; tick
one S11 41 "$SHA12" existing
grep -q 'status requested' <<<"$(skips 41)" && ok || bad "S11 reason: $(skips 41)"

# ── S12 (red): the row was superseded as needs rebase ──
reset; pr 41 "$SHA"; approve 41 "$SHA"; tick
jq -c 'map(.status = "superseded" | .detail = "needs rebase: conflicts with main (mergeable_state dirty)")' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
rm -f "$H/logs"/*; tick
one S12 41 "$SHA12" existing
grep -q 'needs rebase' <<<"$(skips 41)" && ok || bad "S12 reason: $(skips 41)"

# ── S13: the live head is unreadable -> the existing line, suffix only ──
reset; pr 41 "$SHA"; approve 41 "$SHA"; : > "$T/head500/41"; tick
[ "$(skipn 41)" = 1 ] && ok || bad "S13 want one skip line: $(cat "$LOGF")"
grep -q 'live head unreadable.*\[skip unreadable\]$' <<<"$(skips 41)" && ok || bad "S13 line: $(skips 41)"

# ── S14: REQB=1 and the APPROVE is on an older sha ──
reset; pr 41 "$SHA"; approve 41 "$OLD"; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 tick
one S14 41 "$SHA12" no-approve

# ── S15 (red): S1-S13 in ONE tick: skip lines == PRs not requested == summary ──
reset
pr 51 "$(sha 51)" true; approve 51 "$(sha 51)"                                      # draft
pr 52 "$(sha 52)"; verdict 52 REQUEST_CHANGES "$(sha 52)"                           # no-approve
pr 53 "$(sha 53)"; : > "$T/jv500/53"                                                # no-approve (unreadable)
pr 54 "$(sha 54)"; verdict 54 REQUEST_CHANGES "$(sha 54)"; echo operator > "$T/author/54"   # no-approve (lead)
pr 55 "$(sha 55)"; approve 55 "$(sha 55)"; standing_merge 55                        # verdict
pr 56 "$(sha 56)"; lead_row 56 "$(sha 56)"                                          # verdict (history)
pr 57 "$(sha 57)"                                                                   # ci
pr 58 "$(sha 58)"; approve 58 "$(sha 58)"; selfc "$(sha 58)"                        # self
pr 59 "$(sha 59)"; approve 59 "$(sha 59)"                                           # tripped
mkdir -p "${LEDGER%/*}"; printf '%s\texample-org/demo-os\t59\t%s\tlr-x\n' "$((NOW - 3600))" "$OLD" > "$LEDGER"
pr 60 "$(sha 60)"; approve 60 "$(sha 60)"; seeded 60 "$(sha 60)" requested ""       # existing
pr 61 "$(sha 61)"; approve 61 "$(sha 61)"; seeded 61 "$(sha 61)" superseded "needs rebase: conflicts with main"  # existing
pr 62 "$(sha 62)"; approve 62 "$(sha 62)"; : > "$T/head500/62"                      # unreadable
pr 63 "$(sha 63)"; approve 63 "$(sha 63)"                                           # requested
pr 64 "$(sha 64)"; approve 64 "$(sha 64)"                                           # deferred
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 LEAD_REVIEW_MAX_PER_PR_DAY=1 tick
[ "$RC" -eq 0 ] && ok || bad "S15 rc=$RC"
has requested=1 && [ "$(jq -c '[.[] | select(.id | startswith("lr-s") | not) | .pr]' "$T/lrrows.json")" = '[63]' ] \
  && ok || bad "S15 want only #63 requested: $(summ) $(jq -c '[.[] | .pr]' "$T/lrrows.json")"
NSKIP=$(grep -c '\[skip ' "$LOGF")
[ "$NSKIP" = 13 ] && ok || bad "S15 want 13 skip lines (14 PRs, 1 requested), got $NSKIP: $(grep '\[skip ' "$LOGF")"
for n in 51 52 53 54 55 56 57 58 59 60 61 62 64; do
  [ "$(skipn "$n")" = 1 ] && ok || bad "S15 #$n has $(skipn "$n") skip lines"
done
[ "$(skipn 63)" = 0 ] && ok || bad "S15 the requested #63 has a skip line: $(skips 63)"
SUM=$(summ | tr ' ' '\n' | awk -F= '$1 ~ /^(skipped_[a-z_]+|deferred|tripped|existing|unreadable)$/ {s += $2} END {print s + 0}')
[ "$SUM" = "$NSKIP" ] && ok || bad "S15 the summary counts add up to $SUM, the skip lines to $NSKIP: $(summ)"

# ── S16: the rebase hold's exit is a skip line too ──
reset
pr 71 "$(sha 71)"; approve 71 "$(sha 71)"
mkdir -p "$H/state/merge-conductor"
printf 'example-org/demo-os#71\tNEEDS_REBASE\t-\t%s\t-\t-\tconflicts with main\n' "$(sha 71)" > "$H/state/merge-conductor/pr-state.tsv"
tick
[ "$RC" -eq 0 ] && ok || bad "S16 rc=$RC"
one S16 71 "$(sha 71 | cut -c1-12)" rebase
has skipped_rebase=1 && ok || bad "S16 the summary counts skipped_rebase=1: $(summ)"
SUM=$(summ | tr ' ' '\n' | awk -F= '$1 ~ /^(skipped_[a-z_]+|deferred|tripped|existing|unreadable)$/ {s += $2} END {print s + 0}')
[ "$SUM" = "$(grep -c '\[skip ' "$LOGF")" ] && ok || bad "S16 the summary sum $SUM must equal the skip lines: $(summ)"
tick
[ "$(skipn 71)" = 1 ] && ok || bad "S16 the rebase skip is written once per head: $(skips 71)"

# ── D1-D4: a skip is written once per (PR, head, class), then counted ──
# (the lead, 2026-10-10: one line per open PR per tick was ~29,000 a day)
reset; pr 41 "$SHA"; verdict 41 REQUEST_CHANGES "$SHA"; tick; tick
[ "$(skipn 41)" = 1 ] && ok || bad "D1 the same skip on the same head was written twice: $(skips 41)"
has skips=1 && has skips_logged=0 && ok || bad "D1 the second tick's summary must count skips=1 skips_logged=0: $(summ)"
grep -q ' rung=[0-9]*$' <<<"$(summ)" && ok || bad "D1 the summary must still end with rung=: $(summ)"
: > "$T/jv500/41"; tick
[ "$(skipn 41)" = 1 ] && ok || bad "D2 a changed reason with the same head and class must stay quiet, got $(skipn 41): $(skips 41)"
rm -f "$T/jv500/41"; echo '[]' > "$T/prs.json"; pr 41 "$SHA" true; tick
[ "$(skipn 41)" = 2 ] && grep -q '\[skip draft\]$' <<<"$(skips 41 | tail -1)" && ok || bad "D3 a new class must be written: $(skips 41)"
S2H=$(printf 'f%.0s' {1..40}); echo '[]' > "$T/prs.json"; pr 41 "$S2H"; verdict 41 REQUEST_CHANGES "$S2H"; tick
grep -q "@${S2H:0:12}" <<<"$(skips 41 | tail -1)" && ok || bad "D4 a new head must be written: $(skips 41)"

[ -s "$T/log/agent" ] && bad "agent-call.sh ran: $(cat "$T/log/agent")" || ok
grep -q 'test-secret\|lead-test-token' "$LOGF" && bad "a secret reached the log" || ok
echo "lead-review-enqueue-no-silent-skip.bh-5779: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
