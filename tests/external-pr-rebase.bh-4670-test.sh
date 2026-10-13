#!/bin/bash
# tests/external-pr-rebase.bh-4670-test.sh — BH-4664.3 (BH-4670): a dirty
# EXTERNAL PR gets main merged into its branch, once per head.
#
# WHAT IS CLAIMED. An outsider's open PR on an opted-in project whose branch is
# `dirty`, with a quiet author, reaches br_xpr_rebase (bin/lib/br/opt/extrebase.sh)
# through the REAL tick: br_candidates -> br_one -> br_opt_external_rung ->
# br_xpr_gate. The hook takes the conductor's per-PR lock FIRST, then checks and
# writes the `ext-rebase` pr_attempts row on the head, then calls mc_rebase, and
# posts one fixed comment for a merge, a conflict or a red gate. A second tick
# on the same head, a conductor that owns the PR, a held lock, an author still
# pushing or an unreadable attempts ledger make no call. Nothing closes the PR.
#
# The REAL bin/blocked-resolver.sh runs each tick over a scratch $HARNESS with a
# fake `gh` (REST envelope from files, every call and comment body recorded).
# mc_rebase is a recording stub appended to the scratch copy of
# bin/lib/mc/rebase.sh; pr_attempt_has / pr_attempt_put are the REAL functions
# from bin/lib/jobs/jobs.sh over a _jobs_req stub on a scratch file.
#
# Run from anywhere: tests/external-pr-rebase.bh-4670-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos" "$T/f"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
# mc_rebase: a recording stub defined AFTER the real one, so the lane calls it.
cat >> "$H/bin/lib/mc/rebase.sh" <<EOF

mc_rebase() {
  printf '%s\n' "\$*" >> "$T/rebase.calls"
  cat "$T/f/mc-out" 2>/dev/null
  return "\$(cat "$T/f/mc-rc" 2>/dev/null || echo 4)"
}
EOF
OPTD="$H/bin/lib/br/opt"; mkdir -p "$OPTD"
XMOD="$DIR/bin/lib/br/opt/external.sh"
RMOD="$DIR/bin/lib/br/opt/extrebase.sh"
chmod +x "$H/bin/"*.sh
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = harness\n\temail = bot@harness.test\n' > "$GIT_CONFIG_GLOBAL"
export HARNESS_OPERATOR_LOGIN=operator
printf 'project-3 o/project-3 - - 2 box-project-3 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" project-3
: > "$H/env/global.env"
for f in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh beat.sh lane-alert.sh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/side.txt"\nexit 0\n' "$T" > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# The jobs client: settings from $T/f/knob-<key>, and the REAL pr_attempt_has /
# pr_attempt_put lifted out of bin/lib/jobs/jobs.sh over a _jobs_req that keeps
# the pr_attempts rows in $T/attempts (one `repo num kind sha` line each).
# $T/f/attempts-outage makes every pr_attempts request an outage (rc 1).
{ cat <<EOF
JOBS_BOX=hub
queue_put() { printf 'put %s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
setting_get() {
  local a; a=\$(cat "$T/f/knob-\$1" 2>/dev/null) || return 2
  case "\$a" in row:*) printf '%s' "\${a#row:}"; return 0 ;; outage) return 1 ;; *) return 2 ;; esac
}
_jobs_req() {
  case "\$2" in /api/pr-attempts*) ;; *) return 1 ;; esac
  [ -f "$T/f/attempts-outage" ] && return 1
  case "\$1" in
    PUT) printf '%s\n' "\$(printf '%s' "\$3" | jq -r '[.repo, (.number|tostring), .kind, .sha] | join(" ")')" >> "$T/attempts"
         echo '{}'; return 0 ;;
    GET) local q="\${2#*\?}" r n k s
         r=\$(printf '%s' "\$q" | sed -n 's/.*repo=\([^&]*\).*/\1/p' | sed 's/%2F/\//g')
         n=\$(printf '%s' "\$q" | sed -n 's/.*number=\([^&]*\).*/\1/p')
         k=\$(printf '%s' "\$q" | sed -n 's/.*kind=\([^&]*\).*/\1/p')
         s=\$(printf '%s' "\$q" | sed -n 's/.*sha=\([^&]*\).*/\1/p')
         grep -qxF "\$r \$n \$k \$s" "$T/attempts" 2>/dev/null && { echo '{}'; return 0; }
         return 2 ;;
  esac
  return 1
}
EOF
  awk '/^pr_attempt_(put|has)\(\) \{/{on=1} on{print} on&&/^\}/{on=0}' "$DIR/bin/lib/jobs/jobs.sh"
} > "$H/bin/jobs-client.sh"
grep -q '^pr_attempt_has()' "$H/bin/jobs-client.sh" && grep -q '^pr_attempt_put()' "$H/bin/jobs-client.sh" \
  || { echo "FAIL: could not lift pr_attempt_has/put out of bin/lib/jobs/jobs.sh"; exit 1; }
touch "$H/flags/fly-pool-project-3"

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
URL='https://github.com/o/project-3/pull/7'
MC_ROWS_F="$H/state/merge-conductor/pr-state.tsv"
LOCKF="$H/locks/merge-conductor-project-3-7.lock"

# PR <head> [mergeable_state] — outsider collaborator-1's PR #7 on agent/TK-245, our repo.
PR() {
  jq -nc --arg h "$1" --arg u "$(ISO 300)" --arg ms "${2:-dirty}" \
    '{number:7, html_url:"https://github.com/o/project-3/pull/7", state:"open", title:"Improve the layout",
      draft:false, updated_at:$u, user:{login:"collaborator-1", type:"User"}, author_association:"COLLABORATOR",
      head:{sha:$h, ref:"agent/TK-245", repo:{full_name:"o/project-3", fork:false}},
      base:{ref:"main"}, merged_at:null, maintainer_can_modify:false, mergeable_state:$ms}' > "$T/f/pr-7.json"
  jq -s . "$T/f/pr-7.json" > "$T/f/list.json"
}
# COMMIT <sha> <age-s>
COMMIT() {
  jq -nc --arg d "$(ISO "$2")" '{sha:"x", commit:{committer:{date:$d}, author:{email:"y@example.com"}}}' \
    > "$T/f/commit-$1.json"
}
MC() { printf '%s' "$1" > "$T/f/mc-rc"; printf '%s' "$2" > "$T/f/mc-out"; }
RESET() { rm -rf "$T/f"/* "$H/state/blocked-resolver" "$OPTD"/* "$H/logs/"* \
                 "$H/state/merge-conductor/"* "$H/locks/"* "${TMPDIR:-/tmp}"/br-open-prs.* 2>/dev/null
          mkdir -p "$T/f"; echo '[]' > "$T/f/list.json"
          : > "$T/gh.txt"; : > "$T/patch.txt"; : > "$T/comments.txt"; : > "$T/rebase.calls"
          : > "$T/attempts"; : > "$T/queue.txt"; : > "$T/side.txt"; : > "$T/run.log"
          rm -rf "$T/bodies"; mkdir -p "$T/bodies"
          printf 'row:1' > "$T/f/knob-external_pr.fix_rounds.project-3"
          printf 'row:60' > "$T/f/knob-external_pr.author_quiet_min"
          printf '%s\n' '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}' > "$T/f/ratelimit.json"
          cp "$XMOD" "$OPTD/external.sh"
          [ "${NO_MODULE:-0}" = 1 ] || cp "$RMOD" "$OPTD/extrebase.sh"; }
export GH_BUDGET_TTL_S=0

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
F="$T/f"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
case "\$1 \$2" in
  "api rate_limit") cat "\$F/ratelimit.json"; exit 0 ;;
esac
if [ "\$1" = api ] && [ "\$2" = -i ] && [ "\$3" = -X ]; then
  M="\$4"; P="\$5"
  case "\$M \$P" in
    "PATCH repos/"*)
      printf '%s\n' "\$*" >> "$T/patch.txt"; send 200 '{"state":"closed"}' ;;
    "POST repos/"*"/comments")
      printf '%s\n' "\$*" >> "$T/comments.txt"
      for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/bodies/\$(grep -c . "$T/comments.txt")" ;; esac; done
      send 201 '{"id":1}' ;;
    "GET repos/o/project-3/pulls") send 200 "\$(cat "\$F/list.json")" ;;
    "GET repos/o/project-3/pulls/"*"/reviews"*) send 200 '[]' ;;
    "GET repos/o/project-3/pulls/"*)
      N=\${P##*/}
      [ -f "\$F/pr-\$N.json" ] || { send 404 '{"message":"Not Found"}'; exit 0; }
      send 200 "\$(cat "\$F/pr-\$N.json")" ;;
    "GET repos/o/project-3/commits/"*)
      S=\${P##*/}
      if [ -f "\$F/commit-\$S.json" ]; then send 200 "\$(cat "\$F/commit-\$S.json")"; else send 404 '{"message":"Not Found"}'; fi ;;
    *) send 200 '[]' ;;
  esac
  exit 0
fi
echo ""
exit 0
EOF
chmod +x "$T/fakebin/gh"
# Any raw push is recorded: the only push this hook makes is mc_rebase's (stubbed).
REALGIT=$(command -v git)
printf '#!/bin/bash\ncase "$1" in push) printf "%%s\\n" "$*" >> "%s/push.txt"; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$T" "$REALGIT" > "$T/fakebin/git"
chmod +x "$T/fakebin/git"
: > "$T/push.txt"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

RC=0
RUN() { RC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           bash "$H/bin/blocked-resolver.sh" project-3 >>"$T/run.log" 2>&1 ) || RC=$?; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
HAS() { grep -qF -- "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
NCALL() { grep -c . "$T/rebase.calls"; }
NCOMM() { grep -c . "$T/comments.txt"; }
NATT() { grep -c ' ext-rebase ' "$T/attempts"; }
BODY() { cat "$T/bodies/$1" 2>/dev/null; }
# R10 is checked after every tick: never a PATCH (close), never an ALERTS line, never a raw push.
BELT() {
  [ "$(grep -c . "$T/patch.txt")" = 0 ] && ok || bad "R10 ($1): the PR must never be PATCHed/closed: $(cat "$T/patch.txt")"
  [ ! -s "$H/logs/ALERTS.log" ] && ok || bad "R10 ($1): no ALERTS line: $(cat "$H/logs/ALERTS.log")"
  [ ! -s "$T/push.txt" ] && ok || bad "R10 ($1): no raw git push: $(cat "$T/push.txt")"
}

# ===========================================================================
# R1: dirty + quiet -> one rebase through the real tick.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 5 "$H2"
RUN
[ "$RC" = 0 ] && ok || bad "R1: the tick must exit 0 (rc $RC): $(tail -3 "$T/run.log")"
[ "$(NCALL)" = 1 ] && [ "$(cat "$T/rebase.calls")" = "o/project-3 project-3 agent/TK-245 $H1 $URL" ] && ok \
  || bad "R1: exactly one mc_rebase <slug> <project> <ref> <head> <url>: '$(cat "$T/rebase.calls")' $(LOG | tail -4)"
[ "$(NATT)" = 1 ] && grep -qxF "o/project-3 7 ext-rebase $H1" "$T/attempts" && ok \
  || bad "R1: one ext-rebase attempt row on H1: $(cat "$T/attempts")"
[ "$(NCOMM)" = 1 ] && grep -qF 'repos/o/project-3/issues/7/comments' "$T/comments.txt" && ok \
  || bad "R1: exactly one comment on #7: $(cat "$T/comments.txt")"
BODY 1 | grep -qF "Merged \`main\` into this branch (was \`${H1:0:12}\`, now \`${H2:0:12}\`)" \
  && BODY 1 | grep -qF 'Your commits are untouched' && ok \
  || bad "R1: the merged comment text: '$(BODY 1)'"
HAS "merged main into agent/TK-245, ${H1:0:8} -> ${H2:0:8} (mc_rebase rc 5)" && ok \
  || bad "R1: the lane log must name the merge: $(LOG | tail -4)"
BELT R1

# R2: a second tick on the same head -> no call, no comment.
RUN
[ "$(NCALL)" = 1 ] && [ "$(NCOMM)" = 1 ] && [ "$(NATT)" = 1 ] && ok \
  || bad "R2: a second tick on H1 must make no call (calls=$(NCALL) comments=$(NCOMM) rows=$(NATT))"
HAS "already tried a rebase on ${H1:0:8}" && ok || bad "R2: the log must say it already tried: $(LOG | tail -3)"
BELT R2

# ===========================================================================
# R3: a conductor row that owns the PR -> no call; WAIT_CI -> call.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 5 "$H2"
printf 'o/project-3#7\tREADY\t0\t%s\t-\t-\t-\t%s\n' "$H1" "$URL" > "$MC_ROWS_F"
RUN
[ "$(NCALL)" = 0 ] && [ "$(NATT)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "R3: a READY conductor row must stop the call and write no row (calls=$(NCALL) rows=$(NATT))"
HAS "conductor holds o/project-3#7 in READY" && ok || bad "R3: the log must name READY: $(LOG | tail -3)"
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 5 "$H2"
printf 'o/project-3#7\tWAIT_CI\t0\t%s\t-\t-\t-\t%s\n' "$H1" "$URL" > "$MC_ROWS_F"
RUN
[ "$(NCALL)" = 1 ] && ok || bad "R3: a WAIT_CI conductor row does not own the rebase (calls=$(NCALL)): $(LOG | tail -3)"
BELT R3

# ===========================================================================
# R4: the author is still pushing -> the tracer gate refuses, no call.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 600; MC 5 "$H2"
RUN
[ "$(NCALL)" = 0 ] && [ "$(NATT)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "R4: an active author means no call, row or comment (calls=$(NCALL) rows=$(NATT) comments=$(NCOMM))"
HAS "AUTHOR_ACTIVE o/project-3#7" && ok || bad "R4: the gate must log AUTHOR_ACTIVE: $(LOG | tail -3)"
BELT R4

# ===========================================================================
# R5: a conflict -> one comment naming the files, and never a second one.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 1 $'src/a.ts\nsrc/b.ts'
RUN
[ "$(NCALL)" = 1 ] && [ "$(NCOMM)" = 1 ] && ok || bad "R5: one call, one comment (calls=$(NCALL) comments=$(NCOMM))"
BODY 1 | grep -qF "We tried to merge \`main\` into this branch and hit conflicts in:" \
  && BODY 1 | grep -qxF ' - `src/a.ts`' && BODY 1 | grep -qxF ' - `src/b.ts`' \
  && BODY 1 | grep -qF "Could you merge \`main\` in and push? We left the branch exactly as it was." && ok \
  || bad "R5: the conflict comment must list both files: '$(BODY 1)'"
RUN
[ "$(NCALL)" = 1 ] && [ "$(NCOMM)" = 1 ] && ok || bad "R5: a second tick: no second call or comment (calls=$(NCALL) comments=$(NCOMM))"
BELT R5
# More than 20 files: 20 listed, then the count of the rest.
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 1 "$(seq -f 'f%g.ts' 1 23)"
RUN
[ "$(BODY 1 | grep -c '^ - `f')" = 20 ] && BODY 1 | grep -qF '…and 3 more' && ok \
  || bad "R5: 23 conflicting files list 20 and '…and 3 more': '$(BODY 1)'"

# ===========================================================================
# R6: the conductor's PR lock is held -> no call, NO attempt row; then it runs.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 5 "$H2"
mkdir -p "$H/locks"
( exec 9>"$LOCKF"; flock 9; touch "$T/f/held"; sleep 30 ) &
HOLDER=$!
for _ in $(seq 1 50); do [ -f "$T/f/held" ] && break; sleep 0.1; done
RUN
[ "$(NCALL)" = 0 ] && [ "$(NATT)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "R6: a held PR lock must make no call and burn no attempt row (calls=$(NCALL) rows=$(NATT))"
HAS "o/project-3#7 is locked by another lane — retried next tick" && ok || bad "R6: the log must say locked: $(LOG | tail -3)"
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
RUN
[ "$(NCALL)" = 1 ] && [ "$(NATT)" = 1 ] && ok || bad "R6: with the lock free the next tick rebases (calls=$(NCALL) rows=$(NATT))"
BELT R6

# ===========================================================================
# R7: the attempts ledger is unreadable -> no call, no write.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 5 "$H2"; touch "$T/f/attempts-outage"
RUN
[ "$(NCALL)" = 0 ] && [ "$(NATT)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "R7: an attempts outage means no call and no row (calls=$(NCALL) rows=$(NATT))"
HAS "pr_attempts unreadable (rc 1) — nothing done" && ok || bad "R7: the log must say unreadable: $(LOG | tail -3)"
BELT R7

# ===========================================================================
# R8: a red gate -> one 'did not push' comment; a lease/hold -> a log line only.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 2 ""
RUN
[ "$(NCALL)" = 1 ] && [ "$(NCOMM)" = 1 ] && BODY 1 | grep -qF 'so we did not push it. The branch is unchanged.' && ok \
  || bad "R8: rc 2 posts the red-gate comment (calls=$(NCALL) comments=$(NCOMM)): '$(BODY 1)'"
RESET; PR "$H3"; COMMIT "$H3" 3660; MC 3 ""
RUN
[ "$(NCALL)" = 1 ] && [ "$(NCOMM)" = 0 ] && ok || bad "R8: rc 3 posts nothing (calls=$(NCALL) comments=$(NCOMM))"
[ "$(LOG | grep -c "no push at ${H3:0:8} (mc_rebase rc 3")" = 1 ] && ok || bad "R8: rc 3 is one log line: $(LOG | tail -3)"
BELT R8

# ===========================================================================
# R9: dirty but nothing to merge -> no comment.
# ===========================================================================
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 0 "$H1"
RUN
[ "$(NCALL)" = 1 ] && [ "$(NCOMM)" = 0 ] && ok || bad "R9: nothing to merge posts nothing (calls=$(NCALL) comments=$(NCOMM))"
HAS "nothing to merge at ${H1:0:8}" && ok || bad "R9: the log must say nothing to merge: $(LOG | tail -3)"
BELT R9

# Observe mode: says what it WOULD do, writes nothing.
RESET; PR "$H1"; COMMIT "$H1" 3660; MC 5 "$H2"
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(NCALL)" = 0 ] && [ "$(NATT)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "observe: no call, row or comment (calls=$(NCALL) rows=$(NATT) comments=$(NCOMM)): $(LOG | tail -3)"
HAS "WOULD merge main into agent/TK-245 at ${H1:0:8} — observe mode" && ok || bad "observe: the WOULD line: $(LOG | tail -3)"

echo "external-pr-rebase.bh-4670: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
