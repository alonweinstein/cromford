#!/bin/bash
# tests/blocked-resolver-plan-excerpt.bh-3971-test.sh — a rebuild that ends
# PLAN_BLOCKED tells the ticket the QUESTION the plan stopped on (BH-3971).
#
# THE DEFECT THIS PINS. br_ticket_comment said "The detail is in <path>", and
# that path is a file on the build machine. For project-3 TK-166 it was
# /root/harness/builds/project-3-TK-166-…/plan.md on a box that had since been
# reaped, so the client was pointed at a file nobody can open and never saw the
# question. BH-531 already keeps the blocked plan in the jobs ledger
# (job_transcripts, source plan_md); the comment never read it back.
#
# Driven, not grepped: br_abandon_rebuild, br_ticket_comment, br_blocked_excerpt
# and br_html_esc are lifted out of bin/blocked-resolver.sh exactly as written
# (the fn_body awk of tests/comment-mark.bh-2317-test.sh) and run against the
# real bin/lib/comment-mark.sh and the real bin/transcript-scrub.sh. The issue
# comment and the board POST are recorded; every assertion is on what was sent.
# Run from anywhere: tests/blocked-resolver-plan-excerpt.bh-3971-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

fn_body() {
  awk -v P="$2() {" '
    !f && substr($0, 1, length(P)) == P && /\}[[:space:]]*$/ { print; exit }
    substr($0, 1, length(P)) == P    { f=1 }
    f                                { print }
    f && /^\}$/                      { exit }' "$1"
}
RES_SH="$DIR/bin/blocked-resolver.sh"
: > "$T/fns.sh"
for fn in br_html_esc br_blocked_excerpt br_ticket_comment br_abandon_rebuild; do
  fn_body "$RES_SH" "$fn" >> "$T/fns.sh"
done
CMSRC=$(grep -m1 -E '^[^#]*lib/comment-mark\.sh' "$RES_SH")
[ -n "$CMSRC" ] && ok || bad "bin/blocked-resolver.sh must source bin/lib/comment-mark.sh"

# The jobs DB on disk, as in comment-mark.bh-2317 (rc 0 row, rc 2 none).
DB="$T/db"; export DB
cat > "$T/jobs-stub.sh" <<'JS'
_db() { printf '%s/%s--%s' "$DB" "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' _)"; }
job_ledger_row() { [ -f "$(_db "$1" "$2")" ] || return 2; cat "$(_db "$1" "$2")"; }
job_ledger_get() { local r; r=$(job_ledger_row "$@") || return $?; printf '%s' "$r" | jq -r .status; }
job_ledger_put() { local f; f=$(_db "$1" "$2"); mkdir -p "$DB"; jq -nc --arg s "$3" '{status:$s}' > "$f"; }
# BH-531's copy of the blocked plan: job_for_record maps the build dir to a job,
# job_transcript_get_source hands back the plan_md body. $LEDGER_PLAN absent =
# the ledger has no such record.
job_for_record() { printf '%s %s\n' "$1" "$2" >> "$CASE/jfr.log"; [ -s "${LEDGER_PLAN:-/nonexistent}" ] || return 1; echo job-7; }
job_transcript_get_source() { [ "$1" = job-7 ] && [ "$2" = plan_md ] || return 1; cat "$LEDGER_PLAN"; }
JS

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env-empty" "$T/fakebin"
cp "$DIR/bin/transcript-scrub.sh" "$H/bin/"; cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/comment-mark.sh" "$H/bin/lib/"
chmod +x "$H/bin/transcript-scrub.sh"
printf '#!/bin/bash\necho tok-123\n' > "$H/bin/internal-token-for.sh"; chmod +x "$H/bin/internal-token-for.sh"
# The board POST: -d is recorded, and the board answers a created comment.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -d) printf '%s\n' "$2" >> "$CASE/board.log"; shift 2 ;; *) shift ;; esac; done
echo '{"comment":{"id":1}}'
SH
chmod +x "$T/fakebin/curl"

cat > "$T/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; ST="$H/state/blocked-resolver"; OBSERVE=0
say() { :; }
br_cap_key() { printf '%s' "$2"; }
br_load() { jq -nc --arg r "$RESULT" '{rebuild_result:$r}'; }
br_rebuild_artifact() { printf '%s' "$ART"; }
br_abandon() { return 0; }
br_ticket_id() { echo 42; }
br_comment_refused() { printf 'refused %s\n' "$5" >> "$CASE/refused.log"; }
br_issue_comment() { printf '%s' "$3" > "$CASE/issue.$(ls "$CASE" | grep -c '^issue\.')"; return 0; }
. "$JSTUB"
eval "$CMSRC"
. "$FNS"
br_abandon_rebuild "$PROJ" "$PROJ-TK-9" rebuild-stopped https://github.com/o/tproj/pull/9 "$REC" TK-9
DRIVE

newcase() { CASE="$T/case-$1"; mkdir -p "$CASE"; scratch_rm "$DB" 2>/dev/null; scratch_rm "$H/state" 2>/dev/null; }
lane() { # lane issues|board
  if [ "$1" = issues ]; then
    printf '#!/bin/bash\ncase "$2" in board_prefix) echo "-" ;; repo) echo o/tproj ;; *) exit 1 ;; esac\n' > "$H/bin/fleet-conf.sh"
  else
    printf '#!/bin/bash\ncase "$2" in board_prefix) echo /api/board ;; repo) echo o/tproj ;; prod) echo https://app.example ;; *) exit 1 ;; esac\n' > "$H/bin/fleet-conf.sh"
  fi
  chmod +x "$H/bin/fleet-conf.sh"
}
# drive <outcome> <rec> <art> [ledger-plan-file]
drive() {
  local oc="$1"
  CASE="$CASE" HARNESS="$H" HARNESS_ENV_DIR="$H/env-empty" PATH="$T/fakebin:$PATH" DB="$DB" \
    JSTUB="$T/jobs-stub.sh" CMSRC="$CMSRC" FNS="$T/fns.sh" PROJ=tproj \
    RESULT="$oc see $3" REC="$2" ART="$3" LEDGER_PLAN="${4:-}" \
    bash "$T/drive.sh" >/dev/null 2>"$CASE/err"
}
issue_body() { cat "$CASE/issue.0" 2>/dev/null; }
posts() { ls "$CASE" | grep -c '^issue\.'; }

# A parked plan as the planner writes it: the marker, the question, then 50
# lines of reasoning. The question sits at the top by the marker rule.
mkplan() {
  { echo "BLOCKED-NEEDS-CLARIFICATION"
    echo "1. Which fee field does the rep edit?"
    echo "2. Should the toggle stay for admins?"
    for i in $(seq 1 50); do echo "reasoning line $i"; done; } > "$1"
}

# ════════════════════════════════════════════════════════════════════════════
# P1 (THE DEFECT). Issues lane, PLAN_BLOCKED, the plan on this box.
# ════════════════════════════════════════════════════════════════════════════
newcase p1; lane issues
REC="$T/builds/tproj-TK-9-202610030001"; mkdir -p "$REC"; mkplan "$REC/plan.md"
drive PLAN_BLOCKED "$REC" "/root/harness/builds/tproj-TK-9-202610030001/plan.md"
B=$(issue_body)
[ "$(posts)" = 1 ] && ok || bad "P1 exactly one post, got $(posts): $(cat "$CASE/err")"
grep -qF 'The question the plan stopped on:' <<<"$B" && ok || bad "P1 the body must introduce the plan's question: $B"
grep -qxF '> 1. Which fee field does the rep edit?' <<<"$B" && ok || bad "P1 the question must be quoted: $B"
QN=$(grep -c '^>' <<<"$B")
[ "$QN" -ge 1 ] && [ "$QN" -le 40 ] && ok || bad "P1 at most 40 quoted lines, got $QN"
grep -qF 'reasoning line 50' <<<"$B" && bad "P1 a plan past 40 lines is cut: $B" || ok
grep -q 'BLOCKED-NEEDS-CLARIFICATION' <<<"$B" && bad "P1 the bare parked marker line is not quoted: $B" || ok
grep -qF 'The detail is in /root/harness/builds' <<<"$B" && bad "P1 the comment must not point the client at a machine-local path: $B" || ok
grep -qF 'the rebuild stopped at PLAN_BLOCKED' <<<"$B" && ok || bad "P1 the existing opening sentence stays: $B"

# ════════════════════════════════════════════════════════════════════════════
# P2. Board lane: the excerpt goes in a blockquote, every byte escaped.
# ════════════════════════════════════════════════════════════════════════════
newcase p2; lane board
REC="$T/builds/p2"; mkdir -p "$REC"
printf 'BLOCKED\nWhich of <b>&x is right?\nsecond "line"\n' > "$REC/plan.md"
drive PLAN_BLOCKED "$REC" "/root/harness/builds/p2/plan.md"
PB=$(jq -r '.body' < "$CASE/board.log" 2>/dev/null)
[ "$(grep -c . "$CASE/board.log" 2>/dev/null)" = 1 ] && ok || bad "P2 exactly one board POST: $(cat "$CASE/board.log" 2>/dev/null) $(cat "$CASE/refused.log" 2>/dev/null)"
grep -qF '<blockquote>' <<<"$PB" && ok || bad "P2 the board body must hold a blockquote: $PB"
grep -qF 'Which of &lt;b&gt;&amp;x is right?' <<<"$PB" && ok || bad "P2 plan text must be HTML-escaped: $PB"
grep -qF '<b>&x' <<<"$PB" && bad "P2 raw plan HTML must never reach the board: $PB" || ok
grep -qF '<br>second &quot;line&quot;' <<<"$PB" && ok || bad "P2 one <br> per plan line: $PB"

# ════════════════════════════════════════════════════════════════════════════
# P3. The reaped box (TK-166): no record dir, the artifact path is gone, the
# jobs ledger still holds the plan (BH-531) -> the comment quotes it.
# ════════════════════════════════════════════════════════════════════════════
newcase p3; lane issues
mkplan "$T/ledger-plan.md"
drive PLAN_BLOCKED "" "/root/harness/builds/project-3-TK-166-202609191002/plan.md" "$T/ledger-plan.md"
B=$(issue_body)
grep -qxF '> 1. Which fee field does the rep edit?' <<<"$B" && ok || bad "P3 the ledger's copy of the plan must be quoted: $B"
grep -qF 'tproj project-3-TK-166-202609191002' "$CASE/jfr.log" 2>/dev/null \
  && ok || bad "P3 the ledger lookup is keyed by the build dir the artifact names: $(cat "$CASE/jfr.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# P4. Nothing to read anywhere -> an honest sentence, no dead path, one post.
# ════════════════════════════════════════════════════════════════════════════
newcase p4; lane issues
drive PLAN_BLOCKED "" "/root/harness/builds/gone-202609191002/plan.md"
B=$(issue_body)
[ "$(posts)" = 1 ] && ok || bad "P4 exactly one post: $(posts)"
grep -qF 'could not read the plan back' <<<"$B" && ok || bad "P4 the body must say the plan could not be read back: $B"
grep -qF '/root/harness' <<<"$B" && bad "P4 the body must name no machine path: $B" || ok
grep -q '^>' <<<"$B" && bad "P4 nothing is quoted: $B" || ok

# ════════════════════════════════════════════════════════════════════════════
# P5. The excerpt is scrubbed, and fails CLOSED without the scrubber.
# ════════════════════════════════════════════════════════════════════════════
TOKEN="ghp_$(printf 'a1B2c3D4e5F6g7H8i9J0%.0s' 1 2)"
newcase p5; lane issues
REC="$T/builds/p5"; mkdir -p "$REC"
printf 'BLOCKED\nThe deploy used %s, which key should the build use?\n' "$TOKEN" > "$REC/plan.md"
drive PLAN_BLOCKED "$REC" "/root/harness/builds/p5/plan.md"
B=$(issue_body)
grep -qF "$TOKEN" <<<"$B" && bad "P5 a token in the plan must never reach the ticket: $B" || ok
grep -qF 'REDACTED' <<<"$B" && ok || bad "P5 the scrubber's redaction is what is quoted: $B"
newcase p5b; lane issues
mv "$H/bin/transcript-scrub.sh" "$T/scrub.away"
drive PLAN_BLOCKED "$REC" "/root/harness/builds/p5/plan.md"
mv "$T/scrub.away" "$H/bin/transcript-scrub.sh"
B=$(issue_body)
grep -q '^>' <<<"$B" && bad "P5 with no scrubber nothing is quoted (fail closed): $B" || ok
grep -qF 'which key' <<<"$B" && bad "P5 with no scrubber no plan text leaks: $B" || ok
grep -qF 'could not read the plan back' <<<"$B" && ok || bad "P5 with no scrubber the honest sentence goes out: $B"

# ════════════════════════════════════════════════════════════════════════════
# P6. Every other outcome is byte-identical to before; the once-ever rule holds.
# ════════════════════════════════════════════════════════════════════════════
newcase p6; lane issues
REC="$T/builds/p6"; mkdir -p "$REC"; mkplan "$REC/plan.md"
drive REVIEW_BLOCKED "$REC" "/root/harness/builds/p6/review.md"
WANT="We rebuilt this ticket fresh after the first PR could not be landed, and the rebuild stopped at REVIEW_BLOCKED: the review read the diff and refused it. The detail is in /root/harness/builds/p6/review.md. The parked PR https://github.com/o/tproj/pull/9 is closed and this ticket has no build in flight now."
[ "$(issue_body)" = "$WANT" ] && ok || bad "P6 a REVIEW_BLOCKED body must be unchanged: $(issue_body)"
newcase p6b; lane issues
drive PLAN_BLOCKED "$REC" "/root/harness/builds/p6/plan.md"
drive PLAN_BLOCKED "$REC" "/root/harness/builds/p6/plan.md"
[ "$(posts)" = 1 ] && ok || bad "P6 a second PLAN_BLOCKED call must not post again: $(posts)"

# Marker-strip negative: a first line that only CONTAINS the word is content.
newcase p7; lane issues
REC="$T/builds/p7"; mkdir -p "$REC"
printf '# Plan: unblock the BLOCKED_HUMAN lane\nWhich lane first?\n' > "$REC/plan.md"
drive PLAN_BLOCKED "$REC" "/root/harness/builds/p7/plan.md"
grep -qxF '> # Plan: unblock the BLOCKED_HUMAN lane' <<<"$(issue_body)" \
  && ok || bad "P7 a title that merely contains BLOCKED_HUMAN is not the marker: $(issue_body)"

# P8. The 3000-byte cap cuts on a line end: 30 lines of 200 bytes each.
newcase p8; lane issues
REC="$T/builds/p8"; mkdir -p "$REC"
{ echo BLOCKED; for i in $(seq 10 39); do printf 'q%s %s\n' "$i" "$(printf 'x%.0s' $(seq 1 196))"; done; } > "$REC/plan.md"
drive PLAN_BLOCKED "$REC" "/root/harness/builds/p8/plan.md"
Q=$(grep '^> ' <<<"$(issue_body)" | sed 's/^> //')
[ "$(printf '%s' "$Q" | LC_ALL=C wc -c)" -le 3000 ] && ok || bad "P8 the quote is capped at 3000 bytes: $(printf '%s' "$Q" | wc -c)"
[ "$(grep -c . <<<"$Q")" -ge 10 ] && ok || bad "P8 the cap keeps the lines that fit: $(grep -c . <<<"$Q")"
grep -vqE '^q[0-9]{2} x{196}$' <<<"$Q" && bad "P8 every quoted line is whole: $(grep -vE '^q[0-9]{2} x{196}$' <<<"$Q" | head -2)" || ok

echo "blocked-resolver-plan-excerpt (BH-3971): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
