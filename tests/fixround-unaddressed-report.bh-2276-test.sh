#!/bin/bash
# tests/fixround-unaddressed-report.bh-2276-test.sh — BH-2276: a lead-blocked fix
# round escapes fix-round-noop by listing what it could not address, and that
# list must not depend on the agent writing outside its worktree.
#
# THE DEFECT. BH-2200's prompt told the agent to write the list to
# $ST/<project>/<ck>.unaddressed.md, outside the worktree. A runner confined to
# its workspace (gemini -y, or any future sandbox) cannot write there, so an
# honest round that could not address a finding ended fix-round-noop instead of
# reporting. The list now travels in the agent's final report (the harness, not
# the agent, writes that to $ST/<project>/<ck>.fix-run.txt) under a line reading
# exactly `UNADDRESSED:`, and br_fix_round copies its `- ` items itself.
#
# THE FAKE AGENT IS SANDBOXED: any path it is asked to write that resolves
# outside its cwd (the worktree) is refused and logged `DENIED <path>`. It writes
# its final report to $5 the way bin/agent-call.sh does.
#
#   U1  the lead-blocked prompt asks for an `UNADDRESSED:` section and names no $ST path
#   U2  sandboxed round, report ends with a real list -> posted, pushed, not noop
#   U3  `UNADDRESSED: none` (with or without bullets under it) -> noop, nothing pushed, nothing posted
#   U4  a bare header followed only by prose -> noop
#   U5  the instruction quoted mid-text, no header line of its own -> noop
#   U6  two headers: only the LAST list is posted
#
# BR=<path> runs the suite against another copy of bin/blocked-resolver.sh (the
# merge base, to see it red). Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

BR="${BR:-$DIR/bin/blocked-resolver.sh}"
SLUG=o/tproj
URL="https://github.com/$SLUG/pull/7"
HEAD1=1111111111111111111111111111111111111111
NEWHEAD=3333333333333333333333333333333333333333
LBODY='1. bin/lib/widget.sh:42 still builds the SQL by hand — bind it.
2. tests/widget-test.sh never covers the empty list.'

mkdir -p "$T/fakebin" "$T/gh"
export HARNESS="$T/h"
mkdir -p "$HARNESS/state/gh-etag" "$HARNESS/logs"

# --- the fake GitHub (the REST shapes bin/lib/gh-rest.sh reads under -i) -------
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
JQX=""; PREV=""
for A in "\$@"; do case "\$PREV" in --jq|-q) JQX="\$A" ;; esac; PREV="\$A"; done
emit() { if [ -n "\$JQX" ]; then jq -r "\$JQX" "\$1"; else cat "\$1"; fi; }
send() { printf 'HTTP/1.1 %s\r\ncontent-type: application/json\r\n\r\n' "\$1"; [ -n "\${2:-}" ] && cat "\$2"; printf '\n'; }
case "\$*" in
  *"-i -X GET"*"/pulls/7/reviews"*) send "200 OK" "$T/gh/reviews.json" ;;
  *"-i -X GET"*"/issues/7/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"-i -X GET"*) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
  *"/pulls/7"*) emit "$T/gh/pr.json" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
jq -nc --arg h "$HEAD1" '{number:7, head:{sha:$h, ref:"ticket/TK-7"}, base:{ref:"main"}}' > "$T/gh/pr.json"
# The lead's standing CHANGES_REQUESTED at the head: the round is lead-blocked.
jq -nc --arg c "$HEAD1" --arg b "$LBODY" \
  '[{id:11, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"operator", type:"User"}, author_association:"MEMBER", body:$b}]' > "$T/gh/reviews.json"

# --- the functions under test, lifted by name -----------------------------------
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BR"; }
{
  grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$BR"
  for fn in br_review_rows br_review_harness_pick br_review_harness_newest br_lead_merges_only br_lead_pick \
            br_lead_review br_review_newest br_findings br_findings_join br_fix_round; do lift "$fn"; done
} > "$T/lib.sh"
grep -q '^br_fix_round() {' "$T/lib.sh" && ok || bad "U0 br_fix_round could not be lifted from $BR"

H="$T/h"; ST="$T/st"; REPOS="$T/repos"
mkdir -p "$H/bin" "$ST/tproj" "$REPOS/tproj/.git"
printf '#!/bin/bash\n[ "$2" = repo ] && echo %s\nexit 0\n' "$SLUG" > "$H/bin/fleet-conf.sh"
# THE SANDBOXED AGENT. Its args are the real agent-call.sh contract:
# execute <project> <model> <timeout> <out> <prompt>. It obeys a prompt that
# names an .unaddressed.md file by trying to write it, and the sandbox refuses
# any path outside its cwd. Then it writes its final message ($AGENT_REPORT) to $5.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.txt"
printf 'agent %s cwd %s\n' "\$1" "\$PWD" >> "$T/agent.log"
root=\$(pwd -P)
sandbox_write() { # sandbox_write <path> <text>
  local d; d=\$(cd "\$(dirname "\$1")" 2>/dev/null && pwd -P) || d=/nonexistent
  case "\$d/" in
    "\$root"/*) printf '%s\n' "\$2" > "\$1"; printf 'WROTE %s\n' "\$1" >> "$T/sandbox.log" ;;
    *) printf 'DENIED %s\n' "\$1" >> "$T/sandbox.log"; return 1 ;;
  esac
}
if [ -n "\${AGENT_UNADDR:-}" ]; then
  for f in \$(printf '%s' "\$6" | grep -oE '[^[:space:]\`]*\.unaddressed\.md'); do sandbox_write "\$f" "\$AGENT_UNADDR"; done
fi
printf '%s\n' "\${AGENT_REPORT:-done}" > "\$5"
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.log"
EOF
chmod +x "$H/bin/"*.sh

cat > "$T/stubs.sh" <<EOF
say() { printf '%s\n' "\$*" >> "$T/say.log"; }
harness_verdict_author_match() { case "\${1:-}" in operator|cromford|cromford\[bot\]|app/cromford) return 0 ;; esac; return 1; }
harness_verdict_authors_json() { echo '["operator","cromford[bot]","cromford"]'; }
br_slug_of_url() { printf '%s' "$SLUG"; }
mc_num_of_url() { printf '%s' "\$1" | sed -nE 's#.*/pull/([0-9]+).*#\1#p'; }
OBSERVE=0; H="$H"; ST="$ST"; LOG="$T/br.log"; REPOS="$REPOS"; FIX_AGENT_TIMEOUT=60; BR_EXECUTE_MODEL_ENV=BR_EXECUTE_MODEL
STAMP() { printf '2026-09-26 00:00:00Z'; }
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
br_hold_issue() { return 1; }
git() {
  local a=("\$@"); [ "\${a[0]}" = -C ] && a=("\${a[@]:2}")
  case "\${a[*]}" in
    "remote get-url origin") echo /srv/clone ;;
    "rev-parse --verify -q origin/main") echo mainsha ;;
    "rev-parse --verify -q origin/"*) echo "$HEAD1" ;;
    "rev-parse --verify -q brfix/"*) return 1 ;;
    "worktree add"*) mkdir -p "\${a[3]}" ;;
    "rev-parse HEAD"|"rev-parse --short HEAD") echo "$NEWHEAD" ;;
    "log --no-merges --name-only --format= HEAD --not"*) : ;;
    "ls-files") printf '%s\n' bin/lib/widget.sh tests/widget-test.sh README.md ;;
    "push "*) printf '%s\n' "\${a[*]}" >> "$T/push.log" ;;
    *) return 0 ;;
  esac
}
EOF
printf '. "%s/bin/lib/gh-rest.sh"\n' "$DIR" >> "$T/stubs.sh"

FR() { # FR — the real br_fix_round on a lead-blocked park; the round changes no file
  rm -f "$T/prompt.txt" "$T/agent.log" "$T/record.log" "$T/push.log" "$T/comments.log" \
        "$T/alerts.log" "$T/events.log" "$T/sandbox.log" "$T/rec.json" "$ST/tproj/ck.unaddressed.md" "$ST/tproj/ck.fix-run.txt"
  bash -c '. "$4/bin/lib/hold-push.sh"; . "$1"; . "$2"; br_fix_round tproj rk head-not-reapproved "$3" /rec TK-7' _ \
    "$T/stubs.sh" "$T/lib.sh" "$URL" "$DIR" >/dev/null 2>&1
}
NOOP() { # NOOP <case> — the round must be fix-round-noop: nothing pushed, nothing posted
  grep -q 'fix-round-noop' "$T/record.log" 2>/dev/null && ok || bad "$1 must record fix-round-noop: $(cat "$T/record.log" 2>/dev/null)"
  [ ! -s "$T/push.log" ] && ok || bad "$1 must push nothing: $(cat "$T/push.log")"
  [ ! -s "$T/comments.log" ] && ok || bad "$1 must post nothing: $(cat "$T/comments.log")"
}
ITEM='- 1. bin/lib/widget.sh:42 — the SQL builder is generated; the generator is out of this repo'

# ============================================================================
# U1 + U2 — sandboxed round with a real list: the prompt asks for the report
# section, and the list reaches the PR although the agent can write nothing
# outside its worktree.
# ============================================================================
AGENT_UNADDR="$ITEM" AGENT_REPORT="I could not bind the SQL builder here.

UNADDRESSED:
$ITEM" FR
[ -s "$T/agent.log" ] && ok || bad "U2 the fix round must run on the lead's findings (say: $(tail -3 "$T/say.log" 2>/dev/null))"
P=$(cat "$T/prompt.txt" 2>/dev/null)
grep -qF 'UNADDRESSED:' <<<"$P" && ok || bad "U1 the prompt must ask for an UNADDRESSED: section in the final report"
grep -qF "$ST/tproj/ck.unaddressed.md" <<<"$P" && bad "U1 the prompt must not send the list to a file outside the worktree" || ok
grep -q '^WROTE' "$T/sandbox.log" 2>/dev/null && bad "U2 the sandboxed agent wrote a file: $(cat "$T/sandbox.log")" || ok
grep -q 'the SQL builder is generated' "$T/comments.log" 2>/dev/null && ok || bad "U2 the listed finding must be posted on the PR (sandbox: $(cat "$T/sandbox.log" 2>/dev/null); record: $(cat "$T/record.log" 2>/dev/null))"
[ -s "$T/push.log" ] && ok || bad "U2 a round that listed what it could not address must be pushed"
grep -q 'fix-round-noop' "$T/record.log" 2>/dev/null && bad "U2 a round that listed what it could not address is not a noop: $(cat "$T/record.log")" || ok
[ -s "$ST/tproj/ck.fix-run.txt" ] && ok || bad "U2 the final report is the round's audit record and is kept"

# ============================================================================
# U3 — `UNADDRESSED: none` is an empty list
# ============================================================================
AGENT_REPORT="Nothing to report.

UNADDRESSED: none" FR
NOOP U3
# ...even when bullets follow it: the header is the whole line, so a `none`
# section with a summary under it is not a list of unaddressed findings.
AGENT_REPORT="UNADDRESSED: none
- every lead finding was looked at; nothing to fix" FR
NOOP U3b

# ============================================================================
# U4 — a bare header followed by prose only is an empty list
# ============================================================================
AGENT_REPORT="UNADDRESSED:
I think everything is fine, see the commit." FR
NOOP U4

# ============================================================================
# U5 — the instruction quoted mid-text, with no header line of its own
# ============================================================================
AGENT_REPORT="The brief said to end with a line reading exactly UNADDRESSED: followed by items. - none here." FR
NOOP U5

# ============================================================================
# U6 — two headers: the LAST list wins
# ============================================================================
AGENT_REPORT="The format is:
UNADDRESSED:
- <the finding> — <why it cannot be done here>

My answer:

UNADDRESSED:
$ITEM" FR
grep -q 'the SQL builder is generated' "$T/comments.log" 2>/dev/null && ok || bad "U6 the last list must be posted: $(cat "$T/comments.log" 2>/dev/null)"
grep -qF '<the finding>' "$T/comments.log" 2>/dev/null && bad "U6 the quoted example must not be posted: $(cat "$T/comments.log")" || ok
[ -s "$T/push.log" ] && ok || bad "U6 the round must be pushed"

echo "fixround-unaddressed-report.bh-2276: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
