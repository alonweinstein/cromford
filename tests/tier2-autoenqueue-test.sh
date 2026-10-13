#!/bin/bash
# tests/tier2-autoenqueue-test.sh — BH-1668: a tier-2 PR on a Mergify repo that
# carries a harness APPROVE on its CURRENT head, a green required check and a
# clean merge state gets ONE `@mergifyio queue` comment, posted with a PAT (never
# the App token), recorded in the ledger (kind autoenqueue, key <url>@<head>) and
# on the build row, and never re-posted for that head.
#
# AT-1..AT-17 (minus 13) source bin/lib/autoenqueue.sh and call ae_project
# with the conductor's own 13-column tsv rows. Every gate the conductor already
# owns (lead fence, ticket hold, block gate, hotfix proof, the verdict reads) is
# stubbed at its entry point; the GitHub reads and the POST go through the REAL
# bin/lib/gh-rest.sh and bin/lib/gh-repo-token.sh against a stub `gh` that
# records argv and GH_TOKEN. AT-13 drives the whole bin/merge-conductor.sh.
# Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/autoenqueue.sh" ] || { echo "FAIL: bin/lib/autoenqueue.sh does not exist"; exit 1; }

SLUG=example-org/mgfy-os
H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40)); H0=$(printf 'c%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"

# ============================================================================
# The unit harness: the module sourced into THIS shell, its neighbours stubbed.
# ============================================================================
export HARNESS="$T/u"; H="$HARNESS"; MC_H="$H"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fx" "$T/ubin"
printf 'GH_ADMIN_TOKEN=pat-admin\n' > "$H/env/github-admin.env"
printf '#!/bin/bash\n[ "$2" = board_prefix ] && echo X\nexit 0\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/ubin/restpr"; chmod +x "$T/ubin/restpr"
MC_ATTEMPTS="$H/state/attempts.txt"; MC_LOG="$H/logs/merge-conductor.log"; : > "$MC_ATTEMPTS"; : > "$MC_LOG"
MC_TICK_ID=unit-tick; MC_TICK_DIR="$H/state/tick"
export MC_ATTEMPTS MC_LOG MC_TICK_ID MC_TICK_DIR

# The stub gh. Every call is logged with the GH_TOKEN it ran under.
cat > "$T/ubin/gh" <<EOF
#!/bin/bash
printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/gh-calls.txt"
FX="$T/fx"
num_of() { printf '%s' "\$1" | sed -nE 's#.*/(pulls|issues)/([0-9]+).*#\2#p'; }
case "\$*" in
  # the PAT probe (_ghrt_pat_probe): a token sees the repo iff it is listed
  "api repos/$SLUG -q .id")
    grep -qxF "\${GH_TOKEN:-<unset>}" "\$FX/visible" && { echo 1; exit 0; }; exit 1 ;;
  *"api -i -X GET repos/$SLUG/commits/"*"/check-runs"*)
    sha=\$(printf '%s' "\$*" | sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p')
    [ -f "\$FX/checks-down" ] && { restpr --raw 502 '{"message":"bad gateway"}'; exit 0; }
    restpr --raw 200 "\$(cat "\$FX/checks-\$sha" 2>/dev/null || echo '{"check_runs":[]}')" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*)
    [ -f "\$FX/thread-down-\$(num_of "\$*")" ] && { restpr --raw 502 '{"message":"bad gateway"}'; exit 0; }
    restpr --raw 200 "\$(cat "\$FX/thread-\$(num_of "\$*")" 2>/dev/null || echo '[]')" ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/posts.txt"
    if [ -f "\$FX/postfail" ]; then restpr --raw 500 '{"message":"boom"}'
    else restpr --raw 201 '{"id":777,"body":"@mergifyio queue"}'; fi ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    n=\$(num_of "\$*"); read -r st hd base ms login < "\$FX/pr-\$n"
    restpr "\$st" "\$hd" "ticket/mg-\$n" "\$base" "" MERGEABLE "\$ms" "\$login" ;;
  *) printf '%s\n' "\$*" >> "$T/gh-other.txt"; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/ubin/gh"
export PATH="$T/ubin:$PATH"

# THE CONDUCTOR'S DEFAULT TOKEN IS THE PAT; the App token is what use_token has
# exported by the time the step runs (the armed case, AT-14).
export GH_TOKEN=pat-default
# shellcheck source=bin/lib/gh-rest.sh
. "$DIR/bin/lib/gh-rest.sh" || exit 1
# shellcheck source=bin/lib/gh-repo-token.sh
. "$DIR/bin/lib/gh-repo-token.sh" || exit 1
export GH_TOKEN=app-tok
export GH_ETAG=0

# --- neighbours, stubbed at their entry points ---------------------------------
mc_log()   { echo "$*" >> "$MC_LOG"; }
mc_alert() { echo "ALERT $*" >> "$H/logs/ALERTS.log"; }
# TEST-CHANGE (BH-2360): _ae_once rides the conductor's attempt verbs, which
# bin/lib/mc/locks.sh defines; this suite does not source locks.sh (it would
# reset MC_TICK_DIR), so these are the verbs' flag-down behaviour.
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
mc_record_for() { echo "$T/rec"; }
mc_issue_of() { echo 1; }
mc_verdict() { # fixture: verdict-<num> = "VERDICT sha job"
  local n="${1##*/}" v s j; read -r v s j < "$T/fx/verdict-$n" 2>/dev/null || { printf -- '-\t-\t-\t-\t-'; return 0; }
  printf '%s\t-\t%s\t%s\t-' "$v" "$s" "$j"; }
vd_standing() { # fixture: standing-<num> = "WORD" (rc 0) | "down" (rc 2); absent = rc 1
  local w; w=$(cat "$T/fx/standing-$2" 2>/dev/null) || return 1
  [ "$w" = down ] && return 2; printf '%s\tlead\t1\t2026-09-23\t-\t-\n' "$w"; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; [ -f "$T/fx/lead-$3" ] && return 0; return 1; }
to_lane_hold() { [ -f "$T/fx/held-$3" ]; }
bg_scan() { echo "bg_scan $*" >> "$T/bg-streak.txt"; return 0; }   # the streak-noting read: must never be called here
bg_scan_read() { [ -f "$T/fx/block-$2" ] && { echo "https://x/comment"; return 1; }; return 0; }
main_red_exempt() { return 1; }
hotfix_pr_is() { case ",$1," in *,hotfix,*) return 0 ;; esac; return 1; }
mc_hotfix_proof() { cat "$T/fx/hproof" 2>/dev/null || echo ok; }
flag_active() { [ -f "$H/flags/$1" ]; }
# The ledger client: a jsonl file, and a switch that makes the worker "down".
job_ledger_get() {
  [ -f "$T/fx/worker-down" ] && return 1
  local s; s=$(jq -r --arg k "$1" --arg v "$2" 'select(.kind==$k and .key==$v) | .status' "$T/ledger.jsonl" 2>/dev/null | tail -1)
  [ -n "$s" ] || return 2; printf '%s' "$s"; }
job_ledger_put() {
  [ -f "$T/fx/worker-down" ] && return 1
  jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "${4:-}" '{kind:$k,key:$v,status:$s,detail:$d}' >> "$T/ledger.jsonl"; }
job_artifact_put() {
  jq -nc --arg k "$1" --arg r "$2" --arg d "${3:-}" --arg j "${4:-}" '{kind:$k,ref:$r,detail:$d,job:$j}' >> "$T/artifacts.jsonl"; }

# shellcheck source=bin/lib/autoenqueue.sh
. "$DIR/bin/lib/autoenqueue.sh" || exit 1
command -v ae_project >/dev/null 2>&1 || { echo "FAIL: ae_project not defined"; exit 1; }

# row <num> <head> [labels] [base] [branch] [draft] [inq] — the conductor's tsv
row() { printf '%s\t%s\t%s\t%s\t%s\tCLEAN\tMERGEABLE\tOPEN\t%s\t%s\t%s\t-\tfalse' \
  "$1" "$U/$1" "$2" "${5:-ticket/mg-$1}" "${6:-false}" "${7:-false}" "${3:--}" "${4:-main}"; }
green() { printf '{"check_runs":[{"name":"Other","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"},{"name":"%s","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' "${1:-Build + Unit tests}"; }
# fx <num> <head> — the eligible default: APPROVE@head, green, open/clean on main,
# and the conductor's pr_worker marked that head READY this tick (ae_mark).
fx() {
  echo "APPROVE $2 J$1" > "$T/fx/verdict-$1"; rm -f "$T/fx/standing-$1"
  green > "$T/fx/checks-$2"; echo "open $2 main clean operator" > "$T/fx/pr-$1"
  ae_mark mgfy ready "$SLUG#$1" "$2"
}
reset() { # a fresh world (ledger kept unless asked)
  rm -f "$T/fx"/* "$H/flags"/* ; : > "$T/posts.txt"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$H/logs/ALERTS.log"
  : > "$T/artifacts.jsonl"; : > "$T/gh-other.txt"; : > "$T/gh-calls.txt"; : > "$T/bg-streak.txt"; scratch_rm "$MC_TICK_DIR"
  [ "${1:-}" = keep ] || { : > "$T/ledger.jsonl"; rm -f "$H/state/tier2-autoenqueue.txt"; }
  printf 'pat-default\npat-admin\napp-tok\n' > "$T/fx/visible"
}
ae() { ( MODE="${MODE:-merge}"; MERGES="${MERGES:-1}"; ae_project mgfy "$SLUG" "${PROV:-mergify}" main "$@"; printf '%s' "${GH_TOKEN:-<unset>}" > "$T/after-tok" ); }
posts() { grep -c . "$T/posts.txt" 2>/dev/null || true; }
lstat() { jq -r --arg v "$1" 'select(.key==$v)|.status' "$T/ledger.jsonl" | tail -1; }

# AT-1 APPROVE@head, check success, clean, MODE=merge -> exactly one POST.
reset; fx 31 "$H1"; ae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-1 exactly one POST (got $(posts); log: $(cat "$MC_LOG"))"
grep -q "api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue" "$T/posts.txt" && ok || bad "AT-1 the POST is '@mergifyio queue' on issues/31/comments (got $(cat "$T/posts.txt"))"
[ "$(jq -r --arg v "$U/31@$H1" 'select(.key==$v)|.status' "$T/ledger.jsonl" | tr '\n' ' ')" = "posting enqueued " ] && ok || bad "AT-1 ledger must go posting -> enqueued (got $(cat "$T/ledger.jsonl"))"
jq -e --arg v "$U/31@$H1" --arg h "$H1" 'select(.key==$v and .status=="enqueued") | .detail | fromjson | (.enqueued_at|length>0) and .enqueued_head==$h and .comment_id==777 and .job=="J31"' "$T/ledger.jsonl" >/dev/null && ok || bad "AT-1 enqueued detail carries enqueued_at, enqueued_head, comment_id, job (got $(tail -1 "$T/ledger.jsonl"))"
jq -e --arg h "$H1" 'select(.kind=="enqueued" and .ref==$h and .job=="J31") | .detail | fromjson | .enqueued_head==$h and (.enqueued_at|length>0)' "$T/artifacts.jsonl" >/dev/null && ok || bad "AT-1 one artifact 'enqueued' on the build row (got $(cat "$T/artifacts.jsonl"))"
grep -qE 'pr merge|/merge|labels|git push' "$T/gh-calls.txt" && bad "AT-1 the step must never merge, label or push ($(grep -E 'merge|labels' "$T/gh-calls.txt"))" || ok
grep -q "AUTOENQUEUE $SLUG#31 posted @mergifyio queue at ${H1:0:8} as pat:default" "$MC_LOG" && ok || bad "AT-1 the log names the post and the PAT rung (log: $(cat "$MC_LOG"))"
grep -q "$H1 enqueued" "$H/state/tier2-autoenqueue.txt" && ok || bad "AT-1 the file ledger mirrors the row"

# AT-2 the same fixture on a second tick -> nothing.
: > "$T/posts.txt"; : > "$MC_ATTEMPTS"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-2 a second tick on the same head must not re-post (got $(posts))"

# AT-3 APPROVE on an OLDER head -> nothing, one aeskip verdict line.
reset; fx 31 "$H1"; echo "APPROVE $H0 J31" > "$T/fx/verdict-31"; ae "$(row 31 "$H1")"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-3 a verdict on an older head must never post (got $(posts))"
[ "$(grep -c "^aeskip $SLUG#31 $H1 verdict$" "$MC_ATTEMPTS")" = 1 ] && ok || bad "AT-3 exactly one aeskip verdict line over two ticks (attempts: $(cat "$MC_ATTEMPTS"))"
# ...and CONTRADICTION / REJECT refuse too.
reset; fx 31 "$H1"; echo "CONTRADICTION $H1 J31" > "$T/fx/verdict-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-3b a CONTRADICTION verdict must never post"
reset; fx 31 "$H1"; echo "REJECT $H1 J31" > "$T/fx/verdict-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-3c a REJECT verdict must never post"

# AT-4 no build verdict, a standing MERGE-WITH-NOTES@head -> 1; standing BLOCK -> 0.
reset; fx 31 "$H1"; rm -f "$T/fx/verdict-31"; echo MERGE-WITH-NOTES > "$T/fx/standing-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-4 a standing MERGE-WITH-NOTES on the head must post (got $(posts); log: $(cat "$MC_LOG"))"
reset; fx 31 "$H1"; rm -f "$T/fx/verdict-31"; echo BLOCK > "$T/fx/standing-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-4b a standing BLOCK must never post"
reset; fx 31 "$H1"; echo BLOCK > "$T/fx/standing-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-4c a standing BLOCK on the head beats a build APPROVE"
reset; fx 31 "$H1"; rm -f "$T/fx/verdict-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && [ ! -s "$MC_LOG" ] && ok || bad "AT-4d no verdict at all is not a harness-reviewed PR: silent skip (log: $(cat "$MC_LOG"))"

# AT-5 the required check.
reset; fx 31 "$H1"; printf '{"check_runs":[{"name":"Other","status":"completed","conclusion":"success","started_at":"x"},{"name":"Build + Unit tests","status":"completed","conclusion":"failure","started_at":"x"}]}' > "$T/fx/checks-$H1"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-5 a failed required check must never post"
reset; fx 31 "$H1"; printf '{"check_runs":[{"name":"Build + Unit tests","status":"in_progress","conclusion":null,"started_at":"x"}]}' > "$T/fx/checks-$H1"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-5b an in-progress required check must never post"
reset; fx 31 "$H1"; green Other > "$T/fx/checks-$H1"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-5c an absent required check (another one green) must never post"
reset; fx 31 "$H1"; green CI > "$T/fx/checks-$H1"; MC_AUTOENQUEUE_CHECK=CI ae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-5d the check name is the knob: CI green with MC_AUTOENQUEUE_CHECK=CI posts (got $(posts))"
reset; fx 31 "$H1"; touch "$T/fx/checks-down"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-5e an unreadable check read must never post"
# the LATEST run by started_at decides: an old success under a newer failure refuses
reset; fx 31 "$H1"; printf '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"failure","started_at":"2026-09-23T12:00:00Z"},{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' > "$T/fx/checks-$H1"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-5f the latest run of the check decides"

# AT-6 mergeable_state.
reset; fx 31 "$H1"; echo "open $H1 main dirty operator" > "$T/fx/pr-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-6 dirty must never post"
reset; fx 31 "$H1"; echo "open $H1 main blocked operator" > "$T/fx/pr-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-6b blocked must never post"
grep -q "mergeable_state blocked" "$MC_LOG" && ok || bad "AT-6b the log line names 'blocked' (log: $(cat "$MC_LOG"))"
reset; fx 31 "$H1"; echo "open $H1 main behind operator" > "$T/fx/pr-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-6c behind must never post"
# the pre-act re-read shows the head moved since the list
reset; fx 31 "$H1"; echo "open $H2 main clean operator" > "$T/fx/pr-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-6d a head that moved under the tick must never post"

# AT-7 base / train / draft / already queued.
reset; fx 31 "$H1"; ae "$(row 31 "$H1" - feature/x)"
[ "$(posts)" = 0 ] && ok || bad "AT-7 a PR based on feature/x (stacked) must wait"
reset; fx 31 "$H1"; echo "open $H1 feature/x clean operator" > "$T/fx/pr-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-7b the REST re-read's base decides too"
reset; fx 31 "$H1"; ae "$(row 31 "$H1" - main train/mgfy-1)"
[ "$(posts)" = 0 ] && ok || bad "AT-7c a train/* head must never post"
reset; fx 31 "$H1"; ae "$(row 31 "$H1" - main ticket/mg-31 true)"
[ "$(posts)" = 0 ] && ok || bad "AT-7d a draft must never post"
reset; fx 31 "$H1"; ae "$(row 31 "$H1" queued)"
[ "$(posts)" = 0 ] && ok || bad "AT-7e a PR already carrying Mergify's queued label must never post"
reset; fx 31 "$H1"; ae "$(row 31 "$H1" - main ticket/mg-31 false true)"
[ "$(posts)" = 0 ] && ok || bad "AT-7f a PR already isInMergeQueue must never post"

# AT-8 kill switches -> no POST, one WOULD line per (PR, head) over two ticks.
for sw in automerge-disabled paused-mgfy; do
  reset; fx 31 "$H1"; touch "$H/flags/$sw"; ae "$(row 31 "$H1")"; ae "$(row 31 "$H1")"
  [ "$(posts)" = 0 ] && ok || bad "AT-8 flags/$sw must never post (got $(posts))"
  [ "$(grep -c "WOULD enqueue $SLUG#31 @${H1:0:8}" "$MC_LOG")" = 1 ] && ok || bad "AT-8 flags/$sw: exactly one WOULD line over two ticks (log: $(cat "$MC_LOG"))"
  [ -s "$T/ledger.jsonl" ] && bad "AT-8 flags/$sw: no ledger row either" || ok
done
for m in observe actions kill-switch; do
  reset; fx 31 "$H1"; MODE=$m ae "$(row 31 "$H1")"; MODE=$m ae "$(row 31 "$H1")"
  [ "$(posts)" = 0 ] && [ "$(grep -c 'WOULD enqueue' "$MC_LOG")" = 1 ] && ok || bad "AT-8 MODE=$m: no POST and one WOULD line (posts $(posts); log: $(cat "$MC_LOG"))"
done
reset; fx 31 "$H1"; MC_AUTOENQUEUE=0 ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && [ ! -s "$MC_LOG" ] && ok || bad "AT-8 MC_AUTOENQUEUE=0 is a silent no-op"
reset; fx 31 "$H1"; PROV=github ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && [ ! -s "$T/gh-calls.txt" ] && ok || bad "AT-8 a non-Mergify provider is a no-op with no read"

# AT-9 hold labels.
reset; fx 31 "$H1"; ae "$(row 31 "$H1" "bug,hold")"
[ "$(posts)" = 0 ] && ok || bad "AT-9 a PR labelled hold must never post"
reset; fx 31 "$H1"; MC_AUTOENQUEUE_HOLD_LABELS=freeze ae "$(row 31 "$H1" "freeze")"
[ "$(posts)" = 0 ] && ok || bad "AT-9b the hold-label set is the knob"
# G7 fences: lead PR, ticket hold, block gate, main-red freeze
reset; fx 31 "$H1"; touch "$T/fx/lead-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-9c a lead PR must never post"
reset; fx 31 "$H1"; touch "$T/fx/held-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-9d a held ticket must never post"
reset; fx 31 "$H1"; touch "$T/fx/block-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-9e a human BLOCK on the thread must never post"
reset; fx 31 "$H1"; ( MAIN_RED=main-red-mgfy; MODE=merge; MERGES=1; ae_project mgfy "$SLUG" mergify main "$(row 31 "$H1")" )
[ "$(posts)" = 0 ] && ok || bad "AT-9f a main-red freeze must never post"

# AT-10 a hotfix PR whose migration proof is `hold`.
reset; fx 31 "$H1"; echo hold > "$T/fx/hproof"; ae "$(row 31 "$H1" hotfix)"
[ "$(posts)" = 0 ] && ok || bad "AT-10 a hotfix PR held by hotfix-migration-hold must never post"
reset; fx 31 "$H1"; echo ok > "$T/fx/hproof"; ae "$(row 31 "$H1" hotfix)"
[ "$(posts)" = 1 ] && ok || bad "AT-10b a hotfix PR with an accepted proof posts (got $(posts))"

# AT-11 after AT-1's shape, the head moves to H2 with APPROVE@H2 -> one NEW post.
reset; fx 31 "$H1"; ae "$(row 31 "$H1")"
reset keep; fx 31 "$H2"; ae "$(row 31 "$H2")"
[ "$(posts)" = 1 ] && ok || bad "AT-11 a new approved head posts once more (got $(posts))"
[ "$(lstat "$U/31@$H2")" = enqueued ] && ok || bad "AT-11 keyed on the new head"

# AT-12 ejected (no queued label, same head, enqueued row stands) -> nothing.
reset; fx 31 "$H1"; ae "$(row 31 "$H1" queued)"; ae "$(row 31 "$H1")"
reset keep; fx 31 "$H1"; ae "$(row 31 "$H1")"   # AT-1 again: the row exists now
: > "$T/posts.txt"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-12 an ejected PR on the same head must not be re-posted (got $(posts))"

# AT-14 identity: the App token is armed; the POST runs under the PAT.
reset; fx 31 "$H1"; ae "$(row 31 "$H1")"
grep -q 'GH_TOKEN=pat-default$' "$T/posts.txt" && ok || bad "AT-14 the POST runs under the default PAT (got $(cat "$T/posts.txt"))"
grep -q 'GH_TOKEN=app-tok$' "$T/posts.txt" && bad "AT-14 the POST must never run under the App token" || ok
[ "$(cat "$T/after-tok")" = app-tok ] && ok || bad "AT-14 the caller's token is left as it was"
reset; fx 31 "$H1"; printf 'pat-admin\napp-tok\n' > "$T/fx/visible"; ae "$(row 31 "$H1")"
grep -q 'GH_TOKEN=pat-admin$' "$T/posts.txt" && ok || bad "AT-14b the admin PAT when the default cannot see the repo (got $(cat "$T/posts.txt"))"
reset; fx 31 "$H1"; printf 'app-tok\n' > "$T/fx/visible"; ae "$(row 31 "$H1")"; : > "$MC_ATTEMPTS"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-14c no PAT sees the repo: no POST (got $(posts))"
[ "$(lstat "$U/31@$H1")" = not-configured ] && ok || bad "AT-14c the row is not-configured (got $(lstat "$U/31@$H1"))"
[ "$(grep -c 'ALERT' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "AT-14c one ALERTS line per repo per day (got $(cat "$H/logs/ALERTS.log"))"
# gh_repo_use_pat itself: never the App rung.
( GH_TOKEN=app-tok; printf 'app-tok\n' > "$T/fx/visible"; unset '_GHRT_PAT_TOK[example-org/other]'
  gh_repo_use_pat example-org/other; echo "rc=$? tok=${GH_TOKEN:-<unset>}" ) > "$T/usepat.txt" 2>&1
grep -q '^rc=1 tok=pat-default$' "$T/usepat.txt" && ok || bad "AT-14d gh_repo_use_pat answers rc 1 and never exports the App token (got $(cat "$T/usepat.txt"))"

# AT-15 crash recovery from a `posting` row.
reset; fx 31 "$H1"; job_ledger_put autoenqueue "$U/31@$H1" posting '{}'
echo '[{"id":555,"body":"@mergifyio queue","user":{"login":"operator"}}]' > "$T/fx/thread-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-15 our comment is on the thread: no second POST (got $(posts))"
[ "$(lstat "$U/31@$H1")" = enqueued ] && ok || bad "AT-15 the row is upgraded to enqueued (got $(lstat "$U/31@$H1"))"
reset; fx 31 "$H1"; job_ledger_put autoenqueue "$U/31@$H1" posting '{}'; ae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-15b the thread shows nothing: re-sent once (got $(posts))"

# AT-16 the worker is down.
reset; fx 31 "$H1"; touch "$T/fx/worker-down"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-16 worker down and no file line: fail closed (got $(posts))"
reset; fx 31 "$H1"; touch "$T/fx/worker-down"; echo "$U/31 $H1 enqueued 2026-09-23T00:00:00Z" > "$H/state/tier2-autoenqueue.txt"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-16b worker down and the file says enqueued: nothing"
reset; fx 31 "$H1"; echo "$U/31 $H1 enqueued 2026-09-23T00:00:00Z" > "$H/state/tier2-autoenqueue.txt"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-16c worker UP with no row, but the file records our own enqueued write: nothing (got $(posts))"

# failure path: non-201 -> failed row, retried, capped at 3 with one ALERTS line.
reset; fx 31 "$H1"; touch "$T/fx/postfail"
for _ in 1 2 3 4; do : > "$MC_ATTEMPTS"; ae "$(row 31 "$H1")"; done
[ "$(posts)" = 3 ] && ok || bad "AT-16d a failing POST is retried up to 3 times, then stops (got $(posts))"
[ "$(lstat "$U/31@$H1")" = failed-3 ] && ok || bad "AT-16d the row is failed-3 (got $(lstat "$U/31@$H1"))"
# ...and the cap holds on the ledger alone: the file cannot be written (review F4).
reset; fx 31 "$H1"; touch "$T/fx/postfail"; mkdir -p "$H/state/tier2-autoenqueue.txt"
for _ in 1 2 3 4 5; do : > "$MC_ATTEMPTS"; ae "$(row 31 "$H1")"; done
[ "$(posts)" = 3 ] && ok || bad "AT-16e with the file ledger unwritable the ledger's failed-<n> still caps the retries at 3 (got $(posts))"
[ "$(lstat "$U/31@$H1")" = failed-3 ] && ok || bad "AT-16e the ledger row is failed-3 (got $(lstat "$U/31@$H1"))"
[ "$(grep -c ALERT "$H/logs/ALERTS.log")" = 1 ] && ok || bad "AT-16e one ALERTS line (got $(cat "$H/logs/ALERTS.log"))"
rmdir "$H/state/tier2-autoenqueue.txt"
[ "$(grep -c ALERT "$H/logs/ALERTS.log")" = 1 ] && ok || bad "AT-16d one ALERTS line after the third failure (got $(cat "$H/logs/ALERTS.log"))"

# AT-17 cap: 12 eligible PRs with CAP=10 -> 10 POSTs and one DEFERRED 2 line.
reset; R=()
for n in $(seq 101 112); do h=$(printf '%040d' "$n"); fx "$n" "$h"; R+=("$(row "$n" "$h")"); done
MC_AUTOENQUEUE_CAP=10 ae "${R[@]}"
[ "$(posts)" = 10 ] && ok || bad "AT-17 CAP=10 over 12 eligible PRs posts 10 (got $(posts))"
grep -q "DEFERRED 2" "$MC_LOG" && ok || bad "AT-17 one DEFERRED 2 line (log: $(grep -i defer "$MC_LOG"))"
: > "$T/posts.txt"; MC_AUTOENQUEUE_CAP=10 ae "${R[@]}"
[ "$(posts)" = 2 ] && ok || bad "AT-17 the deferred two are re-offered next tick (got $(posts))"

# AT-18 the conductor's READY hand-off (review F1/F2). Without a `ready` mark
# for THIS head THIS tick, every other gate passing is not enough.
reset; fx 31 "$H1"; scratch_rm "$MC_TICK_DIR"; ae "$(row 31 "$H1")"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-18 a row the conductor did not clear READY (parked on provenance, iron-law, tightened, a dependency…) must never post (got $(posts))"
[ "$(grep -c "^aeskip $SLUG#31 $H1 conductor$" "$MC_ATTEMPTS")" = 1 ] && ok || bad "AT-18 one aeskip conductor line over two ticks (attempts: $(cat "$MC_ATTEMPTS"))"
grep -q 'check-runs\|pulls/31' "$T/gh-calls.txt" && bad "AT-18 no GitHub read before the READY mark is checked" || ok
reset; fx 31 "$H1"; scratch_rm "$MC_TICK_DIR"; ae_mark mgfy ready "$SLUG#31" "$H0"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-18b a READY mark on an older head must never post"
reset; fx 31 "$H1"; ( MC_TICK_ID=other-tick; MODE=merge; MERGES=1; ae_project mgfy "$SLUG" mergify main "$(row 31 "$H1")" )
[ "$(posts)" = 0 ] && ok || bad "AT-18c a READY mark from ANOTHER tick must never post"
reset; fx 31 "$H1"; ( unset MC_TICK_ID; MODE=merge; MERGES=1; ae_project mgfy "$SLUG" mergify main "$(row 31 "$H1")" )
[ "$(posts)" = 0 ] && ok || bad "AT-18d no MC_TICK_ID: nothing posted"
reset; fx 31 "$H1"; ae_mark othr ready "$SLUG#31" "$H1"; scratch_rm "$MC_TICK_DIR"; ae_mark othr ready "$SLUG#31" "$H1"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-18e a READY mark for another project must never post"
# AT-19 the conductor's own enqueue was witnessed this tick: no second ask.
reset; fx 31 "$H1"; ae_mark mgfy asked "$SLUG#31" "$H1"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-19 a row the conductor already enqueued this tick gets no second @mergifyio queue (got $(posts))"
# AT-20 the conductor's merge switch: MODE=merge but MERGES=0 -> a WOULD line.
reset; fx 31 "$H1"; MERGES=0 ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && grep -q "WOULD enqueue $SLUG#31 .*MERGES=0" "$MC_LOG" && ok || bad "AT-20 MERGES=0 must never post (posts $(posts); log: $(cat "$MC_LOG"))"
# AT-21 the block gate is read without noting the refusal streak a second time.
reset; fx 31 "$H1"; ae "$(row 31 "$H1")"
[ ! -s "$T/bg-streak.txt" ] && ok || bad "AT-21 bg_scan (which notes the streak) must not be called by the step (got $(cat "$T/bg-streak.txt"))"

# AT-23 A HOLD ON THE PR ITSELF (lead round, 2026-09-24). project-5 #3214
# (TK-3108, a sign-in identity change) carries `HOLD: do not enqueue or merge
# automatically` as a comment on the PR, not on its ticket, and it must never
# self-enqueue however green and approved it is until a human lifts it. The PR
# thread is read with bin/lib/hold.sh's own classifier: the newest decisive
# HUMAN comment wins, bot comments are ignored, RESUME lifts.
thread() { # thread <num> <json-array of [login, type, created_at, body]>
  jq -c 'map({user:{login:.[0],type:.[1]},created_at:.[2],body:.[3]})' <<<"$2" > "$T/fx/thread-$1"; }
reset; fx 31 "$H1"
thread 31 '[["operator","User","2026-09-24T12:14:18Z","HOLD: do not enqueue or merge automatically. TK-3108 changes a user sign-in identity."],
            ["operator","User","2026-09-24T12:20:36Z","## Review round (lane F): answers to the harness review. Pushed 8b1461f5."]]'
ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-23 a HOLD comment on the PR must never post, even after a later neutral comment (got $(posts); log: $(cat "$MC_LOG"))"
grep -q "AUTOENQUEUE $SLUG#31 not enqueued at ${H1:0:8}: pr-hold — .*HOLD: do not enqueue" "$MC_LOG" && ok || bad "AT-23 the skip line names the PR hold and quotes it (log: $(cat "$MC_LOG"))"
grep -q "GET repos/$SLUG/issues/31/comments" "$T/gh-calls.txt" && ok || bad "AT-23 the PR's own thread must be read (calls: $(cat "$T/gh-calls.txt"))"
# a later human RESUME lifts it
reset; fx 31 "$H1"
thread 31 '[["operator","User","2026-09-24T12:14:18Z","HOLD: do not enqueue."],["operator","User","2026-09-24T13:00:00Z","RESUME — identity change reviewed, ship it."]]'
ae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-23b a later RESUME on the PR lifts the hold (got $(posts); log: $(cat "$MC_LOG"))"
# a bot's HOLD is not an instruction
reset; fx 31 "$H1"
thread 31 '[["coderabbitai[bot]","Bot","2026-09-24T12:14:18Z","HOLD: nitpicks pending"]]'
ae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-23c a bot comment saying HOLD must not hold (got $(posts); log: $(cat "$MC_LOG"))"
# an unreadable thread is never "no hold"
reset; fx 31 "$H1"; touch "$T/fx/thread-down-31"; ae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-23d an unreadable PR thread must never post (got $(posts))"
grep -q "pr-hold-read" "$MC_LOG" && ok || bad "AT-23d the skip line says the thread was unreadable (log: $(cat "$MC_LOG"))"
# and HOLD in prose ("until the operator lifts the hold") holds nothing
reset; fx 31 "$H1"
thread 31 '[["operator","User","2026-09-24T12:14:18Z","the ticket hold was lifted earlier; nothing to do here"]]'
ae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-23e lower-case prose about a hold must not hold (got $(posts); log: $(cat "$MC_LOG"))"

# AT-24 THE REQUIRED CHECKS ARE THE REPO'S OWN ADMISSION CHECKS (Lane D,
# 2026-09-24). The gate read ONE check name, `Build + Unit tests`, which is
# project-5's. No cromford check carries it, so every READY row there was
# refused at G4. With MC_AUTOENQUEUE_CHECK empty the names are the
# `check-success` conditions under `queue_conditions:` in the repo's own
# .mergify.yml — what Mergify requires to ADMIT a PR. `merge_conditions:` are
# evaluated on the batch draft, and a check that runs only there reads
# completed/skipped on the PR head (review of #2215, the #2220 .mergify.yml), so
# requiring it here would refuse every row for ever. The yml is served through a
# stub of the conductor's cached policy read, mc_policy_get.
# mgyml <queue-names-csv> [merge-only-names-csv] — a #2220-shaped config: two
# rules, admission checks under queue_conditions, the superset under
# merge_conditions.
mgyml() {
  local q m r
  q=$(tr ',' '\n' <<<"$1" | sed '/^$/d; s/.*/      - check-success = "&"/')
  m=$( { tr ',' '\n' <<<"$1"; tr ',' '\n' <<<"${2:-}"; } | sed '/^$/d; s/.*/      - check-success = "&"/')
  r="queue_rules:
  - name: hotfix
    queue_conditions:
      - base = main
      - label = fix-main-red
$q
    merge_conditions:
$m
    merge_method: merge
  - name: default
    queue_conditions:
      - base = main
$q
    merge_conditions:
$m
    merge_method: merge
pull_request_rules:
  - name: queue on the harness label
    conditions:
      - check-success = \"Never an admission check\"
    actions:
      queue:
        name: default"
  jq -nc --arg c "$(printf '%s\n' "$r" | base64 | tr -d '\n')" '{content:$c}' > "$T/fx/mgyml"
}
runs() { # runs name=conclusion... — one completed run per name on the head
  local a out="[]"
  for a in "$@"; do out=$(jq -c --arg n "${a%%=*}" --arg c "${a#*=}" '. + [{name:$n,status:"completed",conclusion:$c,started_at:"2026-09-24T10:00:00Z"}]' <<<"$out"); done
  jq -nc --argjson r "$out" '{total_count:($r|length),check_runs:$r}'
}
# mgae <row...> — ae with the conductor's policy reader present (fixture mgyml;
# mgyml-down = the read failed, rc 75).
mgae() { ( mc_policy_get() { [ -f "$T/fx/mgyml-down" ] && return 75; printf -v "$1" '%s' "$(cat "$T/fx/mgyml")"; }
           unset MC_AUTOENQUEUE_CHECK; ae "$@" ); }
S="Syntax + shellcheck + config integrity"; D="Test determinism lint"; P="Prompt replay evals (prompts/** only)"
ONLY_MERGE="Pure-logic gate fixtures,Tests cannot touch a real harness,Mission Control SPA — unit tests + build,Jobs worker — routes + schema"
# AT-24: the #2220 shape. The three admission checks green, the four merge-only
# checks SKIPPED on the PR head (they run on the batch draft), no 'Build + Unit
# tests' anywhere: posts.
reset; fx 31 "$H1"; mgyml "$S,$D,$P" "$ONLY_MERGE"
runs "$S=success" "$D=success" "$P=success" "Pure-logic gate fixtures=skipped" "Tests cannot touch a real harness=skipped" \
     "Mission Control SPA — unit tests + build=skipped" "Jobs worker — routes + schema=skipped" > "$T/fx/checks-$H1"
mgae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-24 admission checks green, merge-only checks skipped on the head (#2220 shape) posts (got $(posts); log: $(cat "$MC_LOG"))"
# AT-24b one admission check red: never
reset; fx 31 "$H1"; mgyml "$S,$D,$P" "$ONLY_MERGE"; runs "$S=failure" "$D=success" "$P=success" > "$T/fx/checks-$H1"
mgae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-24b one admission check red must never post (got $(posts))"
grep -q "'$S' is completed/failure" "$MC_LOG" && ok || bad "AT-24b the skip names the red admission check (log: $(cat "$MC_LOG"))"
# AT-24c an admission check with no run on the head: never
reset; fx 31 "$H1"; mgyml "$S,$D,$P" "$ONLY_MERGE"; runs "$S=success" "$D=success" > "$T/fx/checks-$H1"
mgae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-24c an admission check with no run on the head must never post (got $(posts))"
# AT-24d the .mergify.yml read failed: never, and it says so
reset; fx 31 "$H1"; touch "$T/fx/mgyml-down"; runs "$S=success" "$D=success" "$P=success" > "$T/fx/checks-$H1"
mgae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-24d an unreadable .mergify.yml must never post (got $(posts))"
grep -q "not enqueued at ${H1:0:8}: check — the repo's required checks could not be read" "$MC_LOG" && ok || bad "AT-24d the skip says the required checks were unreadable (log: $(cat "$MC_LOG"))"
# AT-24e an explicit knob value beats the derivation
reset; fx 31 "$H1"; mgyml "$S,$D,$P" "$ONLY_MERGE"; green CI > "$T/fx/checks-$H1"
( mc_policy_get() { printf -v "$1" '%s' "$(cat "$T/fx/mgyml")"; }; MC_AUTOENQUEUE_CHECK=CI ae "$(row 31 "$H1")" )
[ "$(posts)" = 1 ] && ok || bad "AT-24e MC_AUTOENQUEUE_CHECK=CI still decides alone (got $(posts); log: $(cat "$MC_LOG"))"
# AT-24f a queue rule naming no admission check falls back to the documented default name
reset; fx 31 "$H1"; mgyml "" "$S"; mgae "$(row 31 "$H1")"
[ "$(posts)" = 1 ] && ok || bad "AT-24f no admission check in queue_conditions falls back to 'Build + Unit tests' (got $(posts); log: $(cat "$MC_LOG"))"
# AT-24g the registry default is EMPTY, so the derivation is what a box runs
[ "$(jq -r '.knobs[] | select(.env=="MC_AUTOENQUEUE_CHECK") | .default' "$DIR/catalog/lanes.d/merge-conductor.json")" = "" ] \
  && ok || bad "AT-24g the MC_AUTOENQUEUE_CHECK registry default must be empty (derive from .mergify.yml)"
# AT-24h ONE check-runs read per row, however many names are required (review
# nit 2): the unfiltered page, not one ?check_name= read per name.
reset; fx 31 "$H1"; mgyml "$S,$D,$P" "$ONLY_MERGE"; runs "$S=success" "$D=success" "$P=success" > "$T/fx/checks-$H1"
mgae "$(row 31 "$H1")"
[ "$(grep -c "commits/$H1/check-runs" "$T/gh-calls.txt")" = 1 ] && ok || bad "AT-24h one check-runs read per row (calls: $(grep check-runs "$T/gh-calls.txt"))"
grep -q "check-runs?check_name=" "$T/gh-calls.txt" && bad "AT-24h no per-name check read" || ok
# AT-24i a check-runs page that does not hold every run is unreadable, not green
reset; fx 31 "$H1"; mgyml "$S" ""; jq -c '.total_count = 250' <<<"$(runs "$S=success")" > "$T/fx/checks-$H1"
mgae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-24i a partial check-runs page must never post (got $(posts))"

# AT-27 TWO TICKS, ONE ASK (review nit 1). A keyed tick and the cron tick can
# both pass the gates for the same (PR, head). The ledger is re-read under a
# per-PR flock right before the POST: a row another tick enqueued after this
# one's G2 read is never asked twice.
reset; fx 31 "$H1"
( job_ledger_get() { # a miss at G2, then the other tick's enqueued row
    local n; n=$(cat "$T/fx/lg-n" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/fx/lg-n"
    [ "$n" -ge 1 ] && { printf enqueued; return 0; }; return 2; }
  ae "$(row 31 "$H1")" )
[ "$(posts)" = 0 ] && ok || bad "AT-27 a row enqueued by another tick between the gates and the POST is not asked again (got $(posts); log: $(cat "$MC_LOG"))"
grep -q "already enqueued by another tick" "$MC_LOG" && ok || bad "AT-27 the skip says so (log: $(cat "$MC_LOG"))"

# AT-28 THE LOCKED RE-READ ALSO HOLDS THE FAILED-N CAP (review round 2 of #2215).
# G2 read a miss; by the time this tick holds the per-PR lock another tick has
# spent the last retry (failed-3). The re-read must refuse, not POST a fourth.
reset; fx 31 "$H1"
( job_ledger_get() {
    local n; n=$(cat "$T/fx/lg-n" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/fx/lg-n"
    [ "$n" -ge 1 ] && { printf failed-3; return 0; }; return 2; }
  ae "$(row 31 "$H1")" )
[ "$(posts)" = 0 ] && ok || bad "AT-28 a head out of retries by the locked re-read is never POSTed again (got $(posts); log: $(cat "$MC_LOG"))"
grep -q "out of retries" "$MC_LOG" && ok || bad "AT-28 the skip says the head is out of retries (log: $(cat "$MC_LOG"))"
# AT-28b under the cap (failed-1) the locked re-read still sends
reset; fx 31 "$H1"
( job_ledger_get() {
    local n; n=$(cat "$T/fx/lg-n" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/fx/lg-n"
    [ "$n" -ge 1 ] && { printf failed-1; return 0; }; return 2; }
  ae "$(row 31 "$H1")" )
[ "$(posts)" = 1 ] && ok || bad "AT-28b a head under the retry cap still posts (got $(posts); log: $(cat "$MC_LOG"))"

# AT-29 .mergify.yml SHAPES THE ADMISSION READER MUST NOT MISREAD (review round 2
# of #2215). YAML lets a block list sit at the SAME indent as its key, and lets a
# list be written inline as [ ... ]. The reader used to end the block at a
# same-indent `-` (reading no names, so the legacy fallback name) and never saw an
# inline list. A shape it cannot read (a [ list over several lines) is refused
# with a named log line, never guessed.
mgraw() { jq -nc --arg c "$(printf '%s\n' "$1" | base64 | tr -d '\n')" '{content:$c}' > "$T/fx/mgyml"; }
admit() { ( mc_policy_get() { printf -v "$1" '%s' "$(cat "$T/fx/mgyml")"; }; ae_mergify_admit_checks "$SLUG" ); }
mgraw 'queue_rules:
  - name: default
    queue_conditions:
    - base = main
    - check-success = "Same indent A"
    - "check-success = Same indent B"
    merge_conditions:
    - check-success = "Merge only"'
[ "$(admit | paste -sd'|' -)" = "Same indent A|Same indent B" ] && ok \
  || bad "AT-29a same-indent block list items are admission checks (got: $(admit | paste -sd'|' -))"
mgraw 'queue_rules:
  - name: default
    queue_conditions: [ base = main, "check-success = Inline A", check-success = Inline B, "check-success=Inline, with comma" ]  # a comment
    merge_conditions: [ "check-success = Merge only" ]'
[ "$(admit | paste -sd'|' -)" = "Inline A|Inline B|Inline, with comma" ] && ok \
  || bad "AT-29b an inline [ ... ] list is read, quote-aware (got: $(admit | paste -sd'|' -))"
SPLIT='queue_rules:
  - name: default
    queue_conditions: [ base = main,
      "check-success = Split" ]'
mgraw "$SPLIT"
admit >/dev/null; [ "$?" = 3 ] && ok || bad "AT-29c a [ list over several lines is refused rc 3, not guessed"
reset; fx 31 "$H1"; mgraw "$SPLIT"; runs "Split=success" "Build + Unit tests=success" > "$T/fx/checks-$H1"
mgae "$(row 31 "$H1")"
[ "$(posts)" = 0 ] && ok || bad "AT-29c an unreadable queue_conditions shape never posts (got $(posts))"
grep -q "AUTOENQUEUE $SLUG .mergify.yml queue_conditions shape not understood" "$MC_LOG" && ok \
  || bad "AT-29c the refusal is a named log line (log: $(cat "$MC_LOG"))"


# AT-24j an `or:` (alternatives) or `not:` block under queue_conditions is NOT a
# list of required checks (lead MINOR 2 on #2215): reading every check-success
# line in it made "A or B" into "A and B" and "not C" into "C must succeed", so
# a row could be refused at G4 for ever. Their subtrees are skipped; `and:` is
# still read.
mgraw 'queue_rules:
  - name: default
    queue_conditions:
      - base = main
      - check-success = "Plain"
      - or:
          - check-success = "Alt one"
          - check-success = "Alt two"
      - not:
          - check-success = "Never"
      - and:
          - check-success = "Both A"
          - check-success = "Both B"
    merge_conditions:
      - check-success = "Merge only"'
[ "$(admit | paste -sd'|' -)" = "Plain|Both A|Both B" ] && ok \
  || bad "AT-24j or:/not: subtrees are skipped, and: is read (got: $(admit | paste -sd'|' -))"

# ============================================================================
# AT-13 — the WHOLE bin/merge-conductor.sh in a scratch tree.
# ============================================================================
export PATH="${PATH#"$T/ubin:"}"
unset MC_TICK_ID MC_TICK_DIR
unset -f mc_log mc_alert mc_record_for mc_issue_of mc_verdict vd_standing to_lane_lead_fence to_lane_hold bg_scan bg_scan_read \
  main_red_exempt hotfix_pr_is mc_hotfix_proof flag_active job_ledger_get job_ledger_put job_artifact_put
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/autoenqueue.sh" "$DIR/bin/lib/pr-dep-gate.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"; cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
REC="$T/h/builds/pool-mgfy-MG-31-202609120001"; mkdir -p "$REC"
echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$T/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/c-calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  # AT-25 sets c-mgfy-check: Mergify's own queue check, the conductor's witness.
  # Otherwise the head's one required check, green: the self-enqueue's G4 reads
  # this unfiltered page once per row since the #2215 review (nit 2).
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 "\$(cat "$T/c-mgfy-check" 2>/dev/null || echo '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}')" ;;
  *"api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue"*)
    printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/c-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/c-cond-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-cond-cmds.txt"
    # AT-30c: a flag that appears DURING the witness poll (after the label).
    # merge-conductor-merge-off = the merge switch itself going OFF.
    case "\$(cat "$T/c-at30c-touch" 2>/dev/null)" in
      '') ;;
      merge-conductor-merge-off) rm -f "$T/h/flags/merge-conductor-merge" ;;
      *) touch "$T/h/flags/\$(cat "$T/c-at30c-touch")" ;;
    esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-merges.txt"; exit 0 ;;
  # The REST merge (gh_pr_merge_rest, mc_merge's first path) is a merge too.
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 "\$(cat "$T/c-thread" 2>/dev/null || echo '[]')" ;;
  # A second READY PR (#32) for two-PR ticks: its thread, diff and pull read.
  # AT-30c: a HOLD on #32's own thread that lands after its label went on.
  *"api -i -X GET repos/$SLUG/issues/32/comments"*)
    if [ -f "$T/c-hold-32-after-label" ] && grep -q "issues/32/labels" "$T/c-cond-cmds.txt" 2>/dev/null; then
      restpr --raw 200 '[{"user":{"login":"operator","type":"User"},"created_at":"2026-09-24T12:14:18Z","body":"HOLD: do not merge this one yet."}]'
    else restpr --raw 200 '[]'; fi ;;
  *"api -i -X GET repos/$SLUG/pulls/32"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/$SLUG/pulls/32"*) restpr OPEN "$H2" ticket/mg-32 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) if [ -f "$T/c-diff" ]; then restpr --diff "\$(cat "$T/c-diff")"; else restpr --diff; fi ;;
  *"api repos/$SLUG/pulls/31 -q"*) cat "$T/c-body" 2>/dev/null ;;
  *"api repos/$SLUG/issues/32 -q"*) echo "open -" ;;
  # The ticket-hold read (bin/lib/ticket-ownership.sh, AT-30c): an open ticket
  # with no hold label.
  *"api repos/$SLUG/issues/31"|*"api repos/$SLUG/issues/32") printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\${2##*/}" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  # The PR body rides the REST pull read too: since BH-1735 pdg_hold reads it
  # through gh_rest_var (this arm) whenever the conductor has gh-rest loaded,
  # and only the raw \`-q\` arm above when it has not. AT-22 dependency sets it.
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "$H1" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "\$(cat "$T/c-body" 2>/dev/null)" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# The worker: a file-backed ledger (PUT appends, GET answers the last row), no
# standing verdicts, and 404 for everything else.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*/api/ledger) printf '%s\n' "\$D" >> "$T/c-ledger.jsonl"; printf '{"ok":true}\n200\n' ;;
  "PUT "*/artifacts) printf '%s\n' "\$D" >> "$T/c-artifacts.jsonl"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/ledger\?*)
    K=\$(printf '%s' "\${URL#*key=}" | sed 's/&.*//' | jq -Rr '@text|gsub("%3A";":")|gsub("%2F";"/")|gsub("%40";"@")')
    R=\$(jq -c --arg k "\$K" 'select(.kind=="autoenqueue" and .key==\$k)' "$T/c-ledger.jsonl" 2>/dev/null | tail -1)
    if [ -n "\$R" ]; then printf '{"ledger":%s}\n200\n' "\$R"; else printf '{"error":"not found"}\n404\n'; fi ;;
  # AT-30b: a lead BLOCK row on #32 that lands AFTER its enqueue label went on
  # (i.e. during the witness poll), when c-block-32-after-label is set.
  "GET "*/api/verdicts\?*pr=32*)
    if [ -f "$T/c-block-32-after-label" ] && grep -q "issues/32/labels" "$T/c-cond-cmds.txt" 2>/dev/null; then
      printf '{"standing":{"verdict":"BLOCK","source":"lead","id":7,"created_at":"2026-09-24T12:00:00Z","report_url":null,"reviewer":"lead"}}\n200\n'
    else printf '{"standing":null}\n200\n'; fi ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"; : > "$T/c-ledger.jsonl"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
# MC_MERGE_BUDGET=0: the conductor's OWN READY enqueue spends nothing this tick,
# so the one POST this test counts can only be the BH-1668 step's.
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
cposts() { grep -c . "$T/c-posts.txt" 2>/dev/null || true; }
: > "$T/c-posts.txt"; run_tick
[ "$(cposts)" = 1 ] && ok || bad "AT-13 the whole conductor posts @mergifyio queue once (posts: $(cposts); log: $(grep -i 'autoenqueue\|31' "$T/h/logs/merge-conductor.log" | tail -8))"
grep -q 'GH_TOKEN=pat-default$' "$T/c-posts.txt" && ok || bad "AT-13 the conductor's post runs under the PAT"
jq -e --arg k "$U/31@$H1" 'select(.kind=="autoenqueue" and .key==$k and .status=="enqueued")' "$T/c-ledger.jsonl" >/dev/null && ok || bad "AT-13 the worker ledger carries the enqueued row (got $(cat "$T/c-ledger.jsonl"))"
[ -s "$T/c-merges.txt" ] && bad "AT-13 no gh pr merge ($(cat "$T/c-merges.txt"))" || ok
run_tick
[ "$(cposts)" = 1 ] && ok || bad "AT-13 a second conductor tick does not re-post (posts: $(cposts))"
: > "$T/c-posts.txt"; : > "$T/c-ledger.jsonl"; rm -rf "$T/h/state/merge-conductor" "$T/h/state/tier2-autoenqueue.txt"
touch "$T/h/flags/automerge-disabled"; run_tick
[ "$(cposts)" = 0 ] && ok || bad "AT-13 automerge-disabled: no POST through the conductor"
grep -q "WOULD enqueue $SLUG#31 @${H1:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "AT-13 automerge-disabled: a WOULD line in the conductor log"

# AT-22 the conductor's own holds, through the whole conductor: each one parks
# or holds the row before the READY arm's enqueue point, so the step posts
# nothing (review F1; security review 1-3). Same PR, same APPROVE@head, same
# green check and clean state as AT-13's post; one hold at a time.
rm -f "$T/h/flags/automerge-disabled"
at22() { # at22 <name> — run one tick from a clean slate, expect zero POSTs
  : > "$T/c-posts.txt"; : > "$T/c-ledger.jsonl"; rm -rf "$T/h/state/merge-conductor" "$T/h/state/tier2-autoenqueue.txt"
  : > "$T/h/logs/merge-conductor.log"; run_tick
  [ "$(cposts)" = 0 ] && ok || bad "AT-22 $1: the conductor holds this PR, so no @mergifyio queue (posts: $(cposts); log: $(grep -i 'autoenqueue\|#31' "$T/h/logs/merge-conductor.log" | tail -6))"
  grep -q "AUTOENQUEUE $SLUG#31 not enqueued at ${H1:0:8}: conductor" "$T/h/logs/merge-conductor.log" && ok \
    || bad "AT-22 $1: the refusal names the conductor's hand-off (log: $(grep -i 'autoenqueue' "$T/h/logs/merge-conductor.log" | tail -4))"
}
printf '+++ b/src/agent.ts\n+const model = "claude-opus-5-5";\n' > "$T/c-diff"; at22 iron-law; rm -f "$T/c-diff"
echo "judge provenance: fallback runner wrote this verdict" >> "$REC/pipeline.log"; at22 provenance; : > "$REC/pipeline.log"
touch "$T/h/flags/review-tighten-example-org-mgfy-os"; at22 tightened; rm -f "$T/h/flags/review-tighten-example-org-mgfy-os"
printf 'Depends on #32\n' > "$T/c-body"; at22 dependency; rm -f "$T/c-body"
# The PR-level HOLD through the whole conductor (lead round): the conductor
# clears the head READY, and the step itself refuses on the PR's own thread.
: > "$T/c-posts.txt"; : > "$T/c-ledger.jsonl"; rm -rf "$T/h/state/merge-conductor" "$T/h/state/tier2-autoenqueue.txt"
: > "$T/h/logs/merge-conductor.log"
printf '[{"user":{"login":"operator","type":"User"},"created_at":"2026-09-24T12:14:18Z","body":"HOLD: do not enqueue or merge automatically."}]' > "$T/c-thread"; run_tick; rm -f "$T/c-thread"
[ "$(cposts)" = 0 ] && ok || bad "AT-22 pr-hold: a HOLD on the PR itself posts nothing through the whole conductor (posts: $(cposts))"
grep -q "AUTOENQUEUE $SLUG#31 not enqueued at ${H1:0:8}: pr-hold — " "$T/h/logs/merge-conductor.log" && ok \
  || bad "AT-22 pr-hold: the refusal names the PR hold (log: $(grep -i 'autoenqueue' "$T/h/logs/merge-conductor.log" | tail -4))"
# ...and with every hold lifted the same fixture posts again (the control).
: > "$T/c-posts.txt"; : > "$T/c-ledger.jsonl"; rm -rf "$T/h/state/merge-conductor" "$T/h/state/tier2-autoenqueue.txt"; run_tick
[ "$(cposts)" = 1 ] && ok || bad "AT-22 control: with no hold the same fixture posts once (posts: $(cposts))"

# AT-25 A MERGIFY ENQUEUE IS NOT A MERGE, SO IT DOES NOT QUEUE ON THE PROJECT
# MERGE LOCK (Lane D, 2026-09-24). mc_enqueue_mergify polls for Mergify's
# witness for up to MC_MERGIFY_WAIT_S (90s) and it ran INSIDE
# mc_merge_locked, whose other waiters give up after MC_MERGE_LOCK_WAIT (120s):
# about two READY PRs per project per tick were enqueued and the rest logged
# "another PR of <p> held the project merge lock" and waited a tick, in flock's
# random order. The lock guards racing main; a label plus a comment does not
# touch main. The degraded direct merge (rc 3) still takes it. Driven with the
# REAL flock: the fixture holds the project's merge lock for the whole tick.
rm -f "$T/fakebin/flock"
run_tick_env() { ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
at25_reset() { : > "$T/c-posts.txt"; : > "$T/c-ledger.jsonl"; : > "$T/c-cond-cmds.txt"; : > "$T/c-merges.txt"
  rm -rf "$T/h/state/merge-conductor" "$T/h/state/tier2-autoenqueue.txt"; : > "$T/h/logs/merge-conductor.log"; }
if command -v flock >/dev/null 2>&1; then
  at25_reset
  printf '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":"In merge queue"},"app":{"slug":"mergify"}}]}' > "$T/c-mgfy-check"
  MLK="$T/h/locks/merge-conductor-mgfy-merge.lock"; mkdir -p "$T/h/locks"
  ( exec 8>"$MLK"; flock -w 5 8 || exit 1; exec sleep 30 ) >/dev/null 2>&1 &
  HOLDER=$!
  i=0; while flock -n "$MLK" true 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  run_tick_env MC_MERGE_BUDGET=1 MC_MERGE_LOCK_WAIT=1 MC_AUTOENQUEUE=0
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  grep -q "labels" "$T/c-cond-cmds.txt" && ok || bad "AT-25 with the project merge lock held, the conductor still adds the queue label (cmds: $(cat "$T/c-cond-cmds.txt"); log: $(grep '#31' "$T/h/logs/merge-conductor.log" | tail -4))"
  grep -q "$SLUG#31 enqueued in the mergify merge queue at ${H1:0:8}" "$T/h/logs/merge-conductor.log" && ok \
    || bad "AT-25 the enqueue is witnessed and logged (log: $(grep '#31' "$T/h/logs/merge-conductor.log" | tail -4))"
  grep -q "$SLUG#31 not enqueued this tick: another PR of mgfy held the project merge lock" "$T/h/logs/merge-conductor.log" \
    && bad "AT-25 a Mergify enqueue must not wait on the project merge lock" || ok
  [ -s "$T/c-merges.txt" ] && bad "AT-25 no direct merge ($(cat "$T/c-merges.txt"))" || ok
  rm -f "$T/c-mgfy-check"
else
  echo "flock missing — AT-25 skipped"
fi

# AT-26 READY WITH MERGES OFF SAYS SO (Lane D). The READY arm returned with no
# line at all when the merge switch was off (a project pause, observe, a
# missing merge flag): the row sat READY with nothing in the log naming why.
at25_reset; rm -f "$T/h/flags/merge-conductor-merge"
run_tick_env MC_AUTOENQUEUE=0
grep -q "$SLUG#31 READY on ${H1:0:8} and NOT enqueued: merges are off this tick" "$T/h/logs/merge-conductor.log" && ok \
  || bad "AT-26 a READY row with merges off names the reason (log: $(grep '#31' "$T/h/logs/merge-conductor.log" | tail -4))"
run_tick_env MC_AUTOENQUEUE=0
[ "$(grep -c "$SLUG#31 READY on ${H1:0:8} and NOT enqueued: merges are off" "$T/h/logs/merge-conductor.log")" = 1 ] && ok \
  || bad "AT-26 the reason is said once per (PR, head), not every tick"
touch "$T/h/flags/merge-conductor-merge"

# AT-30 A SILENT QUEUE HOLDS; NOTHING MERGES AROUND IT (BH-2199; the operator
# 2026-09-25: the queue owns main).
# TEST-CHANGE, REVERSED ON PURPOSE. In #2215's review rounds AT-30 pinned the
# opposite policy (the operator 2026-09-24): the 09-12 no-stall fallback merged a PR
# directly when Mergify stayed silent, re-checking every gate under the merge
# lock first (mc_merge_rechecked). On 2026-09-25 the operator chose main's BH-2199 hold
# instead, so the fallback, its re-check and the rc 98 arm are gone, and AT-30
# now asserts what happens: two READY PRs, queue silent (no witness), one tick
# with the enqueue lock-free (Lane D) — each PR is HELD, is NOT merged, and the
# hold records a `mergifyhold <key> <head>` row. The same fixtures that made a
# gate appear DURING the witness poll (a lead BLOCK, a main-red freeze, the kill
# switch, the merge switch going off, a HOLD on the thread) still run: with no
# direct merge on the rc-3 arm, none of them can produce one either.
ATT="$T/h/state/merge-conductor/attempts.txt"
at30_held() { # at30_held <label> — neither PR merged; both held, with their mergifyhold rows
  [ -s "$T/c-merges.txt" ] && bad "$1: a silent queue must never be merged around (merges: $(cat "$T/c-merges.txt"))" || ok
  grep -q "^mergifyhold $SLUG#31 $H1\$" "$ATT" 2>/dev/null && ok || bad "$1: #31's hold records a mergifyhold row (attempts: $(grep mergifyhold "$ATT" 2>/dev/null))"
  grep -q "$SLUG#31 MERGE_HELD: .*NOT merged directly" "$T/h/logs/merge-conductor.log" && ok \
    || bad "$1: #31 is logged MERGE_HELD, not merged (log: $(grep -E '#31' "$T/h/logs/merge-conductor.log" | tail -4))"
  grep -q "re-check under the merge lock\|re-checked under the project merge lock" "$T/h/logs/merge-conductor.log" \
    && bad "$1: there is no direct merge, so no re-check line (log: $(grep -E 're-check' "$T/h/logs/merge-conductor.log" | tail -2))" || ok
}
at30_setup() {
  at25_reset; rm -f "$T/c-block-32-after-label"
  REC32="$T/h/builds/pool-mgfy-MG-32-202609120002"; mkdir -p "$REC32"
  echo "PR_CREATED $U/32" > "$REC32/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC32/review.md"
  echo "$H2" > "$REC32/reviewed-sha"; : > "$REC32/pipeline.log"
  cp "$T/list.json" "$T/list.json.at30"
  cat > "$T/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]},
 {"number":32,"url":"$U/32","headRefOid":"$H2","headRefName":"ticket/mg-32","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
  cp "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$T/h/bin/lib/"
}
at30_teardown() { mv "$T/list.json.at30" "$T/list.json"; scratch_rm "$REC32"; rm -f "$T/h/bin/lib/block-gate.sh" "$T/h/bin/lib/verdicts.sh" "$T/c-block-32-after-label"; }
at30_setup
run_tick_env MC_MERGE_BUDGET=2 MC_AUTOENQUEUE=0
at30_held AT-30a
grep -q "^mergifyhold $SLUG#32 $H2\$" "$ATT" 2>/dev/null && ok || bad "AT-30a #32's hold records a mergifyhold row too (attempts: $(grep mergifyhold "$ATT" 2>/dev/null))"
grep -q "$SLUG#32 MERGE_HELD: .*NOT merged directly" "$T/h/logs/merge-conductor.log" && ok \
  || bad "AT-30a #32 is logged MERGE_HELD, not merged (log: $(grep -E '#32' "$T/h/logs/merge-conductor.log" | tail -4))"
at30_teardown
at30_setup; touch "$T/c-block-32-after-label"
run_tick_env MC_MERGE_BUDGET=2 MC_AUTOENQUEUE=0
at30_held AT-30b
at30_teardown

# AT-30c each gate that appears DURING the witness poll: still held, never merged.
at30c() { # at30c [env...] — one tick; the lead list is supplied (nobody here is a lead)
  run_tick_env MC_MERGE_BUDGET=2 MC_AUTOENQUEUE=0 TO_LEAD_AUTHORS=some-lead-bot "$@"
}
at30_setup; cp "$DIR/bin/lib/main-red-gate.sh" "$T/h/bin/lib/"; echo main-red-mgfy > "$T/c-at30c-touch"; at30c
[ -s "$T/c-merges.txt" ] && bad "AT-30c a main-red freeze raised during the poll: nothing merges (merges: $(cat "$T/c-merges.txt"))" || ok
rm -f "$T/h/flags/main-red-mgfy" "$T/c-at30c-touch" "$T/h/bin/lib/main-red-gate.sh"; at30_teardown
at30_setup; echo automerge-disabled > "$T/c-at30c-touch"; at30c
[ -s "$T/c-merges.txt" ] && bad "AT-30c the kill switch raised during the poll: nothing merges (merges: $(cat "$T/c-merges.txt"))" || ok
rm -f "$T/h/flags/automerge-disabled" "$T/c-at30c-touch"; at30_teardown
at30_setup; echo merge-conductor-merge-off > "$T/c-at30c-touch"
at30c
[ -s "$T/c-merges.txt" ] && bad "AT-30c the merge switch turned off during the poll: nothing merges (merges: $(cat "$T/c-merges.txt"))" || ok
touch "$T/h/flags/merge-conductor-merge"; rm -f "$T/c-at30c-touch"; at30_teardown
at30_setup; cp "$DIR/bin/lib/ticket-ownership.sh" "$T/h/bin/lib/"; touch "$T/c-hold-32-after-label"; at30c
at30_held AT-30c-hold
rm -f "$T/c-hold-32-after-label" "$T/h/bin/lib/ticket-ownership.sh"; at30_teardown

echo "tier2-autoenqueue-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
