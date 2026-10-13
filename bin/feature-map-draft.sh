#!/bin/bash
# gh-identity: app-token
# bin/feature-map-draft.sh — BH-2005.3: draft a verification map for an app repo
# that has none, and open a PR with it. Operator-invoked, no cron line. It never
# merges: a map drafted by an agent is read by a person before it lands.
#
# usage: feature-map-draft.sh <project>|--all [--dry-run]
#   Runs on a BUILDER box: bin/agent-call.sh refuses on the hub (rc 77), which
#   this script reports as rc 1 with nothing pushed.
#   --all      every project with an in-app board (`fleet-conf.sh
#              --projects-with-board`, in fleet.conf order: the app repos a map is
#              drafted for); prints `<project> <OUTCOME>` per project and carries
#              on past a refusal. An unreadable project list fails closed (rc 1).
#   --dry-run  resolve the slug, run the refusal checks and read the cap, print
#              them, and stop. No worktree, no agent call, no push, no PR.
#
# Steps, stopping at the first unsatisfied one:
#   1 slug from fleet-conf.sh           4 cap from settings feature_map.draft_max_usd
#   2 map on origin/main -> skip        5 --dry-run stops here
#   3 open draft PR / branch -> refuse  6 agent drafts in a fresh worktree
#   7 deterministic post-check, commit, push, PR   8 record in logs/feature-map-draft.log
#
# rc: 0 PR opened / dry-run / --all all clean   1 failure (ALERTS line)
#     2 bad knob or usage   3 REFUSED (incl. FEATURE_MAP_DRAFT_ENABLED off)
#     4 DRAFT_EMPTY   5 ALREADY_MAPPED
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
REPOS_ROOT="${REPOS_ROOT:-/root/repos}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HARNESS/logs/feature-map-draft.log"
ALERTS="$HARNESS/logs/ALERTS.log"
BRANCH=feature-map/draft
# feature_map.draft_max_usd: the per-run dollar cap. 15 is the documented code
# fallback, used only when the settings row is absent or unreadable.
CAP_KEY=feature_map.draft_max_usd
CAP_DEFAULT=15

usage() {
  echo "usage: feature-map-draft.sh <project>|--all [--dry-run]  (run on a builder box: agent-call.sh refuses on the hub, rc 77)" >&2
  exit 2
}
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
alert() { mkdir -p "$HARNESS/logs"; echo "$(STAMP) [feature-map-draft] $*" >> "$ALERTS"; }
die() { echo "feature-map-draft: $2" >&2; alert "$2"; return "$1"; }
note() { mkdir -p "$HARNESS/logs"; echo "feature-map-draft: $*" >&2; echo "$(STAMP) $*" >> "$LOG"; }

TARGET=""; DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --all) [ -z "$TARGET" ] || usage; TARGET=--all ;;
    -*|"") usage ;;
    *) [ -z "$TARGET" ] || usage; TARGET="$a" ;;
  esac
done
[ -n "$TARGET" ] || usage

# The lane gate (catalog/lanes.d/feature-map-draft.json): flags/all-off or
# flags/lane-off-feature-map-draft exits 0 here, and lane_env_apply exports the
# settings row for FEATURE_MAP_DRAFT_ENABLED when one exists. AGENT_CALL_LANE
# names that lane to llm-gate.sh, which reads its three LLM_* knobs.
export AGENT_CALL_LANE=feature-map-draft
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit feature-map-draft
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    feature-map-draft
# OFF BY DEFAULT. A paid agent lane is not armed by being invoked: only
# FEATURE_MAP_DRAFT_ENABLED=1 lets a real run through, and the refusal comes
# before any fetch, worktree or agent call. --dry-run spends nothing, so it runs.
if [ "${FEATURE_MAP_DRAFT_ENABLED:-0}" != 1 ] && [ "$DRY" != 1 ]; then
  echo "REFUSED FEATURE_MAP_DRAFT_ENABLED is off (set it to 1 to draft; nothing fetched, nothing spent)"
  exit 3
fi

# shellcheck source=lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# The REST contract (bin/lib/gh-rest.sh): beside this script first, then the
# harness copy. The open-draft-PR check below reads over REST, never GraphQL.
for _P in "$BIN/lib/gh-rest.sh" "$HARNESS/bin/lib/gh-rest.sh"; do
  # shellcheck source=lib/gh-rest.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
unset _P

# manual_only <entry.md> — rc 0 when the Manual-only field has a real body: the
# text up to the next **Label:** or heading, with `none` / `n/a` read as empty.
manual_only() {
  awk '
    /^\*\*Manual-only \/ not automatable:\*\*/ { on=1; sub(/^\*\*Manual-only \/ not automatable:\*\*/, ""); }
    on && (/^\*\*[^*]+:\*\*/ && !/^\*\*Manual-only/ || /^#/) { on=0 }
    on { body = body " " $0 }
    END {
      gsub(/^[ \t.]+|[ \t.]+$/, "", body); b = tolower(body)
      exit !(b != "" && b != "none" && b != "n/a")
    }' "$1"
}

draft_one() { # draft_one <project> — runs in its own subshell, so the trap is per project
  local p="$1" slug repo open heads v r cap model wt="" out prompt body_src tpl
  local before=0 cost entries n man names fresh url prod stamp drive
  MADE_BRANCH=0; WT=""
  repo="$REPOS_ROOT/$p"

  # 1. slug
  slug=$("$HARNESS/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  [ -n "$slug" ] || { die 1 "cannot resolve repo slug for $p"; return 1; }

  # 2. a map already on main. Fetch first: a stale ref would say "no map".
  git -C "$repo" fetch -q origin main 2>/dev/null \
    || { die 1 "$p: git fetch origin main failed in $repo — cannot prove main has no map"; return 1; }
  if [ -n "$(git -C "$repo" ls-tree --name-only origin/main docs/verification-map/ 2>/dev/null)" ]; then
    echo "ALREADY_MAPPED $p"; return 5
  fi

  # 3. refuse twice, before any spend. Each answer is read into a variable first
  # and a failed read refuses: an empty answer from a broken read is not "none".
  # Over REST (bin/lib/gh-rest.sh): rc 0 with a JSON array is an answer; any
  # other rc (75 rate limit / non-2xx / network, 44) or a non-array body is not.
  # A plain call into a file, never `$( )`: GH_REST_STATUS / GH_REST_REASON are
  # set in the calling shell, so the refusal can say what GitHub answered.
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  command -v gh_rest >/dev/null 2>&1 \
    || { die 1 "$p: no REST contract lib (gh-rest.sh) — cannot prove no open draft PR on $slug ($BRANCH)"; return 1; }
  local openf grc=0
  openf=$(mktemp "${TMPDIR:-/tmp}/feature-map-draft-open.XXXXXX") \
    || { die 1 "$p: no temp file for the open-draft-PR read — cannot prove no open draft PR on $slug ($BRANCH)"; return 1; }
  gh_rest GET "repos/$slug/pulls?state=open&head=${slug%%/*}:$BRANCH&per_page=100" > "$openf" 2>/dev/null || grc=$?
  open=$(cat "$openf"); rm -f "$openf"
  if [ "$grc" != 0 ] || ! printf '%s' "$open" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die 1 "$p: cannot prove no open draft PR on $slug ($BRANCH) — HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ ($GH_REST_REASON)}"; return 1
  fi
  if [ "$(printf '%s' "$open" | jq 'length')" != 0 ]; then
    echo "REFUSED open draft PR $(printf '%s' "$open" | jq -r '.[0].html_url')"; return 3
  fi
  heads=$(git -C "$repo" ls-remote --heads origin "$BRANCH" 2>/dev/null) \
    || { die 1 "$p: git ls-remote origin $BRANCH failed — cannot prove the branch is absent"; return 1; }
  if [ -n "$heads" ]; then
    echo "REFUSED $BRANCH branch exists without PR, open or delete it"; return 3
  fi

  # 4. the cap. Never clamped: a value that is not a positive decimal stops the run.
  if command -v setting_get >/dev/null 2>&1; then v=$(setting_get "$CAP_KEY"); r=$?; else v=""; r=1; fi
  case "$r" in
    0) if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v x="$v" 'BEGIN{exit !(x > 0)}'; then cap="$v"
       else echo "feature-map-draft: bad knob $CAP_KEY='$v'" >&2; return 2; fi ;;
    2) cap=$CAP_DEFAULT ;;
    *) cap=$CAP_DEFAULT; note "$p: knob unreadable, default \$$CAP_DEFAULT" ;;
  esac
  export AGENT_CALL_BUDGET_USD_FEATURE_MAP_DRAFT="$cap"

  # 5.
  if [ "$DRY" = 1 ]; then echo "slug=$slug refuse-check=clear cap=$cap"; return 0; fi

  # 6. the draft. Model through the route, as every non-build lane resolves it.
  . "$HARNESS/bin/lib/lane-model.sh"
  model=$(lane_model FEATURE_MAP_MODEL feature-map.draft "$p") && [ -n "$model" ] \
    || { die 1 "$p: no model route for role feature-map.draft — nothing drafted"; return 1; }

  # The drive's base URL. Resolved before the worktree and the spend: an agent
  # told to drive production with no production to drive would draft from the
  # code alone, which is the one thing the prompt forbids.
  prod=$("$HARNESS/bin/prod-url.sh" "$p" 2>/dev/null) && [ -n "$prod" ] \
    || { die 1 "$p: bin/prod-url.sh has no production URL for $p — nothing to drive, nothing drafted"; return 1; }

  body_src=$(awk 'f; /^---$/ && !f { f=1 }' "$BIN/../docs/VMAP-BACKFILL-TICKET.md" 2>/dev/null)
  tpl=$(cat "$BIN/../docs/verification-map/TEMPLATE.md" 2>/dev/null)
  [ -n "$body_src" ] && [ -n "$tpl" ] \
    || { die 1 "$p: docs/VMAP-BACKFILL-TICKET.md or docs/verification-map/TEMPLATE.md missing or empty — no prompt"; return 1; }

  WT=$(mktemp -d) || { die 1 "$p: mktemp failed"; return 1; }
  trap 'cleanup' EXIT
  git -C "$repo" worktree add -q -b "$BRANCH" "$WT" origin/main 2>/dev/null \
    || { die 1 "$p: cannot create worktree on $BRANCH in $repo (a local $BRANCH branch from an earlier run? delete it by hand)"; return 1; }
  MADE_BRANCH=1; wt="$WT"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  out="$HARNESS/logs/feature-map-draft-$p-$stamp.out"
  # qa-drive's screenshots land OUTSIDE the worktree: nothing of production's
  # rendered pages can reach the commit even by accident.
  drive="$HARNESS/logs/feature-map-draft-$p-$stamp.drive"

  prompt="You are drafting the first verification map for the project $p ($slug), in this checkout.

$body_src

## The entry shape (docs/verification-map/TEMPLATE.md)

$tpl

## How to do it
- Enumerate routes, nav and the QA role accounts from the code, and from qa/personas.json and qa/apps.json when present.
- Drive every screen at 1280px and 375px, always through the ban-guarded wrapper (it owns the QA account's ban state; never drive around it). The scripts live in the harness, not in this checkout, so use these absolute paths:
  \`QA_TEST_USER_ID=\$($HARNESS/bin/qa-account.sh $p <role>) $HARNESS/bin/qa-unbanned.sh $p <role> -- node $HARNESS/bin/qa-drive.mjs $prod $wt $drive <path> [path...] --production\`
  The positionals are <base-url> <resolve-root> <out-dir> <path...>: $prod is production, $wt is this checkout, $drive takes the screenshots. Write selectors only from what you drove.
- An entry you could not drive says so under **Manual-only / not automatable:**.
- Fill **What usually lies:** for every entry.
- If .github/workflows/verification-map-freshness.yml is absent, adopt it.
- Production is non-destructive only: read and navigate, never create, edit, send or delete.
- Do not stage, commit, push or open a PR. Leave the files in the working tree. Only docs/verification-map/ and the freshness workflow are committed."

  mkdir -p "$HARNESS/logs"
  [ -r "$HARNESS/logs/cost.csv" ] && before=$(wc -l < "$HARNESS/logs/cost.csv")
  (cd "$wt" && AGENT_CALL_ROLE=feature-map.draft "$HARNESS/bin/agent-call.sh" feature-map-draft "$p" "$model" 3600 "$out" "$prompt")
  r=$?
  [ "$r" = 0 ] || { die 1 "$p: agent-call.sh feature-map-draft exited rc $r (77 = refused on the hub; run on a builder box), see $out — nothing pushed"; return 1; }

  cost=$(tail -n +"$((before + 1))" "$HARNESS/logs/cost.csv" 2>/dev/null \
    | awk -F, -v p="$p" '$3 == p && $4 == "feature-map-draft" { s += $13; f = 1 } END { if (f) print s }')
  [ -n "$cost" ] || cost=unknown
  # Before any outcome branch: an inert budget flag overspends just as much on a
  # draft that comes back empty or fails to push as on one that opens a PR.
  if [ "$cost" != unknown ] && awk -v c="$cost" -v m="$cap" 'BEGIN{exit !(c > m)}'; then
    alert "feature-map draft $p cost \$$cost over cap \$$cap (budget flag may be inert)"
  fi

  # 7. deterministic post-check: the files decide, not the agent's say-so.
  entries=$(cd "$wt" && for f in docs/verification-map/*.md docs/verification-map/entries/*.md; do
    case "$f" in */README.md|*/TEMPLATE.md) ;; *) [ -f "$f" ] && echo "$f" ;; esac; done)
  if [ ! -f "$wt/docs/verification-map/README.md" ] || [ -z "$entries" ]; then
    echo "DRAFT_EMPTY $p"; note "$p DRAFT_EMPTY cost=$cost (nothing pushed)"; return 4
  fi
  n=$(printf '%s\n' "$entries" | wc -l | tr -d ' ')
  man=0; names=""
  while IFS= read -r e; do
    if manual_only "$wt/$e"; then man=$((man + 1)); names="$names ${e#docs/verification-map/}"; fi
  done <<< "$entries"
  if [ -f "$wt/.github/workflows/verification-map-freshness.yml" ]; then fresh="wired"
  else fresh="NOT wired, adopt before relying on the map"; fi

  # Empty the index first and commit by pathspec: whatever the agent staged on
  # its own (a screenshot, a scratch file, a .env) is never committed or pushed.
  git -C "$wt" reset -q || { die 1 "$p: cannot clear the index on $BRANCH"; return 1; }
  local paths=(docs/verification-map)
  [ "$fresh" = wired ] && paths+=(.github/workflows/verification-map-freshness.yml)
  git -C "$wt" add -A -- "${paths[@]}" || { die 1 "$p: cannot stage ${paths[*]} on $BRANCH"; return 1; }
  git -C "$wt" -c user.name=feature-map-draft -c user.email=harness@box \
    commit -q -m "docs(verification-map): draft map for $p (BH-2005)" -- "${paths[@]}" >/dev/null 2>&1 \
    || { die 1 "$p: commit on $BRANCH failed"; return 1; }
  git -C "$wt" push -q -u origin "$BRANCH" >/dev/null 2>&1 \
    || { die 1 "$p: push of $BRANCH to $slug failed — no PR opened; the commit is gone with the worktree, re-run after fixing origin"; return 1; }

  {
    echo "A first verification map for $p, drafted by an agent that drove the app. Read it before merging: every entry becomes something QA lanes click through."
    echo
    echo "- entries: $n"
    echo "- Manual-only: $man${names:+ (${names# })}"
    echo "- FRESHNESS: $fresh"
    echo "- cost: \$$cost (cap \$$cap)"
    echo
    echo "Opened by \`bin/feature-map-draft.sh\` in cromford (BH-2005). It does not merge."
    echo
    echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  } > "$WT.body"
  # >>> pr trailers (BH-3987)
  [ -r "${HARNESS:-}/bin/lib/pr-trailers.sh" ] && . "$HARNESS/bin/lib/pr-trailers.sh"
  if command -v pr_trailers_apply >/dev/null 2>&1; then
    pr_trailers_apply "$WT.body" lane:feature-map-draft none \
      || echo "feature-map-draft: $p: pr trailers: could not write $WT.body — PR opened without trailers" >&2
  fi
  url=$(gh pr create -R "$slug" --base main --head "$BRANCH" \
    --title "docs(verification-map): draft map for $p" --body-file "$WT.body" 2>/dev/null)
  r=$?
  rm -f "$WT.body"
  # <<< pr trailers
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  [ "$r" = 0 ] && [[ "$url" =~ ^https://github.com/ ]] \
    || { die 1 "$BRANCH pushed on $slug but gh pr create failed — open the PR from $BRANCH by hand, or delete the branch on origin before re-running"; return 1; }

  # 8. record, only now that a real URL is in hand.
  printf '%s\t%s\tPR_OPENED\t%s\t%s\n' "$(STAMP)" "$p" "$url" "$cost" >> "$LOG"
  echo "$url"
  return 0
}

cleanup() {
  [ -n "${WT:-}" ] || return 0
  git -C "$REPOS_ROOT/$P" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPOS_ROOT/$P" worktree prune >/dev/null 2>&1
  [ "${MADE_BRANCH:-0}" = 1 ] && git -C "$REPOS_ROOT/$P" branch -D "$BRANCH" >/dev/null 2>&1
  rm -rf "$WT" "$WT.body"
}

outcome() { # outcome <rc>
  case "$1" in
    0) [ "$DRY" = 1 ] && echo DRY_RUN || echo PR_OPENED ;;
    2) echo BAD_KNOB ;; 3) echo REFUSED ;; 4) echo DRAFT_EMPTY ;; 5) echo ALREADY_MAPPED ;;
    *) echo FAILED ;;
  esac
}

if [ "$TARGET" != --all ]; then
  P="$TARGET"; ( draft_one "$P" ); exit $?
fi
# The project list is the fleet's own answer, never a literal here: the projects
# whose board is an in-app one. Read into a variable first — an empty or failed
# read is not "no projects", it stops the run.
ALL_PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects-with-board 2>/dev/null) && [ -n "$ALL_PROJECTS" ] \
  || { die 1 "--all: fleet-conf.sh --projects-with-board gave no project list — nothing drafted"; exit 1; }
FIRST=0
for P in $ALL_PROJECTS; do
  ( draft_one "$P" ); r=$?
  echo "$P $(outcome "$r")"
  [ "$FIRST" = 0 ] && [ "$r" != 0 ] && [ "$r" != 5 ] && FIRST=$r
done
exit "$FIRST"
