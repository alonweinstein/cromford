#!/bin/bash
# bin/lib/gh-pr-merge.sh — MERGING IS A REST CALL, NOT A GRAPHQL MUTATION.
# Sourced, never executed.
#
#   gh_pr_merge_rest <owner/repo> <pr-number> <sha-or-empty> \
#                    <stderr-log> <pipeline-log> [tag] [delete:0|1]
#     rc 0  MERGED over REST. stdout = the merge sha from the 200 body. That sha
#           may be empty (GitHub answered `merged:true` and nothing else); the
#           log says so and the caller reads the merge commit its own way.
#     rc 2  NO REST rung reached a verdict — every rung was rate-limited (403 /
#           429), invisible (404), 5xx, or answered no status at all — OR the
#           ladder is switched off. The CALLER runs its own `gh pr merge` line,
#           byte for byte as it did before BH-892.
#     rc 3  HTTP 405 — a NAMED PARK ("Base branch was modified", "Pull Request is
#           not mergeable", a merge-queue-required repo …). stdout = GitHub's
#           message. Terminal for this call: no climb, no GraphQL retry.
#     rc 4  HTTP 409 — the head moved since the sha this merge was bound to.
#           stdout = GitHub's message. Terminal.
#     rc 5  HTTP 422 or any other 4xx refusal. stdout = the message. Terminal.
#
# WHY (BH-892, 2026-09-18). `gh pr merge` is a GraphQL mutation. On 2026-09-18
# the fleet PAT's GraphQL bucket was empty:
#   GraphQL: API rate limit already exceeded for user ID 2220366
# Mission Control commands 15934 (example-org/project-4#1598) and 15937 (#1599)
# DEAD-LETTERED with `merge failed: GraphQL: API rate limit …` — while
# `PUT /repos/example-org/project-4/pulls/1598/merge` with merge_method=squash landed
# both PRs at once. REST and GraphQL are separate budgets; this repo already
# learned that for READS (BH-709, BH-374) and for the PR CREATE (BH-848, whose
# bin/lib/gh-pr-create.sh this lib is built on and sources), and not for the
# merge — the one write where a failure costs a strike, a park, or a rebuild of a
# ticket that was ready.
#
# THE RUNGS, in order:
#   rest              the identity the caller is already holding
#   rest:default-pat  the token bin/lib/gh-app-auth.sh saved before it swapped in
#                     an App token, when there is one
#   rest:admin-pat    GH_ADMIN_TOKEN from the env bundle, when set
#
# A RATE LIMIT CLIMBS; A REFUSAL DOES NOT. 403/429/404/5xx/no-status are "this
# identity could not answer" and move to the next rung. 200/405/409/422 are
# GitHub's answer ABOUT THE MERGE, and a second identity must never re-try a
# merge GitHub already refused — that is the whole of "never merged blind". Only
# exact HTTP STATUS CODES decide that (D10); a rate-limit message only decorates
# the log line, so a GitHub rewording cannot change the ladder's behaviour.
#
# THE REVIEWED SHA RIDES ON THE PUT whenever the caller has one. That is what
# makes a head that moved after the approval a 409 from GitHub rather than a
# merge of code no reviewer read. An EMPTY sha is an UNBOUND merge — today's
# behaviour at every call site that has no reviewed sha in hand — and it is
# logged as unbound, never filled in with a guess (D11).
#
# THE MERGE METHOD COMES FROM THE REPO (BH-1313), not from this file: a repo
# that refuses squash merges is merged with a merge commit, a rebase-only repo
# with a rebase, and a merge TRAIN with a merge commit even where squash is
# allowed. `gh_pr_merge_flag <slug>` gives the four lanes' own `gh pr merge`
# fallback lines the same answer. The rules and their cache live at _gpm_method.
#
# THE KILL FLAG puts the machine back on today's behaviour byte for byte:
#   PR_MERGE_REST=0 (env, or the row lib.gh-pr-merge.pr_merge_rest)   or   the row
#   switch.pr-merge-rest-off[.<box>]=1 (no row: flags/pr-merge-rest-off)
# The ladder then answers rc 2 without spending a single REST call, and every
# caller runs the `gh pr merge` line it ran before this shipped. The one
# difference since BH-1715: merge-sweep and poll-commands no longer put
# `--delete-branch` on that line. After a confirmed merge they call
# `_gpm_delete_branch`, which moves stacked children off the branch before
# deleting it.
#
# NATIVE-QUEUE REPOS ARE NOT THIS LIB'S BUSINESS. Under GitHub's own merge queue
# `gh pr merge` ENQUEUES, and REST has no equivalent — the callers check the
# provider before they get here (bin/merge-sweep.sh's SWEEP_QUEUE,
# bin/poll-commands.sh's mc_queue_provider, the conductor's mc_enqueue_github).
#
# NO TOKEN VALUE EVER REACHES A LOG. Rungs are named by WORD, the way
# bin/lib/gh-repo-token.sh names default/admin.
[ -n "${_GPM_LOADED:-}" ] && return 0
_GPM_H="${HARNESS:-/root/harness}"
_GPM_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
# The REST helpers (_gpc_split, _gpc_reason, _gpc_log, _gpc_is_ratelimit,
# _gpc_other_identities, gh_pr_rest_read) come from the create ladder rather than
# a second copy of them: two implementations of "read the status before the body"
# that drifted is exactly the bug BH-709 bought. Without that lib this file
# defines NOTHING and returns 0, so every caller's `command -v gh_pr_merge_rest`
# guard falls through to its own `gh pr merge` line.
# shellcheck source=bin/lib/gh-pr-create.sh
command -v gh_pr_rest_read >/dev/null 2>&1 \
  || . "$_GPM_H/bin/lib/gh-pr-create.sh" 2>/dev/null \
  || . "$_GPM_LIBDIR/gh-pr-create.sh" 2>/dev/null \
  || true
command -v gh_pr_rest_read >/dev/null 2>&1 || return 0
# The TRAIN recogniser is shared with bin/test-impact.sh (BH-1428): two
# recognisers that disagree is what let a batch train squash-merge. It is
# OPTIONAL — without it `_gpm_is_train` answers "not a train", which is the
# pre-BH-1313 answer and never a guess in the other direction.
# shellcheck source=bin/lib/train-shape.sh
command -v train_is_train >/dev/null 2>&1 \
  || . "$_GPM_H/bin/lib/train-shape.sh" 2>/dev/null \
  || . "$_GPM_LIBDIR/train-shape.sh" 2>/dev/null \
  || true
_GPM_LOADED=1

# PR_MERGE_REST is a registry knob since BH-1940
# (catalog/lanes.d/_lib.gh-pr-merge.json): operator row > cached row > env >
# registry default, through lane-gate.sh's lib_env_apply. That runs in a
# subshell, so its fail-closed exit 75 writes its one ALERTS line and cannot end
# the merge lane that sourced this file. Resolved once per process for each env
# value. Nothing resolved leaves the ladder ON: only 0 has ever switched it off.
_GPM_REST_KEY="none"; _GPM_REST=""
_gpm_knobs() {
  local k="${PR_MERGE_REST-}|${PR_MERGE_REST+set}"
  [ "$k" = "$_GPM_REST_KEY" ] && return 0
  _GPM_REST_KEY="$k"
  _GPM_REST=$(
    lg="$_GPM_H/bin/lib/lane-gate.sh"
    [ -r "$lg" ] || lg="$_GPM_LIBDIR/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply gh-pr-merge >/dev/null 2>&1
    printf '%s' "${PR_MERGE_REST:-}"
  ) || _GPM_REST=""
  return 0
}

# _gpm_switch — rc 0 when switch.pr-merge-rest-off[.<box>] (no row: the file
# flags/pr-merge-rest-off) is ON, 1 when not, 2 when lane-switch.sh could not
# load. A subshell: the resolver never reaches the caller.
_gpm_switch() {
  ( HARNESS="$_GPM_H"; . "$_GPM_LIBDIR/lane-switch.sh" >/dev/null 2>&1 || exit 2; lane_switch pr-merge-rest-off file ) >/dev/null 2>&1
}

_gpm_on() { # rc 1 = the ladder is switched off; the caller keeps today's line
  local rc=0
  if _gpm_switch; then return 1; else rc=$?; fi
  [ "$rc" = 2 ] && [ -f "$_GPM_H/flags/pr-merge-rest-off" ] && return 1
  _gpm_knobs
  [ "$_GPM_REST" = 0 ] && return 1
  return 0
}

# ── the merge METHOD comes from the repo (BH-1313, 2026-09-22) ───────────────
# example-org/cromford was switched to allow_squash_merge=false,
# allow_rebase_merge=false, allow_merge_commit=true at ~04:10Z, after an
# App-identity actor squash-merged three merge trains and #1191 within a minute
# of CI going green, once while the run was red. Every merge write in this fleet
# was hard-coded to squash, so under that setting every hub-lane merge on this
# repo answers HTTP 405 and the four merge lanes stay off.
#
# The method is READ, once per process per slug, and cached in a variable: a
# sourced lib's process is one lane tick, so a scratch file would only add a
# second thing that can go stale. The rules, in order:
#
#   1. squash REFUSED + merge commits allowed             -> merge
#   2. rebase is the ONLY method allowed                  -> rebase
#   3. both squash and merge allowed AND the PR is a TRAIN -> merge
#   4. anything else, INCLUDING a read that did not answer -> squash
#
# Rule 4 is today's behaviour, and it is also the answer when the read fails,
# comes back unparseable, or names none of the three fields — a repo whose
# settings we could not read merges exactly as it did before this shipped, with
# one log line saying so. Rule 3 is the only one that spends a SECOND read (the
# pull object, for the head ref and the title), and it is skipped whenever rule
# 1 or 2 already decided: a squash strands a train's members, because the
# train's commits never reach main and merged-by-ancestry never becomes true —
# each member then has to be closed by hand, which is what happened on
# 2026-09-22.
_GPM_METHOD_SLUG=""   # the slug the cached answer is about
_GPM_METHOD=""        # the method that answer resolved to
_GPM_ALLOWED=""       # the repo's OWN words for what it allows, for the 405 line

_gpm_bool() { # _gpm_bool <body> <field> -> true|false|"" (absent or unparseable)
  jq -r --arg f "$2" 'if has($f) and ((.[$f]|type)=="boolean") then (.[$f]|tostring) else "" end' \
    2>/dev/null <<<"${1:-}"
}

# _gpm_is_train <slug> <n> [token] — rc 0 when this PR is a merge train. WHAT a
# train looks like is bin/lib/train-shape.sh's answer and nobody else's
# (BH-1428): both of this repo's train shapes count, `batch/` + `batch(` as well
# as `train/` + `merge train:`. An unreadable pull object is NOT a train, and
# neither is anything at all when that lib is absent: a guess here would raise
# the method on a PR nobody asked to land as a merge commit.
_gpm_is_train() {
  local out code body ref title
  command -v train_is_train >/dev/null 2>&1 || return 1
  out=$(gh_pr_rest_read "repos/$1/pulls/$2" "${3:-}")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  [ "$code" = 200 ] || return 1
  ref=$(jq -r '.head.ref // empty' 2>/dev/null <<<"$body")
  title=$(jq -r '.title // empty' 2>/dev/null <<<"$body")
  train_is_train "$title" "$ref"
}

# _gpm_method SETS $_GPM_METHOD (and $_GPM_ALLOWED); it prints NOTHING and is
# never called in a command substitution — a subshell would throw the cache away
# on every call, and this lib's own stdout is the merge sha.
_gpm_method() { # _gpm_method <slug> <n> <plog> <tag> [token]
  local slug="$1" num="${2:-0}" plog="${3:-}" tag="${4:-pr-merge}" tok="${5:-}" \
        out code body sq mc rb
  if [ "$_GPM_METHOD_SLUG" = "$slug" ] && [ -n "$_GPM_METHOD" ]; then
    return 0
  fi
  # NOTHING IS CACHED UNTIL A 200 (BH-1428). Caching a refusal pinned `squash`
  # for the whole process off ONE identity's answer: a rate-limited (403/429) or
  # blind (404) first identity made the SECOND identity's PUT 405-park on a
  # merge-commit-only repo, and two conductor ticks later the wave was
  # BLOCKED_HUMAN. An unread answer leaves the key EMPTY, so the next rung asks
  # again with its own token.
  _GPM_METHOD_SLUG=""; _GPM_METHOD=squash; _GPM_ALLOWED=""
  out=$(gh_pr_rest_read "repos/$slug" "$tok")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  sq=$(_gpm_bool "$body" allow_squash_merge)
  mc=$(_gpm_bool "$body" allow_merge_commit)
  rb=$(_gpm_bool "$body" allow_rebase_merge)
  if [ "$code" != 200 ] || [ -z "$sq$mc$rb" ]; then
    _gpc_log "$plog" "[$tag] $slug's merge settings could not be read (HTTP ${code:-none}) — this merge goes out with merge_method=squash, exactly as this lane did before BH-1313; the answer is NOT cached, so the next identity reads it again with its own token"
    return 0
  fi
  _GPM_METHOD_SLUG="$slug"   # only a 200 is worth remembering
  _GPM_ALLOWED=""
  [ "$sq" = true ] && _GPM_ALLOWED="squash"
  [ "$mc" = true ] && _GPM_ALLOWED="${_GPM_ALLOWED:+$_GPM_ALLOWED, }merge"
  [ "$rb" = true ] && _GPM_ALLOWED="${_GPM_ALLOWED:+$_GPM_ALLOWED, }rebase"
  [ -n "$_GPM_ALLOWED" ] || _GPM_ALLOWED="none"
  if [ "$sq" != true ] && [ "$mc" = true ]; then
    _GPM_METHOD=merge
    _gpc_log "$plog" "[$tag] $slug refuses squash merges — this merge goes out with merge_method=merge (the repo allows: $_GPM_ALLOWED)"
  elif [ "$sq" != true ] && [ "$mc" != true ] && [ "$rb" = true ]; then
    _GPM_METHOD=rebase
    _gpc_log "$plog" "[$tag] $slug allows only rebase merges — this merge goes out with merge_method=rebase"
  elif [ "$sq" = true ] && [ "$mc" = true ] && _gpm_is_train "$slug" "$num" "$tok"; then
    _GPM_METHOD=merge
    _gpc_log "$plog" "[$tag] $slug#$num is a merge train — it goes out with merge_method=merge, because a squash leaves its members' commits off main and every one of them then has to be closed by hand"
  fi
  return 0
}

# gh_pr_merge_flag <slug> — the `gh pr merge` FLAG for the same answer, for the
# four lanes' own fallback lines. A caller that cannot find this function (a box
# whose harness sync has not landed the lib) keeps its own `--squash`, and so
# does every caller while the kill flag is on: "today's behaviour byte for byte"
# includes spending no REST call to decide it.
gh_pr_merge_flag() { # gh_pr_merge_flag <slug> [pr-number] [pipeline-log] [tag]
  local slug="${1:-}"
  [ -n "$slug" ] || { printf -- '--squash'; return 0; }
  _gpm_on || { printf -- '--squash'; return 0; }
  _gpm_method "$slug" "${2:-0}" "${3:-}" "${4:-pr-merge}"
  printf -- '--%s' "$_GPM_METHOD"
}

_gpm_put() { # _gpm_put <slug> <n> <sha> [token] [method] -> line 1 = HTTP code, rest = body
  local slug="$1" n="$2" sha="$3" tok="${4:-}" method="${5:-squash}" raw=""
  local -a a=(api -i -X PUT "repos/$slug/pulls/$n/merge" -f "merge_method=$method")
  # The sha FIELD only exists when we have one: an empty `sha=` would be a
  # fabricated binding, and GitHub would refuse every merge on it.
  [ -n "$sha" ] && a+=(-f "sha=$sha")
  if [ -n "$tok" ]; then raw=$(GH_TOKEN="$tok" gh "${a[@]}" 2>>"${_GPC_STDERR:-/dev/null}")
  else raw=$(gh "${a[@]}" 2>>"${_GPC_STDERR:-/dev/null}"); fi
  _gpc_split "$raw"
}

_gpm_del_ref() { # _gpm_del_ref <slug> <ref> [token] -> line 1 = HTTP code
  local slug="$1" ref="$2" tok="${3:-}" raw=""
  if [ -n "$tok" ]; then
    raw=$(GH_TOKEN="$tok" gh api -i -X DELETE "repos/$slug/git/refs/heads/$ref" 2>>"${_GPC_STDERR:-/dev/null}")
  else
    raw=$(gh api -i -X DELETE "repos/$slug/git/refs/heads/$ref" 2>>"${_GPC_STDERR:-/dev/null}")
  fi
  _gpc_split "$raw"
}

# THE OPEN PRs STACKED ON A REF (BH-1483). Deleting a branch that an open PR is
# BASED on is how GitHub closes that PR: `base_ref_deleted` and then `closed`,
# two seconds apart. `delete_branch_on_merge` is false on these repos, so
# GitHub's own retarget-on-delete never runs and there is nothing to catch it.
#
#   rc 0 — stdout is the open child PR numbers, one per line, and that list is
#          PROVEN complete (possibly empty).
#   rc 1 — stdout is WHY the list is not proven, in one phrase for the log.
#
# A full page of 100 is rc 1 on purpose (D12): `_gpc_split` drops the `Link`
# header, so a second page cannot be proven absent, and "we read 100 and stopped"
# is not "there are no more". Every rc 1 arm keeps the branch.
_gpm_open_children() { # _gpm_open_children <slug> <ref> [token]
  local slug="$1" ref="$2" tok="${3:-}" enc out code body n
  # A ref with a `/` is the normal case (ticket/bh-1385), and an unencoded slash
  # in the query value makes GitHub read a different filter than we meant.
  enc=$(jq -rn --arg r "$ref" '$r|@uri' 2>/dev/null)
  if [ -z "$enc" ]; then
    printf 'the head ref could not be encoded for the open-PR query'; return 1
  fi
  out=$(gh_pr_rest_read "repos/$slug/pulls?state=open&base=$enc&per_page=100" "$tok")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  if [ "$code" != 200 ]; then
    printf 'the open-PR list answered HTTP %s' "${code:-none}"; return 1
  fi
  n=$(jq -r 'if type=="array" then length else empty end' 2>/dev/null <<<"$body")
  case "${n:-x}" in
    ''|*[!0-9]*) printf 'the open-PR list answered 200 with a body that is not a JSON array'; return 1 ;;
  esac
  if [ "$n" -ge 100 ]; then
    printf 'the open-PR list came back a full page of %s and there is no Link header here to prove a second page is absent' "$n"
    return 1
  fi
  jq -r '.[].number // empty' 2>/dev/null <<<"$body"
  return 0
}

# RETARGET ONE CHILD, over REST. Line 1 of the answer is the HTTP status, and
# the caller branches on THAT and never on gh's exit code (D10) — the same
# reason mc_retarget_base takes this route at bin/lib/mc/rebase.sh:448: `gh pr
# edit --base` has reported success on this object and changed nothing.
_gpm_patch_base() { # _gpm_patch_base <slug> <n> <base> [token] -> line 1 = HTTP code
  local slug="$1" n="$2" base="$3" tok="${4:-}" raw=""
  if [ -n "$tok" ]; then
    raw=$(GH_TOKEN="$tok" gh api -i -X PATCH "repos/$slug/pulls/$n" -f "base=$base" 2>>"${_GPC_STDERR:-/dev/null}")
  else
    raw=$(gh api -i -X PATCH "repos/$slug/pulls/$n" -f "base=$base" 2>>"${_GPC_STDERR:-/dev/null}")
  fi
  _gpc_split "$raw"
}

# A CHILD MOVED OFF A MERGED PARENT IS OWED A RESTACK (BH-1715). The PATCH
# below only changes the child's base. Its branch still carries the parent's
# pre-merge commits, and nothing pushes it, so it sits with no CI and a diff two
# tickets wide. The conductor restacks such a child when IT merged the parent
# (BH-1670), but merge-sweep and poll-commands merge through here, and by the
# time the conductor looks the child is already on main.
#
# So this writes the conductor's own owed-follow record, which pr_worker drains
# through mc_stack_follow. The ancestry check there decides whether there is
# anything to do: a branch that still has the parent head is rebased with
# `--onto <base> <parent head>` and pushed once, and one that does not is
# cleared. The format is bin/lib/mc/rebase.sh `mc_stack_pending_put`'s, and it
# is written here because this lib does not source the conductor's.
# tests/stack-follow-sweep-merge.bh-1715-test.sh section A pins that the two
# agree field for field.
#   $HARNESS/state/stack-follow/<owner_repo>#<child>
#   <parent-num> <parent-url> <parent-branch> <parent-head> <base> 0 <since>
# Atomic (tmp + mv), so a conductor worker reads the old line or the new one.
_gpm_owe_restack() { # _gpm_owe_restack <slug> <child> <parent-num> <parent-url> <parent-branch> <parent-head> <base>
  local f tmp
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${6:-}" ] && [ -n "${7:-}" ] || return 1
  f="$_GPM_H/state/stack-follow/${1//\//_}#$2"; tmp="$f.tmp.$$"
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\t%s\t0\t%s\n' "${3:--}" "${4:--}" "${5:--}" "$6" "$7" "$(date -u +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# What `--delete-branch` did, after the merge and never instead of it. BEST
# EFFORT throughout: a protected branch, a branch someone already deleted, or a
# token that cannot write refs is one log line and nothing else — the merge has
# already happened and no failure here may change that verdict.
#
# rc 1 means the branch was deliberately KEPT because an open PR is still based
# on it. It is NOT a failed merge and no caller may read it as one — the one
# call site swallows it.
_gpm_delete_branch() { # _gpm_delete_branch <slug> <n> <token> <plog> <tag>
  local slug="$1" n="$2" tok="$3" plog="$4" tag="$5" out code body ref hrepo \
        pbase phead kids kid left=0 leftn=""
  out=$(gh_pr_rest_read "repos/$slug/pulls/$n" "$tok")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  ref=$(jq -r '.head.ref // empty' 2>/dev/null <<<"$body")
  hrepo=$(jq -r '.head.repo.full_name // empty' 2>/dev/null <<<"$body")
  # WHERE A STACKED CHILD GOES: this PR's OWN base, read from the object we are
  # already holding, so it costs no second call. Literally its own base and not
  # the repo's default branch — a doubly stacked PR's base IS a feature branch,
  # and retargeting to main would silently flatten a stack nobody asked us to.
  pbase=$(jq -r '.base.ref // empty' 2>/dev/null <<<"$body")
  # The PRE-MERGE head, from the same object: the restack a retargeted child is
  # owed replays everything after it (BH-1715).
  phead=$(jq -r '.head.sha // empty' 2>/dev/null <<<"$body")
  if [ "$code" != 200 ] || [ -z "$ref" ]; then
    _gpc_log "$plog" "[$tag] the merged branch was NOT deleted: its head ref could not be read (HTTP ${code:-none}) — best effort, the merge stands"
    return 0
  fi
  # ONLY A PR GITHUB SAYS IS MERGED (BH-1715). The gh fallbacks call this after
  # `gh pr merge` exits 0, and on a repo behind GitHub's native queue that exit
  # is an ENQUEUE which the queue reader cannot tell from a merge (it answers
  # `unknown`). Retargeting the children of an unmerged parent puts its commits
  # in their diffs, and deleting its head ref drops it from the queue. So the
  # object already in hand has to say `merged: true`; anything else keeps the
  # branch and touches no child.
  if [ "$(jq -r '.merged // empty' 2>/dev/null <<<"$body")" != true ]; then
    _gpc_log "$plog" "[$tag] the branch $ref was NOT deleted: GitHub does not say #$n is merged (an enqueue is not a merge) — no child retargeted, nothing recorded"
    return 0
  fi
  # THE DELETE IS AGAINST THE BASE REPO, so the branch it names must LIVE there.
  # A PR from a fork has its head in the fork, and `refs/heads/$ref` in the base
  # repo is then a DIFFERENT branch that happens to share the name — deleting it
  # would destroy work no one asked us to touch. `gh pr merge --delete-branch`,
  # the call this replaces, skips the remote delete on a cross-repository head
  # for the same reason. Ownership has to be PROVEN: a head whose repo the answer
  # does not name (a fork deleted before the merge settled) is not proof.
  # Lowercased on both sides: GitHub's canonical full_name and a fleet.conf slug
  # can differ in case, and a case-only mismatch must not skip every delete.
  if [ "${hrepo,,}" != "${slug,,}" ]; then
    _gpc_log "$plog" "[$tag] the merged branch $ref was NOT deleted: its head lives in ${hrepo:-a repo this answer does not name}, not $slug — a branch of that name here is not the one that merged"
    return 0
  fi
  # NOTHING IS DELETED UNTIL EVERY STACKED CHILD HAS BEEN MOVED OFF IT. The
  # order is the whole of BH-1483: list, PATCH, and only then DELETE. Every arm
  # that cannot finish that sequence KEEPS the branch and says which PRs kept it
  # — a branch left behind costs one line of cleanup, a closed PR costs a human
  # reopening it by hand (#1453, 14:27:16Z).
  if [ -z "$pbase" ]; then
    _gpc_log "$plog" "[$tag] the merged branch $ref was NOT deleted: this PR's own base ref did not read, so an open PR stacked on $ref would have nowhere to be retargeted to — the branch stays"
    return 1
  fi
  kids=$(_gpm_open_children "$slug" "$ref" "$tok") || {
    _gpc_log "$plog" "[$tag] the merged branch $ref was NOT deleted: $kids — an open PR based on it would be CLOSED by the delete, and a list we could not read is never read as no children"
    return 1
  }
  for kid in $kids; do
    out=$(_gpm_patch_base "$slug" "$kid" "$pbase" "$tok")
    code=$(head -n 1 <<<"$out")
    if [ "$code" = 200 ]; then
      _gpc_log "$plog" "[$tag] $slug#$kid was based on the merged branch $ref — retargeted to $pbase before the delete"
      # BEST EFFORT: a record that is not written leaves the child retargeted
      # and unrestacked, which is what happened before BH-1715, and says so. It
      # never changes the delete decision or the merge verdict.
      if [ -z "$phead" ]; then
        _gpc_log "$plog" "[$tag] $slug#$kid is owed a restack, but #$n's head sha did not read — nothing recorded; rebase it onto $pbase by hand"
      elif _gpm_owe_restack "$slug" "$kid" "$n" "https://github.com/$slug/pull/$n" "$ref" "$phead" "$pbase"; then
        _gpc_log "$plog" "[$tag] $slug#$kid is owed a restack onto $pbase from ${phead:0:8} — recorded for the merge conductor"
      else
        _gpc_log "$plog" "[$tag] $slug#$kid is owed a restack onto $pbase from ${phead:0:8}, and the record could not be written under $_GPM_H/state/stack-follow — rebase it by hand"
      fi
    else
      left=$((left + 1)); leftn="${leftn:+$leftn, }#$kid"
      _gpc_log "$plog" "[$tag] $slug#$kid is based on the merged branch $ref and the retarget to $pbase answered HTTP ${code:-none} — it stays where it is"
    fi
  done
  if [ "$left" != 0 ]; then
    _gpc_log "$plog" "[$tag] the merged branch $ref was NOT deleted: $left open PR(s) are still based on it ($leftn) — deleting it would close them"
    return 1
  fi
  out=$(_gpm_del_ref "$slug" "$ref" "$tok")
  code=$(head -n 1 <<<"$out")
  case "$code" in
    200|202|204) _gpc_log "$plog" "[$tag] deleted the merged branch $ref" ;;
    *) _gpc_log "$plog" "[$tag] the merged branch $ref was NOT deleted (HTTP ${code:-none}) — best effort, the merge stands" ;;
  esac
  return 0
}

# ONE rung. rc 0/3/4/5 are verdicts and stop the ladder; rc 2 means this identity
# did not answer and the caller may climb.
_gpm_rung() { # _gpm_rung <slug> <n> <sha> <plog> <tag> <rung> <token> <delete> [method]
  local slug="$1" num="$2" sha="$3" plog="$4" tag="$5" rung="$6" tok="$7" del="${8:-0}" \
        method="${9:-squash}"
  local out code body reason merged msha
  out=$(_gpm_put "$slug" "$num" "$sha" "$tok" "$method")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  reason=$(_gpc_reason "$body")
  case "$code" in
    200)
      # D9: a 200 is not a merge until GitHub SAYS merged. Anything else here is
      # an answer we do not understand, and reading it as a landing would stamp
      # a ticket merged that is still open.
      merged=$(jq -r '.merged // empty' 2>/dev/null <<<"$body")
      if [ "$merged" != true ]; then
        _gpc_log "$plog" "[$tag] rung $rung: HTTP 200 without \"merged\": true ($reason) — read as NO verdict, never as a merge"
        return 2
      fi
      msha=$(jq -r '.sha // empty' 2>/dev/null <<<"$body")
      # WHO MERGED IT, by WORD (BH-1313). The rung names the identity the PUT
      # went out on — that is the attribution an unexplained merge needs, and it
      # costs nothing: `GET /user` is 403 for an installation token and would
      # spend a call per merge to learn what the rung already says.
      if [ -n "$msha" ]; then
        _gpc_log "$plog" "[$tag] rung $rung: merged $slug#$num at $msha over REST with merge_method=$method, on identity $rung"
        printf '%s' "$msha"
      else
        _gpc_log "$plog" "[$tag] rung $rung: merged $slug#$num over REST with merge_method=$method, on identity $rung — the 200 carried no sha, so the caller reads the merge commit its own way"
      fi
      # The rc is DISCARDED on purpose (BH-1483): _gpm_delete_branch now answers
      # non-zero when it deliberately kept the branch, and this merge has already
      # happened. Under a caller's `set -e` the bare `&&` form would have taken
      # that non-zero as the lane's own exit status.
      if [ "$del" = 1 ]; then
        _gpm_delete_branch "$slug" "$num" "$tok" "$plog" "$tag" || true
      fi
      return 0 ;;
    405)
      # ONE LOUD LINE, NEVER A RETRY (BH-1313). A 405 is now also how a repo says
      # "not with THAT method", and the line has to carry enough to act on: the
      # repo, the method we tried, and what the repo's own settings allow. A
      # second attempt with another method would be this ladder re-trying a merge
      # GitHub already refused, which is the one thing it must never do.
      _gpc_log "$plog" "[$tag] rung $rung: HTTP 405 — park: $reason — $slug refused merge_method=$method; the repo allows: ${_GPM_ALLOWED:-unknown (its settings did not read)}"
      printf '%s' "$reason"; return 3 ;;
    409)
      _gpc_log "$plog" "[$tag] rung $rung: HTTP 409 — the head moved since the sha this merge was bound to: $reason"
      printf '%s' "$reason"; return 4 ;;
    403|429)
      if _gpc_is_ratelimit "$reason"; then
        _gpc_log "$plog" "[$tag] rung $rung: HTTP $code — this identity is rate-limited on $slug ($reason) — climbing"
      else
        _gpc_log "$plog" "[$tag] rung $rung: HTTP $code — this identity may not merge $slug#$num ($reason) — climbing"
      fi
      return 2 ;;
    404)
      _gpc_log "$plog" "[$tag] rung $rung: HTTP 404 — $slug#$num is invisible to this identity ($reason) — climbing, never read as merged or as absent"
      return 2 ;;
    5??)
      _gpc_log "$plog" "[$tag] rung $rung: HTTP $code from GitHub ($reason) — no verdict about this merge, climbing"
      return 2 ;;
    4??)
      _gpc_log "$plog" "[$tag] rung $rung: HTTP $code — GitHub refused this merge: $reason"
      printf '%s' "$reason"; return 5 ;;
    "")
      _gpc_log "$plog" "[$tag] rung $rung: the merge PUT answered no HTTP status at all — no verdict, climbing"
      return 2 ;;
    *)
      _gpc_log "$plog" "[$tag] rung $rung: HTTP $code ($reason) — no verdict about this merge, climbing"
      return 2 ;;
  esac
}

gh_pr_merge_rest() { # <slug> <pr-number> <sha-or-empty> <stderr-log> <pipeline-log> [tag] [delete]
  local slug="${1:?owner/repo}" num="${2:?pr number}" sha="${3:-}" \
        errlog="${4:-/dev/null}" plog="${5:-}" tag="${6:-pr-merge}" del="${7:-0}"
  local _GPC_STDERR="$errlog"   # every rung's stderr lands where the caller reads it
  local name tok rc n=0 method

  if ! _gpm_on; then
    _gpc_log "$plog" "[$tag] the REST merge ladder is switched off (PR_MERGE_REST=0 or flags/pr-merge-rest-off) — the caller's own gh pr merge runs, which is the pre-BH-892 behaviour"
    return 2
  fi
  [ -n "$sha" ] || _gpc_log "$plog" "[$tag] no reviewed sha in hand — this merge goes out UNBOUND, exactly as this lane did before BH-892"

  # EVERY RUNG RESOLVES THE METHOD WITH ITS OWN IDENTITY (BH-1428). A 200 is
  # cached, so on the healthy path this is one read for the whole ladder and
  # every rung sends the same method — a climb is a change of IDENTITY, never of
  # what this merge is. When an identity could not READ the settings, nothing is
  # cached and the next rung asks again with its own token, which is the whole
  # point: the capped identity must not decide the method for the one that can.
  _gpm_method "$slug" "$num" "$plog" "$tag" ""; method="$_GPM_METHOD"
  _gpm_rung "$slug" "$num" "$sha" "$plog" "$tag" rest "" "$del" "$method"; rc=$?
  [ "$rc" = 2 ] || return "$rc"

  while IFS=$'\t' read -r name tok; do
    [ -n "${tok:-}" ] || continue
    n=$((n + 1))
    _gpm_method "$slug" "$num" "$plog" "$tag" "$tok"; method="$_GPM_METHOD"
    _gpm_rung "$slug" "$num" "$sha" "$plog" "$tag" "rest:$name" "$tok" "$del" "$method"; rc=$?
    [ "$rc" = 2 ] || return "$rc"
  done < <(_gpc_other_identities)

  [ "$n" = 0 ] && _gpc_log "$plog" "[$tag] no second identity on this machine — the REST ladder ends at rung rest"
  _gpc_log "$plog" "[$tag] no REST rung reached a verdict about this merge — the caller's own gh pr merge runs next"
  return 2
}
