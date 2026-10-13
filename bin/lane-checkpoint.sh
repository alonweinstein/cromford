#!/bin/bash
# bin/lane-checkpoint.sh — NO FINISHED WORK IS EVER LOST.
#
# usage:
#   lane-checkpoint.sh <build-dir> <worktree> <branch> [stage]
#   lane-checkpoint.sh --watch <build-dir> <worktree> <branch> [stage]
#   lane-checkpoint.sh --resume-branch <worktree> <branch> [base]
#
# THE INCIDENT (2026-09-15). Seventeen lanes died on max-turns in 24 hours with
# no PR, and today's project-5 migrations lane had COMMITTED twelve files and
# then died before it pushed — the operator pushed the branch by hand to rescue
# it as project-5 #1156. The tree only ever existed on one disk, and on the Fly
# pool that disk is an ephemeral machine that gets reaped. bin/run-build.sh
# already pushes after each commit-producing stage (PUSH_BRANCH), but the
# EXECUTE stage is the long one — 40-75 minutes of editing between the branch
# being cut and the first push — and that is exactly the window every one of
# those deaths fell into.
#
# So the execute stage gets a heartbeat that commits and pushes whatever is on
# disk, every CHECKPOINT_EVERY_MIN minutes and once more in the exit trap. A
# lane that dies now costs a resumed execute session; it never costs the diff.
#
# WHAT THIS IS NOT. It is not a merge, not a deploy, and not a PR: it pushes a
# FEATURE BRANCH, the same object PUSH_BRANCH has pushed since 2026-09-11.
# Nothing downstream reacts to a branch push, and the wip commits it writes are
# squashed out of the history before the PR is opened (the `wip squash` block in
# bin/run-build.sh). A PR therefore never carries checkpoint noise, which is
# also the invariant --resume-branch leans on: wip commits at a branch's tip
# mean the lane that wrote them died before it reached the PR step.
#
# NEVER FATAL TO A BUILD. Every call site treats this as a backup, and a backup
# that can fail a build is worse than no backup. Refusals and failures are one
# pipeline.log line (plus an ALERTS line, once per build, when the refusal means
# work is going unprotected) and a non-zero rc the caller ignores.
#
# CONFIG (env/global.env, documented fallbacks in docs/CHECKPOINTS.md):
#   CHECKPOINTS=1             kill switch; 0 (or flags/lane-checkpoints-off, or
#                             the `switch.lane-checkpoints-off` settings row)
#                             makes every mode a silent no-op — the pre-2026-09-15
#                             pipeline, byte for byte.
#   CHECKPOINT_EVERY_MIN=15   how often --watch checkpoints during a stage.
#   CHECKPOINT_EXCLUDE="node_modules .next"
#                             directories never committed even when the repo's
#                             .gitignore forgets them (the same two names
#                             bin/run-build.sh already excludes from git clean).
#                             __pycache__/, *.pyc and *.pyo are excluded on top
#                             of this and cannot be switched off by narrowing it
#                             (BH-1138).
#
# rc: 0 checkpointed, or a clean no-op, or switched off
#     1 the commit or the push did not land (work is local-only — say so)
#     2 usage / not a git worktree
#     4 REFUSED (a secret in the diff, main, or a branch that is not checked out)
set -uo pipefail
H="${HARNESS:-/root/harness}"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# The pipeline.log line the operator greps for. project/key come from the build
# dir's own job.json (bin/run-build.sh writes it before anything else), so this
# script needs no extra arguments to say WHICH build it just protected.
BUILD=""; TAG="-/-"
say() { # say <text>
  [ -n "$BUILD" ] && [ -d "$BUILD" ] && echo "$(STAMP) [$TAG] CHECKPOINT $*" >> "$BUILD/pipeline.log"
  return 0
}
# An alert, not a whisper (LESSONS 2026-08-13): a refusal means this build's
# tree is NOT being backed up, which nobody learns from a per-build log. Once
# per build dir — a 15-minute watcher must not write 20 identical alerts.
alert_once() { # alert_once <marker> <text>
  local m="$BUILD/.checkpoint-alerted-$1"
  [ -n "$BUILD" ] && [ -d "$BUILD" ] || return 0
  [ -e "$m" ] && return 0
  : > "$m" 2>/dev/null
  mkdir -p "$H/logs" 2>/dev/null
  echo "$(STAMP) [$TAG] checkpoint REFUSED: $2" >> "$H/logs/ALERTS.log"
  return 0
}

load_build() { # load_build <build-dir>
  BUILD="$1"
  local p k
  p=$(jq -r '.project // ""' "$BUILD/job.json" 2>/dev/null)
  k=$(jq -r '.key // ""'     "$BUILD/job.json" 2>/dev/null)
  TAG="${p:--}/${k:--}"
  CK_PROJECT="${p:--}"
}

# The kill switch, read the same way every other one in this repo is: an env
# value OR a flag file, either of which restores the previous behaviour.
# shellcheck source=lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
disabled() {
  lane_switch lane-checkpoints-off file && return 0
  case "$(printf '%s' "${CHECKPOINTS:-1}" | tr '[:upper:]' '[:lower:]')" in
    0|off|false|no) return 0 ;;
  esac
  return 1
}

# --- the secret refusal -------------------------------------------------------
# `git add -A` is a blunt instrument and the one thing it must never sweep up is
# a credential. env/ is chmod-600 machine state on every box in this fleet
# (iron guardrail 3: "no secrets in commits, comments, or logs"), and a bare
# *.env is the same file by another name. If either is sitting in the working
# tree we do not "add it anyway minus that path" — we refuse the whole
# checkpoint and say so, because a tree that contains a live secret is a tree
# someone has to look at before any of it is pushed anywhere.
#
# .env.example / .env.sample / .env.template are the documented exception: they
# are committed on purpose in most repos, carry no values, and refusing on them
# would switch checkpointing off for every build that touches one.
secret_in() { # secret_in <porcelain-path>
  local p="$1" b
  case "$p" in *.example|*.sample|*.template) return 1 ;; esac
  case "$p" in env/*|*/env/*) return 0 ;; esac
  b="${p##*/}"
  case "$b" in *.env|.env|.env.*) return 0 ;; esac
  return 1
}

# --- one checkpoint -----------------------------------------------------------
do_checkpoint() { # do_checkpoint <build-dir> <worktree> <branch> <stage>
  local wt="$2" br="$3" stage="${4:-execute}"
  load_build "$1"
  disabled && { say "$stage skipped — checkpointing is switched off (CHECKPOINTS=0 or flags/lane-checkpoints-off)"; return 0; }

  cd "$wt" 2>/dev/null || { say "$stage cannot run — $wt is not a directory"; return 2; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { say "$stage cannot run — $wt is not a git worktree"; return 2; }

  # NEVER ON MAIN. A checkpoint is an unreviewed machine commit; the one place
  # it may never land is the branch everything else merges into. Both the name
  # the caller passed and the branch actually checked out are tested, so a
  # caller that hands us the wrong name cannot talk us onto main either.
  local head_br
  head_br=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
  case "$br" in
    main|master|trunk) say "$stage REFUSED — '$br' is a trunk branch and a checkpoint never commits to one"
                       alert_once main "'$br' is a trunk branch; this build's tree is NOT being checkpointed"
                       return 4 ;;
  esac
  case "$head_br" in
    main|master|trunk) say "$stage REFUSED — the worktree has '$head_br' checked out, not '$br'"
                       alert_once main "the worktree at $wt sits on '$head_br', not '$br'; this build's tree is NOT being checkpointed"
                       return 4 ;;
  esac
  # A detached HEAD (a rebase left half-finished, a stage that checked out a
  # sha) is refused rather than committed onto: a commit made there is
  # unreachable the moment anything checks out a branch, which is the exact
  # loss this script exists to stop.
  if [ -z "$head_br" ]; then
    say "$stage REFUSED — the worktree is on a detached HEAD, so a commit here would be unreachable"
    alert_once detached "the worktree at $wt is on a detached HEAD (a half-finished rebase?); $br is NOT being checkpointed"
    return 4
  fi
  if [ "$head_br" != "$br" ]; then
    say "$stage REFUSED — the worktree is on '$head_br' but this build owns '$br'"
    alert_once mismatch "the worktree at $wt is on '$head_br', not the build's branch '$br'; it is NOT being checkpointed"
    return 4
  fi

  local porcelain
  porcelain=$(git status --porcelain --untracked-files=all 2>/dev/null)

  # Secrets first, before anything is staged.
  local line path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    # Renames read `old -> new`; whichever half looks like a credential is the
    # one named in the refusal, and a rename FROM env/ is as much a leak as a
    # rename into it.
    case "$path" in
      *" -> "*) if secret_in "${path%% -> *}"; then path="${path%% -> *}"; else path="${path##* -> }"; fi ;;
    esac
    if secret_in "$path"; then
      say "$stage REFUSED — the working tree holds '$path', which looks like a credential file; nothing committed, nothing pushed"
      alert_once secret "the worktree at $wt holds '$path' (env/ or *.env) — $br is NOT being checkpointed until it is removed or ignored"
      return 4
    fi
  done <<< "$porcelain"

  # --- commit ---------------------------------------------------------------
  local committed="" sha="" nfiles=0
  if [ -n "$porcelain" ]; then
    # .gitignore is respected (git add honours it), and CHECKPOINT_EXCLUDE
    # covers the build junk a repo forgot to ignore — bin/run-build.sh already
    # carries the same two names in its `git clean -e` list, for the same
    # reason: node_modules in a commit is a checkpoint nobody can push.
    local -a ex=()
    local tok
    for tok in ${CHECKPOINT_EXCLUDE:-node_modules .next}; do
      ex+=(":!$tok/*" ":!*/$tok/*")
    done
    # BH-1138-PYCACHE-EXCLUDE — python bytecode, unconditionally, and NOT inside
    # the CHECKPOINT_EXCLUDE default. gitignore stops an UNTRACKED __pycache__
    # file; it has no say over one that is already tracked, and `git add -A`
    # restages a tracked path whatever the ignore rules say. That is how
    # bin/__pycache__/gate-selfwrite.cpython-312.pyc came back onto main twice
    # (c4c147a8 / #1125), as a stray hunk in a PR about something else. The
    # exclusion sits outside the knob because an operator narrowing
    # CHECKPOINT_EXCLUDE to "node_modules" is a config line nobody reviews, and
    # it would silently restore the bug. A deletion of such a path is excluded
    # too — the one place it is removed from the index is a deliberate
    # `git rm --cached`, never a machine commit nobody read.
    #
    # The magic is spelled `:(exclude)` and not `:!`: git reads the short form's
    # following characters as more magic and dies with "Unimplemented pathspec
    # magic '_'" on `:!__pycache__/*` — which the `2>/dev/null` below would have
    # turned into a stage that silently added nothing at all.
    ex+=(":(exclude)__pycache__/*" ":(exclude)*/__pycache__/*" ":(exclude)*.pyc" ":(exclude)*.pyo")  # BH-1138-PYCACHE-EXCLUDE
    if [ "${#ex[@]}" -gt 0 ]; then git add -A -- . "${ex[@]}" 2>/dev/null
    else git add -A -- . 2>/dev/null; fi
    if git diff --cached --quiet 2>/dev/null; then
      say "$stage nothing to commit — everything in the working tree is ignored or excluded"
    else
      nfiles=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
      # --no-verify: a checkpoint is a backup, and a repo's pre-commit hook
      # (lint, typecheck, a formatter) is a minutes-long gate this must not
      # wait on and must not be failed by. The PR-time commit still runs them.
      local -a id=()
      git config user.email >/dev/null 2>&1 \
        || id=(-c "user.name=${CHECKPOINT_GIT_NAME:-harness}" -c "user.email=${CHECKPOINT_GIT_EMAIL:-harness@localhost}")
      if git ${id[@]+"${id[@]}"} commit -q --no-verify -m "wip: checkpoint $stage $(STAMP)" 2>/dev/null; then
        committed=1; sha=$(git rev-parse --short HEAD 2>/dev/null)
      else
        say "$stage commit FAILED — the tree is still only on this machine"
        return 1
      fi
    fi
  fi

  # --- push -----------------------------------------------------------------
  # Nothing to push is a real outcome, not a failure: a clean tree whose branch
  # already matches origin is the idempotent no-op this is meant to be.
  local remote_sha local_sha
  remote_sha=$(git rev-parse -q --verify "refs/remotes/origin/$br" 2>/dev/null || true)
  local_sha=$(git rev-parse HEAD 2>/dev/null)
  if [ -z "$committed" ] && [ "$remote_sha" = "$local_sha" ]; then
    say "$stage clean — nothing uncommitted and $br is already on origin at ${local_sha:0:7}"
    return 0
  fi

  # The token is re-read HERE, immediately before the spend, exactly as
  # bin/run-build.sh's GH_LIVE does: an installation token lives an hour and a
  # watcher that resolved one at minute zero would push with a dead credential
  # at minute sixty (bin/lib/gh-token-live.sh, the 2026-09-14 incident).
  # shellcheck source=bin/lib/gh-token-live.sh
  [ -r "$H/bin/lib/gh-token-live.sh" ] && . "$H/bin/lib/gh-token-live.sh"
  command -v gh_token_live >/dev/null 2>&1 && gh_token_live "$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  # The lease is EXPLICIT for the same reason bin/run-build.sh's LEASE() is:
  # pool clones are `--depth 50` single-branch, so refs/remotes/origin/<branch>
  # does not exist through a fetch refspec and a bare --force-with-lease reads
  # as "the remote must not exist" — rejecting every push after the first.
  # A HELD ticket's branch is not written from here either (BH-2504): a lead
  # who put the ticket on HOLD mid-build owns the branch, and this watcher
  # would otherwise keep pushing under them. The hold is read per push.
  # shellcheck source=bin/lib/hold-push.sh
  command -v hold_push >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null || . "$H/bin/lib/hold-push.sh" 2>/dev/null
  if HOLD_PUSH_LOG="" hold_push -u "${CK_PROJECT:--}" - "$PWD" origin "$br" "$br" "${remote_sha:-new}" 2>/dev/null; then
    git update-ref "refs/remotes/origin/$br" "$local_sha" 2>/dev/null || true
    if [ -n "$committed" ]; then
      say "$stage committed $nfiles file(s) as $sha and pushed $br to origin — this tree now survives the machine"
    else
      say "$stage pushed $br to origin at ${local_sha:0:7} (already committed, not yet on origin)"
    fi
    return 0
  fi
  if [ -n "$committed" ]; then
    say "$stage committed $nfiles file(s) as $sha but the push of $br did NOT land — the work is on this machine only"
  else
    say "$stage push of $br did NOT land — the commits are on this machine only"
  fi
  alert_once push "$br could not be pushed from $wt — a machine death here loses the committed tree"
  return 1
}

# --- the watcher --------------------------------------------------------------
# Backgrounded by the stage it protects, killed when the stage ends, and it dies
# on its own when its parent does: a run-build that is SIGKILLed runs no trap,
# and an orphan looping forever on a box would keep force-pushing a branch
# nothing owns any more.
do_watch() { # do_watch <build-dir> <worktree> <branch> <stage>
  load_build "$1"
  disabled && return 0
  local every="${CHECKPOINT_EVERY_MIN:-15}"
  case "$every" in ''|*[!0-9]*) every=15 ;; esac
  [ "$every" -gt 0 ] || return 0
  local parent="${CHECKPOINT_PARENT_PID:-$PPID}"
  say "${4:-execute} watcher armed — checkpointing every ${every}m while the stage runs"
  while :; do
    sleep $(( every * 60 ))
    kill -0 "$parent" 2>/dev/null || return 0
    do_checkpoint "$1" "$2" "$3" "${4:-execute}" || true
  done
}

# --- resume detection ---------------------------------------------------------
# "Is there already a pushed, unfinished attempt at this ticket?" Answered from
# the REMOTE, because the disk that held the last attempt is usually gone.
#
# The signal is wip commits at the tip. Every finished build squashes them away
# before it opens its PR, so a branch that still carries them is a lane that
# died on the way — which is precisely the branch a new build of the same key
# must continue instead of re-deriving from scratch.
do_resume_branch() { # do_resume_branch <worktree> <branch> [base]
  disabled && return 1
  cd "$1" 2>/dev/null || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local br="$2" base="${3:-}"
  [ -n "$base" ] || base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -n "$base" ] || base=main

  # A base we cannot resolve locally is fetched once; without it "commits this
  # branch has that the base does not" has no meaning and we say nothing rather
  # than guess at a count.
  local baseref=""
  for r in "refs/remotes/origin/$base" "refs/heads/$base"; do
    git rev-parse -q --verify "$r" >/dev/null 2>&1 && { baseref="$r"; break; }
  done
  if [ -z "$baseref" ]; then
    git fetch origin "+refs/heads/$base:refs/remotes/origin/$base" --quiet 2>/dev/null \
      && baseref="refs/remotes/origin/$base"
  fi
  [ -n "$baseref" ] || return 1

  # Newest attempt first: ticket/x-r3 beats ticket/x-r2 beats ticket/x.
  local cands
  cands=$(git ls-remote --heads origin "$br" "$br-r*" 2>/dev/null \
            | awk '{sub(/^refs\/heads\//,"",$2); print $2}' \
            | sed -E 's/^(.*)-r([0-9]+)$/\2 \1-r\2/; t; s/^(.*)$/1 \1/' \
            | sort -rn -k1,1 | awk '{print $2}')
  [ -n "$cands" ] || return 1

  local b nwip nall
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    git fetch origin "+refs/heads/$b:refs/remotes/origin/$b" --quiet 2>/dev/null || continue
    nwip=$(git log --format=%s "refs/remotes/origin/$b" --not "$baseref" 2>/dev/null | grep -c '^wip:' || true)
    [ "${nwip:-0}" -gt 0 ] || continue
    # An open PR means the dispatcher, not this script, decides what happens to
    # that head (bin/run-build.sh's TARGET_BRANCH path). Only consulted when gh
    # answers: no gh, no network, no opinion — the wip-tip invariant above is
    # the load-bearing guard and a PR-less dead lane is the whole point.
    if command -v gh >/dev/null 2>&1; then
      local pr
      pr=$(gh pr list --head "$b" --state open --json number -q '.[0].number' 2>/dev/null)
      [ -n "$pr" ] && continue
    fi
    nall=$(git rev-list --count "refs/remotes/origin/$b" --not "$baseref" 2>/dev/null || echo 0)
    printf '%s|%s|%s\n' "$b" "$nwip" "$nall"
    return 0
  done <<< "$cands"
  return 1
}

case "${1:-}" in
  --watch)          shift; do_watch "${1:?build-dir}" "${2:?worktree}" "${3:?branch}" "${4:-execute}" ;;
  --resume-branch)  shift; do_resume_branch "${1:?worktree}" "${2:?branch}" "${3:-}" ;;
  ''|-h|--help)     sed -n '2,8p' "$0"; exit 2 ;;
  *)                do_checkpoint "${1:?build-dir}" "${2:?worktree}" "${3:?branch}" "${4:-execute}" ;;
esac
