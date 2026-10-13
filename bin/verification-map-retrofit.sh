#!/bin/bash
# bin/verification-map-retrofit.sh — move a PR's hand-added verification-map
# README rows into docs/verification-map/entries/<TICKET>.md, then rebuild the
# README from its sources.
#
#   verification-map-retrofit.sh [--dry-run] <repo-path> <pr-number>
#   verification-map-retrofit.sh [--dry-run] --all-open <repo-path>
#
# WHY (BH-868). Until BH-798 docs/verification-map/README.md was a source that
# every build hand-edited. It is now GENERATED from index/head.md, entries/<KEY>.md
# and index/tail.md. Every PR cut before that change still carries its row as a
# hand edit of the README, so merging main into it conflicts on a file the ticket
# is not about — and the only mechanical resolver that matched the README was the
# `*.md` UNION arm of mc_resolve_conflicts, which glues main's generated table
# and the PR's hand table into one file. That "resolution" pushes a head with a
# duplicated header and a row no entry file backs, CI's
# `bin/verification-map-build.sh --check` step goes red, and the park spends a
# whole fix round on a mechanical problem. ~27 open PRs sit on that shape.
#
# The right operation for a generated file is REBUILD FROM SOURCES, which first
# needs the hand row moved into a source. That is this script:
#   1. diff the PR head against its merge base, take the rows it ADDED
#   2. write them to docs/verification-map/entries/<TICKET>.md
#   3. take main's README, re-run bin/verification-map-build.sh, assert --check
#   4. commit on the PR's own branch, push, comment the before/after row count
#
# IT REFUSES ANYTHING BUT APPENDED ROWS. An edited row, a removed row, an added
# header or separator, a line of prose, a row whose entry target main already
# has: all rc 3, nothing written, nothing pushed. A human (or the fix round)
# owns those, because guessing at them is how a mechanical rung ships a wrong
# table.
#
# EXIT CODES
#   0  retrofitted — an entry file was written and the branch was pushed
#   1  not this script's business (no build script / no generated layout on main)
#   2  a conflicted path outside docs/verification-map/README.md — out of scope,
#      the fix round owns it, and this script never touches those files
#   3  refused: the README change is not a pure row append (or no ticket key)
#   4  the PR head moved between the read and the push — nothing spent
#   5  NOTHING to retrofit: no appended row and the merged README already
#      rebuilds to itself. Distinct from 0 on purpose — a sweep that renders a
#      no-op as RETROFITTED reports 87 PRs fixed that it never touched.
#
# The `vmr-core` block below is sourced by mc_resolve_vmap_readme in
# bin/lib/merge-conductor-lib.sh, so the mechanical rung and this CLI resolve a
# README the same way, in one implementation. Sourcing it runs no CLI.
set -uo pipefail
# BH-868: the PR read below runs on a repo-scoped App token when this box mints one (gh-app-ratchet); unarmed boxes fall through to the PAT unchanged.
. "${HARNESS:-/root/harness}/bin/lib/gh-app-auth.sh" 2>/dev/null || true
# BH-4080: the bot commit identity lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-${BASH_SOURCE[0]%/*}/lib/deployment.sh}" || exit 1

VMR_REL=docs/verification-map
VMR_README="$VMR_REL/README.md"

# >>> vmr-core
# Everything in this block operates on a worktree that has just merged main —
# either mid-merge (MERGE_HEAD present) or with the merge already committed,
# which is what git leaves behind when the `merge=union` attribute on
# docs/verification-map/README.md resolves it without a conflict (BH-865). The
# ref that carries main's side is therefore a PARAMETER, not always MERGE_HEAD.
# Nothing here writes outside that worktree, calls gh, or pushes.

vmr_log() { echo "verification-map-retrofit: $*" >&2; }

# vmr_ticket_of_branch <branch> — BH-560 from ticket/bh-560 or ticket/bh-560-r2.
# Same rule as mc_ticket_of_branch; a branch with no key turns the whole
# mechanism off for that PR rather than guessing a filename.
vmr_ticket_of_branch() {
  local b="${1:-}" t
  [ -n "$b" ] || return 1
  t=$(tr '[:lower:]' '[:upper:]' <<<"${b##*/}")
  if [[ "$t" =~ ^([A-Z][A-Z0-9]*-[0-9]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  return 1
}

# vmr_is_table_row <line> — a data row, not the header and not the separator.
vmr_is_table_row() {
  local l="$1"
  case "$l" in
    '|'*) ;;
    *) return 1 ;;
  esac
  # `| feature | entry | primary lane |` and `|---|---|---|` are the table's
  # frame. A PR that adds either is re-opening the table, not appending to it.
  [[ "$l" =~ ^\|[[:space:]]*feature[[:space:]]*\| ]] && return 1
  [[ "$l" =~ ^\|[-[:space:]:|]*\|$ ]] && return 1
  return 0
}

# vmr_rows_of_file <file> — the data rows, one per line.
vmr_rows_of_file() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    vmr_is_table_row "$l" && printf '%s\n' "$l"
  done < "$1"
}

# vmr_added_rows <wt> <base> <ours> [theirs-readme-file]
#   The rows the PR appended to the README, on stdout. rc 3 = refuse, and the
#   message names the offending line so the fix round reads why.
vmr_added_rows() {
  local wt="$1" base="$2" ours="$3" theirs_readme="${4:-}" line body rows=""
  local diff
  diff=$(git -C "$wt" diff "$base" "$ours" -- "$VMR_README" 2>/dev/null) || return 3
  while IFS= read -r line; do
    case "$line" in
      # The two file headers, with their space: bare `---`/`+++` prefixes also
      # match a REMOVED `---` rule line (`-` + `---`) or an added `++x`, and
      # skipping those would let the classifier wave through exactly the edit
      # it exists to refuse.
      '--- '*|'+++ '*|'@@'*|'diff '*|'index '*) continue ;;
      '-'*)
        body="${line#-}"
        [ -z "${body//[[:space:]]/}" ] && continue
        vmr_log "refusing: the PR REMOVES or EDITS a README line, that is not an append: ${body}"
        return 3 ;;
      '+'*)
        body="${line#+}"
        body="${body%"${body##*[![:space:]]}"}"
        [ -z "$body" ] && continue
        if ! vmr_is_table_row "$body"; then
          vmr_log "refusing: the PR adds a README line that is not a table row: ${body}"
          return 3
        fi
        rows="$rows$body"$'\n' ;;
    esac
  done <<<"$diff"
  [ -n "$rows" ] || { printf ''; return 0; }
  # An added row whose entry target main's table already carries is an
  # edit-in-place wearing an append's clothes, or a duplicate feature. Either
  # way a human decides which of the two rows is the real one.
  if [ -n "$theirs_readme" ] && [ -f "$theirs_readme" ]; then
    local tgt
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      tgt=$(sed -n 's/.*](\([^)]*\)).*/\1/p' <<<"$line" | head -1)
      [ -n "$tgt" ] || continue
      if grep -qF "]($tgt)" "$theirs_readme"; then
        vmr_log "refusing: the added row's entry target $tgt is already in main's table: ${line}"
        return 3
      fi
    done <<<"$rows"
  fi
  printf '%s' "$rows"
  return 0
}

# vmr_theirs_ref <wt> — the ref carrying MAIN's side of the merge. MERGE_HEAD
#   while the merge is open; `origin/main` once git has committed it, which is
#   what a CLEAN merge under the union attribute leaves behind.
vmr_theirs_ref() {
  git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && { printf 'MERGE_HEAD'; return 0; }
  printf 'origin/main'
}

# vmr_check_in_sync <wt> — does the tree's README already rebuild to itself?
#   --check-committed, not --check: this asks about BYTES. Since BH-1175 plain
#   --check grades the SOURCES and would answer 0 for a glued README, which
#   would make every caller of this helper believe there is nothing to repair.
vmr_check_in_sync() {
  [ -x "$1/bin/verification-map-build.sh" ] || return 1
  "$1/bin/verification-map-build.sh" --check-committed --repo "$1" >/dev/null 2>&1
}

# vmr_preconditions <wt> <ticket-key> <theirs-ref>
#   Everything that decides WHETHER this script may act, in one place so the
#   dry run enforces exactly what the real run does (a dry run that prints
#   "WOULD write" for a PR the real run declines is a lie the operator acts on).
#   rc 0 mine | 1 not mine | 3 refused.
vmr_preconditions() {
  local wt="$1" key="$2" ref="${3:-MERGE_HEAD}"
  [ -n "$key" ] || { vmr_log "no ticket key — not resolving"; return 3; }
  [ -x "$wt/bin/verification-map-build.sh" ] || {
    vmr_log "$wt has no executable bin/verification-map-build.sh — not mine, falling through"; return 1; }
  git -C "$wt" cat-file -e "$ref:$VMR_REL/index/head.md" 2>/dev/null || {
    vmr_log "$ref carries no $VMR_REL/index/head.md — not the generated layout, falling through"; return 1; }
  git -C "$wt" cat-file -e "$ref:$VMR_README" 2>/dev/null || {
    vmr_log "$ref carries no $VMR_README — not the generated layout, falling through"; return 1; }
  return 0
}

# vmr_entry_clash <wt> <key> <rows> — rc 3 when an entry file is already on this
#   head carrying DIFFERENT rows; a human decides which of the two is real.
vmr_entry_clash() {
  local wt="$1" key="$2" rows="$3" entry="$1/$VMR_REL/entries/$2.md"
  [ -n "$rows" ] && [ -f "$entry" ] || return 0
  [ "$(cat "$entry")" = "$(printf '%s' "$rows")" ] && return 0
  vmr_log "refusing: $VMR_REL/entries/$key.md is already on this head with different rows"
  return 3
}

# vmr_decline <wt> <readme-keep-file> <entry> <entry-existed> <rc>
#   PUT THE TREE BACK. Everything after the README overwrite is fallible, and a
#   decline that leaves its half-done writes behind breaks two promises at once:
#   the `*.md` union fall-through needs the conflict markers this restores, and
#   an untracked entries/<KEY>.md survives `git merge --abort` in the conductor's
#   REUSED scratch clone, where the NEXT PR's retrofit would commit another
#   ticket's row into an unrelated PR.
vmr_decline() {
  local wt="$1" keep="$2" entry="$3" existed="$4" rc="$5"
  [ -f "$keep" ] && mv -f "$keep" "$wt/$VMR_README"
  [ "$existed" = 1 ] || rm -f "$entry"
  return "$rc"
}

# vmr_resolve_readme <wt> <base> <ours> <ticket-key> [theirs-ref]
#   The whole resolution, on a worktree that has just merged main (open or
#   committed). Stages the entry file and the regenerated README. Prints
#   `rows_before=<n> rows_after=<m>` for the caller's comment.
#   rc 0 resolved (a no-op counts) | 1 not mine | 3 refused, tree UNCHANGED.
vmr_resolve_readme() {
  local wt="$1" base="$2" ours="$3" key="$4" ref="${5:-}"
  local rows entry theirs tmp keep before after existed=0 rc=0
  [ -n "$ref" ] || ref=$(vmr_theirs_ref "$wt")
  vmr_preconditions "$wt" "$key" "$ref" || return $?

  theirs="$wt/.git-vmr-theirs-readme.$$"
  git -C "$wt" show "$ref:$VMR_README" > "$theirs" 2>/dev/null || { rm -f "$theirs"; return 1; }
  rows=$(vmr_added_rows "$wt" "$base" "$ours" "$theirs") || { rm -f "$theirs"; return 3; }
  before=$(vmr_rows_of_file "$theirs" | grep -c . )
  rm -f "$theirs"

  entry="$wt/$VMR_REL/entries/$key.md"
  vmr_entry_clash "$wt" "$key" "$rows" || return 3
  [ -f "$entry" ] && existed=1

  # Main's README wins, always: it is the generated artifact, and the rows the
  # PR added are now a source that the rebuild will fold back in. From here on
  # the tree is mutated, so every exit goes through vmr_decline.
  keep="$wt/.git-vmr-readme-keep.$$"
  cp "$wt/$VMR_README" "$keep" 2>/dev/null || : > "$keep"
  tmp="$wt/$VMR_README.vmr.$$"
  git -C "$wt" show "$ref:$VMR_README" > "$tmp" 2>/dev/null || { rm -f "$tmp"; vmr_decline "$wt" "$keep" "$entry" "$existed" 1; return 1; }
  mv "$tmp" "$wt/$VMR_README" || { vmr_decline "$wt" "$keep" "$entry" "$existed" 1; return 1; }
  if [ -n "$rows" ]; then
    mkdir -p "$wt/$VMR_REL/entries" || { vmr_decline "$wt" "$keep" "$entry" "$existed" 1; return 1; }
    printf '%s' "$rows" > "$entry" || { vmr_decline "$wt" "$keep" "$entry" "$existed" 1; return 1; }
  fi

  "$wt/bin/verification-map-build.sh" --repo "$wt" >/dev/null 2>&1 || {
    vmr_log "refusing: bin/verification-map-build.sh could not regenerate the README"
    vmr_decline "$wt" "$keep" "$entry" "$existed" 3; return 3; }
  # THE SECOND GATE: the repaired README must rebuild to itself, byte for byte.
  # --check-committed, not --check — this script only ever runs on a repo that
  # COMMITS its index (vmr_preconditions requires the README at the theirs ref),
  # and since BH-1175 plain --check grades the SOURCES instead of the bytes, so
  # it would accept a repair that did not actually converge.
  "$wt/bin/verification-map-build.sh" --check-committed --repo "$wt" >/dev/null 2>&1 || {
    vmr_log "refusing: --check-committed is still out of sync after the regenerate"
    vmr_decline "$wt" "$keep" "$entry" "$existed" 3; return 3; }

  git -C "$wt" add -- "$VMR_README" >/dev/null 2>&1 || rc=1
  [ "$rc" = 0 ] && [ -n "$rows" ] && { git -C "$wt" add -- "$VMR_REL/entries/$key.md" >/dev/null 2>&1 || rc=1; }
  [ "$rc" = 0 ] || { vmr_decline "$wt" "$keep" "$entry" "$existed" 1; return 1; }
  rm -f "$keep"
  after=$(vmr_rows_of_file "$wt/$VMR_README" | grep -c . )
  printf 'rows_before=%s rows_after=%s rows_moved=%s\n' "$before" "$after" "$(grep -c . <<<"$rows")"
  return 0
}
# <<< vmr-core

# ─── CLI ─────────────────────────────────────────────────────────────────────
# Sourcing the file stops here; only direct execution runs a sweep.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

# EVERY PR READ BELOW IS REST (bin/lib/gh-rest.sh), never the GraphQL-backed
# `gh pr view` / `gh pr list`: an --all-open sweep over ~90 PRs is exactly the
# burst that rate-limits the account, and a GraphQL limit answers with silence
# a caller reads as "no such PR" (#768).
# shellcheck source=/dev/null
. "${BASH_SOURCE[0]%/*}/lib/gh-rest.sh" 2>/dev/null || {
  echo "verification-map-retrofit: bin/lib/gh-rest.sh not found next to this script" >&2; exit 2; }

usage() { echo "usage: verification-map-retrofit.sh [--dry-run] <repo-path> <pr-number> | [--dry-run] --all-open <repo-path>" >&2; exit 2; }

DRY=0; ALL=0; REPO=""; PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --all-open) ALL=1; shift ;;
    -h|--help) usage ;;
    -*) echo "verification-map-retrofit: unknown argument $1" >&2; usage ;;
    *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$PR" ]; then PR="$1"; else usage; fi; shift ;;
  esac
done
[ -n "$REPO" ] && [ -d "$REPO/.git" ] || { echo "verification-map-retrofit: <repo-path> must be a git checkout" >&2; usage; }
[ "$ALL" = 1 ] || [ -n "$PR" ] || usage

# `config --get`, not `remote get-url`: the latter applies url.<base>.insteadOf
# rewrites, so on a box that rewrites github.com to a mirror or a local path the
# slug the REST calls are built from would stop being owner/repo.
SLUG=$(git -C "$REPO" config --get remote.origin.url 2>/dev/null \
        | sed -e 's#^git@[^:]*:##' -e 's#^https\?://[^/]*/##' -e 's/\.git$//')
[ -n "$SLUG" ] || { echo "verification-map-retrofit: $REPO has no origin remote" >&2; exit 2; }

WT=""
cleanup() {
  [ -n "$WT" ] && { git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; WT=""; }
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset || true
  return 0
}
trap cleanup EXIT INT TERM

# retrofit_one <pr-number> — rc per the header. Prints a human line; the sweep
# turns it into one summary line per PR.
retrofit_one() {
  local n="$1" meta branch head fork base ours conf out rc msg ref rows before after theirs bodyf
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  # BH-1485: `gh_rest_var`, so the line an operator reads names why.
  meta=""
  gh_rest_var meta GET "repos/$SLUG/pulls/$n" 2>/dev/null || {
    echo "#$n: could not read the PR (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON})"; return 1; }
  branch=$(jq -r '.head.ref // empty' <<<"$meta" 2>/dev/null)
  head=$(jq -r '.head.sha // empty' <<<"$meta" 2>/dev/null)
  fork=$(jq -r 'if (.head.repo.fork // false) then "true" else "false" end' <<<"$meta" 2>/dev/null)
  [ -n "$branch" ] && [ -n "$head" ] || { echo "#$n: no branch/head"; return 1; }
  SUM_BRANCH="$branch"
  if [ "$fork" = true ]; then
    echo "#$n $branch: fork PR, hands off"; return 3
  fi
  local key; key=$(vmr_ticket_of_branch "$branch") || { echo "#$n $branch: no ticket key in the branch name"; return 3; }

  git -C "$REPO" fetch -q origin main "$branch" >/dev/null 2>&1 || { echo "#$n $branch: fetch failed"; return 1; }
  # The lease is bound to the sha gh reported: if origin has moved since, this
  # run is reading a head nobody reviewed, so it spends nothing.
  local tip; tip=$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
  [ -n "$tip" ] || { echo "#$n $branch: the branch is gone from origin"; return 1; }
  if [ "$tip" != "$head" ]; then
    echo "#$n $branch: head moved ($head -> $tip), nothing spent"; return 4
  fi

  WT="$REPO/../.vmr-wt.$n.$$"
  git -C "$REPO" worktree add -f --detach "$WT" "$head" >/dev/null 2>&1 || { echo "#$n $branch: worktree add failed"; WT=""; return 1; }
  # --no-commit: git AUTO-COMMITS a clean merge, and since BH-865 main's
  # .gitattributes carries `docs/verification-map/README.md merge=union`, so the
  # README no longer conflicts for any branch that has merged main — the union
  # driver glues the two tables and the merge is clean. Reading the merge base
  # off MERGE_HEAD after that auto-commit found nothing and answered "nothing to
  # retrofit" for exactly the PRs that are red. Keep the merge open, and take
  # the base from origin/main so it is right whether or not one is in progress.
  git -C "$WT" -c user.email="$HARNESS_BOT_GIT_EMAIL" -c user.name="$HARNESS_BOT_GIT_NAME" \
      merge --no-commit --no-edit origin/main >/dev/null 2>&1
  conf=$(git -C "$WT" diff --name-only --diff-filter=U)
  if [ -n "$conf" ] && [ "$conf" != "$VMR_README" ]; then
    echo "#$n $branch: conflicted paths outside the generated README, out of scope:"
    printf '%s\n' "$conf"
    git -C "$WT" merge --abort >/dev/null 2>&1
    cleanup; return 2
  fi
  ref=$(vmr_theirs_ref "$WT")
  base=$(git -C "$WT" merge-base HEAD origin/main 2>/dev/null) || base=""
  ours=$(git -C "$WT" rev-parse HEAD)
  if [ -z "$base" ]; then
    echo "#$n $branch: no merge base with origin/main"
    git -C "$WT" merge --abort >/dev/null 2>&1; cleanup; return 1
  fi

  # The same preconditions on both paths, so a dry run can never print "WOULD
  # write" for a PR the real run then declines.
  vmr_preconditions "$WT" "$key" "$ref" 2>/dev/null; rc=$?
  if [ "$rc" != 0 ]; then
    echo "#$n $branch: $([ "$rc" = 1 ] && echo "not this script's business (no generated layout / no build script)" || echo "refused")"
    git -C "$WT" merge --abort >/dev/null 2>&1; cleanup; return "$rc"
  fi

  theirs="$WT/.vmr-theirs.$$"
  git -C "$WT" show "$ref:$VMR_README" > "$theirs" 2>/dev/null
  rows=$(vmr_added_rows "$WT" "$base" "$ours" "$theirs"); rc=$?
  before=$(vmr_rows_of_file "$theirs" | grep -c . ); rm -f "$theirs"
  if [ "$rc" != 0 ]; then
    echo "#$n $branch: REFUSED, the README change is not a pure row append"
    git -C "$WT" merge --abort >/dev/null 2>&1; cleanup; return 3
  fi
  if ! vmr_entry_clash "$WT" "$key" "$rows" 2>/dev/null; then
    echo "#$n $branch: REFUSED, $VMR_REL/entries/$key.md is already on this head with different rows"
    git -C "$WT" merge --abort >/dev/null 2>&1; cleanup; return 3
  fi

  # NOTHING is its own answer (rc 5). No appended row AND the merged tree's
  # README already rebuilds to itself means this PR was never in the cohort;
  # calling that RETROFITTED is how a sweep reports 87 PRs fixed it never
  # touched.
  if [ -z "$rows" ] && vmr_check_in_sync "$WT"; then
    echo "#$n $branch: nothing to retrofit"
    git -C "$WT" merge --abort >/dev/null 2>&1; cleanup; return 5
  fi

  if [ "$DRY" = 1 ]; then
    if [ -z "$rows" ]; then
      echo "#$n $branch: WOULD regenerate $VMR_README from main's sources (no row to move)"
    else
      after=$((before + $(grep -c . <<<"$rows")))
      echo "#$n $branch: WOULD write $VMR_REL/entries/$key.md:"
      printf '%s' "$rows"
      echo "#$n $branch: rows_before=$before rows_after=$after (dry run, nothing pushed)"
    fi
    git -C "$WT" merge --abort >/dev/null 2>&1; cleanup; return 0
  fi

  out=$(vmr_resolve_readme "$WT" "$base" "$ours" "$key" "$ref"); rc=$?
  if [ "$rc" != 0 ]; then
    echo "#$n $branch: retrofit declined (rc=$rc)"
    git -C "$WT" merge --abort >/dev/null 2>&1; cleanup; return "$rc"
  fi
  if [ -z "$(git -C "$WT" diff --cached --name-only)" ] && [ -z "$(git -C "$WT" rev-parse -q --verify MERGE_HEAD 2>/dev/null)" ]; then
    echo "#$n $branch: nothing to retrofit"; cleanup; return 5
  fi
  git -C "$WT" -c user.email="$HARNESS_BOT_GIT_EMAIL" -c user.name="$HARNESS_BOT_GIT_NAME" \
      commit -q -m "BH-868 retrofit: $key verification-map row moved to $VMR_REL/entries/$key.md, README regenerated" >/dev/null 2>&1 || {
    echo "#$n $branch: nothing to commit"; cleanup; return 0; }
  # The hold on the ticket the branch names is re-read at the push, and the
  # lease stays the sha gh reported (BH-2504, bin/lib/hold-push.sh). This lane
  # retrofits cromford's own verification map, whose tickets are issues.
  if ! { command -v hold_push >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null; } \
     || ! hold_push - "$SLUG#${key##*-}" "$WT" origin HEAD "$branch" "$head" >/dev/null 2>&1; then
    echo "#$n $branch: push refused (the head moved), nothing spent"
    cleanup; return 4
  fi
  before=$(sed -n 's/.*rows_before=\([0-9]*\).*/\1/p' <<<"$out")
  after=$(sed -n 's/.*rows_after=\([0-9]*\).*/\1/p' <<<"$out")
  msg="Retrofit by bin/verification-map-retrofit.sh (BH-868): moved this PR's hand-added README row(s) into $VMR_REL/entries/$key.md and regenerated the README from main. Rows before $before, after $after. bin/verification-map-build.sh --check-committed is in sync on this head. This push moved the head, so the sha-bound approval is dropped and the conductor buys one re-review of this PR."
  bodyf=$(mktemp "${TMPDIR:-/tmp}/vmr-comment.XXXXXX") && printf '%s\n' "$msg" > "$bodyf"
  gh_rest_comment "$SLUG" "$n" "$bodyf" \
    || echo "verification-map-retrofit: pushed, but the PR comment failed" >&2
  rm -f "$bodyf"
  echo "#$n $branch: retrofitted, rows_before=$before rows_after=$after"
  cleanup; return 0
}

status_of() {
  case "$1" in
    0) echo RETROFITTED ;;
    2) echo CODE-CONFLICT ;;
    3) echo REFUSED ;;
    4) echo HEAD-MOVED ;;
    5) echo NOTHING ;;
    *) echo UNREADABLE ;;
  esac
}

if [ "$ALL" = 1 ]; then
  REFUSALS=0
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  while IFS=$'\t' read -r n br; do
    [ -n "$n" ] || continue
    SUM_BRANCH="$br"
    body=$(retrofit_one "$n"); rc=$?
    detail=""
    [ "$rc" = 2 ] && detail=" $(grep -v ':' <<<"$body" | tr '\n' ' ')"
    echo "#$n $SUM_BRANCH $(status_of "$rc")${detail% }"
    [ "$rc" = 3 ] && REFUSALS=$((REFUSALS + 1))
  done < <(gh_rest_pr_list "$SLUG" open 2>/dev/null \
             | jq -r '.[] | [.number, .head.ref] | @tsv' 2>/dev/null)
  [ "$REFUSALS" = 0 ] || exit 3
  exit 0
fi

retrofit_one "$PR"; exit $?
