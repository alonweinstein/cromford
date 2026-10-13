#!/bin/bash
# tests/lead-review-precision.bh-3548-test.sh — BH-3548 (BH-3479.4): the hub
# precision lane, bin/lead-review-precision.sh, run WHOLE against a scratch
# harness carrying the real jobs client, bin/lib/gh-rest.sh, gh-app-auth.sh,
# hub-box.sh and lane-gate.sh, with only these stubbed:
#   * curl — the jobs worker: GET /api/verdicts?repo=&pr=&head= answers from
#            $T/vrows.json (rows id DESC); $T/vget500-<pr> makes it a 500;
#   * gh   — GitHub REST (`gh api -i -X GET <path>`): the closed-PR list from
#            $T/pulls1.json (page 1) and $T/pulls2.json (page 2), main's
#            commits from $T/commits.json, check runs from $T/checks-<sha>.json;
#            $T/pulls500, $T/commits500 and $T/checks500-<sha> make them a 500;
#   * $H/bin/lane-alert.sh — records its argv in $T/log/alerts.
# Every GitHub call is logged to $T/log/gh, every worker call to $T/log/worker.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-precision.bh-3548-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in env-path hub-box lane-gate gh-rest gh-app-auth; do cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"; done
[ -f "$DIR/bin/lead-review-precision.sh" ] && cp "$DIR/bin/lead-review-precision.sh" "$H/bin/"

NOW=$(date +%s)
IN=$(date -u -d "@$((NOW - 86400))" +%Y-%m-%dT%H:%M:%SZ)
OUT=$(date -u -d "@$((NOW - 40 * 86400))" +%Y-%m-%dT%H:%M:%SZ)
REPO=example-org/demo-os
sha() { printf 'c%039d' "$1"; }

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
p="\${url#https://jobs.test}"
printf 'GET %s\n' "\$p" >> "$T/log/worker"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$p" in
  /api/verdicts\?*)
    if [ -e "$T/vget500-\$(qp pr)" ]; then code=500; out='{"error":"boom"}'
    elif [ -e "$T/vgetnorows-\$(qp pr)" ]; then out='{"repo":"x"}'
    else
      out=\$(jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
        [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
        | {repo:\$r, pr:\$pr, head:\$h, rows:\$rows, truncated:false}' "$T/vrows.json")
    fi ;;
  *) code=404; out='{"error":"unknown endpoint"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
p=""; prev=""
for a in "\$@"; do [ "\$prev" = -X ] && p=next; [ "\$p" = next ] && [ "\$a" != GET ] && p="\$a"; prev="\$a"; done
ok() { printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$(cat "\$1")"; }
okb() { printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$1"; }
boom() { printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n{"message":"boom"}\n'; exit 1; }
case "\$p" in
  repos/*/pulls\?*)
    [ -e "$T/pulls500" ] && boom
    case "\$p" in
      *"&page=1") ok "$T/pulls1.json" ;;
      *"&page=2") [ -e "$T/pulls500-p2" ] && boom; [ -f "$T/pulls2.json" ] && ok "$T/pulls2.json" || okb '[]' ;;
      *) okb '[]' ;;
    esac ;;
  repos/*/commits\?*)
    [ -e "$T/commits500" ] && boom
    case "\$p" in *"&page=1") ok "$T/commits.json" ;; *) okb '[]' ;; esac ;;
  repos/*/commits/*/check-runs*)
    s=\${p#repos/*/commits/}; s=\${s%%/*}
    [ -e "$T/checks500-\$s" ] && boom
    if [ -f "$T/checks-\$s.json" ]; then ok "$T/checks-\$s.json"; else okb '{"check_runs":[]}'; fi ;;
  *) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_REVIEW_AUTO_REPOS="$REPO"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME GH_TOKEN LEAD_REVIEW_PRECISION_WINDOW_DAYS LEAD_REVIEW_PRECISION_WARN \
  LEAD_REVIEW_PRECISION_MIN_N LEAD_REVIEW_PRECISION_MAX_PAGES

# pulls <n>[:<merged_at>] ... -> $T/pulls1.json (merged_at defaults to one day ago)
pulls() {
  local a n m
  for a in "$@"; do
    n=${a%%:*}; m=$IN; [ "$a" = "$n" ] || m=${a#*:}
    jq -nc --argjson n "$n" --arg s "$(sha "$n")" --arg m "$m" '{number:$n, merged_at:$m, updated_at:$m, head:{sha:$s}}'
  done | jq -sc . > "$T/pulls1.json"
}
# vrow <id> <pr> <source> <verdict> [head] — one verdict row (lead rows carry the lead-review: token)
vrow() {
  jq -nc --argjson id "$1" --argjson pr "$2" --arg src "$3" --arg v "$4" --arg h "${5:-$(sha "$2")}" --arg r "$REPO" \
    '{id:$id, repo:$r, pr:$pr, head_sha:$h, source:$src, verdict:$v,
      note:(if $src == "lead" then "lead-review:lr-\($pr)" else null end)}'
}
setrows() { printf '%s\n' "$@" | jq -sc . > "$T/vrows.json"; }
# leads <pr>... — a lead MERGE row on each PR's head
leads() { local n i=0 rows=(); for n in "$@"; do i=$((i+1)); rows+=("$(vrow "$i" "$n" lead MERGE)"); done; setrows "${rows[@]}"; }
commits() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({commit:{message:.}})' > "$T/commits.json"; }
checks() { printf '%s' "$2" > "$T/checks-$(sha "$1").json"; }

reset() {
  rm -f "$T/log"/* "$T"/{pulls500,pulls500-p2,commits500,pulls2.json,vrows.json} "$T"/vget500-* "$T"/vgetnorows-* "$T"/checks500-* "$T"/checks-*.json \
    "$H/logs/lead-review-precision.log"
  scratch_rm "$H/state/lead-review-precision"
  echo box-hub > "$H/state/box-name"
  pulls 11 12 13; leads 11 12 13; commits
}
run() { ( cd "$T" && env "$@" bash "$H/bin/lead-review-precision.sh" ) > "$T/out" 2>&1; RC=$?; }
dayfile() { ls "$H/state/lead-review-precision/"*.json 2>/dev/null | head -1; }
nfiles() { ls "$H/state/lead-review-precision/"*.json 2>/dev/null | wc -l | tr -d ' '; }
r() { jq -c ".repos[0]$1" "$(dayfile)" 2>/dev/null; }
alerts() { [ -f "$T/log/alerts" ] && wc -l < "$T/log/alerts" | tr -d ' ' || echo 0; }
# TEST-CHANGE (BH-3683): the run now ends with the authority gate, which logs its
# own lines (here: bin/lib/lead-authority.sh is not in this scratch tree, so one
# "gate is skipped" line per run). P8's contract is one SUMMARY line per run, so
# only the `day=` lines are counted; the gate's lines are pinned by
# tests/lead-review-precision-authority.bh-3683-test.sh.
loglines() { cat "$H/logs/lead-review-precision.log" 2>/dev/null | grep -c ' day='; }

# ── P0: the script exists, makes no model call, and runs on the hub only ────
[ -f "$DIR/bin/lead-review-precision.sh" ] && ok || bad "P0 bin/lead-review-precision.sh does not exist"
[ "$(grep -L agent-call "$DIR/bin/lead-review-precision.sh" 2>/dev/null)" = "$DIR/bin/lead-review-precision.sh" ] && ok || bad "P0 grep -L agent-call does not list the script"
reset; echo builder-7 > "$H/state/box-name"; run
[ "$RC" = 0 ] && [ "$(nfiles)" = 0 ] && ok || bad "P0 non-hub: rc=$RC files=$(nfiles)"
grep -q 'not the hub (builder-7); lead-review-precision runs on the hub only' "$H/logs/lead-review-precision.log" 2>/dev/null && ok || bad "P0 no 'not the hub' log line"
[ ! -s "$T/log/gh" ] && ok || bad "P0 a non-hub box called GitHub"

# ── P1: 3 lead MERGEs, #12 reverted -> precision 0.667 ───────────────────────
reset; commits 'Revert "Add thing (#12)"' 'Revert "x (#123)"' 'Revert "y (#1)"' 'Add z (#11)'; run
[ "$RC" = 0 ] && ok || bad "P1 rc=$RC out=$(cat "$T/out")"
[ "$(nfiles)" = 1 ] && basename "$(dayfile)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$' && ok || bad "P1 day file: $(ls "$H/state/lead-review-precision/" 2>/dev/null)"
[ "$(r .lead_merge)" = 3 ] && [ "$(r .reverted)" = 1 ] && [ "$(r .batch_failed)" = 0 ] && [ "$(r .unreadable)" = 0 ] && ok || bad "P1 counts: $(r '')"
[ "$(r .precision)" = 0.667 ] && ok || bad "P1 precision $(r .precision) (want 0.667)"
[ "$(r '.prs | map(.pr)')" = '[11,12,13]' ] && ok || bad "P1 prs order: $(r '.prs')"
[ "$(r '.prs[] | select(.pr==12) | .reverted')" = true ] && ok || bad "P1 #12 not marked reverted"
[ "$(r '.prs[] | select(.pr==11) | .reverted')" = false ] && ok || bad "P1 #11 marked reverted by '#1'/'Add z (#11)': $(r '.prs')"
[ "$(r '.repo')" = "\"$REPO\"" ] && [ "$(r .window_days)" = 30 ] && [ "$(r .truncated)" = false ] && ok || bad "P1 repo/window/truncated: $(r '')"
[ "$(jq -r .window_days "$(dayfile)")" = 30 ] && [ "$(jq -r .day "$(dayfile)").json" = "$(basename "$(dayfile)")" ] && ok || bad "P1 file header"
# control: #123 alone never marks #12
reset; commits 'Revert "x (#123)"'; run
[ "$(r .reverted)" = 0 ] && [ "$(r .precision)" = 1 ] && ok || bad "P1 control: #123 counted as #12: $(r '')"
# ── P8: exactly one log line per run, naming the counts ──────────────────────
reset; commits 'Revert "Add thing (#12)"'; run
[ "$(loglines)" = 1 ] && ok || bad "P8 want 1 log line, got $(loglines): $(cat "$H/logs/lead-review-precision.log")"
grep -q "day=.* window=30d $REPO lead_merge=3 reverted=1 batch_failed=0 unreadable=0 precision=0.667 truncated=false" "$H/logs/lead-review-precision.log" && ok || bad "P8 log line: $(cat "$H/logs/lead-review-precision.log")"

# ── P2: no lead row, or a lead row on another head -> not counted, not listed ─
reset; pulls 11 14 15; setrows "$(vrow 1 11 lead MERGE)" "$(vrow 2 14 box APPROVE)" "$(vrow 3 15 lead MERGE "$(sha 999)")"; run
[ "$(r .lead_merge)" = 1 ] && [ "$(r '.prs | map(.pr)')" = '[11]' ] && ok || bad "P2 $(r '')"
# ── P9: no check-runs read for a PR with no lead MERGE ───────────────────────
grep -q "commits/$(sha 14)/check-runs" "$T/log/gh" && bad "P9 check runs read for #14" || ok
grep -q "commits/$(sha 11)/check-runs" "$T/log/gh" && ok || bad "P9 no check runs read for #11"
# a lead row whose note carries no lead-review: token is not the lead's verdict
reset; setrows "$(vrow 1 11 lead MERGE)" "$(vrow 2 12 lead MERGE)" "$(vrow 3 13 lead MERGE | jq -c '.note = "manual"')"; run
[ "$(r .lead_merge)" = 2 ] && [ "$(r '.prs | map(.pr)')" = '[11,12]' ] && ok || bad "P2 tokenless lead row counted: $(r '')"
# a BLOCK that merged anyway is listed, not scored
reset; setrows "$(vrow 1 11 lead MERGE)" "$(vrow 2 12 lead BLOCK)" "$(vrow 3 13 lead MERGE-WITH-NOTES)"; run
[ "$(r .lead_merge)" = 2 ] && [ "$(r '.prs[] | select(.pr==12) | .verdict')" = '"BLOCK"' ] && ok || bad "P2 BLOCK: $(r '')"
# the newest lead row on the head wins
reset; setrows "$(vrow 1 11 lead MERGE)" "$(vrow 2 12 lead MERGE)" "$(vrow 3 13 lead MERGE)" "$(vrow 4 13 lead BLOCK)"; run
[ "$(r .lead_merge)" = 2 ] && [ "$(r '.prs[] | select(.pr==13) | .verdict')" = '"BLOCK"' ] && ok || bad "P2 newest row: $(r '')"

# ── P3: an unreadable verdict is unreadable, never clean ─────────────────────
reset; commits 'Revert "Add thing (#12)"'; : > "$T/vget500-13"; run
[ "$(r .unreadable)" = 1 ] && [ "$(r .lead_merge)" = 2 ] && [ "$(r .precision)" = 0.5 ] && ok || bad "P3 $(r '')"
[ "$(r '.prs[] | select(.pr==13) | .verdict')" = '"unreadable"' ] && [ "$(r '.prs[] | select(.pr==13) | .reverted')" = null ] && ok || bad "P3 #13 entry: $(r '.prs')"
# a 200 with no rows array is unreadable too, never "no lead row"
reset; : > "$T/vgetnorows-13"; run
[ "$(r .unreadable)" = 1 ] && [ "$(r '.prs[] | select(.pr==13) | .verdict')" = '"unreadable"' ] && ok || bad "P3 no-rows answer: $(r '')"
# P3b: a failed check-runs read
reset; : > "$T/checks500-$(sha 11)"; run
[ "$(r .unreadable)" = 1 ] && [ "$(r .lead_merge)" = 2 ] && [ "$(r '.prs[] | select(.pr==11) | .batch_failed')" = null ] && ok || bad "P3b $(r '')"
# P3c: a failed commits read makes every lead MERGE unreadable and names it
reset; : > "$T/commits500"; run
[ "$(r .unreadable)" = 3 ] && [ "$(r .lead_merge)" = 0 ] && [ "$(r .precision)" = null ] && r .error | grep -q 'commits unreadable' && ok || bad "P3c $(r '')"

# ── P4: n=0 -> precision null, no warn; the warn beat and its bounds ─────────
reset; pulls "11:$OUT" "12:$OUT"; run
[ "$(r .lead_merge)" = 0 ] && [ "$(r .precision)" = null ] && [ "$(alerts)" = 0 ] && ok || bad "P4 $(r '') alerts=$(alerts)"
grep -q 'repos/example-org/demo-os/commits?' "$T/log/gh" && bad "P4 read main's commits with no lead MERGE" || ok
p4b() { reset; pulls 21 22 23 24 25; leads 21 22 23 24 25; commits 'Revert "a (#21)"' 'Revert "b (#22)"' 'Revert "c (#23)"'; }
p4b; run
DAY=$(jq -r .day "$(dayfile)" 2>/dev/null)
[ "$(r .precision)" = 0.4 ] && [ "$(alerts)" = 1 ] && ok || bad "P4b precision $(r .precision) alerts=$(alerts)"
grep -q -- "--severity warn --id lead-precision-$DAY lead-review-precision .*$REPO.*0.4" "$T/log/alerts" 2>/dev/null && ok || bad "P4b alert argv: $(cat "$T/log/alerts" 2>/dev/null)"
grep -q "state/lead-review-precision/$DAY.json" "$T/log/alerts" 2>/dev/null && ok || bad "P4b alert does not name the file"
# ── P6: a same-day rerun: one byte-identical file, still one alert ───────────
S1=$(sha256sum "$(dayfile)" | cut -d' ' -f1); run
[ "$(nfiles)" = 1 ] && [ "$(sha256sum "$(dayfile)" | cut -d' ' -f1)" = "$S1" ] && ok || bad "P6 rerun changed the file (files=$(nfiles))"
[ "$(alerts)" = 1 ] && ok || bad "P6 rerun alerted again: $(alerts)"
[ "$(loglines)" = 2 ] && ok || bad "P8 two runs want two log lines, got $(loglines)"
# P4c: n < MIN_N
reset; commits 'Revert "a (#11)"' 'Revert "b (#12)"'; run
[ "$(r .precision)" = 0.333 ] && [ "$(alerts)" = 0 ] && ok || bad "P4c precision $(r .precision) alerts=$(alerts)"
# P4d: the WARN knob is read; so is MIN_N
p4b; run LEAD_REVIEW_PRECISION_WARN=0.3
[ "$(alerts)" = 0 ] && ok || bad "P4d WARN=0.3 still alerted"
p4b; run LEAD_REVIEW_PRECISION_MIN_N=6
[ "$(alerts)" = 0 ] && ok || bad "P4d MIN_N=6 still alerted"
p4b; run LEAD_REVIEW_PRECISION_WARN=abc
[ "$(alerts)" = 1 ] && grep -q "LEAD_REVIEW_PRECISION_WARN='abc'" "$H/logs/lead-review-precision.log" && ok || bad "P4d a bad WARN must log and fall back to 0.9"
# the window knob: a 50-day window scores the 40-day-old merges
reset; pulls "11:$OUT"; run LEAD_REVIEW_PRECISION_WINDOW_DAYS=50
[ "$(r .lead_merge)" = 1 ] && [ "$(r .window_days)" = 50 ] && ok || bad "P4 WINDOW_DAYS=50: $(r '')"

# ── P5: a failed or cancelled Queue: run on the head = batch failure ─────────
reset; checks 11 '{"check_runs":[{"name":"Queue: embarked","status":"completed","conclusion":"failure"}]}'; run
[ "$(r .batch_failed)" = 1 ] && [ "$(r '.prs[] | select(.pr==11) | .batch_failed')" = true ] && [ "$(r .precision)" = 0.667 ] && ok || bad "P5 $(r '')"
grep -qE "commits/$(sha 11)/check-runs[^ ]*filter=all" "$T/log/gh" && ok || bad "P5 check runs not read with filter=all: $(grep check-runs "$T/log/gh" | head -1)"
reset; checks 11 '{"check_runs":[{"name":"Queue: embarked","status":"completed","conclusion":"cancelled"}]}'; run
[ "$(r .batch_failed)" = 1 ] && ok || bad "P5 cancelled: $(r '')"
reset; checks 11 '{"check_runs":[{"name":"Queue: embarked","status":"completed","conclusion":"success"}]}'; run
[ "$(r .batch_failed)" = 0 ] && ok || bad "P5 control success: $(r '')"
reset; checks 11 '{"check_runs":[{"name":"CI / test","status":"completed","conclusion":"failure"}]}'; run
[ "$(r .batch_failed)" = 0 ] && ok || bad "P5 control CI failure: $(r '')"
# both reverted and batch-failed counts once
reset; commits 'Revert "a (#11)"'; checks 11 '{"check_runs":[{"name":"Queue: embarked","conclusion":"failure"}]}'; run
[ "$(r .reverted)" = 1 ] && [ "$(r .batch_failed)" = 1 ] && [ "$(r .precision)" = 0.667 ] && ok || bad "P5 bad counted twice: $(r '')"

# ── P7: an unreadable PR list is an error, never a partial score; the cap flags ─
reset; : > "$T/pulls500"; run
[ "$RC" = 0 ] && r .error | grep -q 'pulls unreadable (HTTP 500)' && [ "$(r .precision)" = null ] && [ "$(alerts)" = 0 ] && ok || bad "P7 $(r '')"
[ ! -s "$T/log/worker" ] && ok || bad "P7 scored against a list it could not read"
reset
jq -nc --arg s "$IN" '[range(100; 200) | {number:., merged_at:$s, updated_at:$s, head:{sha:("d\(.)")}}]' > "$T/pulls1.json"
run LEAD_REVIEW_PRECISION_MAX_PAGES=1
[ "$(r .truncated)" = true ] && ok || bad "P7 MAX_PAGES=1 over a full page: truncated $(r .truncated)"
grep -q 'page=2' "$T/log/gh" && bad "P7 read past MAX_PAGES" || ok
# a readable page 1 and a failed page 2: the rows page 1 gave are not scored either
reset
jq -nc --arg s "$IN" '[range(100; 200) | {number:., merged_at:$s, updated_at:$s, head:{sha:("d\(.)")}}]' > "$T/pulls1.json"
setrows "$(vrow 1 100 lead MERGE d100)"; : > "$T/pulls500-p2"; run
r .error | grep -q 'pulls unreadable (HTTP 500)' && [ "$(r .lead_merge)" = 0 ] && [ "$(r '.prs')" = '[]' ] && ok || bad "P7 page-2 failure scored page 1: $(r '')"
# a full page 1 and a short page 2 is complete, not truncated
reset
jq -nc --arg s "$IN" '[range(100; 200) | {number:., merged_at:$s, updated_at:$s, head:{sha:("d\(.)")}}]' > "$T/pulls1.json"
cp "$T/pulls1.json" "$T/p1"; pulls 11; cp "$T/pulls1.json" "$T/pulls2.json"; cp "$T/p1" "$T/pulls1.json"
run
[ "$(r .truncated)" = false ] && [ "$(r .lead_merge)" = 1 ] && ok || bad "P7 two pages: $(r '')"

# ── no repo list = nothing scored, no file ───────────────────────────────────
reset; run LEAD_REVIEW_AUTO_REPOS=
[ "$RC" = 0 ] && [ "$(nfiles)" = 0 ] && grep -q 'LEAD_REVIEW_AUTO_REPOS is empty' "$H/logs/lead-review-precision.log" && ok || bad "empty repo list"

# ── Registry and cron ────────────────────────────────────────────────────────
REG=$(rendered_registry)
L() { jq -c --arg id lead-review-precision ".lanes[] | select(.id == \$id) | $1" "$REG" 2>/dev/null; }
K() { jq -c --arg id lead-review-precision --arg e "$1" ".lanes[] | select(.id == \$id) | .knobs[] | select(.env == \$e) | $2" "$REG" 2>/dev/null; }
[ "$(L .scope)" = '"hub"' ] && [ "$(L .cadence)" = '"40 5 * * *"' ] && [ "$(L .switch.name)" = '"lane-off-lead-review-precision"' ] && ok || bad "Registry lane: $(L '{scope,cadence,switch}')"
[ "$(L .script)" = '"bin/lead-review-precision.sh"' ] && ok || bad "Registry script: $(L .script)"
[ "$(K LEAD_REVIEW_PRECISION_WARN .type)" = '"float"' ] && [ "$(K LEAD_REVIEW_PRECISION_WARN .default)" = 0.9 ] && ok || bad "Registry WARN: $(K LEAD_REVIEW_PRECISION_WARN .)"
[ "$(K LEAD_REVIEW_PRECISION_WINDOW_DAYS .type)" = '"int"' ] && [ "$(K LEAD_REVIEW_PRECISION_WINDOW_DAYS .default)" = 30 ] && ok || bad "Registry WINDOW_DAYS: $(K LEAD_REVIEW_PRECISION_WINDOW_DAYS .)"
[ "$(K LEAD_REVIEW_PRECISION_MIN_N .default)" = 5 ] && [ "$(K LEAD_REVIEW_PRECISION_MAX_PAGES .default)" = 30 ] && ok || bad "Registry MIN_N/MAX_PAGES"
HUBCRON=$(rendered_cron hub)
grep -qxF '40 5 * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/lead-review-precision.sh >/dev/null 2>&1' "$HUBCRON" && ok || bad "Registry hub crontab has no lead-review-precision line"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check ) >/dev/null 2>&1 && ok || bad "Registry lanes-build.sh --check"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/render-cron.sh --check ) >/dev/null 2>&1 && ok || bad "Registry render-cron.sh --check"

echo "lead-review-precision.bh-3548: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
