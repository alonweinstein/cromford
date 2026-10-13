#!/bin/bash
# tests/blocked-resolver-carry.bh-1470-test.sh — BH-1470: the CARRY rung of
# bin/lib/br/opt/mechanical.sh.
#
# WHAT IT PINS. A `head-not-reapproved` park means main moved under a PR whose
# APPROVE was bound to the sha a reviewer read. When the branch's OWN added and
# removed lines are unchanged, the approval binds to the new head and this lane
# rebinds it instead of buying a re-review. Everything here is driven through the
# REAL bin/blocked-resolver.sh against a scratch $HARNESS (D2) and a REAL bare
# git origin: every claim is about what `git diff` and `git merge-base` actually
# say about two patches, which a stubbed git could never prove. `gh`, the jobs
# client and bin/agent-call.sh are stubbed; nothing here touches GitHub.
#
# D1 MUTATION, run once before the PR and confirmed red: make the carry stop
# READING job_verdict_rebind's rc (`rc=0` in place of the call) — case 2c goes
# red on four assertions, because a ledger that refused the rebind is then
# stamped `carry`, transitioned to WAIT_REVIEW and counted.
#
# Run from anywhere: tests/blocked-resolver-carry.bh-1470-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

SLUG=o/p1
PROJ=p1

# ── a real repository, and a real remote that never leaves this box ──────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

git init -q --bare "$T/origin.git"
git -C "$T/origin.git" config core.logAllRefUpdates true
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
S="$T/seed"
mkdir -p "$S/src" "$S/scripts"

printf 'export const base = 1\n' > "$S/src/base.ts"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/regen-out.json"
cat > "$S/scripts/regen.sh" <<'REGEN'
#!/bin/sh
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/regen-out.json
REGEN
chmod +x "$S/scripts/regen.sh"
# The repo's OWN declaration of what is machine-written. mc_regen_table reads it
# off the BASE ref, and its first column is the exclude file the carry is
# decided against.
cat > "$S/AGENT_ARCHITECTURE.md" <<'ARCH'
# Architecture

## Generated files

| File | Regenerate with |
|---|---|
| `scripts/regen-out.json` | `bash scripts/regen.sh` |
ARCH
git -C "$S" add -A && git -C "$S" commit -qm base >/dev/null && git -C "$T/origin.git" fetch -q "$S" main:main
BASE=$(git -C "$S" rev-parse HEAD)

# mkbranch <n> <body> — one PR branch off BASE, with its own source file.
mkbranch() {
  git -C "$S" checkout -q -b "ticket/ts-$1" "$BASE"
  printf '%s\n' "$2" > "$S/src/f$1.ts"
  git -C "$S" add -A && git -C "$S" commit -qm "ts-$1" >/dev/null
  git -C "$S" push -q origin "ticket/ts-$1"
  printf '%s' "$(git -C "$S" rev-parse HEAD)" > "$T/old-$1"
}
for N in 21 22 23 24 25 26 27 28 29; do mkbranch "$N" "export const x$N = 1"; done

# THE HUB'S CHECKOUT IS MADE HERE, before main moves and before any branch is
# rebased: that is the production shape — the box already had the reviewed sha
# when the mover pushed over it, which is why mrt_carry_ok can read both sides.
git clone -q "$T/origin.git" "$T/repos-src" 2>/dev/null
mkdir -p "$T/repos"
cp -a "$T/repos-src" "$T/repos/$PROJ"

# Main moves on.
git -C "$S" checkout -q main
printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
( cd "$S" && ./scripts/regen.sh )
git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null && git -C "$T/origin.git" fetch -q "$S" main:main

# rebase_pr <n> — the PURE rebase a mover would have made: same patch, new base.
rebase_pr() {
  git -C "$S" checkout -q "ticket/ts-$1"
  git -C "$S" rebase -q main >/dev/null 2>&1
  git -C "$S" push -q -f origin "ticket/ts-$1"
  printf '%s' "$(git -C "$S" rev-parse HEAD)" > "$T/new-$1"
}
for N in 21 22 23 26 27 28 29; do rebase_pr "$N"; done

# #24: rebased AND one added line changed — the carry must refuse this one.
git -C "$S" checkout -q ticket/TK-24
git -C "$S" rebase -q main >/dev/null 2>&1
printf 'export const x24 = 2\n' > "$S/src/f24.ts"
git -C "$S" commit -qam 'TK-24 edit' >/dev/null
git -C "$S" push -q -f origin ticket/TK-24
printf '%s' "$(git -C "$S" rev-parse HEAD)" > "$T/new-24"

# #25: rebased AND the DECLARED generated file moved. That file is a function of
# the tree, so it is excluded from the patch's identity and the carry still holds.
git -C "$S" checkout -q ticket/TK-25
git -C "$S" rebase -q main >/dev/null 2>&1
printf '{"imports":["src/base.ts","src/f25.ts","src/main-advance.ts","src/extra.ts"]}\n' > "$S/scripts/regen-out.json"
git -C "$S" commit -qam 'TK-25 regen' >/dev/null
git -C "$S" push -q -f origin ticket/TK-25
printf '%s' "$(git -C "$S" rev-parse HEAD)" > "$T/new-25"

OLD() { cat "$T/old-$1"; }
NEW() { cat "$T/new-$1"; }
ORIGREF() { git -C "$T/origin.git" rev-parse "refs/heads/ticket/ts-$1" 2>/dev/null; }

# ── the harness tree ─────────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/tmp" "$H/state/merge-conductor" "$T/fakebin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# The module under test travels with the lane (tests/br-split-layout-test.sh
# case 7 is the ratchet that makes a fixture carry bin/lib/br/).
mkdir -p "$H/bin/lib/br/opt"
cp "$DIR/bin/lib/br/opt/mechanical.sh" "$H/bin/lib/br/opt/" 2>/dev/null
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf '%s %s - - 2 box-%s 192.0.2.1\n' "$PROJ" "$SLUG" "$PROJ" > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning, such as it was\nREJECT\n' > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# ── the fake gh ──────────────────────────────────────────────────────────────
# Per-PR head and branch, written into the shared fixture files the REST stub
# reads, so two PRs in one scenario never answer each other's sha.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
esac
case "\$*" in
  *"-i -X GET repos/$SLUG/pulls/"*)
    # A READ THAT FAILS PART WAY THROUGH A TICK. The threshold is a call COUNT
    # because the merged guard and the carry rung read the SAME route, and a
    # route-wide 500 would stop the row at the guard and never reach the rung.
    echo x >> "$T/prcount.txt"
    TH=\$(cat "$T/pr500from" 2>/dev/null || echo 0)
    if [ "\$TH" != 0 ] && [ "\$(grep -c . "$T/prcount.txt")" -ge "\$TH" ]; then
      printf '500' > "$T/st-pr"
    else rm -f "$T/st-pr"; fi ;;
esac
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    cat "$T/pr-\$N.branch" 2>/dev/null > "$T/prbranch"
    cat "$T/pr-\$N.head"   2>/dev/null > "$T/prhead"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) printf '%s ticket/ts-%s\n' "\$(cat "$T/pr-\$N.head" 2>/dev/null)" "\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (the rule tests/blocked-resolver-test.sh holds).
export GH_TOKEN=""
echo OPEN > "$T/prstate"
for N in 21 22 23 24 25 26 27 28 29; do
  printf 'ticket/ts-%s' "$N" > "$T/pr-$N.branch"
  NEW "$N" > "$T/pr-$N.head"
done

# The jobs client. job_verdict_rebind is the DURABLE half of a carry, so its
# argv is recorded and its rc is armable: rc 2 is the ledger saying "this row
# makes no reviewed-sha claim to move", which is not a rebind.
JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
job_verdict_rebind() {
  printf 'verdict-rebind %s %s\n' "\$1" "\$2" >> "$T/jobs.txt"
  [ -f "$T/rebind-rc" ] && return "\$(cat "$T/rebind-rc")"
  return 0
}
EOF
}
JOBS_OK

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
BRENV=()
RC=0
RUN() { RC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" MC_REPOS="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || RC=$?; }
# ROWADD <num> <why> <head> <reviewed> — one conductor hand-off row.
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$SLUG#$1" BLOCKED_HUMAN "$((NOW - 600))" "$3" "$4" "$2" \
             "https://github.com/$SLUG/pull/$1" >> "$ROWS"; }
ROWSTATE() { awk -F'\t' -v k="$SLUG#$1" '$1==k{s=$2} END{print s}' "$ROWS" 2>/dev/null; }
ROWFIELD() { awk -F'\t' -v k="$SLUG#$1" -v f="$2" '$1==k{s=$f} END{print s}' "$ROWS" 2>/dev/null; }
STATEJSON() { cat "$ST/$PROJ/$PROJ-TK-$1.json" 2>/dev/null; }
# ACTIONS <num> — the attempt actions recorded on that ticket's record.
ACTIONS() { STATEJSON "$1" | jq -r '.attempts[]?.action' 2>/dev/null | tr '\n' ' '; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
ORDER() { grep -oE '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild)' \
            "$H/logs/blocked-resolver.log" 2>/dev/null | sed 's/-> //' | tr '\n' ' '; }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null; }
NLINES() { grep -c "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
JOBSARGV() { cat "$T/jobs.txt" 2>/dev/null; }

# RECMK <num> <reviewed-sha> — a build record mc_record_for can find, carrying
# the reviewed sha where bin/blocked-resolver.sh and mrt_carry_verdict write it.
RECMK() { mkdir -p "$H/builds/$PROJ-TK-$1-1"
          printf 'PR_CREATED https://github.com/%s/pull/%s (harness build)\n' "$SLUG" "$1" \
            > "$H/builds/$PROJ-TK-$1-1/RESULT"
          printf '%s\n' "$2" > "$H/builds/$PROJ-TK-$1-1/reviewed-sha"; }

CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          scratch_rm "$H/tmp" 2>/dev/null; mkdir -p "$H/tmp"
          : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"; : > "$T/jobs.txt"
          : > "$T/alerts.txt"; : > "$T/agent.txt"; : > "$T/prcount.txt"
          rm -f "$T/rebind-rc" "$T/pr500from" "$T/st-pr" "$H/flags/blocked-resolver-observe"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          echo OPEN > "$T/prstate"; JOBS_OK
          : > "$ROWS"; }

NOTREAPP="head-not-reapproved: main moved under the approved sha"

# ============================================================================
# 1. NO bin/lib/mc/train.sh IN THE HARNESS. The module is there, the helpers it
#    needs are not, so both rungs decline on their first line and the park takes
#    its ordinary fix-round rung. That is the "a box without it keeps today's
#    behaviour" half of the contract.
# ============================================================================
CLEAN
mv "$H/bin/lib/mc/train.sh" "$T/train.sh.away"
ROWADD 21 "$NOTREAPP" "$(OLD 21)" "$(OLD 21)"
RUN
mv "$T/train.sh.away" "$H/bin/lib/mc/train.sh"
[ "$RC" = 0 ] && ok || bad "1: the tick must exit 0 without train.sh (rc $RC)"
[ "$(LFIELD carried)" = 0 ] && ok || bad "1: carried must read 0 (tick: $(LASTTICK))"
case "$(ORDER)" in *fix-round*) ok ;; *) bad "1: the ordinary rung must run (order: $(ORDER))" ;; esac
[ "$(NLINES 'fix-round worktree')" -ge 1 ] && ok \
  || bad "1: and really RUN it — the rung set up its own worktree (log: $(LOG | tail -4))"
# The lane must page for NOTHING here. Lines matching "lane fence" are the
# harness's own act-time fence reporting itself inert inside this scratch
# $HARNESS (it looks for a classifier the fixture does not ship); they are not
# the resolver's and are excluded by cause, never by weakening the assertion.
BRALERTS() { grep -v 'lane fence' "$H/logs/ALERTS.log" 2>/dev/null; }
[ -z "$(BRALERTS)" ] && ok \
  || bad "1: an absent optional dependency is silent (alerts: $(BRALERTS))"

# ============================================================================
# 2. THE CARRY. Main moved, the branch's own +/- lines did not, so the verdict
#    is rebound to the new head and no model is bought.
# ============================================================================
CLEAN
RECMK 23 "$(OLD 23)"
ROWADD 23 "$NOTREAPP" "$(OLD 23)" "-"
RUN
[ "$RC" = 0 ] && ok || bad "2: the tick must exit 0 (rc $RC)"
case " $(ACTIONS 23) " in *" carry "*) ok ;; *) bad "2: a carry attempt is recorded (record: $(STATEJSON 23))" ;; esac
grep -qxF "verdict-rebind https://github.com/$SLUG/pull/23 $(NEW 23)" "$T/jobs.txt" && ok \
  || bad "2: the ledger verdict is rebound to the new head (jobs: $(JOBSARGV))"
[ "$(ROWSTATE 23)" = WAIT_REVIEW ] && ok || bad "2: the conductor row is WAIT_REVIEW (got: $(ROWSTATE 23))"
[ "$(ROWFIELD 23 5)" = "$(NEW 23)" ] && ok \
  || bad "2: and its reviewed sha is the new head (got: $(ROWFIELD 23 5))"
[ "$(NAGENT)" = 0 ] && ok || bad "2: a carried park calls no model (agent: $(cat "$T/agent.txt"))"
[ "$(LFIELD carried)" = 1 ] && ok || bad "2: carried=1 (tick: $(LASTTICK))"
[ "$(LFIELD llm_rungs)" = 0 ] && ok || bad "2: a carry is not an llm rung (tick: $(LASTTICK))"
[ "$(ORIGREF 23)" = "$(NEW 23)" ] && ok || bad "2: a carry pushes nothing (origin moved)"
grep -q 'pr merge' "$T/gh.txt" && bad "2: nothing here merges a PR (gh: $(cat "$T/gh.txt"))" || ok
[ "$(head -1 "$H/builds/$PROJ-TK-23-1/reviewed-sha")" = "$(NEW 23)" ] && ok \
  || bad "2: the record's reviewed sha moves with the verdict (got: $(cat "$H/builds/$PROJ-TK-23-1/reviewed-sha"))"

# 2b. A DECLARED GENERATED FILE differing between the two heads still carries:
#     it is a function of the tree, so it is not part of the patch's identity.
CLEAN
RECMK 25 "$(OLD 25)"
ROWADD 25 "$NOTREAPP" "$(OLD 25)" "-"
RUN
case " $(ACTIONS 25) " in *" carry "*) ok ;; *) bad "2b: a declared generated file must not block the carry (record: $(STATEJSON 25))" ;; esac
[ "$(LFIELD carried)" = 1 ] && ok || bad "2b: carried=1 (tick: $(LASTTICK))"

# 2c. THE LEDGER REFUSED THE REBIND (rc 2 = the row makes no reviewed-sha claim
#     to move). A failed rebind is NOT a rebind: nothing is recorded, nothing
#     transitions, nothing is counted, and today's ladder runs.
CLEAN
echo 2 > "$T/rebind-rc"
RECMK 26 "$(OLD 26)"
ROWADD 26 "$NOTREAPP" "$(OLD 26)" "-"
RUN
case " $(ACTIONS 26) " in *" carry "*) bad "2c: a refused rebind must record no carry (record: $(STATEJSON 26))" ;; *) ok ;; esac
[ "$(ROWSTATE 26)" != WAIT_REVIEW ] && ok || bad "2c: and must not transition the row (got: $(ROWSTATE 26))"
[ "$(LFIELD carried)" = 0 ] && ok || bad "2c: carried=0 (tick: $(LASTTICK))"
case "$(ORDER)" in *fix-round*) ok ;; *) bad "2c: the ordinary rung runs (order: $(ORDER))" ;; esac

# 2d. A PARK WHOSE BUILD RECORD IS GONE still carries: the reviewed sha falls
#     back to the conductor row's own field and the ledger rebind is durable.
CLEAN
ROWADD 28 "$NOTREAPP" "$(OLD 28)" "$(OLD 28)"
RUN
case " $(ACTIONS 28) " in *" carry "*) ok ;; *) bad "2d: a record-less park still carries (record: $(STATEJSON 28))" ;; esac
grep -qxF "verdict-rebind https://github.com/$SLUG/pull/28 $(NEW 28)" "$T/jobs.txt" && ok \
  || bad "2d: and the rebind still lands (jobs: $(JOBSARGV))"
[ "$(LFIELD carried)" = 1 ] && ok || bad "2d: carried=1 (tick: $(LASTTICK))"

# ============================================================================
# 3. ONE CHANGED ADDED LINE. The patch is not the same patch, so the approval
#    does not travel and the ladder owns the park exactly as it does today.
# ============================================================================
CLEAN
RECMK 24 "$(OLD 24)"
ROWADD 24 "$NOTREAPP" "$(OLD 24)" "-"
RUN
case " $(ACTIONS 24) " in *" carry "*) bad "3: a changed line must not carry (record: $(STATEJSON 24))" ;; *) ok ;; esac
[ -z "$(JOBSARGV)" ] && ok || bad "3: and nothing is rebound (jobs: $(JOBSARGV))"
[ "$(LFIELD carried)" = 0 ] && ok || bad "3: carried=0 (tick: $(LASTTICK))"
case "$(ORDER)" in *fix-round*) ok ;; *) bad "3: the ordinary rung runs (order: $(ORDER))" ;; esac
[ "$(NLINES 'fix-round worktree')" -ge 1 ] && ok \
  || bad "3: and really RUN it — the rung set up its own worktree (log: $(LOG | tail -4))"

# ============================================================================
# 4. GITHUB DID NOT ANSWER the head read the carry is decided on (rc 75). No
#    carry, no counter, no record — the next tick asks again.
# ============================================================================
CLEAN
echo 3 > "$T/pr500from"
RECMK 27 "$(OLD 27)"
ROWADD 27 "$NOTREAPP" "$(OLD 27)" "-"
RUN
[ "$RC" = 0 ] && ok || bad "4: an unreadable head must not fail the tick (rc $RC)"
[ "$(NLINES 'head sha UNVERIFIABLE')" -ge 1 ] && ok \
  || bad "4: the failed read is the carry rung's own (log: $(LOG | tail -5))"
[ "$(NLINES 'merged-state UNVERIFIABLE')" = 0 ] && ok \
  || bad "4: the merged guard answered before it, so the rung was never reached"
case " $(ACTIONS 27) " in *" carry "*) bad "4: nothing may be carried (record: $(STATEJSON 27))" ;; *) ok ;; esac
[ "$(LFIELD carried)" = 0 ] && ok || bad "4: carried=0 (tick: $(LASTTICK))"

# ============================================================================
# 5. THE KILL SWITCH. BR_OPT_OFF=mechanical leaves the file on disk unsourced,
#    and the park takes the same rung it takes with no module at all (case 1).
# ============================================================================
CLEAN
ROWADD 22 "$NOTREAPP" "$(OLD 22)" "$(OLD 22)"
BRENV=(BR_OPT_OFF=mechanical)
RUN
BRENV=()
[ -s "$H/bin/lib/br/opt/mechanical.sh" ] && ok || bad "5: the module must still be on disk"
[ "$(LFIELD carried)" = 0 ] && ok || bad "5: carried=0 (tick: $(LASTTICK))"
case "$(ORDER)" in *fix-round*) ok ;; *) bad "5: today's path runs (order: $(ORDER))" ;; esac
[ -z "$(JOBSARGV)" ] && ok || bad "5: and nothing is rebound (jobs: $(JOBSARGV))"

# ============================================================================
# 6. OBSERVE MODE predicts the carry and writes nothing.
# ============================================================================
CLEAN
touch "$H/flags/blocked-resolver-observe"
RECMK 29 "$(OLD 29)"
ROWADD 29 "$NOTREAPP" "$(OLD 29)" "-"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(NLINES 'WOULD carry')" = 1 ] && ok || bad "6: exactly one WOULD carry line (log: $(LOG | tail -5))"
case " $(ACTIONS 29) " in *" carry "*) bad "6: observe writes no carry (record: $(STATEJSON 29))" ;; *) ok ;; esac
[ -z "$(JOBSARGV)" ] && ok || bad "6: observe rebinds nothing (jobs: $(JOBSARGV))"
[ "$(ORIGREF 29)" = "$(NEW 29)" ] && ok || bad "6: observe pushes nothing (origin moved)"
[ "$(LFIELD carried)" = 0 ] && ok || bad "6: and counts nothing (tick: $(LASTTICK))"

echo "blocked-resolver carry (BH-1470): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
