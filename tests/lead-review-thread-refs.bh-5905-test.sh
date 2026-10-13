#!/bin/bash
# tests/lead-review-thread-refs.bh-5905-test.sh — BH-5905: the lead review
# reads the ticket thread of a partial build. A partial build (BH-5798) says
# `Refs #<n>` on line 2, not `Closes #<n>`. Before this ticket the lead review
# looked only for Closes, so a partial build was reviewed with no ticket thread.
#
#   T1  `Refs #77` and no Closes line: issue #77 and its comments are read and
#       the `## Ticket thread` section carries them
#   T2  `Closes #77` and `Refs #9`: the Closes number wins, #9 is never read
#   T3  `**Refs** #77` (bold markdown) at line start: read
#   T4  `see Refs #77` in prose (not at line start): no read, the prompt says
#       "(no Closes #<n> line in the PR body)"
#   T5  `Refs other-org/other#77`: another repo's ticket, no read
#
# The ticket is #77 and the PR is #41. They differ on purpose: since #5889
# (BH-5801) every review also reads the PR's own comments (lp_evidence reads
# issues/41/comments), so a ticket numbered like the PR could not tell a ticket
# read from that read. reads() lists the ticket reads only (not issues/41).
#
# Drives the REAL bin/lead-review.sh tick, with the rig of
# tests/lead-review-rules-pack.bh-3546-test.sh (stub curl, gh, agent-call and
# rules pack).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-thread-refs.bh-5905-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure of bin/jobs-client.sh"
scratch_install_closure bin/box-for.sh "$H" >/dev/null || bad "closure of bin/box-for.sh"
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || bad "closure of bin/fleet-conf.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$H/fleet.conf"

o="$T/origin.git"; w="$T/work"
git init -q --bare -b main "$o"; git init -q -b main "$w"
printf '# bh\n' > "$w/CLAUDE.md"; echo one > "$w/a.txt"
git -C "$w" add -A; git -C "$w" -c user.email=t@example.invalid -c user.name=t commit -qm base
git -C "$w" push -q "$o" main
echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@example.invalid -c user.name=t commit -qam "pr change"
git -C "$w" push -q "$o" "HEAD:refs/pull/41/head"
git clone -q "$o" "$T/repos/cromford"
SHA=$(git -C "$w" rev-parse HEAD)

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    if [ "\$(cat "$T/jobstate" 2>/dev/null)" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
# gh answers any issue number: issues/<n> and issues/<n>/comments, logged.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/gh"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$SHA" --rawfile b "$T/prbody" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:\$b}' ;;
  *"-X GET repos/"*"/issues/"*"/comments"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc '[{user:{login:"client"},created_at:"2026-09-29T11:00:00Z",body:"thread-comment-body"}]' ;;
  *"-X GET repos/"*"/issues/"*)
    n=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --argjson n "\$n" '{number:\$n,title:"The ask",body:"spec text"}' ;;
esac
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
case "\$6" in @/*) cat "\${6#@}" ;; *) printf '%s' "\$6" ;; esac > "$T/log/prompt"
printf 'Findings\n- [NOTE] a.txt:2: fine\n\nVERDICT: MERGE-WITH-NOTES\n' > "\$5"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/bin/rules-pack.sh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh" "$H/bin/rules-pack.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_THREAD_MAX_BYTES=60000
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW
jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:41,head_sha:$s,scope_notes:"x",prior_verdict_ref:"v",status:"requested"}],truncated:false}' \
  > "$T/requests.json"

# drive <pr body> — one tick; the prompt lands in $T/log/prompt, gh argv in $T/log/gh
drive() {
  rm -f "$T/log"/* "$T/jobstate"; scratch_rm "$H/state/lead-reviews"
  printf '%s\n' "$1" > "$T/prbody"
  ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
}
thread() { awk '$0 == "## Ticket thread" {f=1; next} $0 == "## Scope notes" {f=0} f' "$T/log/prompt" 2>/dev/null; }
reads() { grep -oE 'issues/[0-9]+(/comments)?' "$T/log/gh" 2>/dev/null | grep -vE '^issues/41(/|$)' | sort -u | paste -sd' '; }
NOCLOSE='(no Closes #<n> line in the PR body)'

# ── T1: Refs #77, no Closes ──
drive $'PR body text.\nRefs #77'
[ "$RC" -eq 0 ] && [ -s "$T/log/prompt" ] && ok || bad "T1 tick rc=$RC, prompt missing: $(tail -5 "$T/out")"
[ "$(reads)" = "issues/77 issues/77/comments" ] && ok || bad "T1 gh reads '$(reads)', want issues/77 and its comments"
th=$(thread)
grep -q '^#77 The ask' <<<"$th" && grep -q 'spec text' <<<"$th" && grep -q 'thread-comment-body' <<<"$th" \
  && ok || bad "T1 the ## Ticket thread section lacks #77: $th"
grep -qF "$NOCLOSE" "$T/log/prompt" 2>/dev/null && bad "T1 the prompt still says there is no Closes line" || ok

# ── T2: Closes wins over Refs ──
drive $'Closes #77\nRefs #9'
[ "$(reads)" = "issues/77 issues/77/comments" ] && ok || bad "T2 gh reads '$(reads)', want #77 only"

# ── T3: bold markdown Refs ──
drive $'Summary.\n**Refs** #77'
[ "$(reads)" = "issues/77 issues/77/comments" ] && ok || bad "T3 gh reads '$(reads)' for '**Refs** #77'"

# ── T4: Refs in prose is not a link line ──
drive 'This change is related; see Refs #77 in prose.'
[ -z "$(reads)" ] && ok || bad "T4 prose Refs was read: $(reads)"
grep -qF "$NOCLOSE" "$T/log/prompt" 2>/dev/null && ok || bad "T4 the prompt lacks '$NOCLOSE'"

# ── T5: another repo's Refs is not this ticket ──
drive 'Refs other-org/other#77'
[ -z "$(reads)" ] && ok || bad "T5 a foreign Refs was read: $(reads)"
drive 'Refs example-org/Cromford#77'
[ "$(reads)" = "issues/77 issues/77/comments" ] && ok || bad "T5 this repo named in full was not read: '$(reads)'"

echo "lead-review-thread-refs.bh-5905: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
