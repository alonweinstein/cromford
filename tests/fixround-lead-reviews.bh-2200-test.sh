#!/bin/bash
# tests/fixround-lead-reviews.bh-2200-test.sh — BH-2200: a fix round reads the
# LEAD's (or a human's) REQUEST_CHANGES, and a round that answers none of it is
# never pushed as a silent main merge.
#
# THE INCIDENT (2026-09-24). br_findings / br_review_newest only accepted a
# review carrying the review lane's footer from a harness verdict author. The
# lead's REQUEST_CHANGES (operator, no footer, the findings ARE the body) was
# invisible, so the fix rounds on #2045, #2051 and #2065 pushed main merges and
# nothing else, and #2158 was merged over the lead's unfixed BLOCK.
#
# THE ACCEPTANCE ROWS (red first):
#   L1  a footer-less operator CR (MEMBER) at the head -> br_review_newest and
#       br_findings carry "LEAD FINDINGS — every item must be addressed in code"
#       and its body
#   L2  trust: CONTRIBUTOR+write counts, CONTRIBUTOR+read / NONE / no association
#       / a Bot do not; an unreadable permission read is rc 2
#   L3  standing: a later APPROVED or a DISMISSED lifts it
#   L4  an older head followed only by main merges counts; a real commit does not
#   L5  a harness footer CR (verdict author) still works exactly as before
#   L6  an unreadable reviews list: br_lead_review rc 2, br_findings rc 75
#   F1  the fix-round prompt carries the lead body under the LEAD header
#   F2  a round that only merges main -> nothing pushed, `fix-round-noop`
#   F3  a round that touches a file the findings name -> pushed
#   F4  a round that lists what it could not address -> comment posted, pushed
#   F5  a head that ended fix-round-noop is not run again; it goes to its terminal
#
# The functions under test are the real ones, lifted out of bin/blocked-resolver.sh
# by name; GitHub is a fake `gh` that answers REST shapes and applies --jq itself.
# Run from anywhere: tests/fixround-lead-reviews.bh-2200-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

BR="$DIR/bin/blocked-resolver.sh"
SLUG=o/tproj
URL="https://github.com/$SLUG/pull/7"
HEAD1=1111111111111111111111111111111111111111   # the PR head the lead reviewed
HEAD2=2222222222222222222222222222222222222222   # the head after a main merge
NEWHEAD=3333333333333333333333333333333333333333 # what the fix round commits
LEAD_HDR='LEAD FINDINGS — every item must be addressed in code'
LBODY='1. bin/lib/widget.sh:42 still builds the SQL by hand — bind it.
2. tests/widget-test.sh never covers the empty list.'
FOOTER='_Automated harness review (Fable) of '
HBODY_FOOTER="1. HIGH src/rate.ts:12 the route is unauthenticated.

TIER: 2
VERDICT: REQUEST_CHANGES

---
${FOOTER}${HEAD1}. Static review — no build run._"

mkdir -p "$T/fakebin" "$T/gh"
# A SCRATCH HARNESS, before anything sources bin/lib/gh-rest.sh: its ETag cache
# (gh-rest-etag.sh) reads and deletes under $HARNESS/state/gh-etag, and the
# default is /root/harness. Every child shell below inherits this.
export HARNESS="$T/h"
mkdir -p "$HARNESS/state/gh-etag" "$HARNESS/logs"

# --- the fake GitHub ----------------------------------------------------------
#   $T/gh/reviews.json            pulls/7/reviews (--paginate, --jq applied)
#   $T/gh/reviews-fail            that read fails
#   $T/gh/perm-<login>.json       collaborators/<login>/permission
#   $T/gh/perm-fail               that read fails
#   $T/gh/compare-<a>-<b>.json    compare/<a>...<b>
#   $T/gh/pr.json                 pulls/7
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
JQX=""; PREV=""
for A in "\$@"; do case "\$PREV" in --jq|-q) JQX="\$A" ;; esac; PREV="\$A"; done
emit() { if [ -n "\$JQX" ]; then jq -r "\$JQX" "\$1"; else cat "\$1"; fi; }
# The REST contract (bin/lib/gh-rest.sh) reads under -i: a status line, a blank
# line, the body. Every decision read in this suite arrives that way.
send() { printf 'HTTP/1.1 %s\r\ncontent-type: application/json\r\n\r\n' "\$1"; [ -n "\${2:-}" ] && cat "\$2"; printf '\n'; }
case "\$*" in
  *"-i -X GET"*"/pulls/7/reviews"*)
    [ -f "$T/gh/reviews-fail" ] && { printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1; }
    send "200 OK" "$T/gh/reviews.json" ;;
  *"-i -X GET"*"/collaborators/"*"/permission"*)
    [ -f "$T/gh/perm-fail" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{}\n'; exit 1; }
    L=\$(printf '%s' "\$*" | sed -nE 's#.*/collaborators/([^/]+)/permission.*#\1#p')
    [ -f "$T/gh/perm-\$L.json" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
    send "200 OK" "$T/gh/perm-\$L.json" ;;
  *"-i -X GET"*"/compare/"*)
    [ -f "$T/gh/compare-fail" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{}\n'; exit 1; }
    C=\$(printf '%s' "\$*" | sed -nE 's#.*/compare/([^ ?]+).*#\1#p' | sed 's#\.\.\.#-#')
    [ -f "$T/gh/compare-\$C.json" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
    send "200 OK" "$T/gh/compare-\$C.json" ;;
  *"-i -X GET"*"/issues/7/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"/pulls/7"*) emit "$T/gh/pr.json" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

REV() { # REV <id> <state> <commit> <login> <association> <type> <body> — appended, oldest first
  jq -nc --argjson i "$1" --arg s "$2" --arg c "$3" --arg l "$4" --arg a "$5" --arg ty "$6" --arg b "$7" \
    '{id:$i, state:$s, commit_id:$c, user:{login:$l, type:$ty}, author_association:$a, body:$b}' >> "$T/gh/revrows"
  jq -s . "$T/gh/revrows" > "$T/gh/reviews.json"
}
RESET() { scratch_rm "$T/gh"; mkdir -p "$T/gh"; : > "$T/gh/revrows"; echo '[]' > "$T/gh/reviews.json"; : > "$T/gh.log"
          jq -nc --arg h "$HEAD1" '{number:7, head:{sha:$h, ref:"ticket/TK-7"}, base:{ref:"main"}}' > "$T/gh/pr.json"; }
PERM() { jq -nc --arg p "$2" '{permission:$p, role_name:$p}' > "$T/gh/perm-$1.json"; }
COMPARE() { # COMPARE <base> <head> <status> <json-array-of-{sha,parents:n}>
  jq -nc --arg s "$3" --argjson c "$4" '{status:$s, commits:[$c[] | {sha:.sha, parents:[range(.parents) | {sha:"p"}]}]}' > "$T/gh/compare-$1-$2.json"
}

# --- the functions under test, lifted by name ------------------------------------
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BR"; }
{
  grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$BR"
  for fn in br_review_rows br_review_harness_pick br_review_harness_newest br_lead_merges_only br_lead_pick \
            br_lead_review br_review_newest br_findings br_findings_join; do lift "$fn"; done
} > "$T/lib.sh"
cat > "$T/stubs.sh" <<EOF
say() { printf '%s\n' "\$*" >> "$T/say.log"; }
harness_verdict_author_match() { case "\${1:-}" in operator|cromford|cromford\[bot\]|app/cromford) return 0 ;; esac; return 1; }
harness_verdict_authors_json() { echo '["operator","cromford[bot]","cromford"]'; }
br_slug_of_url() { printf '%s' "$SLUG"; }
mc_num_of_url() { printf '%s' "\$1" | sed -nE 's#.*/pull/([0-9]+).*#\1#p'; }
EOF
# The REAL REST contract: every review / permission / compare read goes through it.
printf '. "%s/bin/lib/gh-rest.sh"\n' "$DIR" >> "$T/stubs.sh"
L() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$T/stubs.sh" "$T/lib.sh" "$@"; }
dec() { base64 -d 2>/dev/null; }

# ============================================================================
# L1 — a footer-less operator CHANGES_REQUESTED at the head is the brief
# ============================================================================
RESET
REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"
OUT=$(L br_review_newest "$SLUG" 7 "$HEAD1"); RC=$?
[ "$RC" = 0 ] && ok || bad "L1 br_review_newest must find the lead's CR (rc $RC)"
B=$(printf '%s' "$OUT" | dec)
grep -qF "$LEAD_HDR" <<<"$B" && ok || bad "L1 the lead review must be framed '$LEAD_HDR': $B"
grep -qF 'bin/lib/widget.sh:42 still builds the SQL by hand' <<<"$B" && ok || bad "L1 the lead review's body must be the findings: $B"
F=$(L br_findings "$URL" review-changes-requested "$HEAD1"); RC=$?
[ "$RC" = 0 ] && ok || bad "L1 br_findings rc must be 0 (got $RC)"
grep -qF "$LEAD_HDR" <<<"$F" && grep -qF 'tests/widget-test.sh never covers the empty list' <<<"$F" \
  && ok || bad "L1 br_findings (review park) must carry the LEAD header and the body: $F"
# ...and on a conductor park too: br_findings reads the lead CR for EVERY reason.
F=$(L br_findings "$URL" head-not-reapproved "$HEAD1"); RC=$?
[ "$RC" = 0 ] && grep -qF "$LEAD_HDR" <<<"$F" && grep -qF 'bin/lib/widget.sh:42' <<<"$F" \
  && ok || bad "L1 br_findings (head-not-reapproved) must carry the lead findings too (rc $RC): $F"

# ============================================================================
# L2 — who is a lead: write access, never a bot
# ============================================================================
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" someone CONTRIBUTOR User "$LBODY"; PERM someone write
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "L2 a CONTRIBUTOR with write permission is a lead reviewer (rc $RC)"
grep -q 'collaborators/someone/permission' "$T/gh.log" && ok || bad "L2 a CONTRIBUTOR's permission must be READ, not assumed: $(cat "$T/gh.log")"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" someone CONTRIBUTOR User "$LBODY"; PERM someone read
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L2 a CONTRIBUTOR with read permission is not a lead reviewer (rc $RC)"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" someone CONTRIBUTOR User "$LBODY"; touch "$T/gh/perm-fail"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "L2 an unreadable permission read is UNREADABLE, never 'no lead' (rc $RC)"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" drive-by NONE User "$LBODY"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L2 a NONE-association reviewer is not a lead reviewer (rc $RC)"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator "" User "$LBODY"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L2 a review with no author association proves no write access (rc $RC)"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" 'some-app[bot]' MEMBER Bot "$LBODY"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L2 a bot's CR is never a lead review (rc $RC)"

# ============================================================================
# L3 — only a STANDING changes-requested counts
# ============================================================================
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"; REV 12 APPROVED "$HEAD1" operator MEMBER User "LGTM"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L3 a later APPROVED by the same reviewer lifts the CR (rc $RC)"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"; REV 12 COMMENTED "$HEAD1" operator MEMBER User "one more thought"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "L3 a later COMMENT does not lift the CR (rc $RC)"
RESET; REV 11 DISMISSED "$HEAD1" operator MEMBER User "$LBODY"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L3 a DISMISSED review is not standing (rc $RC)"

# ============================================================================
# L4 — an older head counts only when every later branch commit is a merge
# ============================================================================
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"
COMPARE "$HEAD1" "$HEAD2" ahead '[{"sha":"m1","parents":1},{"sha":"mergeA","parents":2}]'
COMPARE main "$HEAD2" ahead '[{"sha":"own1","parents":1},{"sha":"mergeA","parents":2}]'
OUT=$(L br_lead_review "$SLUG" 7 "$HEAD2"); RC=$?
[ "$RC" = 0 ] && ok || bad "L4 a CR on an older head followed only by a main merge still stands (rc $RC; gh: $(tail -3 "$T/gh.log"))"
printf '%s' "$OUT" | dec | grep -qF 'bin/lib/widget.sh:42' && ok || bad "L4 the older-head CR's body is the findings"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"
COMPARE "$HEAD1" "$HEAD2" ahead '[{"sha":"fix1","parents":1},{"sha":"mergeA","parents":2}]'
COMPARE main "$HEAD2" ahead '[{"sha":"own1","parents":1},{"sha":"fix1","parents":1},{"sha":"mergeA","parents":2}]'
L br_lead_review "$SLUG" 7 "$HEAD2" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L4 a CR followed by a real commit is for the lead to look at again, not a fix round (rc $RC)"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"; touch "$T/gh/compare-fail"
L br_lead_review "$SLUG" 7 "$HEAD2" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "L4 an unreadable compare (502) is UNREADABLE (rc $RC)"
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"
L br_lead_review "$SLUG" 7 "$HEAD2" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L4 an old head GitHub no longer knows (404, history rewritten) is not 'followed only by merges' (rc $RC)"

# ============================================================================
# L5 — the review lane's own footer CR works exactly as before
# ============================================================================
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" 'cromford[bot]' NONE Bot "$HBODY_FOOTER"
OUT=$(L br_review_newest "$SLUG" 7 "$HEAD1"); RC=$?
B=$(printf '%s' "$OUT" | dec)
[ "$RC" = 0 ] && [ "$B" = "$HBODY_FOOTER" ] && ok || bad "L5 a harness footer CR must come back byte for byte (rc $RC): $B"
grep -qF "$LEAD_HDR" <<<"$B" && bad "L5 a harness review must not be framed as LEAD findings" || ok
F=$(L br_findings "$URL" review-changes-requested "$HEAD1")
[ "$F" = "$HBODY_FOOTER" ] && ok || bad "L5 br_findings on a harness-only review is unchanged: $F"
# operator's OWN footer review is the lane's, not a lead review (no double brief).
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$HBODY_FOOTER"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L5 a footer review is the lane's own, never a lead review (rc $RC)"
# Both standing: the lead block leads, the lane's findings follow.
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" 'cromford[bot]' NONE Bot "$HBODY_FOOTER"; REV 12 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "$LBODY"
F=$(L br_findings "$URL" review-changes-requested "$HEAD1")
{ grep -qF "$LEAD_HDR" <<<"$F" && grep -qF 'src/rate.ts:12' <<<"$F"; } && ok || bad "L5 with both standing, br_findings carries the lead's AND the lane's findings: $F"
[ "$(grep -n "$LEAD_HDR" <<<"$F" | head -1 | cut -d: -f1)" -lt "$(grep -n 'src/rate.ts:12' <<<"$F" | head -1 | cut -d: -f1)" ] \
  && ok || bad "L5 the lead's findings come first"

# ============================================================================
# L6 — an unreadable reviews list is never "no findings"
# ============================================================================
RESET; touch "$T/gh/reviews-fail"
L br_lead_review "$SLUG" 7 "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "L6 br_lead_review on an unreadable list must be rc 2 (got $RC)"
L br_findings "$URL" head-not-reapproved "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 75 ] && ok || bad "L6 br_findings must answer 75 (retry, nothing spent) when the lead read fails (got $RC)"

# ============================================================================
# F — br_fix_round end to end up to the push (git, agent and bookkeeping stubbed;
# br_findings / br_review_newest / br_lead_review are the real ones).
# ============================================================================
H="$T/h"; ST="$T/st"; REPOS="$T/repos"
mkdir -p "$H/bin" "$ST/tproj" "$REPOS/tproj/.git"
printf '#!/bin/bash\n[ "$2" = repo ] && echo %s\nexit 0\n' "$SLUG" > "$H/bin/fleet-conf.sh"
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.txt"
printf 'agent %s\n' "\$1" >> "$T/agent.log"
[ -n "\${AGENT_UNADDR:-}" ] && printf '%s\n' "\$AGENT_UNADDR" > "$ST/tproj/ck.unaddressed.md"
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.log"
EOF
chmod +x "$H/bin/"*.sh
lift br_fix_round > "$T/fixround.sh"
[ -s "$T/fixround.sh" ] && ok || bad "F0 br_fix_round could not be lifted"
cat > "$T/fr-stubs.sh" <<EOF
OBSERVE=0; H="$H"; ST="$ST"; LOG="$T/br.log"; REPOS="$REPOS"; FIX_AGENT_TIMEOUT=60; BR_EXECUTE_MODEL_ENV=BR_EXECUTE_MODEL
LEASE=$HEAD1
STAMP() { printf '2026-09-24 00:00:00Z'; }
br_event() { printf '%s\n' "\$*" >> "$T/events.log"; }
br_file() { printf '%s' "$T/rec.json"; }
br_load() { cat "$T/rec.json" 2>/dev/null || echo '{}'; }
br_push_field() { local c; c=\$(br_load | jq -c --arg k "\$3" --arg v "\$4" '.[\$k] = (((.[\$k] // []) + [\$v]) | unique)') && printf '%s\n' "\$c" > "$T/rec.json"; }
br_has_field_value() { printf '%s' "\${1:-}" | jq -e --arg k "\$2" --arg v "\$3" '((.[\$k] // []) | index(\$v)) != null' >/dev/null 2>&1; }
br_json_edit() { :; }
br_cap_key() { printf ck; }
br_num() { printf 0; }
br_fix_cap() { printf 2; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { printf 'terminal %s\n' "\$3" >> "$T/terminal.log"; }
br_pr_ref() { printf '%s ticket/TK-7 %s\n' "$SLUG" "$HEAD1"; }
br_sup_seen() { :; }; br_use_token() { :; }; br_setup_blocked() { printf 'setup %s\n' "\$6" >> "$T/terminal.log"; }
br_ladder_class() { case "\$1" in head-not-reapproved) echo review-blocked ;; *) echo "" ;; esac; }
br_conflict_note() { :; }; br_note_conflict_lines() { :; }; mc_conflict_lines() { :; }
br_model() { printf 'model-under-test'; }
br_round_begin() { :; }; br_yield_take() { return 1; }; br_count() { :; }
br_record() { printf 'record %s\n' "\$*" >> "$T/record.log"; }
br_wt_drop() { :; }; mc_git_auth() { :; }; mc_git_auth_clear() { :; }
br_pr_comment() { printf 'comment %s\n' "\$2" >> "$T/comments.log"; }
br_fix_push_note() { :; }
gi_check() { return 0; }
br_rebuild_fresh() { printf 'rebuild %s\n' "\$3" >> "$T/terminal.log"; }
# BH-2504: the push goes through bin/lib/hold-push.sh (sourced in FR below). This
# suite is about the findings, not the hold, so its park has no GitHub issue
# behind it (rc 1 = a board ticket): the push is the lease alone.
br_hold_issue() { return 1; }
git() {
  local a=("\$@"); [ "\${a[0]}" = -C ] && a=("\${a[@]:2}")
  printf 'git %s\n' "\${a[*]}" >> "$T/git.log"
  case "\${a[*]}" in
    "remote get-url origin") echo /srv/clone ;;
    "rev-parse --verify -q origin/main") echo mainsha ;;
    "rev-parse --verify -q origin/"*) echo "\$LEASE" ;;
    "rev-parse --verify -q brfix/"*) return 1 ;;
    "worktree add"*) mkdir -p "\${a[3]}" ;;
    "rev-parse HEAD"|"rev-parse --short HEAD") echo "$NEWHEAD" ;;
    "log --no-merges --name-only --format= HEAD --not"*) cat "$T/own-files" 2>/dev/null ;;
    "ls-files") cat "$T/ls-files" 2>/dev/null ;;
    "push "*) printf '%s\n' "\${a[*]}" >> "$T/push.log" ;;
    *) return 0 ;;
  esac
}
EOF
FR() { # FR <reason> — the real br_fix_round in a fresh shell
  rm -f "$T/prompt.txt" "$T/agent.log" "$T/git.log" "$T/terminal.log" "$T/record.log" "$T/push.log" \
        "$T/comments.log" "$T/alerts.log" "$T/events.log" "$ST/tproj/ck.unaddressed.md"
  bash -c '. "$7/bin/lib/hold-push.sh"; . "$1"; . "$2"; . "$3"; . "$4"; br_fix_round tproj rk "$5" "$6" /rec TK-7' _ \
    "$T/stubs.sh" "$T/lib.sh" "$T/fr-stubs.sh" "$T/fixround.sh" "$1" "$URL" "$DIR" >/dev/null 2>&1
}
LEADPR() { RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "${1:-$LBODY}"; rm -f "$T/rec.json"; }
# The files the repo tracks (`git ls-files`): a finding names a file only when it is one of these.
printf '%s\n' bin/lib/widget.sh tests/widget-test.sh README.md catalog/lanes.d/x.conf catalog/lanes.d/y.conf src/app.ts > "$T/ls-files"

# F1 + F2 — the lead's body is the brief; a round that only merged main is a noop
LEADPR; : > "$T/own-files"
FR head-not-reapproved
[ -s "$T/agent.log" ] && ok || bad "F1 the fix round must run on a lead's findings (terminal: $(cat "$T/terminal.log" 2>/dev/null); say: $(tail -3 "$T/say.log" 2>/dev/null))"
P=$(cat "$T/prompt.txt" 2>/dev/null)
grep -qF "$LEAD_HDR" <<<"$P" && ok || bad "F1 the prompt must carry the LEAD header"
grep -qF 'bin/lib/widget.sh:42 still builds the SQL by hand' <<<"$P" && ok || bad "F1 the prompt must carry the lead review's body"
grep -qF 'end your final message with a line reading exactly `UNADDRESSED:`' <<<"$P" && ok || bad "F1 the prompt must ask for an UNADDRESSED: section for findings the round cannot address (BH-2276)"
[ ! -s "$T/push.log" ] && ok || bad "F2 a round that only merged main must NOT be pushed: $(cat "$T/push.log")"
grep -q 'fix-round-noop' "$T/record.log" 2>/dev/null && ok || bad "F2 the attempt must be recorded fix-round-noop: $(cat "$T/record.log" 2>/dev/null)"
grep -q 'resolver_fix_noop' "$T/events.log" 2>/dev/null && ok || bad "F2 a resolver_fix_noop event must be emitted: $(cat "$T/events.log" 2>/dev/null)"
# TEST-CHANGE BH-4140 the noop used to lane-alert "a person must act or push"; nothing pages a person now (BH-4149)
[ ! -s "$T/alerts.log" ] && ok || bad "F2 a noop pages nobody: $(cat "$T/alerts.log" 2>/dev/null)"
jq -e --arg h "$HEAD1" '(.noop_heads // []) | index($h) != null' "$T/rec.json" >/dev/null 2>&1 && ok || bad "F2 the head must be remembered in noop_heads: $(cat "$T/rec.json" 2>/dev/null)"
# TEST-CHANGE BH-4140 the noop used to park the head for a person; its round is spent, so it goes to br_fix_terminal once (BH-4149)
[ "$(grep -c . "$T/terminal.log" 2>/dev/null || true)" = 1 ] && grep -qx 'terminal head-not-reapproved' "$T/terminal.log" && ok \
  || bad "F2 a noop goes to br_fix_terminal exactly once: $(cat "$T/terminal.log" 2>/dev/null)"

# F5 — the same head is not run again, and costs no GitHub read on the next tick
: > "$T/gh.log"
FR head-not-reapproved
[ ! -s "$T/agent.log" ] && ok || bad "F5 a head that ended fix-round-noop must not buy another round"
grep -E '/reviews|/compare/|/permission' "$T/gh.log" >/dev/null 2>&1 \
  && bad "F5 a noop-frozen head must make ZERO review/compare/permission reads on the next tick: $(cat "$T/gh.log")" || ok
# TEST-CHANGE BH-4140 a frozen head used to return silently until a person pushed; it goes to br_fix_terminal now (BH-4149)
[ "$(grep -c . "$T/terminal.log" 2>/dev/null || true)" = 1 ] && ok || bad "F5 a frozen head goes to br_fix_terminal exactly once: $(cat "$T/terminal.log" 2>/dev/null)"
grep -q 'fix-round-noop already stands' "$T/say.log" 2>/dev/null && ok || bad "F5 the gate must say why it did not run: $(tail -2 "$T/say.log" 2>/dev/null)"

# F3 — a round that touched a file the findings name is pushed
LEADPR; printf 'bin/lib/widget.sh\n' > "$T/own-files"
FR head-not-reapproved
[ -s "$T/push.log" ] && ok || bad "F3 a round that changed a named file must be pushed (record: $(cat "$T/record.log" 2>/dev/null))"
grep -q 'fix-round-noop' "$T/record.log" 2>/dev/null && bad "F3 a real fix is not a noop" || ok
# ...and a file NOT named in the findings does not count
LEADPR; printf 'README.md\n' > "$T/own-files"
FR head-not-reapproved
[ ! -s "$T/push.log" ] && ok || bad "F3 a round that only changed an unnamed file must not be pushed"

# F4 — a round that says what it could not address posts it, then pushes
LEADPR; : > "$T/own-files"
AGENT_UNADDR='- 1. bin/lib/widget.sh:42 — the SQL builder is generated; the generator is out of this repo' FR head-not-reapproved
grep -q 'the SQL builder is generated' "$T/comments.log" 2>/dev/null && ok || bad "F4 the unaddressed findings must be posted on the PR: $(cat "$T/comments.log" 2>/dev/null)"
[ -s "$T/push.log" ] && ok || bad "F4 a round that named what it could not address is pushed"
grep -q 'fix-round-noop' "$T/record.log" 2>/dev/null && bad "F4 a named-unaddressed round is not a noop" || ok

# F7 — words that merely LOOK like paths (e.g, Node.js, a PR URL) are not files:
# with no real file named, any change of the round's own counts.
LEADPR '1. The retry loop is wrong, e.g. it never backs off — see how Node.js does it, and https://github.com/example-org/cromford/pull/2045.'
printf 'src/app.ts\n' > "$T/own-files"
FR head-not-reapproved
[ -s "$T/push.log" ] && ok || bad "F7 a body naming no real file (e.g, Node.js, a URL) must let a real change push: $(cat "$T/record.log" 2>/dev/null)"
grep -q 'fix-round-noop' "$T/record.log" 2>/dev/null && bad "F7 a false noop: the path-looking words were read as files" || ok

# F8 — a DIRECTORY named in the findings is answered by a change under it
LEADPR '1. The lane registry in catalog/lanes.d is missing the new knob.'
printf 'catalog/lanes.d/x.conf\n' > "$T/own-files"
FR head-not-reapproved
[ -s "$T/push.log" ] && ok || bad "F8 a change under a named directory must push: $(cat "$T/record.log" 2>/dev/null)"
# ...and a change elsewhere does not answer it
LEADPR '1. The lane registry in catalog/lanes.d is missing the new knob.'
printf 'README.md\n' > "$T/own-files"
FR head-not-reapproved
[ ! -s "$T/push.log" ] && ok || bad "F8 a change outside the named directory must not push"

# A round with NO lead findings behaves exactly as before: a harness footer review
# with no file change is still pushed (the noop gate is for lead-blocked rounds only).
RESET; REV 11 CHANGES_REQUESTED "$HEAD1" 'cromford[bot]' NONE Bot "$HBODY_FOOTER"; rm -f "$T/rec.json"; : > "$T/own-files"
FR review-changes-requested
[ -s "$T/push.log" ] && ok || bad "F6 a round with no lead findings is gated exactly as before (pushed): $(cat "$T/record.log" 2>/dev/null)"

echo "fixround-lead-reviews.bh-2200: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
