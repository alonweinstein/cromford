# tests/lib/fixround-preflight-fixture.sh — the fake GitHub, the record stubs
# and the extracted resolver blocks the BH-1992 fix-round preflight suites share
# (tests/fixround-preflight-{wait-cap,trust,defer}.bh-1992-test.sh). Sourced,
# never run. Not a suite: tests/*.sh does not glob tests/lib/.
#
# The caller has sourced tests/lib/scratch.sh (so $T is its scratch dir) and set
# DIR to the checkout root. After `frpx_setup`:
#   $T/fakebin/gh       REST shapes as GitHub answers them. The PR body is a
#                       file the PATCH really rewrites; every PATCH is one line
#                       in $T/patches.log.
#     $T/gh/runs-<sha>.json, checks-<sha>.json   the CI of a head
#     $T/gh/pr-7.json                            the PR object (head, body)
#     $T/gh/reviews-7.json                       pulls/7/reviews (default [])
#   $H/bin/lane-alert.sh  appends each alert to $T/alerts.log
#   $T/pre.sh           the real `# >>> br fixround preflight` block
#   $T/fixround.sh      the real br_fix_round
#   $T/findings.sh      the real br_findings
#   $T/rereview.sh      the real br_rereview
#   $T/stubs.sh         the lane's record helpers over $T/rec.json, and logs
# shellcheck shell=bash

OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the head the findings were posted on
NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # the PR's head now
MOVED=dddddddddddddddddddddddddddddddddddddddd # a head the PR moves to mid-wait
SLUG=o/tproj
URL="https://github.com/$SLUG/pull/7"
LIB="$DIR/bin/lib/fixround-preflight.sh"
BR="$DIR/bin/blocked-resolver.sh"
RP="$DIR/bin/review-prs.sh"
HPL="$DIR/bin/lib/gh-pr-list.sh"

# Findings a conductor park carries: posted on OLD, so a head at NEW has moved.
OLD_FINDINGS="1. HIGH src/rate.ts:12 the route is unauthenticated.

VERDICT: BLOCK

---
_Head-bound harness re-review (claude) of $OLD: BLOCK. Static review, no build run. Push fixes; the conductor reviews the next head._"
# A review-lane verdict at NEW whose only blocker is stale PR-body evidence.
STALE_FINDINGS="1. BLOCKER — the PR body Evidence block still reads HARNESS_EXIT: 1 and head-red; I cannot verify CI (check-runs returns 403).

TIER: 2
VERDICT: REQUEST_CHANGES

---
_Automated harness review (Fable) of $NEW. Static review — no build run._"
STALE_BODY='## What

TK-202.

## Evidence

| check | result |
|---|---|
| repo suite | `HARNESS_EXIT: 1` |'

frpx_setup() {
  H="$T/h"; export HARNESS="$H"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/env" "$T/fakebin" "$T/gh"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
JQX=""; PREV=""
for A in "\$@"; do case "\$PREV" in --jq|-q) JQX="\$A" ;; esac; PREV="\$A"; done
case "\$*" in
  *"-X PATCH"*"/pulls/"*)
    N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    F=""; for A in "\$@"; do case "\$A" in body=@*) F="\${A#body=@}" ;; esac; done
    [ -f "$T/gh/patch-fail" ] && { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
    jq --rawfile b "\$F" '.body = \$b' "$T/gh/pr-\$N.json" > "$T/gh/pr.tmp" && mv "$T/gh/pr.tmp" "$T/gh/pr-\$N.json"
    printf 'PATCH %s\n' "\$N" >> "$T/patches.log"
    echo '{}' ;;
  *"/actions/runs?head_sha="*)
    S=\$(printf '%s' "\$*" | sed -nE 's#.*head_sha=([0-9a-f]+).*#\1#p')
    if [ -f "$T/gh/runs-\$S.json" ]; then cat "$T/gh/runs-\$S.json"; else echo '{"total_count":0,"workflow_runs":[]}'; fi ;;
  *"/check-runs"*)
    S=\$(printf '%s' "\$*" | sed -nE 's#.*/commits/([0-9a-f]+)/check-runs.*#\1#p')
    if [ -f "$T/gh/checks-\$S.json" ]; then cat "$T/gh/checks-\$S.json"; else echo '{"total_count":0,"check_runs":[]}'; fi ;;
  *"/pulls/"*"/reviews"*)
    N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+)/reviews.*#\1#p')
    [ -f "$T/gh/reviews-fail" ] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    R="$T/gh/reviews-\$N.json"; [ -f "\$R" ] || { echo '[]' > "$T/gh/reviews-empty.json"; R="$T/gh/reviews-empty.json"; }
    if [ -n "\$JQX" ]; then jq -r "\$JQX" "\$R"; else cat "\$R"; fi ;;
  *"/pulls/"*)
    N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    if [ -n "\$JQX" ]; then jq -r "\$JQX" "$T/gh/pr-\$N.json"; else cat "$T/gh/pr-\$N.json"; fi ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
  export PATH="$T/fakebin:$PATH"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
  chmod +x "$H/bin/lane-alert.sh"

  awk '/^# >>> br fixround preflight/{f=1} f{print} /^# <<< br fixround preflight/{f=0}' "$BR" > "$T/pre.sh"
  awk '/^br_fix_round\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$BR" > "$T/fixround.sh"
  awk '/^br_findings\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$BR" > "$T/findings.sh"
  awk '/^br_rereview\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$BR" > "$T/rereview.sh"

  # The record helpers keep the lane's contract (a failed write is rc 1) over
  # one file; $T/rec-ro makes every write fail, the way a full disk does.
  cat > "$T/stubs.sh" <<EOF
H="$H"
say()  { printf '%s\n' "\$*" >> "$T/say.log"; }
STAMP() { printf '2026-09-24 00:00:00Z'; }
br_event() { printf '%s\n' "\$*" >> "$T/events.log"; }
br_rereview() { printf '%s\n' "\$*" >> "$T/rereview.log"; }
mc_num_of_url() { printf '%s' "\$1" | sed -nE 's#.*/pull/([0-9]+).*#\1#p'; }
br_file() { printf '%s' "$T/rec.json"; }
br_load() { cat "$T/rec.json" 2>/dev/null || echo '{}'; }
br_num() { local v; v=\$(printf '%s' "\$1" | jq -r "(.\$2 // 0)" 2>/dev/null); case "\$v" in ''|*[!0-9]*) echo 0 ;; *) echo "\$v" ;; esac; }
_rec_w() { [ -f "$T/rec-ro" ] && return 1; local c; c=\$(br_load | jq -c "\$@") && [ -n "\$c" ] && printf '%s\n' "\$c" > "$T/rec.json"; }
br_push_field() { _rec_w --arg k "\$3" --arg v "\$4" '.[\$k] = (((.[\$k] // []) + [\$v]) | unique)'; }
br_set_field() { _rec_w --arg k "\$3" --arg v "\${4:--}" '.[\$k] = \$v'; }
br_set_num() { _rec_w --arg k "\$3" --argjson v "\${4:-0}" '.[\$k] = \$v'; }
br_has_field_value() { printf '%s' "\${1:-}" | jq -e --arg k "\$2" --arg v "\$3" '((.[\$k] // []) | index(\$v)) != null' >/dev/null 2>&1; }
br_pr_comment() { [ -f "$T/gh/comment-fail" ] && return 75; printf '%s\n' "\$2" >> "$T/comments.log"; return 0; }
EOF
}

RUNS() { # RUNS <sha> <conclusion|in_progress> — one workflow run named CI
  if [ "$2" = in_progress ]; then
    jq -nc --arg s "$1" '{total_count:1, workflow_runs:[{id:11, name:"CI", head_sha:$s, status:"in_progress", conclusion:null, run_attempt:1, run_started_at:"2026-09-23T21:10:00Z", html_url:"https://github.com/o/tproj/actions/runs/11"}]}' > "$T/gh/runs-$1.json"
  else
    jq -nc --arg s "$1" --arg c "$2" '{total_count:1, workflow_runs:[{id:11, name:"CI", head_sha:$s, status:"completed", conclusion:$c, run_attempt:1, run_started_at:"2026-09-23T21:10:00Z", html_url:"https://github.com/o/tproj/actions/runs/11"}]}' > "$T/gh/runs-$1.json"
  fi
}
PRBODY() { # PRBODY <head> <body>
  jq -nc --arg h "$1" --arg b "$2" '{number:7, head:{sha:$h, ref:"ticket/TK-202"}, body:$b}' > "$T/gh/pr-7.json"
}
body() { jq -r '.body' "$T/gh/pr-7.json"; }
reset_gh() { rm -f "$T/gh/"* "$T/gh.log" "$T/patches.log"; : > "$T/gh.log"; }
reset_rec() { rm -f "$T/rec.json" "$T/rec-ro" "$T/say.log" "$T/events.log" "$T/rereview.log" "$T/comments.log" "$T/alerts.log"; }
patches() { if [ -f "$T/patches.log" ]; then wc -l < "$T/patches.log" | tr -d ' '; else echo 0; fi; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# PRE <reason> <findings> [head] — the real br_preflight in a fresh shell;
# prints its rc on the first line, then the brief.
PRE() {
  env BR_FIXROUND_PREFLIGHT="${BR_FIXROUND_PREFLIGHT:-1}" bash -c '. "$9"; . "$1"; . "$2"; . "$3"
    br_preflight tproj ck rk "$4" "$5" /rec TK-7 "$6" "$7" "$8"; rc=$?
    printf "%s\n" "$rc"; printf "%s" "$BR_PREFLIGHT_BRIEF"' _ \
    "$LIB" "$T/stubs.sh" "$T/pre.sh" "$1" "$URL" "$SLUG" "${3:-$NEW}" "$2" "$HPL"
}

# frpx_fr_setup — br_fix_round end to end up to the agent call: git, the agent
# and the lane's bookkeeping stubbed, the preflight and its lib real.
frpx_fr_setup() {
  REPOS="$T/repos"; mkdir -p "$REPOS/tproj/.git" "$H/bin"
  printf '#!/bin/bash\n[ "$2" = repo ] && echo %s\nexit 0\n' "$SLUG" > "$H/bin/fleet-conf.sh"
  cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.txt"
printf 'agent %s\n' "\$1" >> "$T/agent.log"
exit 0
EOF
  chmod +x "$H/bin/fleet-conf.sh" "$H/bin/agent-call.sh"
  cat > "$T/fr-stubs.sh" <<EOF
OBSERVE=0; H="$H"; ST="$T/st"; LOG="$T/br.log"; REPOS="$REPOS"; FIX_AGENT_TIMEOUT=60; BR_EXECUTE_MODEL_ENV=BR_EXECUTE_MODEL
br_cap_key() { printf ck; }
br_cap_rows() { printf '%s' "\$4"; }
br_fix_cap() { printf 2; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { printf 'terminal %s\n' "\$3" >> "$T/terminal.log"; }
br_slug_of_url() { printf '%s' "$SLUG"; }
br_pr_ref() { printf '%s ticket/TK-202 %s\n' "$SLUG" "\$(jq -r .head.sha "$T/gh/pr-7.json")"; }
br_sup_seen() { :; }; br_use_token() { :; }; br_setup_blocked() { printf 'setup %s\n' "\$6" >> "$T/terminal.log"; }
br_findings() { cat "$T/findings.txt"; }
br_ladder_class() { case "\$1" in head-not-reapproved) echo review-blocked ;; red-ci-twice|red-twice|queue-ejected-twice) echo ci-red ;; *) echo "" ;; esac; }
br_conflict_note() { :; }; br_note_conflict_lines() { :; }; mc_conflict_lines() { :; }
br_model() { printf 'model-under-test'; }
br_round_begin() { :; }; br_yield_take() { return 1; }; br_count() { :; }
br_record() { printf 'record %s\n' "\$*" >> "$T/record.log"; }
br_wt_drop() { :; }; mc_git_auth() { :; }; mc_git_auth_clear() { :; }
git() {
  local a=("\$@"); [ "\${a[0]}" = -C ] && a=("\${a[@]:2}")
  printf 'git %s\n' "\${a[*]}" >> "$T/git.log"
  case "\${a[*]}" in
    "remote get-url origin") echo /srv/clone ;;
    "rev-parse --verify -q origin/"*) jq -r .head.sha "$T/gh/pr-7.json" ;;
    "rev-parse --verify -q brfix/"*) return 1 ;;
    "worktree add"*) mkdir -p "\${a[3]}" ;;
    "rev-parse HEAD") jq -r .head.sha "$T/gh/pr-7.json" ;;
    *) return 0 ;;
  esac
}
EOF
}
# FR <reason> — the real br_fix_round in a fresh shell (one resolver tick).
FR() {
  rm -f "$T/prompt.txt" "$T/git.log" "$T/terminal.log" "$T/record.log"
  env BR_PREFLIGHT_WAIT_MAX="${BR_PREFLIGHT_WAIT_MAX:-6}" bash -c '. "$8"; . "$1"; . "$2"; . "$3"; . "$4"; . "$5"
    br_fix_round tproj rk "$6" "$7" /rec TK-7' _ \
    "$LIB" "$T/stubs.sh" "$T/pre.sh" "$T/fr-stubs.sh" "$T/fixround.sh" "$1" "$URL" "$HPL" >/dev/null 2>&1
}
