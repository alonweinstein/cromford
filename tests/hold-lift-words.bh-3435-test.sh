#!/bin/bash
# tests/hold-lift-words.bh-3435-test.sh — a person's comment that STARTS with a
# lift word lifts a ticket hold, whatever else it says; a person's comment that
# neither lifts nor re-holds a held ticket reaches the operator.
#
# WHY (BH-3435, project-5 #3354, 2026-09-29). the operator wrote "RELEASED (the operator,
# 2026-09-28). Proceed on the decision in #3348 … This supersedes the HOLD." on
# a held ticket. bin/lib/hold.sh lifted only on capital RESUME/UNHOLD, so the
# capital HOLD in that sentence read as a fresh hold. The ticket sat 15.6 hours,
# and the only place anything said so was a comment on the ticket itself.
#
# Sections:
#   1  each lift word, any case, at the start of the newest person comment -> clear
#   2  the exact #3354 comment, and a RELEASED sentence carrying HOLD -> clear
#   3  hold precision for comments that do NOT start with a lift word
#   4  a bot never lifts; our own marked note never lifts
#   5  the ambiguous case, driven through hold_check (gh stub) and hold_read
#      (gh_rest stub): one lane-alert per comment, one ticket comment naming
#      the lift words, verdict unchanged
#   6  hold_is_pause / hold_is_abandon unchanged
# Run from anywhere: tests/hold-lift-words.bh-3435-test.sh   (exit 0 = pass)
# No network, no clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=bin/lib/hold.sh
. "$DIR/bin/lib/hold.sh" || { echo "FAIL: cannot source bin/lib/hold.sh"; exit 1; }

ISSUE='{"state":"open","title":"TK-1 a ticket","body":"## Scope\nx","labels":[{"name":"ai-build"}]}'
T0='2026-09-28T00:00:00Z'; T1='2026-09-28T01:00:00Z'; T2='2026-09-28T02:00:00Z'; T3='2026-09-28T03:00:00Z'
# thread <type> <body> [<type> <body> …] — comments oldest first, ids 101.., one hour apart.
thread() {
  local i=0 at out='[]'
  while [ $# -ge 2 ]; do
    at=$(printf '2026-09-28T%02d:00:00Z' "$i")
    out=$(jq -c --arg t "$1" --arg b "$2" --arg at "$at" --argjson id "$((101 + i))" \
      '. + [{id:$id, body:$b, created_at:$at, user:{login:"x", type:$t}}]' <<<"$out")
    i=$((i + 1)); shift 2
  done
  printf '%s' "$out"
}
cls() { hold_classify "$ISSUE" "$1"; }

# ---------- 1. each lift word at the start of a person's comment --------------
for w in 'RESUME' 'resume' 'RELEASE' 'release' 'RELEASED' 'Released.' 'UNHOLD' 'unhold' \
         'PROCEED' 'Proceed with #3348' 'proceed' '  RESUME — go'; do
  out=$(cls "$(thread User 'HOLD: wait' User "$w")"); rc=$?
  [ "$rc" = 0 ] && [ "${out%% *}" = "clear	lifted-by-comment" ] && ok \
    || bad "§1 '$w' over a HOLD must lift: rc=$rc out='$out'"
done

# ---------- 2. #3354 ------------------------------------------------------------
C3354='RELEASED (the operator, 2026-09-28). Proceed on the decision in #3348 … This supersedes the HOLD.'
out=$(cls "$(thread User 'HOLD: waiting on #3348' User "$C3354")"); rc=$?
[ "$rc" = 0 ] && case "$out" in clear*lifted-by-comment*) true ;; *) false ;; esac && ok \
  || bad "§2 the exact #3354 comment must lift: rc=$rc out='$out'"
out=$(cls "$(thread User 'HOLD: wait' User 'RELEASED. This supersedes the HOLD.')"); rc=$?
[ "$rc" = 0 ] && case "$out" in held*) false ;; *) true ;; esac && ok \
  || bad "§2 a RELEASED sentence carrying HOLD must not re-hold: rc=$rc out='$out'"
# The same comment alone (no earlier hold): it must not CREATE a hold either.
out=$(cls "$(thread User "$C3354")"); rc=$?
[ "$rc" = 0 ] && ok || bad "§2 the #3354 comment alone must not hold: rc=$rc out='$out'"

# ---------- 3. precision kept for comments not starting with a lift word ------
for b in 'HOLD: still waiting' 'HOLD. This supersedes the earlier call' 'HOLD for now, we can proceed later'; do
  out=$(cls "$(thread User 'RESUME' User "$b")"); rc=$?
  [ "$rc" = 1 ] && case "$out" in "held	hold:comment"*) true ;; *) false ;; esac && ok \
    || bad "§3 '$b' must still hold: rc=$rc out='$out'"
done
# BH-6297: a comment holds only when its FIRST line starts with HOLD, so the
# capital word later in the sentence no longer re-holds over a RESUME.
for b in 'This supersedes the HOLD' 'We can proceed later, HOLD for now'; do
  out=$(cls "$(thread User 'RESUME' User "$b")"); rc=$?
  [ "$rc" = 0 ] && ok || bad "§3 '$b' does not open with HOLD and must not re-hold: rc=$rc out='$out'"
done
# Adversarial negatives: none of these lifts an older HOLD. (`RESUME-ish` is not
# here: the older HOLD_LIFT_RE already lifted on it before BH-3435, and this
# ticket leaves that precision alone.)
for b in 'Do not RESUME this yet' 'until the operator lifts the hold' 'Proceed? not yet' \
         'Proceeding once #12 merges' 'PROCEED-ish' "the resume lane's BUILD_DEFERRED" \
         '> RELEASED' 'We can proceed later' 'RESUME once #12 merges, do not release before'; do
  out=$(cls "$(thread User 'HOLD: wait' User "$b")"); rc=$?
  [ "$rc" = 1 ] && ok || bad "§3 '$b' must NOT lift an older HOLD: rc=$rc out='$out'"
done

# ---------- 4. only a person lifts; our own note never does -------------------
MARKED=$'We read your last comment as neither lifting this hold nor keeping it.\nRESUME, RELEASE, RELEASED, UNHOLD or PROCEED\n<!-- harness:hold-ambiguous 102 -->'
for spec in 'Bot|RESUME' 'Bot|RELEASED' 'bot|PROCEED' "User|$MARKED" "Bot|$MARKED"; do
  out=$(cls "$(thread User 'HOLD: wait' "${spec%%|*}" "${spec#*|}")"); rc=$?
  [ "$rc" = 1 ] && ok || bad "§4 '${spec%%|*}' comment '${spec#*|}' must not lift: rc=$rc out='$out'"
done

# ---------- 5. the ambiguous case --------------------------------------------
# Pure seam first: hold_ambiguous names the newest person comment only when it is
# neutral on a ticket held by comment/title/body.
out=$(hold_ambiguous "$ISSUE" "$(thread User 'HOLD: wait' User $'thanks, see #3348\nsecond line')"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "102	2026-09-28T01:00:00Z	thanks, see #3348" ] && ok \
  || bad "§5 hold_ambiguous must name comment 102 and its first line: rc=$rc out='$out'"
TITLED='{"state":"open","title":"TK-1 (HOLD) a ticket","body":"x","labels":[{"name":"ai-build"}]}'
hold_ambiguous "$TITLED" "$(thread User 'looks fine to me')" >/dev/null && ok \
  || bad "§5 a neutral comment on a title-held ticket is ambiguous"
LABELLED='{"state":"open","title":"t","body":"x","labels":[{"name":"ai-build"},{"name":"hold"}]}'
while IFS='|' read -r name ij cj; do
  out=$(hold_ambiguous "$ij" "$cj"); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "§5 $name must not be ambiguous: rc=$rc out='$out'"
done <<EOF
clear ticket|$ISSUE|$(thread User 'thanks')
label hold|$LABELLED|$(thread User 'thanks')
older than a newer HOLD|$ISSUE|$(thread User 'thanks' User 'HOLD: wait')
bot-authored|$ISSUE|$(thread User 'HOLD: wait' Bot 'thanks')
a lift|$ISSUE|$(thread User 'HOLD: wait' User 'RELEASED')
a re-hold|$ISSUE|$(thread User 'HOLD: wait' User 'HOLD: still waiting')
no id|$ISSUE|$(thread User 'HOLD: wait' User 'thanks' | jq -c '.[1] |= del(.id)')
our own note|$ISSUE|$(thread User 'HOLD: wait' User "$MARKED")
EOF

# The production entry points. gh is a PATH stub: the issue and comments reads
# answer the fixture files, a POST (-F body=@file) is recorded with its body.
H="$T/h"; mkdir -p "$H/bin" "$T/fakebin"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FX/gh.log"
case " $* " in
  *" -F "*) f=""; for a in "$@"; do case "$a" in body=@*) f="${a#body=@}" ;; esac; done
            n=$(ls "$FX"/posted.* 2>/dev/null | wc -l); cp "$f" "$FX/posted.$((n + 1))"; echo '{}' ;;
  *"/comments"*) cat "$FX/comments.json" ;;
  *) cat "$FX/issue.json" ;;
esac
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FX/alerts.log"
exit "$(cat "$FX/alert-rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/fakebin/gh" "$H/bin/lane-alert.sh"
export FX="$T/fx"; mkdir -p "$FX"
export PATH="$T/fakebin:$PATH"
nalerts() { [ -f "$FX/alerts.log" ] && wc -l < "$FX/alerts.log" | tr -d ' ' || echo 0; }
nposts()  { ls "$FX"/posted.* 2>/dev/null | wc -l | tr -d ' '; }
fxreset() { scratch_rm "$FX"; scratch_rm "$H/state"; mkdir -p "$FX"; printf '%s' "$ISSUE" > "$FX/issue.json"; }

AMB=$(thread User 'HOLD: waiting on the client' User $'thanks, see #3348\nmore')
for entry in hold_check hold_read; do
  fxreset; printf '%s' "$AMB" > "$FX/comments.json"
  if [ "$entry" = hold_read ]; then
    # shellcheck source=bin/lib/hold-push.sh
    . "$DIR/bin/lib/hold-push.sh" || { bad "§5 cannot source hold-push.sh"; continue; }
    gh_rest() { case "$2" in *"/comments"*page=1) cat "$FX/comments.json" ;; *"/comments"*) echo '[]' ;; *) cat "$FX/issue.json" ;; esac; }
  fi
  out=$(HARNESS="$H" "$entry" o/r 7); rc=$?
  [ "$rc" = 1 ] && case "$out" in "held	hold:comment 2026-09-28T00:00:00Z HOLD: waiting on the client") true ;; *) false ;; esac && ok \
    || bad "§5/$entry verdict must be unchanged (held rc 1): rc=$rc out='$out'"
  [ "$(nalerts)" = 1 ] && ok || bad "§5/$entry one ambiguous comment must raise exactly one alert, got $(nalerts)"
  a=$(cat "$FX/alerts.log" 2>/dev/null)
  case "$a" in *"--severity warn"*"--id hold-ambiguous:o/r#7:102"*) ok ;; *) bad "§5/$entry alert must be warn with id hold-ambiguous:o/r#7:102: '$a'" ;; esac
  case "$a" in *"o/r#7"*'"thanks, see #3348"'*) ok ;; *) bad "§5/$entry alert must name o/r#7 and quote the first line: '$a'" ;; esac
  [ "$(nposts)" = 1 ] && ok || bad "§5/$entry one ticket comment expected, got $(nposts)"
  grep -q 'api repos/o/r/issues/7/comments -F body=@' "$FX/gh.log" && ok || bad "§5/$entry the note must POST to the issue's comments"
  p=$(cat "$FX/posted.1" 2>/dev/null)
  for w in RESUME RELEASE RELEASED UNHOLD PROCEED '<!-- harness:hold-ambiguous 102 -->'; do
    case "$p" in *"$w"*) ok ;; *) bad "§5/$entry ticket comment must name '$w'" ;; esac
  done
  # a rerun on the same thread: nothing new.
  HARNESS="$H" "$entry" o/r 7 >/dev/null
  [ "$(nalerts)" = 1 ] && [ "$(nposts)" = 1 ] && ok || bad "§5/$entry a rerun must not alert or post again: alerts=$(nalerts) posts=$(nposts)"
  # our own posted note fed back into the thread, as User and as Bot: still held, no new alert.
  for ty in User Bot; do
    jq -c --rawfile b "$FX/posted.1" --arg t "$ty" '. + [{id:900, body:$b, created_at:"2026-09-28T05:00:00Z", user:{type:$t}}]' <<<"$AMB" > "$FX/comments.json"
    out=$(HARNESS="$H" "$entry" o/r 7); rc=$?
    [ "$rc" = 1 ] && [ "$(nalerts)" = 1 ] && ok || bad "§5/$entry our note ($ty) must not lift or alert: rc=$rc alerts=$(nalerts)"
  done
  # a NEWER ambiguous comment: one more alert.
  jq -c '. + [{id:103, body:"any update?", created_at:"2026-09-28T06:00:00Z", user:{type:"User"}}]' <<<"$AMB" > "$FX/comments.json"
  HARNESS="$H" "$entry" o/r 7 >/dev/null
  [ "$(nalerts)" = 2 ] && ok || bad "§5/$entry a newer ambiguous comment must raise a second alert, got $(nalerts)"
  unset -f gh_rest
done

# alert fails -> no ticket comment, claim removed, the next read retries.
fxreset; printf '%s' "$AMB" > "$FX/comments.json"; echo 1 > "$FX/alert-rc"
HARNESS="$H" hold_check o/r 7 >/dev/null
[ "$(nalerts)" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "§5 a failed alert must post no comment: alerts=$(nalerts) posts=$(nposts)"
[ -z "$(ls -A "$H/state/hold-ambiguous" 2>/dev/null)" ] && ok || bad "§5 a failed alert must release its claim"
rm -f "$FX/alert-rc"; HARNESS="$H" hold_check o/r 7 >/dev/null
[ "$(nalerts)" = 2 ] && [ "$(nposts)" = 1 ] && ok || bad "§5 the next read after a failed alert must retry: alerts=$(nalerts) posts=$(nposts)"

# no harness root -> no alert, no post, same verdict.
fxreset; printf '%s' "$AMB" > "$FX/comments.json"
out=$(HARNESS='' H='' hold_check o/r 7); rc=$?
[ "$rc" = 1 ] && [ "$(nalerts)" = 0 ] && [ "$(nposts)" = 0 ] && ok \
  || bad "§5 no HARNESS root: no side effects, still held: rc=$rc alerts=$(nalerts) posts=$(nposts)"

# another box already alerted (ledger hit) -> no alert.
fxreset; printf '%s' "$AMB" > "$FX/comments.json"
job_ledger_get() { printf 'alerted'; return 0; }
HARNESS="$H" hold_check o/r 7 >/dev/null
[ "$(nalerts)" = 0 ] && ok || bad "§5 a ledger hit must suppress the alert, got $(nalerts)"
# the ledger worker down (rc 1) -> fail open, alert.
fxreset; printf '%s' "$AMB" > "$FX/comments.json"
job_ledger_get() { return 1; }
HARNESS="$H" hold_check o/r 7 >/dev/null
[ "$(nalerts)" = 1 ] && ok || bad "§5 an unreachable ledger must fail open (alert), got $(nalerts)"
unset -f job_ledger_get

# a lift through hold_check: clear, no alert.
fxreset; printf '%s' "$(thread User 'HOLD: wait' User "$C3354")" > "$FX/comments.json"
out=$(HARNESS="$H" hold_check o/r 7); rc=$?
[ "$rc" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "§5 the #3354 lift via hold_check: clear, no alert: rc=$rc alerts=$(nalerts)"

# ---------- 6. the pause / abandon readings are unchanged ---------------------
hold_is_pause  "held	hold:comment $T0 HOLD" && ok || bad "§6 hold:comment is a pause"
hold_is_abandon "held	abandon:comment $T1 ABANDON" && ok || bad "§6 abandon:comment is an abandon"
hold_is_pause  "clear	lifted-by-comment $T2" && bad "§6 a lift is not a pause" || ok
out=$(cls "$(thread User 'HOLD: wait' User 'ABANDON this')"); hold_is_abandon "$out" && ok || bad "§6 ABANDON still abandons: '$out'"
: "$T3"

echo "hold-lift-words.bh-3435: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
