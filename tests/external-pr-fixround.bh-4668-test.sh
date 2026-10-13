#!/bin/bash
# tests/external-pr-fixround.bh-4668-test.sh — BH-4664.1 (BH-4668): the fix
# round on an EXTERNAL PR.
#
# WHAT IS CLAIMED. A quiet, trusted outsider's PR on an opted-in project with a
# standing CHANGES_REQUESTED gets ONE harness fix round per head
# (bin/lib/br/opt/extfix.sh's br_xpr_fix): pushed as the harness identity
# under a lease on that head, with ONE PR comment in the external template
# (old12 -> new12, the first 10 finding lines, the round's commit subjects,
# "the review lane re-reviews"). A parked head, an unreadable park ledger, a
# fork head and an already-worked head spend nothing. A head that moved under
# the lease, or a round that produced nothing, closes nothing. The owning box's
# `--fix-here` entry runs the same external round when the hub's record says
# `external`.
#
# The REAL bin/blocked-resolver.sh runs: a whole tick (br_candidates -> br_one
# -> br_opt_external_rung -> br_xpr_fix -> br_fix_round) for X3/X3b-g/X6, and
# the `--fix-here` entry for X3f/X12. The origin is a real local bare repo, the
# agent is a fake that commits, `gh` is a fake REST envelope that records every
# call and every comment BODY. Assertions are on git objects, the gh call log,
# the comment bodies, the record and the lane log — never on the source text.
#
# Run from anywhere: tests/external-pr-fixround.bh-4668-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos" "$T/f" || exit 1
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$H/bin/" || exit 1
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# Every bin/lib file the resolver sources, transitively (BH-4552).
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
# The re-review is review-prs' job: any mc_rereview call is recorded, and the
# assertion is that there is none.
printf '\nmc_rereview() { printf "%%s\\n" "$*" >> "%s/rereview.txt"; return 1; }\n' "$T" >> "$H/bin/lib/mc/rebase.sh"
OPTD="$H/bin/lib/br/opt"; mkdir -p "$OPTD"
XMOD="$DIR/bin/lib/br/opt/external.sh"
FMOD="$DIR/bin/lib/br/opt/extfix.sh"
chmod +x "$H/bin/"*.sh
# The harness's own git identity: what every round commit must be.
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
# The jobs client. setting_get answers from $T/f/knob-<key>; pr_attempt_has
# from $T/f/park-<sha>: `hit` rc 0, `outage` rc 1, absent rc 2 (a real miss).
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'put %s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
setting_get() {
  local a; a=\$(cat "$T/f/knob-\$1" 2>/dev/null) || return 2
  case "\$a" in row:*) printf '%s' "\${a#row:}"; return 0 ;; outage) return 1 ;; *) return 2 ;; esac
}
pr_attempt_has() {
  printf '%s\n' "\$*" >> "$T/park-calls.txt"
  case "\$(cat "$T/f/park-\$4" 2>/dev/null)" in hit) return 0 ;; outage) return 1 ;; *) return 2 ;; esac
}
EOF
touch "$H/flags/fly-pool-project-3"

# ---------------------------------------------------------------------------
# The real origin: main carries src/widget.ts; feature/x7 is the outsider's
# branch, one commit by collaborator-1 on top. H1 is that commit.
# ---------------------------------------------------------------------------
REALGIT=$(command -v git)
ORIGIN="$T/origin.git"; SEED="$T/seed"
"$REALGIT" init -q --bare "$ORIGIN" && "$REALGIT" -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || exit 1
"$REALGIT" init -q "$SEED" || exit 1
mkdir -p "$SEED/src"
printf 'export const w = (x) => x.y;\n' > "$SEED/src/widget.ts"; printf 'readme\n' > "$SEED/README.md"
( cd "$SEED" && "$REALGIT" add -A && "$REALGIT" -c user.email=lead@example.com -c user.name=lead commit -q -m main \
  && "$REALGIT" remote add origin "$ORIGIN" && "$REALGIT" push -q origin HEAD:refs/heads/main ) || exit 1
( cd "$SEED" && "$REALGIT" checkout -q -b feature/x7 && printf 'export const v = 2;\n' > src/other.ts \
  && "$REALGIT" add -A && "$REALGIT" -c user.email=collaborator-1@example.com -c user.name=collaborator-1 commit -q -m "Add other" \
  && "$REALGIT" push -q origin HEAD:refs/heads/feature/x7 ) || exit 1
H1=$("$REALGIT" -C "$ORIGIN" rev-parse refs/heads/feature/x7)
"$REALGIT" clone -q "$ORIGIN" "$T/repos/project-3" || exit 1
OHEAD() { "$REALGIT" -C "$ORIGIN" rev-parse refs/heads/feature/x7; }

# Every push is recorded and then really happens.
printf '#!/bin/bash\ncase " $* " in *" push "*) printf "%%s\\n" "$*" >> "%s/push.txt" ;; esac\nexec "%s" "$@"\n' \
  "$T" "$REALGIT" > "$T/fakebin/git"
chmod +x "$T/fakebin/git"

# The agent: records its prompt, commits a change to the file the finding names
# under whatever identity the lane pinned (no --author), and on request moves
# the origin's branch under the round (a sibling commit on H1), or commits nothing.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
n=\$(( \$(cat "$T/agent-n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/agent-n"
printf '%s' "\$6" > "$T/prompt-\$n.txt"
if [ ! -f "$T/agent-nocommit" ]; then
  printf 'export const w = (x) => x?.y;\n' > src/widget.ts
  "$REALGIT" add -A >/dev/null 2>&1
  "$REALGIT" commit -q -m "Guard the null in src/widget.ts (answers: please fix the null check)" >/dev/null 2>&1
fi
if [ -f "$T/agent-move-origin" ]; then
  s=\$("$REALGIT" -C "$ORIGIN" commit-tree "$H1^{tree}" -p "$H1" -m "author pushed meanwhile")
  "$REALGIT" -C "$ORIGIN" update-ref refs/heads/feature/x7 "\$s"
  printf '%s' "\$s" > "$T/h2"
fi
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"

# ---------------------------------------------------------------------------
# Fixtures. pr-<n>.json is the REST PR object; the open list is all of them.
# PRADD <n> <head> <login> <upd-age-s> [head-repo] [fork] [mcm]
PRADD() {
  jq -nc --argjson n "$1" --arg h "$2" --arg l "$3" --arg u "$(ISO "$4")" \
        --arg hr "${5:-o/project-3}" --arg fk "${6:-false}" --arg mc "${7:-false}" \
    '{number:$n, html_url:("https://github.com/o/project-3/pull/"+($n|tostring)), state:"open",
      title:"Improve the layout", draft:false, updated_at:$u, user:{login:$l, type:"User"},
      head:{sha:$h, ref:"feature/x7", repo:{full_name:$hr, fork:($fk=="true")}},
      base:{ref:"main"}, merged_at:null, maintainer_can_modify:($mc=="true"), mergeable_state:"clean"}' \
    > "$T/f/pr-$1.json"
  jq -s . "$T"/f/pr-*.json > "$T/f/list.json"
}
# REVADD <n> <commit> <body> — a lead (operator, OWNER) CHANGES_REQUESTED.
REVADD() {
  jq -nc --arg c "$2" --arg b "$3" \
    '[{id:1, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"operator", type:"User"}, author_association:"OWNER", body:$b}]' \
    > "$T/f/reviews-$1.json"
}
COMMIT() { # COMMIT <sha> <age-s> <author-email>
  jq -nc --arg d "$(ISO "$2")" --arg e "$3" '{sha:"x", commit:{committer:{date:$d}, author:{email:$e}}}' \
    > "$T/f/commit-$1.json"
}
KNOB() { printf '%s' "$2" > "$T/f/knob-$1"; }

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
      for a in "\$@"; do case "\$a" in body=@*) cat "\${a#body=@}" > "$T/cbody-\$(grep -c . "$T/comments.txt").txt" ;; esac; done
      send 201 '{"id":1}' ;;
    "GET repos/o/project-3/pulls") send 200 "\$(cat "\$F/list.json")" ;;
    "GET repos/o/project-3/pulls/"*"/reviews"*)
      N=\${P#repos/o/project-3/pulls/}; N=\${N%%/*}
      send 200 "\$(cat "\$F/reviews-\$N.json" 2>/dev/null || echo '[]')" ;;
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
# br_pr_ref's plain read: gh api repos/o/project-3/pulls/<n> --jq <filter>
if [ "\$1" = api ] && [ "\$3" = --jq ]; then
  case "\$2" in repos/o/project-3/pulls/*) jq -r "\$4" "\$F/pr-\${2##*/}.json" 2>/dev/null; exit 0 ;; esac
fi
echo ""
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN="" GH_BUDGET_TTL_S=0

RESET() {
  rm -rf "$T/f"/* "$H/state/blocked-resolver" "$OPTD"/* "$H/logs/blocked-resolver.log" \
         "$H/tmp/brfix" "$T"/prompt-*.txt "$T"/cbody-*.txt "$T/agent-n" "$T/h2" \
         "$T/agent-nocommit" "$T/agent-move-origin" "${TMPDIR:-/tmp}"/br-open-prs.* 2>/dev/null
  mkdir -p "$T/f"; echo '[]' > "$T/f/list.json"
  : > "$T/gh.txt"; : > "$T/patch.txt"; : > "$T/comments.txt"; : > "$T/push.txt"; : > "$T/queue.txt"
  : > "$T/side.txt"; : > "$T/run.log"; : > "$T/rereview.txt"; : > "$T/park-calls.txt"
  printf '%s\n' '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}' > "$T/f/ratelimit.json"
  "$REALGIT" -C "$ORIGIN" update-ref refs/heads/feature/x7 "$H1"
  "$REALGIT" -C "$T/repos/project-3" worktree prune >/dev/null 2>&1
  "$REALGIT" -C "$T/repos/project-3" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do "$REALGIT" -C "$T/repos/project-3" branch -D "$b" >/dev/null 2>&1; done
  BRENV=(BR_REVIEW_FIX_ROUNDS=1)
}
BRENV=()
RC=0
RUN() { RC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" project-3 >>"$T/run.log" 2>&1 ) || RC=$?; }
FHOUT=""
FIXHERE() { # FIXHERE <stdin-record-file> — the owning box's entry, as fix-round-claim.sh calls it
  FHOUT=$( ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
             env ${BRENV[*]:+"${BRENV[@]}"} \
             bash "$H/bin/blocked-resolver.sh" --fix-here project-3 o-project-3-7 review-changes-requested "$ROW7" - - < "$1" ) 2>>"$T/run.log")
}
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
HAS() { grep -qF -- "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
NPATCH() { grep -c . "$T/patch.txt"; }
NCOMM() { grep -c . "$T/comments.txt"; }
NPUSH() { grep -c . "$T/push.txt"; }
NAGENT() { cat "$T/agent-n" 2>/dev/null || echo 0; }
REC() { cat "$H/state/blocked-resolver/project-3/o-project-3-7.json" 2>/dev/null; }
INSTALL() { cp "$XMOD" "$OPTD/external.sh" && cp "$FMOD" "$OPTD/extfix.sh"; }
ROW7='https://github.com/o/project-3/pull/7'
CMTLINE='every commit message names the review finding it answers'
# The standard case: outsider collaborator-1's PR #7 on H1, quiet for 61 minutes, a
# lead CHANGES_REQUESTED on H1 naming src/widget.ts.
FINDING='Please fix the null check in src/widget.ts.'
TRACER() { # TRACER [review-body]
  PRADD 7 "$H1" collaborator-1 300
  REVADD 7 "$H1" "${1:-$FINDING}"
  COMMIT "$H1" 3660 collaborator-1@example.com
}
NOTHING() { # NOTHING <case> — no agent, no push, no comment, no PATCH
  [ "$(NAGENT)" = 0 ] && [ "$(NPUSH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ "$(NPATCH)" = 0 ] \
    && [ "$(OHEAD)" = "$H1" ] && ok \
    || bad "$1: nothing may be spent or written (agent=$(NAGENT) push=$(NPUSH) comments=$(NCOMM) patch=$(NPATCH) origin=$(OHEAD | cut -c1-8)): $(LOG | tail -4)"
}

# ===========================================================================
# X3: a real tick on the tracer.
# ===========================================================================
RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER
RUN
[ "$RC" = 0 ] && ok || bad "X3: the tick must exit 0 (rc $RC): $(tail -3 "$T/run.log")"
N=$(OHEAD)
# 1. the push: lease H1 on feature/x7, and origin moved to N on top of H1.
grep -qF -- "--force-with-lease=feature/x7:$H1" "$T/push.txt" && ok \
  || bad "X3.1: the push must lease H1 on feature/x7: $(cat "$T/push.txt") $(LOG | tail -5)"
[ "$N" != "$H1" ] && "$REALGIT" -C "$ORIGIN" merge-base --is-ancestor "$H1" "$N" && ok \
  || bad "X3.1: origin feature/x7 must be a new sha on top of H1 (now ${N:0:8})"
# 2. the prompt: the finding and the outside-contributor commit line.
grep -qF "$FINDING" "$T/prompt-1.txt" 2>/dev/null && grep -qF "$CMTLINE" "$T/prompt-1.txt" && ok \
  || bad "X3.2: the prompt must carry the finding and '$CMTLINE': $(head -c 600 "$T/prompt-1.txt" 2>/dev/null)"
# 3. the round's commits are all the harness identity.
IDS=$("$REALGIT" -C "$ORIGIN" log --no-merges --format='%ae %ce' "$H1..$N" | sort -u)
[ "$IDS" = "bot@harness.test bot@harness.test" ] && ok || bad "X3.3: every round commit must be bot@harness.test (got '$IDS')"
# 4. exactly one comment, the external template.
B="$T/cbody-1.txt"
[ "$(NCOMM)" = 1 ] && ok || bad "X3.4: exactly one comment POST (got $(NCOMM))"
grep -qF "${H1:0:12}" "$B" 2>/dev/null && grep -qF "${N:0:12}" "$B" && grep -qF 'src/widget.ts' "$B" \
  && grep -qF 'Guard the null in src/widget.ts' "$B" && grep -qF 'review lane re-reviews' "$B" && ok \
  || bad "X3.4: the comment must carry old12, new12, the finding, the commit subject and the review-lane line: $(cat "$B" 2>/dev/null)"
grep -qF 'Fix round by' "$B" 2>/dev/null && bad "X3.4: the generic comment must not be posted on an external PR: $(cat "$B")" || ok
grep -q '—' "$B" 2>/dev/null && bad "X3.4: the template has no em dashes: $(cat "$B")" || ok
# 5. the record.
[ "$(REC | jq -r --arg h "$H1" '(.review_fix_heads // []) | index($h) != null')" = true ] \
  && [ "$(REC | jq -r '.external | tostring')" = true ] && ok \
  || bad "X3.5: the record must hold H1 in review_fix_heads and external true: $(REC)"
# 6. no re-review call, no PATCH, no rereview counters.
[ ! -s "$T/rereview.txt" ] && [ "$(NPATCH)" = 0 ] \
  && [ "$(REC | jq -r '(.rereviews // 0) + (.preflight_rereviews // 0)')" = 0 ] && ok \
  || bad "X3.6: the resolver never re-reviews and never PATCHes (rereview=$(cat "$T/rereview.txt") patch=$(NPATCH))"
HAS "to feature/x7 — the project box's review lane re-reviews it on its next tick" && ok || bad "X3: the push line must name the review lane as the next judge: $(LOG | grep 'FIX ROUND' )"
# 7. a second tick on the same fixtures spends nothing.
: > "$T/comments.txt"; : > "$T/push.txt"; rm -f "$T/agent-n"
RUN
[ "$(NAGENT)" = 0 ] && [ "$(NPUSH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ "$(OHEAD)" = "$N" ] && ok \
  || bad "X3.7: a second tick must spend nothing (agent=$(NAGENT) push=$(NPUSH) comments=$(NCOMM))"
HAS "external o/project-3#7: fix round already ran on ${H1:0:8} — nothing spent" && ok \
  || bad "X3.7: the second tick must say the head was already worked: $(LOG | tail -4)"
HAS "rungs=0/" && ok || bad "X3.7: the second tick spends no PER_TICK slot: $(LOG | grep 'tick:' | tail -1)"

# ===========================================================================
# X3b / X3c: the park ledger — a hit and an outage both spend nothing.
# ===========================================================================
RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER; printf hit > "$T/f/park-$H1"
RUN
NOTHING X3b
HAS "external o/project-3#7: head ${H1:0:8} is parked for the author" && ok || bad "X3b: an ext-park hit must log parked for the author: $(LOG | tail -3)"
grep -qF "o/project-3 7 ext-park $H1" "$T/park-calls.txt" && ok || bad "X3b: the ledger is asked for (slug, num, ext-park, head): $(cat "$T/park-calls.txt")"

RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER; printf outage > "$T/f/park-$H1"
RUN
NOTHING X3c
HAS "external o/project-3#7: the park ledger would not read" && ok || bad "X3c: an outage must log the park ledger would not read: $(LOG | tail -3)"
[ "$(REC | jq -r '(.review_fix_heads // []) | length')" = 0 ] && ok || bad "X3c: an outage marks no head: $(REC)"

# ===========================================================================
# X3d: a fork head, even with maintainer edits on: no fix round.
# ===========================================================================
RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1
PRADD 7 "$H1" collaborator-1 300 collaborator-1/project-3 true true
REVADD 7 "$H1" "$FINDING"; COMMIT "$H1" 3660 collaborator-1@example.com
RUN
NOTHING X3d
HAS "external o/project-3#7: head lives in collaborator-1/project-3" && ok || bad "X3d: a fork head must log head lives in collaborator-1/project-3: $(LOG | tail -3)"

# ===========================================================================
# X3e: 12 finding lines -> lines 1-10 in the comment, not 11.
# ===========================================================================
RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1
TRACER "$(for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'finding line %s in src/widget.ts\n' "$i"; done)"
RUN
B="$T/cbody-1.txt"
grep -qF 'finding line 1 in' "$B" 2>/dev/null && grep -qF 'finding line 10 in' "$B" && ! grep -qF 'finding line 11 in' "$B" && ok \
  || bad "X3e: the comment carries finding lines 1-10 and not 11: $(cat "$B" 2>/dev/null)"
grep -qF 'LEAD FINDINGS' "$B" 2>/dev/null && bad "X3e: the brief's header is not a finding line: $(cat "$B")" || ok

# ===========================================================================
# X3g: extfix.sh without br_xpr_round_comment -> the generic comment, once.
# ===========================================================================
RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER
printf '\nunset -f br_xpr_round_comment\n' >> "$OPTD/extfix.sh"
RUN
[ "$(NCOMM)" = 1 ] && grep -qF 'Fix round by' "$T/cbody-1.txt" 2>/dev/null && ok \
  || bad "X3g: with no external template the generic comment is posted, exactly once (comments=$(NCOMM)): $(cat "$T/cbody-1.txt" 2>/dev/null)"
[ "$(OHEAD)" != "$H1" ] && ok || bad "X3g: the round still pushes"

# ===========================================================================
# X6: the head moves under the lease (the author pushed mid-round).
# ===========================================================================
RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER; touch "$T/agent-move-origin"
BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
H2=$(cat "$T/h2" 2>/dev/null)
[ "$(NAGENT)" = 1 ] && ok || bad "X6: the round must run (agent=$(NAGENT)): $(LOG | tail -4)"
[ -n "$H2" ] && [ "$(OHEAD)" = "$H2" ] && ok || bad "X6: the author's head H2 must stand on origin (origin=$(OHEAD | cut -c1-8) H2=${H2:0:8})"
[ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok || bad "X6: a rejected push closes and comments nothing (patch=$(NPATCH) comments=$(NCOMM))"
HAS "external PR — nothing closed; the next round waits for the next head" && ok || bad "X6: the log must say the next round waits for the next head: $(LOG | tail -5)"
HAS "left for the author" && ok || bad "X6: the terminal must leave it for the author: $(LOG | tail -4)"
[ -z "$(REC | jq -r '.outcome // ""')" ] && ! HAS ABANDONED && ok || bad "X6: no ABANDONED/closed outcome: $(REC | jq -c '.outcome')"
# At the cap the PARKED word stands alone.
RESET; INSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER; touch "$T/agent-move-origin"
RUN
HAS "waits for the next head" && bad "X6: at the cap (1 of 1) the waits line is not logged: $(LOG | grep waits)" || ok
HAS "PARKED for the author instead" && ok || bad "X6: at the cap the terminal word is PARKED for the author: $(LOG | tail -4)"

# ===========================================================================
# X3f: a HARNESS PR through --fix-here: no external line, the generic comment.
# ===========================================================================
RESET; INSTALL; TRACER
jq -nc '{project:"project-3",rkey:"o-project-3-7",fixrounds:0,attempts:[]}' > "$T/rec.json"
FIXHERE "$T/rec.json"
[ "$(NAGENT)" = 1 ] && ok || bad "X3f: --fix-here must run the round: $FHOUT $(LOG | tail -4)"
grep -qF "$CMTLINE" "$T/prompt-1.txt" 2>/dev/null && bad "X3f: a harness PR's prompt must not carry the outside-contributor line" || ok
[ "$(NCOMM)" = 1 ] && grep -qF 'Fix round by' "$T/cbody-1.txt" 2>/dev/null && ok \
  || bad "X3f: a harness PR gets the generic comment (comments=$(NCOMM)): $(cat "$T/cbody-1.txt" 2>/dev/null)"
HAS "outside contributor's fix round" && bad "X3f: no external line for a harness record" || ok

# ===========================================================================
# X12a: --fix-here with the hub's record carrying "external":"true".
# ===========================================================================
RESET; INSTALL; TRACER
jq -nc '{project:"project-3",rkey:"o-project-3-7",fixrounds:0,external:"true",attempts:[]}' > "$T/rec.json"
FIXHERE "$T/rec.json"
grep -qF "$CMTLINE" "$T/prompt-1.txt" 2>/dev/null && ok || bad "X12a: the prompt must carry '$CMTLINE': $(LOG | tail -4)"
[ "$(NCOMM)" = 1 ] && grep -qF 'review lane re-reviews' "$T/cbody-1.txt" && ! grep -qF 'Fix round by' "$T/cbody-1.txt" && ok \
  || bad "X12a: the comment must be the external template (comments=$(NCOMM)): $(cat "$T/cbody-1.txt" 2>/dev/null)"
HAS "project-3/o-project-3-7 [review-changes-requested]: external PR: this round runs as an outside contributor's fix round" && ok \
  || bad "X12a: --fix-here must say it runs as an external round: $(LOG | tail -4)"
grep -q '^FIX_RESULT done' <<<"$FHOUT" && ok || bad "X12a: the round reports done: $FHOUT"
# The bare-boolean spelling (br_set_flag) counts too.
RESET; INSTALL; TRACER
jq -nc '{project:"project-3",rkey:"o-project-3-7",fixrounds:0,external:true,attempts:[]}' > "$T/rec.json"
FIXHERE "$T/rec.json"
grep -qF "$CMTLINE" "$T/prompt-1.txt" 2>/dev/null && ok || bad "X12a: external:true (boolean) must count too"

# ===========================================================================
# X12b: the same, but the agent commits nothing: terminal, nothing closed.
# ===========================================================================
RESET; INSTALL; TRACER; touch "$T/agent-nocommit"; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
jq -nc '{project:"project-3",rkey:"o-project-3-7",fixrounds:0,external:"true",attempts:[]}' > "$T/rec.json"
FIXHERE "$T/rec.json"
grep -q '^FIX_RESULT terminal' <<<"$FHOUT" && ok || bad "X12b: a round with no commit must answer FIX_RESULT terminal: $FHOUT"
HAS "waits for the next head" && ok || bad "X12b: below the cap the log must say the next round waits for the next head: $(LOG | tail -4)"
[ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ "$(NPUSH)" = 0 ] && ok \
  || bad "X12b: nothing closed, commented or pushed (patch=$(NPATCH) comments=$(NCOMM) push=$(NPUSH))"

echo "external-pr-fixround.bh-4668: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
