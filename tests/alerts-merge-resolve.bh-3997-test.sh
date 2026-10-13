#!/bin/bash
# tests/alerts-merge-resolve.bh-3997-test.sh — BH-3997: pipeline-health's merge
# alerts close when their PRs merge, close or get queued.
#
# 2026-10-03: "harness PR(s) #3917,#3902,#3833 open >12h awaiting merge" and
# "#3928 … not in the merge queue" rows stayed open on the console for a day
# after every PR they named had merged. The open row's akey was a hash of the
# line text (so a shorter PR list minted a sibling row), and nothing that knew
# the PRs had settled ever touched those rows.
#
#   K1-K5  condition keys: bin/lib/alert-state.sh's builtin collapse rules key
#          the three families on family + repo (+ PR for the one-PR families),
#          and bin/alert-line.sh carries that key as the console akey
#   R1-R9  bin/alerts-merge-resolve.sh, PASS mode (one REST read per PR)
#   E1-E5  the event path: bin/lib/wake-class-pr-closed.sh hands closed and
#          queued-label PRs to the resolver, which asks GitHub nothing
#   G1     bin/alerts-groom.sh runs the resolver on every pass
# Run from anywhere: bash tests/alerts-merge-resolve.bh-3997-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

RESOLVER="$DIR/bin/alerts-merge-resolve.sh"
mkdir -p "$T/env" "$T/logs" "$T/locks" "$T/flags" "$T/state/alerts" "$T/stub" "$T/bin" "$T/pr" "$T/calls"
export HARNESS="$T" PATH="$T/stub:$PATH" FLEET_CONF="$T/fleet.conf" GH_ETAG=0 \
       ALERT_STATE_DIR="$T/state/alerts" ALERT_STATE_LOG="$T/logs/alerts-state.log" ALERTS_CONF="$T/flags/alerts.conf"
unset GH_TOKEN
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=s\nJOBS_URL=https://jobs.invalid\n' > "$T/env/global.env"
cat > "$FLEET_CONF" <<'CONF'
cromford example-org/cromford - - 0 hub 10.0.0.1
project-5     example-org/project-5     - - 5 box-ts 10.0.0.2
CONF
# curl: the console's open list, its resolve + beat routes, the worker's merge queue.
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""; url=""; body=""; w=0
for a in "\$@"; do
  case "\$prev" in -d|--data-binary) body="\$a" ;; esac
  [ "\$a" = "-w" ] && w=1
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
echo "\$url" >> "$T/curl.log"
case "\$url" in
  */api/alerts/open) cat "$T/open.json" ;;
  */api/alerts/resolve|*/api/beat) printf '%s\t%s\n' "\${url##*/api/}" "\$body" >> "$T/posts.tsv"
    if [ "\$w" = 1 ]; then printf '%s' "\$(cat "$T/post.code" 2>/dev/null || echo 200)"; else echo '{"ok":true}'; fi ;;
  */api/merge-queue*) [ -f "$T/mq.down" ] && exit 7; cat "$T/mq.json"; [ "\$w" = 1 ] && printf '\n200' ;;
  *) echo '{}' ;;
esac
STUB
# gh: the REST pull read (gh-rest.sh's `gh api -i -X GET repos/<slug>/pulls/<n>`).
cat > "$T/stub/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$T/gh.log"
n=\$(printf '%s' "\$*" | sed -nE 's#.*repos/[^/]+/[^/ ]+/pulls/([0-9]+).*#\1#p')
slug=\$(printf '%s' "\$*" | sed -nE 's#.*repos/([^/]+/[^/ ]+)/pulls/[0-9]+.*#\1#p')
f="$T/pr/\${slug//\//_}_\$n"
if [ -n "\$n" ] && [ -f "\$f.rl" ]; then printf 'HTTP/2 403\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1; fi
if [ -n "\$n" ] && [ -f "\$f.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "\$f.json"; exit 0; fi
printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1
STUB
chmod +x "$T/stub/curl" "$T/stub/gh"

# pr <slug> <n> merged|open|closed|ratelimit [labels-csv]
pr() {
  local f="$T/pr/${1//\//_}_$2"
  rm -f "$f.json" "$f.rl"
  case "$3" in
    ratelimit) : > "$f.rl"; return ;;
  esac
  jq -nc --arg s "$3" --argjson n "$2" --arg l "${4:-}" '{number:$n,
    state: (if $s == "open" then "open" else "closed" end),
    merged_at: (if $s == "merged" then "2026-10-03T12:00:00Z" else null end),
    labels: ($l | split(",") | map(select(length > 0)) | map({name:.}))}' > "$f.json"
}
reset() {
  rm -f "$T/posts.tsv" "$T/gh.log" "$T/curl.log" "$T/mq.down" "$T"/pr/*
  : > "$T/logs/alerts-groom.log"; rm -rf "$T/calls"; mkdir -p "$T/calls"
  echo '{"merge_queue":[]}' > "$T/mq.json"
}
posts()    { [ -f "$T/posts.tsv" ] && awk -F'\t' -v r="$1" '$1==r{print $2}' "$T/posts.tsv"; }
npost()    { posts "$1" | grep -c . ; }
open_rows() { printf '{"alerts":[%s]}' "$(IFS=,; echo "$*")" > "$T/open.json"; }
row() { jq -nc --argjson id "$1" --arg a "$2" --arg l "$3" '{id:$id, akey:$a, project:"cromford", line:$l}'; }

BH=example-org/cromford
AW_TAIL="built work aging into the next watchdog owed-tickets alert"
AW3="2026-10-03 12:13:00Z [pipeline-health] cromford: harness PR(s) #3917,#3902,#3833 open >12h awaiting merge — $AW_TAIL prs=$BH#3917,$BH#3902,$BH#3833"
AW1="2026-10-03 14:13:00Z [pipeline-health] cromford: harness PR(s) #3833 open >12h awaiting merge — $AW_TAIL prs=$BH#3833"
AWKEY="ph-awaitmerge-example-org-cromford"
LU="2026-10-03 12:13:00Z [pipeline-health] $BH #3928 has lead-verdict success on abcdef012345 for 45m and is not in the merge queue (labels: merge-queue); prs=$BH#3928; the conductor enqueues a lead-cleared head through mc_enqueue_mergify — check logs/merge-conductor.log for it: https://github.com/$BH/pull/3928"
AP="2026-10-03 12:13:00Z [pipeline-health] https://github.com/$BH/pull/3940 is APPROVE (record pool-cromford-BH-3930-202610030101), OPEN and CLEAN for 40m and not in the merge queue: prs=$BH#3940; no conductor row for this PR — the silent-skip shape; last merge-conductor.log line: none — the conductor logged no reason for this PR"

# ════════════════════════════════════════════════════════════════════════════
# K. condition keys
# ════════════════════════════════════════════════════════════════════════════
key() { ( . "$DIR/bin/lib/alert-state.sh"; alert_state_key "$1" ); }
K3=$(key "$AW3"); K1L=$(key "$AW1")
[ "$K3" = "$AWKEY" ] && [ "$K1L" = "$AWKEY" ] && ok \
  || bad "K1: the 3-PR and 1-PR awaitmerge lines must share key $AWKEY (got '$K3' / '$K1L')"
# … and the console akey bin/alert-line.sh sends is that same key, for both lines
mkdir -p "$T/al/bin/lib" "$T/al/logs"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/al/bin/"
cp "$DIR/bin/lib/alert-state.sh" "$T/al/bin/lib/"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/al/beats.jsonl"\n' "$T" > "$T/al/bin/beat.sh"
printf '#!/bin/bash\necho cromford\n' > "$T/al/bin/project-of.sh"
chmod +x "$T/al/bin/beat.sh" "$T/al/bin/project-of.sh"
HARNESS="$T/al" "$T/al/bin/alert-line.sh" "${AW3#* * }"
HARNESS="$T/al" "$T/al/bin/alert-line.sh" "${AW1#* * }"
AK=$(jq -r .akey "$T/al/beats.jsonl" 2>/dev/null | sort -u)
[ "$AK" = "alert:$AWKEY" ] && [ "$(grep -c . "$T/al/beats.jsonl")" = 2 ] && ok \
  || bad "K1: both alert-line.sh payloads must carry akey alert:$AWKEY (got: $AK)"
K2=$(key "${AW3//example-org\/cromford/example-org/project-5}")
[ "$K2" = "ph-awaitmerge-example-org-project-5" ] && ok || bad "K2: another repo must key apart (got '$K2')"
LU2=$(printf '%s' "$LU" | sed 's/(labels: merge-queue)/(labels: -)/; s/for 45m/for 90m/; s/abcdef012345/0123456789ab/')
KL1=$(key "$LU"); KL2=$(key "$LU2"); KL3=$(key "${LU//3928/3929}")
[ "$KL1" = "ph-leadunqueued-example-org-cromford-3928" ] && [ "$KL2" = "$KL1" ] && ok \
  || bad "K3: leadunqueued must key on repo + PR, not labels/age/head (got '$KL1' / '$KL2')"
[ "$KL3" = "ph-leadunqueued-example-org-cromford-3929" ] && ok || bad "K3: a different PR must key apart (got '$KL3')"
AP2=$(printf '%s' "$AP" | sed 's/for 40m/for 95m/; s/no conductor row for this PR — the silent-skip shape/conductor row READY since 1 (-)/')
KA1=$(key "$AP"); KA2=$(key "$AP2"); KA3=$(key "${AP//3940/3941}")
[ "$KA1" = "ph-approveunqueued-example-org-cromford-3940" ] && [ "$KA2" = "$KA1" ] && ok \
  || bad "K4: approveunqueued must key on repo + PR (got '$KA1' / '$KA2')"
[ "$KA3" = "ph-approveunqueued-example-org-cromford-3941" ] && ok || bad "K4: a different PR must key apart (got '$KA3')"
# K6 — the documented copy in env-templates/alerts.conf.example says the same thing
# as the shipped table (with the shipped table off, the conf alone keys alike).
kconf() { ( export ALERTS_CONF="$DIR/env-templates/alerts.conf.example" ALERT_BUILTIN_RULES=0
            . "$DIR/bin/lib/alert-state.sh"; alert_state_key "$1" ); }
[ "$(kconf "$AW3")" = "$AWKEY" ] && [ "$(kconf "$LU")" = "$KL1" ] && [ "$(kconf "$AP")" = "$KA1" ] && ok \
  || bad "K6: alerts.conf.example must document the same three keys (got '$(kconf "$AW3")' '$(kconf "$LU")' '$(kconf "$AP")')"
K5=$(key "${AW3% prs=*}")
case "$K5" in auto-*) ok ;; *) bad "K5: a legacy awaitmerge line with no prs= must keep its auto- key (got '$K5')" ;; esac

# ════════════════════════════════════════════════════════════════════════════
# R. PASS mode
# ════════════════════════════════════════════════════════════════════════════
state_file() { # state_file <id> — an open local state row for <id>
  jq -nc --argjson n "$NOW" '{first_seen:($n-3600), last_seen:$n, last_notified:$n, count:3, severity:"critical", resolved_at:0}' \
    > "$T/state/alerts/$1.json"
}
run() { "$RESOLVER" "$@" > "$T/run.out" 2>&1; echo $?; }

# R1 (AT1) — every PR merged: one resolve, the BH-3997 reason, local state closed.
reset; state_file "$AWKEY"
open_rows "$(row 18820 "alert:$AWKEY" "$AW3")"
pr $BH 3917 merged; pr $BH 3902 merged; pr $BH 3833 merged
RC=$(run)
[ "$RC" = 0 ] && ok || bad "R1: rc=$RC $(cat "$T/run.out")"
[ "$(npost alerts/resolve)" = 1 ] && [ "$(posts alerts/resolve | jq -c .ids)" = "[18820]" ] && ok \
  || bad "R1: want one resolve POST for [18820]: $(cat "$T/posts.tsv" 2>/dev/null)"
[ "$(posts alerts/resolve | jq -r .reason)" = "condition cleared: all PRs merged" ] && ok \
  || bad "R1: reason must be 'condition cleared: all PRs merged': $(posts alerts/resolve)"
[ "$(npost beat)" = 0 ] && ok || bad "R1: a full settle rewrites nothing: $(posts beat)"
RA=$(jq -r '.resolved_at // 0' "$T/state/alerts/$AWKEY.json" 2>/dev/null)
[ "${RA:-0}" -gt 0 ] && ok || bad "R1: state/alerts/$AWKEY.json must be resolved (resolved_at=$RA)"
grep -q "merge-resolve: resolve 18820 (condition cleared: all PRs merged)" "$T/logs/alerts-groom.log" && ok \
  || bad "R1: no resolve log line: $(cat "$T/logs/alerts-groom.log")"
grep -q "merge-resolve pass done: rows=1 resolved=1 rewritten=0 kept=0" "$T/logs/alerts-groom.log" && ok \
  || bad "R1: no summary line: $(cat "$T/logs/alerts-groom.log")"

# R2 (AT2) — two of three merged: no resolve, one in-place rewrite naming only #3833.
reset
open_rows "$(row 18820 "alert:$AWKEY" "$AW3")"
pr $BH 3917 merged; pr $BH 3902 merged; pr $BH 3833 open
run >/dev/null
[ "$(npost alerts/resolve)" = 0 ] && ok || bad "R2: a still-open PR must keep the row: $(posts alerts/resolve)"
[ "$(npost beat)" = 1 ] && ok || bad "R2: want exactly one rewrite: $(cat "$T/posts.tsv" 2>/dev/null)"
B=$(posts beat)
NL=$(jq -r .line <<<"$B" 2>/dev/null)
[ "$(jq -r .akey <<<"$B")" = "alert:$AWKEY" ] && [ "$(jq -r .kind <<<"$B")" = alert ] \
  && [ "$(jq -r 'has("alertstate")' <<<"$B")" = false ] && ok \
  || bad "R2: the rewrite must be kind:alert on the SAME akey with no alertstate (no ping): $B"
grep -q "harness PR(s) #3833 open" <<<"$NL" && grep -q "prs=$BH#3833\$" <<<"$NL" \
  && ! grep -q "3917\|3902" <<<"$NL" && ok || bad "R2: the rewritten line must name only #3833: $NL"
[ "$(cut -f2 "$T/posts.tsv" | jq -r '.akey // empty' | sort -u | grep -c .)" = 1 ] && ok \
  || bad "R2: still one row (one akey) across every POST"
grep -q "merge-resolve: rewrite 18820 remaining=$BH#3833" "$T/logs/alerts-groom.log" && ok \
  || bad "R2: no rewrite log line: $(cat "$T/logs/alerts-groom.log")"

# R3 (AT3) — not-in-queue alert whose PR now carries the queued label.
reset
open_rows "$(row 18875 "alert:ph-leadunqueued-example-org-cromford-3928" "$LU")"
pr $BH 3928 open merge-queue,queued
run >/dev/null
[ "$(posts alerts/resolve | jq -c .ids)" = "[18875]" ] \
  && [ "$(posts alerts/resolve | jq -r .reason)" = "condition cleared: PR enqueued (queued label)" ] && ok \
  || bad "R3: a queued label must resolve the not-in-queue row: $(cat "$T/posts.tsv" 2>/dev/null)"

# R4 — approveunqueued: open, no label, but the worker's merge_queue has it queued.
reset
open_rows "$(row 18874 "alert:ph-approveunqueued-example-org-cromford-3940" "$AP")"
pr $BH 3940 open
echo '{"merge_queue":[{"project":"cromford","pr":3940,"status":"queued","repo":null}]}' > "$T/mq.json"
run >/dev/null
[ "$(posts alerts/resolve | jq -c .ids)" = "[18874]" ] \
  && [ "$(posts alerts/resolve | jq -r .reason)" = "condition cleared: PR enqueued (merge_queue row)" ] && ok \
  || bad "R4: a merge_queue row must resolve the approve-unqueued row: $(cat "$T/posts.tsv" 2>/dev/null)"
# … and with the queue unreadable and no label, it stays (an outage is not a settle)
reset; touch "$T/mq.down"
open_rows "$(row 18874 "alert:ph-approveunqueued-example-org-cromford-3940" "$AP")"
pr $BH 3940 open
run >/dev/null
[ "$(npost alerts/resolve)" = 0 ] && ok || bad "R4: an unreadable merge queue must not settle: $(posts alerts/resolve)"

# R5 — fail-open: a rate-limited PR is never settled.
reset
open_rows "$(row 18820 "alert:$AWKEY" "${AW3/,$BH#3833/}")"
pr $BH 3917 merged; pr $BH 3902 ratelimit
run >/dev/null
[ "$(npost alerts/resolve)" = 0 ] && ok || bad "R5: an unknown PR must keep the row: $(posts alerts/resolve)"
NL=$(posts beat | jq -r .line)
grep -q "prs=$BH#3902\$" <<<"$NL" && ! grep -q 3917 <<<"$NL" && ok \
  || bad "R5: the rewrite drops only the merged ref, the unknown stays listed: $NL"
grep -q "unknown=$BH#3902" "$T/logs/alerts-groom.log" && ok || bad "R5: the unknown ref must be logged: $(cat "$T/logs/alerts-groom.log")"
reset
open_rows "$(row 18821 "alert:$AWKEY" "${AW3/,$BH#3902,$BH#3833/}")"
pr $BH 3917 ratelimit
run >/dev/null
[ ! -s "$T/posts.tsv" ] && ok || bad "R5: a row whose only PR is unknown posts nothing: $(cat "$T/posts.tsv")"
grep -q "merge-resolve: keep 18821 unknown=$BH#3917" "$T/logs/alerts-groom.log" && ok \
  || bad "R5: want a keep line: $(cat "$T/logs/alerts-groom.log")"

# R6 — scope: a queued label does not settle an awaiting-merge row.
reset
open_rows "$(row 18822 "alert:$AWKEY" "$AW1")"
pr $BH 3833 open merge-queue,queued
run >/dev/null
[ "$(npost alerts/resolve)" = 0 ] && [ "$(npost beat)" = 0 ] && ok \
  || bad "R6: a queued PR is still awaiting merge: $(cat "$T/posts.tsv" 2>/dev/null)"

# R7 — legacy row: no prs= token, refs from the prose + fleet.conf, state id from the akey.
reset; state_file auto-6950e029cdef-ce73ee54
LEG="2026-10-02 08:00:00Z [pipeline-health] cromford: harness PR(s) #3917,#3902 open >12h awaiting merge — $AW_TAIL (still firing, n=4)"
open_rows "$(row 18708 "alert:auto-6950e029cdef-ce73ee54" "$LEG")"
pr $BH 3917 merged; pr $BH 3902 merged
run >/dev/null
[ "$(posts alerts/resolve | jq -c .ids)" = "[18708]" ] && ok || bad "R7: a legacy row must settle: $(cat "$T/posts.tsv" 2>/dev/null)"
grep -q "repos/$BH/pulls/3917" "$T/gh.log" && ok || bad "R7: the repo must come from fleet.conf: $(cat "$T/gh.log" 2>/dev/null)"
RA=$(jq -r '.resolved_at // 0' "$T/state/alerts/auto-6950e029cdef-ce73ee54.json" 2>/dev/null)
[ "${RA:-0}" -gt 0 ] && ok || bad "R7: the local state id is the akey minus alert: (resolved_at=$RA)"

# R8 — memo: two rows naming one PR cost one read.
reset
open_rows "$(row 18820 "alert:$AWKEY" "$AW1")" "$(row 18823 "alert:auto-x-y" "${AW1% prs=*}")"
pr $BH 3833 merged
run >/dev/null
[ "$(grep -c "pulls/3833" "$T/gh.log")" = 1 ] && ok || bad "R8: one read per PR per pass: $(cat "$T/gh.log")"
[ "$(posts alerts/resolve | jq -c '.ids|sort')" = "[18820,18823]" ] && ok || bad "R8: both rows settle in one POST: $(posts alerts/resolve)"

# R9 — rows outside the three families are untouched and cost nothing.
reset
open_rows "$(row 1 "alert:pipeline-health-resolved-stalepr_cromford" "2026-10-03 12:00:00Z [pipeline-health] RESOLVED stalepr:cromford — cleared")" \
          "$(row 2 "mq-hb-lander:cromford:12" "Merge queue: #12 rebase CONFLICTS with main: https://github.com/$BH/pull/12")" \
          "$(row 3 "alert:auto-a-b" "[jobs-watchdog] SILENT job: cromford BH-1")"
run >/dev/null
[ ! -s "$T/gh.log" ] && [ ! -s "$T/posts.tsv" ] && ok || bad "R9: unrelated rows must cost nothing: gh=$(cat "$T/gh.log" 2>/dev/null) posts=$(cat "$T/posts.tsv" 2>/dev/null)"
grep -q "merge-resolve pass done: rows=0 " "$T/logs/alerts-groom.log" && ok || bad "R9: zero-row summary missing: $(cat "$T/logs/alerts-groom.log")"

# R10 — --dry plans but posts nothing.
reset
open_rows "$(row 18820 "alert:$AWKEY" "$AW1")"
pr $BH 3833 merged
run --dry >/dev/null
[ ! -s "$T/posts.tsv" ] && grep -q "resolve 18820" "$T/run.out" && ok || bad "R10: --dry must print and not post: $(cat "$T/run.out") posts=$(cat "$T/posts.tsv" 2>/dev/null)"

# R11 — a console that refuses the resolve: nothing is recorded as resolved.
reset; state_file "$AWKEY"; echo 500 > "$T/post.code"
open_rows "$(row 18820 "alert:$AWKEY" "$AW1")"
pr $BH 3833 merged
run >/dev/null
rm -f "$T/post.code"
RA=$(jq -r '.resolved_at // 0' "$T/state/alerts/$AWKEY.json" 2>/dev/null)
[ "${RA:-1}" = 0 ] && ok || bad "R11: a failed resolve POST must leave the local state open (resolved_at=$RA)"
grep -q "resolve POST failed" "$T/logs/alerts-groom.log" && grep -q "resolved=0 rewritten=0 kept=1" "$T/logs/alerts-groom.log" && ok \
  || bad "R11: a failed POST is kept and logged, never counted resolved: $(cat "$T/logs/alerts-groom.log")"

# ════════════════════════════════════════════════════════════════════════════
# E. EVENT mode, driven through the wake class
# ════════════════════════════════════════════════════════════════════════════
# pipeline-health is BH-4055's sections run, launched last on the same rows.
for s in reconcile-prs check-migration-prs alerts-groom alerts-resolve-closed-prs pipeline-health; do
  printf '#!/bin/bash\necho "$*" >> "%s/calls/%s"\n' "$T" "$s" > "$T/bin/$s.sh"
done
printf '#!/bin/bash\nexec "%s" "$@"\n' "$RESOLVER" > "$T/bin/alerts-merge-resolve.sh"
chmod +x "$T"/bin/*.sh
# wake <row args>... ; then one dispatch. launch() runs the lane synchronously.
drain() {
  ( SELF="$T/bin"
    cooled() { return 0; }
    launch() { shift; echo "$*" >> "$T/calls/launches"; "$@"; }
    say() { :; }
    # shellcheck source=bin/lib/wake-class-pr-closed.sh
    . "$DIR/bin/lib/wake-class-pr-closed.sh" || exit 1
    local r
    for r in "$@"; do
      # shellcheck disable=SC2086
      wc_pr_closed_row cromford pr ${r%%:*} "${r#*:}" "$BH" 1
    done
    echo "closed_flag=$WC_PR_CLOSED" > "$T/calls/flag"
    wc_pr_closed_dispatch
    wc_pr_closed_dispatch
  )
}

# E1 (AT4) — all three PRs closed by webhook: resolved in the drain, no GitHub read.
reset
open_rows "$(row 18820 "alert:$AWKEY" "$AW3")"
drain "3917:pull_request.closed" "3902:pull_request.closed" "3833:pull_request.closed"
[ "$(posts alerts/resolve | jq -c .ids)" = "[18820]" ] \
  && [ "$(posts alerts/resolve | jq -r .reason)" = "condition cleared: PR closed (webhook)" ] && ok \
  || bad "E1: a closed webhook must resolve the row in the drain: $(cat "$T/posts.tsv" 2>/dev/null)"
[ ! -s "$T/gh.log" ] && ok || bad "E1: the webhook is the evidence — no GitHub call: $(cat "$T/gh.log")"
grep -q "alerts-merge-resolve.sh --closed $BH#3917 $BH#3902 $BH#3833\$" "$T/calls/launches" && ok \
  || bad "E1: one launch with every closed ref: $(cat "$T/calls/launches")"
grep -q "merge-resolve event done" "$T/logs/alerts-groom.log" && ok || bad "E1: no event summary: $(cat "$T/logs/alerts-groom.log")"

# E2 — only one PR closed: the row is rewritten, not resolved.
reset
open_rows "$(row 18820 "alert:$AWKEY" "$AW3")"
drain "3917:pull_request.closed"
NL=$(posts beat | jq -r .line)
[ "$(npost alerts/resolve)" = 0 ] && grep -q "harness PR(s) #3902,#3833 open" <<<"$NL" \
  && grep -q "prs=$BH#3902,$BH#3833\$" <<<"$NL" && ok || bad "E2: want a rewrite listing #3902,#3833: $(cat "$T/posts.tsv" 2>/dev/null)"

# E3 — a queued label: the not-in-queue row resolves, and no closed-PR lane launches.
reset
open_rows "$(row 18875 "alert:ph-leadunqueued-example-org-cromford-3928" "$LU")"
drain "3928:pull_request.labeled"
[ "$(posts alerts/resolve | jq -c .ids)" = "[18875]" ] \
  && [ "$(posts alerts/resolve | jq -r .reason)" = "condition cleared: PR enqueued (queued label, webhook)" ] && ok \
  || bad "E3: a queued-label wake must resolve the row: $(cat "$T/posts.tsv" 2>/dev/null)"
grep -qx "closed_flag=0" "$T/calls/flag" && ok || bad "E3: a label is not a closure (WC_PR_CLOSED must stay 0): $(cat "$T/calls/flag")"
grep -qE '^(reconcile-prs|check-migration-prs|alerts-groom|alerts-resolve-closed-prs)$' <<<"$(ls "$T/calls")" \
  && bad "E3: a label must launch no closed-PR lane: $(ls "$T/calls")" || ok
grep -q "alerts-merge-resolve.sh --queued $BH#3928\$" "$T/calls/launches" && ok || bad "E3: launch carries --queued: $(cat "$T/calls/launches")"

# E4 — a queued label on an awaiting-merge PR settles nothing.
reset
open_rows "$(row 18822 "alert:$AWKEY" "$AW1")"
drain "3833:pull_request.labeled"
[ ! -s "$T/posts.tsv" ] && ok || bad "E4: a queued awaitmerge PR is still awaiting merge: $(cat "$T/posts.tsv")"

# E5 — the second dispatch in every drain above launched nothing.
reset
open_rows "$(row 18822 "alert:$AWKEY" "$AW1")"
drain "3833:pull_request.closed" "3928:pull_request.labeled"
L=$(grep -c . "$T/calls/launches")
grep -q "alerts-merge-resolve.sh --closed $BH#3833 --queued $BH#3928\$" "$T/calls/launches" && ok \
  || bad "E5: one launch carrying both lists: $(cat "$T/calls/launches")"
# TEST-CHANGE (BH-4055): 5 -> 6. The drain also launches pipeline-health's PR
# sections run (--sections stalepr,leadunqueued), last; the second dispatch
# still launches nothing.
[ "$L" = 6 ] && ok || bad "E5: one drain = 3 lanes + 2 resolvers + the pipeline-health sections run, and the second dispatch launches nothing (got $L): $(cat "$T/calls/launches")"

# ════════════════════════════════════════════════════════════════════════════
# G. the groomer runs the pass
# ════════════════════════════════════════════════════════════════════════════
GR=$(awk '/^# >>> merge alerts resolve \(BH-3997\)/{f=1;next} /^# <<< merge alerts resolve/{exit} f' "$DIR/bin/alerts-groom.sh")
grep -q 'bin/alerts-merge-resolve.sh' <<<"$GR" && ok || bad "G1: bin/alerts-groom.sh must run bin/alerts-merge-resolve.sh in its marked block"
reset
open_rows "$(row 18820 "alert:$AWKEY" "$AW1")"
pr $BH 3833 merged
( eval "LOG=$T/logs/alerts-groom.log; $GR" )
[ "$(posts alerts/resolve | jq -c .ids)" = "[18820]" ] && ok || bad "G1: the groomer's block must settle the row: $(cat "$T/posts.tsv" 2>/dev/null)"

echo "alerts-merge-resolve.bh-3997: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
