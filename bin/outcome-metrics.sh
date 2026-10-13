#!/bin/bash
# bin/outcome-metrics.sh — SDLC item 7: METRICS CLOSE THE LOOP.
#
# Everything upstream of this measures OUTPUT. metrics-collect.sh counts builds,
# cost-rollup.sh prices them, findings-log.sh records what reviewers said before
# a PR merged. Nothing measured whether the merge HELD. So the weekly rule miner
# could see every review comment the fleet ever wrote and never see a single one
# of its own mistakes land, which is the one signal a rule should be mined from.
#
# This run reads the PRs the fleet has already MERGED and asks three questions
# with objectively checkable answers:
#
#   reverted          a Revert/Rollback commit on the repo's default branch,
#                     after the merge, that either names the PR (#N or the merge
#                     sha) or touches files the PR touched.
#   reopened          the ticket the PR closed regressed on the product board —
#                     read from logs/reopens.csv, which bin/reopen-metrics.sh
#                     already writes daily. The client came back.
#   merged_then_red   the merge commit's own checks on the default branch
#                     concluded failure. We merged green and main went red.
#
# Each finding lands TWICE, on purpose:
#   * one line in logs/findings.log in the format bin/findings-log.sh writes, so
#     bin/rule-miner.sh source (e) counts it with everything else and a family
#     that crosses PROMOTE_MIN in 30 days becomes a mined rule. Outcomes are the
#     one finding class the reviewers never produced.
#   * one row in logs/outcome-metrics.csv (date,repo,pr,outcome,evidence,repairs),
#     which is the flat rollup a human or a dashboard reads without parsing prose.
#
# `repairs` (2026-09-06, SDLC item 3) is the repair-round count the BUILD wrote
# into its verdict row — how many times a lens or preview QA sent that code back
# before it merged. It is carried onto the outcome, not re-derived here, so this
# lane can answer the question the repair count was measured for: do the builds
# that had to be fixed twice turn into the reverts? A PR whose ledger row
# predates the count reports "-", never 0 — a build nobody measured is not a
# build that was never repaired.
#
# WHERE THE DATA COMES FROM — the P7 ledger first, GitHub only for evidence it
# does not hold. The merged-PR list is `ledgers` kind=merge (bin/merge-sweep.sh
# writes it), and each PR's project / ticket / verdict / merge sha come from
# job_artifacts through GET /api/verdict. Re-deriving any of that by scraping
# GitHub would be a second implementation of facts the fleet already recorded,
# and the two would disagree the first time a sweep parked a PR. GitHub answers
# exactly two things the ledger cannot: what commits landed on main afterwards,
# and what that merge commit's checks concluded.
#
# DETECTION AND REPORTING ONLY. Nothing here reverts, reopens, closes, comments,
# merges or writes a ledger row. Every GitHub call is a read; the only writes are
# two append-only files and a state file on this box. An outcome tracker that
# could act on its own findings would be a second, unreviewed merge path.
#
# Idempotent + resumable:
#   * state/outcome-metrics-seen.txt — "<outcome>:<pr>" per finding ever emitted.
#     A finding is written ONCE, so a re-run inside the recheck window (or two
#     runs the same morning) appends nothing. Same one-shot rule as
#     rule-mining/seen.txt.
#   * state/outcome-metrics.state — "<repo><TAB><highest-pr-scanned><TAB><stamp>".
#     A PR at or below its repo's cursor is settled and never re-examined, EXCEPT
#     inside OUTCOME_RECHECK_DAYS of its merge: a revert or a reopen arrives days
#     after the merge, so a cursor that closed the book at scan time would make
#     this lane structurally incapable of seeing the outcomes it exists for. The
#     cursor advances per PR as the run goes, so a run killed halfway resumes
#     where it stopped instead of restarting the window.
#
# Fail-quiet per repo: a repo whose GitHub reads fail loses its revert and CI
# evidence for that run and is logged; every other repo, and that repo's own
# board-reopen evidence (which is local), still land. ONE ALERTS line is written
# only when the whole run fails — no ledger and no fallback list, or every repo
# attempted failed — because a lane that pages per repo trains people to skim it.
#
# A FOURTH outcome, `reworked` (BH-3956), asks whether a merge's own product
# files were taken apart again within days by somebody else's PR — the number
# that says whether slicing work into siblings helps. bin/lib/outcome-rework.sh
# runs it from GitHub's pulls listing per fleet repo (not the capped ledger
# list), caches each merged PR's product files under state/outcome-rework/, and
# appends one row per (ISO week, project) to logs/outcome-rework-rollup.csv once
# that week's window has closed. Reworked rows go to the CSV and the D1 push
# like the others, but NOT to findings.log: sibling rework is a decomposition
# metric, not a reviewer mistake for bin/rule-miner.sh to mine. The first runs
# backfill REWORK_BACKFILL_DAYS and write state/outcome-rework-backfill.done once
# a run read every repo completely; after that each run scans the window + 14d.
# Knobs: REWORK_WINDOW_DAYS (7; 0 = off) REWORK_MIN_SHARE (30, percent of A's
#        product files) REWORK_BACKFILL_DAYS (60) REWORK_FETCH_CAP (1500 file
#        reads per run) REWORK_GH_RESERVE (1500 core calls left for other lanes).
#
# Cron: hub, Mondays 05:20Z, twenty minutes ahead of bin/rule-miner.sh. The miner
# ALSO invokes it directly (feed the lane before reading it), which is a no-op on
# the second call by the seen-file above.
# Knobs: OUTCOME_LOOKBACK_DAYS (30) OUTCOME_RECHECK_DAYS (7) OUTCOME_MAX_PRS (60)
#        OUTCOME_DRY=1 prints the findings it would write and writes nothing.
# Kill switch: flags/outcome-metrics-disabled (or the `switch.outcome-metrics-disabled` settings row).
set -uo pipefail
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-outcome-metrics
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off outcome-metrics.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit outcome-metrics
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    outcome-metrics
BIN="$(cd "$(dirname "$0")" && pwd)"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/outcome-metrics.log"
ALERTS="$H/logs/ALERTS.log"
FINDINGS="$H/logs/findings.log"
CSV="$H/logs/outcome-metrics.csv"
SEEN="$H/state/outcome-metrics-seen.txt"
STATE="$H/state/outcome-metrics.state"
DRY="${OUTCOME_DRY:-0}"
LOOKBACK="${OUTCOME_LOOKBACK_DAYS:-30}"
RECHECK="${OUTCOME_RECHECK_DAYS:-7}"
MAXPRS="${OUTCOME_MAX_PRS:-60}"

mkdir -p "$H/logs" "$H/state" "$H/locks" "$H/flags" 2>/dev/null
touch "$SEEN" "$STATE" 2>/dev/null

# global.env carries HARNESS_SECRET; cron does not source it. Before the kill
# switch, because the kill switch is a flag lookup and the lookup wants the
# coordination client (the same ordering rule-miner.sh and merge-sweep.sh use).
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    outcome-metrics
# shellcheck source=/dev/null
[ -r "$BIN/jobs-client.sh" ] && . "$BIN/jobs-client.sh"
# App token per repo (#425): armed where the repo becomes known; an unarmed box runs as today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null \
  || lane_switch() { if command -v flag_active >/dev/null 2>&1; then flag_active "$1"; else [ -f "$H/flags/$1" ]; fi; }
lane_switch outcome-metrics-disabled && exit 0
if command -v flock >/dev/null 2>&1; then
  exec 9>"$H/locks/outcome-metrics.lock"; flock -n 9 || exit 0
fi

TODAY=$(date -u +%Y-%m-%d)
d_ago() { date -u -d "$1 days ago" +"$2" 2>/dev/null || date -u -v-"$1"d +"$2" 2>/dev/null; }
SINCE_ISO=$(d_ago "$LOOKBACK" %Y-%m-%dT%H:%M:%SZ)
RECHECK_ISO=$(d_ago "$RECHECK" %Y-%m-%dT%H:%M:%SZ)
WINDOW_ISO=$(d_ago "$LOOKBACK" %Y-%m-%d)

WORK=$(mktemp -d /tmp/outcome-metrics-XXXXXX) || exit 1
RUN_RC=0
finish() {
  local rc=$?
  rm -rf "$WORK"
  # ONE alert, and only for a run that produced nothing it could have produced.
  # ONCE A DAY, not once per invocation: the hub cron fires this at 05:20Z and
  # bin/rule-miner.sh invokes it again at 05:30Z, so a single worker outage would
  # otherwise write the same line twice into the channel people are supposed to
  # read. Same discipline bin/jobs-client.sh uses for its own outage line.
  if [ "$RUN_RC" -ne 0 ]; then
    local flag="$H/flags/alerted-outcome-metrics-$(date -u +%Y%m%d)"
    if [ ! -f "$flag" ]; then
      touch "$flag" 2>/dev/null
      echo "$(STAMP) [outcome-metrics] run failed with nothing measured ($RUN_REASON) — merged-PR outcomes are UNMEASURED this week, so rule-miner reads a feed that cannot fill. Needs: harness-jobs reachable (HARNESS_SECRET in env/global.env) and gh auth on the hub." >> "$ALERTS"
    fi
  fi
  exit "$rc"
}
RUN_REASON=""
trap 'finish' EXIT

# ── 1. The merged-PR list, from the P7 ledger ────────────────────────────────
# kind=merge, key = PR url, status = what the sweep recorded. Only `merged` is
# an outcome to track: parked / flagged / failed-alerted never reached main, so
# asking whether they held is a question with no subject.
LEDGER="$WORK/merged.tsv"; : > "$LEDGER"
LEDGER_SRC="ledger"
if command -v job_ledger_list >/dev/null 2>&1; then
  job_ledger_list merge 500 2>/dev/null \
    | awk -F'\t' -v s="$SINCE_ISO" 'NF>=4 && $2=="merged" && ($4=="-" || $4>=s)' > "$LEDGER"
fi
if [ ! -s "$LEDGER" ]; then
  # The write-through file merge-sweep.sh keeps beside the ledger. It carries no
  # status and no time, so every line is treated as a merge with an unknown date
  # — which the recheck test below reads as "outside the window", i.e. scanned
  # once and then settled. Degraded, and said so, rather than absent.
  DONE="$H/state/merge-sweep-done.txt"
  if [ -s "$DONE" ]; then
    LEDGER_SRC="file"
    grep -oE 'https://github\.com/[^ ]+/pull/[0-9]+' "$DONE" 2>/dev/null \
      | sort -u | tail -200 | awk '{printf "%s\tmerged\t-\t-\n", $1}' > "$LEDGER"
  fi
fi
if [ ! -s "$LEDGER" ]; then
  RUN_RC=1; RUN_REASON="no merged PRs from the harness-jobs merge ledger and none in state/merge-sweep-done.txt"
  echo "$(STAMP) no merged-PR list available (ledger + file both empty) — nothing measured" >> "$LOG"
  exit 1
fi

# ── 2. Per-repo GitHub evidence, fetched once and cached ─────────────────────
# One commits call per repo per run, not one per PR: the revert test is "did any
# revert land after this merge", and the answer for every PR in a repo comes out
# of the same list. ONE PAGE, stated rather than papered over: a repo that lands
# more than 100 commits inside OUTCOME_LOOKBACK_DAYS can push an early revert off
# the page, so this under-reports on a very busy repo and never over-reports. The
# fix if that ever bites is pagination here, not a second detector elsewhere.
REPO_OK=""; REPO_BAD=""; REV_FILE=""
# Sets REV_FILE (the repo's revert-commit TSV: sha, iso, subject) and returns 0.
# NOT a printing function: a `$(repo_reverts ...)` would run it in a subshell and
# the REPO_OK / REPO_BAD tallies it keeps — the difference between "this repo
# failed" and "the whole run failed" — would be discarded with that subshell.
repo_reverts() { # repo_reverts <slug>
  local slug="$1" f
  f="$WORK/rev-$(printf '%s' "$slug" | tr '/' '_').tsv"
  REV_FILE="$f"
  [ -f "$f" ] && return 0
  local raw
  raw=$(gh api "repos/$slug/commits?since=$SINCE_ISO&per_page=100" 2>/dev/null) || raw=""
  if [ -z "$raw" ]; then
    REV_FILE=""
    case " $REPO_BAD " in *" $slug "*) ;; *) REPO_BAD="$REPO_BAD $slug" ;; esac
    return 1
  fi
  case " $REPO_OK " in *" $slug "*) ;; *) REPO_OK="$REPO_OK $slug" ;; esac
  printf '%s' "$raw" | jq -r '
    .[]? | select((.commit.message | split("\n")[0]) | test("^(Revert |Rollback)"))
    | [ .sha, (.commit.committer.date // .commit.author.date // "-"),
        ((.commit.message | split("\n")[0]) | gsub("\t"; " ")) ] | @tsv' 2>/dev/null > "$f"
  return 0
}

commit_files() { # commit_files <slug> <sha> -> newline-separated filenames (cached)
  local slug="$1" sha="$2" f
  f="$WORK/cf-$(printf '%s' "$slug" | tr '/' '_')-$sha"
  [ -f "$f" ] || gh api "repos/$slug/commits/$sha" --jq '.files[]?.filename' 2>/dev/null > "$f"
  cat "$f" 2>/dev/null
}

pr_files() { # pr_files <slug> <number> -> newline-separated filenames (cached)
  local slug="$1" n="$2" f
  f="$WORK/pf-$(printf '%s' "$slug" | tr '/' '_')-$n"
  [ -f "$f" ] || gh api "repos/$slug/pulls/$n/files?per_page=100" --jq '.[]?.filename' 2>/dev/null > "$f"
  cat "$f" 2>/dev/null
}

# The area a finding is filed under. NOT the whole path: a family keyed on the
# exact file can never recur, and one keyed on nothing at all always crosses the
# threshold and mines the rule "do not ship code that gets reverted". Two
# segments under src/ (src/app, src/lib) because in these Next.js repos `src`
# alone is the entire application; one segment everywhere else.
area_of() { # area_of  (file list on stdin)
  awk -F/ 'NF>0 && $1!="" { a = ($1=="src" && NF>1) ? $1"/"$2 : $1; n[a]++ }
       END { b=""; m=0; for (k in n) if (n[k]>m || (n[k]==m && k<b)) { m=n[k]; b=k }
             print (b=="" ? "-" : b) }'
}

# ── 3. Walk the merged PRs, newest first ─────────────────────────────────────
CAND="$WORK/findings.tsv"; : > "$CAND"
SCANNED=0; PRS=0

cursor_of() { awk -F'\t' -v r="$1" '$1==r {print $2}' "$STATE" | tail -1; }
cursor_set() { # cursor_set <repo> <pr-number>
  local r="$1" n="$2" tmp
  tmp="$WORK/state.tmp"
  awk -F'\t' -v r="$r" '$1!=r' "$STATE" > "$tmp" 2>/dev/null
  printf '%s\t%s\t%s\n' "$r" "$n" "$(STAMP)" >> "$tmp"
  [ "$DRY" = 1 ] || mv "$tmp" "$STATE"
}

add_finding() { # add_finding <class> <project> <ticket> <slug> <pr> <area> <evidence>
  # Tabs and the findings.log `::` separator are stripped here rather than at
  # write time: a commit subject containing either would otherwise re-shape the
  # row a downstream parser walks by field.
  # The repair count rides off the loop variable rather than an eighth argument:
  # it is a fact about the PR being walked, not about the finding, and every
  # caller below would have to pass the same value.
  local ev
  ev=$(printf '%s' "$7" | tr '\t\n' '  ' | sed 's/::/:/g' | cut -c1-260)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$ev" "${PR_REPAIRS:--}" >> "$CAND"
}

while IFS=$'\t' read -r PR STATUS JOB_ID MERGED_AT; do
  [ "$PRS" -lt "$MAXPRS" ] || break
  case "$PR" in https://github.com/*/pull/*) ;; *) continue ;; esac
  SLUG=$(sed -E 's|https://github\.com/([^/]+/[^/]+)/pull/[0-9]+.*|\1|' <<<"$PR")
  NUM=$(sed -E 's|.*/pull/([0-9]+).*|\1|' <<<"$PR")
  [ -n "$SLUG" ] && [ -n "$NUM" ] || continue

  # Cursor: settled PRs are skipped, but never one still inside the recheck
  # window — that window is where reverts and reopens actually arrive.
  CUR=$(cursor_of "$SLUG"); CUR=${CUR:-0}
  case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac
  FRESH=0
  [ "$MERGED_AT" != "-" ] && [ -n "$MERGED_AT" ] && [[ "$MERGED_AT" > "$RECHECK_ISO" ]] && FRESH=1
  if [ "$NUM" -le "$CUR" ] && [ "$FRESH" = 0 ]; then continue; fi
  PRS=$((PRS+1))

  # ── P7 facts: project, ticket, verdict, merge sha, repairs. Never scraped. ─
  PROJECT="-"; TICKET="-"; MERGE_SHA="-"; PR_REPAIRS="-"
  if command -v job_pr_facts >/dev/null 2>&1; then
    FACTS=$(job_pr_facts "$PR" 2>/dev/null) || FACTS=""
    if [ -n "$FACTS" ]; then
      # _SCOPE (SDLC item 4) is read into its own variable and ignored here.
      # job_pr_facts APPENDS fields, and the last variable in a `read` collects
      # every remaining one — so an unread trailing field would turn the repair
      # count into "3<TAB>protected", which the digit check below then discards
      # as unmeasured. A new field on that row means a new variable here.
      IFS=$'\t' read -r _JID PROJECT TICKET _VERDICT MERGE_SHA _TIER PR_REPAIRS _SCOPE <<<"$FACTS"
    fi
  fi
  # A PR the ledger never recorded (a hand-opened PR, or one from before phase 7)
  # still gets a project, from the registry that maps repo -> project. The ticket
  # stays "-" and the reopen test simply cannot fire for it, which is the honest
  # answer rather than a guessed key.
  if [ "$PROJECT" = "-" ] || [ -z "$PROJECT" ]; then
    PROJECT=$("$BIN/fleet-conf.sh" --projects 2>/dev/null | while IFS= read -r P; do
      [ "$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null)" = "$SLUG" ] && { echo "$P"; break; }
    done)
    [ -n "$PROJECT" ] || PROJECT="$SLUG"
  fi
  [ -n "$TICKET" ] || TICKET="-"
  # Only a digit is a count. A "-" (no row, or a row from before the count
  # existed) stays "-" all the way into the CSV and the ledger.
  case "${PR_REPAIRS:-}" in ''|*[!0-9]*) PR_REPAIRS="-" ;; esac

  # Arm once per repo, not per PR: the ledger interleaves repos, so re-arm only when the slug changes.
  if [ "$SLUG" != "${ARMED_SLUG:-}" ]; then
    command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true; ARMED_SLUG="$SLUG"
  fi
  FILES=$(pr_files "$SLUG" "$NUM")
  AREA=$(printf '%s\n' "$FILES" | area_of)

  # ── (a) reverted ──────────────────────────────────────────────────────────
  if repo_reverts "$SLUG" && [ -s "$REV_FILE" ]; then
  while IFS=$'\t' read -r RSHA RDATE RMSG; do
    [ -n "$RSHA" ] || continue
    # A revert that predates the merge is somebody else's incident.
    [ "$MERGED_AT" != "-" ] && [ "$RDATE" != "-" ] && [[ "$RDATE" < "$MERGED_AT" ]] && continue
    WHY=""
    case "$RMSG" in
      *"#$NUM"*) WHY="the revert names this PR (#$NUM)" ;;
    esac
    if [ -z "$WHY" ] && [ "$MERGE_SHA" != "-" ] && [ -n "$MERGE_SHA" ]; then
      case "$RMSG" in *"${MERGE_SHA:0:7}"*) WHY="the revert names this PR's merge commit ${MERGE_SHA:0:7}" ;; esac
    fi
    # File overlap is CIRCUMSTANTIAL evidence and only means anything once we
    # know the revert came after the merge. On the file-fallback list there is no
    # merge time, so this branch would happily attribute a year-old revert to a
    # PR that touches the same file. Strong evidence (the revert names the PR or
    # its merge commit) carries its own ordering and still counts there.
    if [ -z "$WHY" ] && [ -n "$FILES" ] && [ "$MERGED_AT" != "-" ] && [ -n "$MERGED_AT" ]; then
      OVER=$(printf '%s\n' "$FILES" | sort -u | comm -12 - <(commit_files "$SLUG" "$RSHA" | sort -u) 2>/dev/null | head -3 | paste -sd' ' -)
      [ -n "$OVER" ] && WHY="the revert touches files this PR changed ($OVER)"
    fi
    [ -n "$WHY" ] || continue
    add_finding reverted "$PROJECT" "$TICKET" "$SLUG" "$PR" "$AREA" \
      "merged and then reverted on main by ${RSHA:0:12} ($RDATE) — $WHY; revert subject: $RMSG"
    break
  done < "$REV_FILE"
  fi

  # ── (b) reopened ──────────────────────────────────────────────────────────
  # logs/reopens.csv is bin/reopen-metrics.sh's daily output: date,project,key,
  # from,to. Read locally; the board is never re-polled here.
  # "After this PR merged" is the whole claim, so a PR with no known merge time
  # (the file-fallback list) is SKIPPED rather than compared against the window
  # start — that comparison would read every reopen in the window as caused by
  # every PR in it.
  RO="$H/logs/reopens.csv"
  if [ -s "$RO" ] && [ "$TICKET" != "-" ] && [ "$PROJECT" != "-" ] && [ "$MERGED_AT" != "-" ] && [ -n "$MERGED_AT" ]; then
    MD=$(printf '%s' "$MERGED_AT" | cut -c1-10 | tr -d '-')
    case "$MD" in ''|*[!0-9]*) MD="" ;; esac
    HIT=""
    [ -n "$MD" ] && HIT=$(awk -F, -v p="$PROJECT" -v k="$TICKET" -v d="$MD" \
      'NR>1 && NF>=5 && $2==p && $3==k && $1>=d {print $1"|"$4"|"$5; exit}' "$RO")
    if [ -n "$HIT" ]; then
      RD=${HIT%%|*}; REST=${HIT#*|}; RFROM=${REST%%|*}; RTO=${REST#*|}
      add_finding reopened "$PROJECT" "$TICKET" "$SLUG" "$PR" "$AREA" \
        "ticket $TICKET regressed from \"$RFROM\" to \"$RTO\" on $RD, after this PR merged — the shipped change did not hold"
    fi
  fi

  # ── (c) merged_then_red ───────────────────────────────────────────────────
  # The merge commit's OWN checks, on the default branch. The merge sha comes
  # from the ledger's job_artifacts when phase 7 recorded it; only when it did
  # not do we ask GitHub which commit the merge produced.
  if [ "$MERGE_SHA" = "-" ] || [ -z "$MERGE_SHA" ]; then
    MERGE_SHA=$(gh pr view "$PR" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null)
  fi
  if [ -n "$MERGE_SHA" ] && [ "$MERGE_SHA" != "-" ]; then
    FAILED=$(gh api "repos/$SLUG/commits/$MERGE_SHA/check-runs" \
      --jq '[.check_runs[]? | select(.conclusion=="failure" or .conclusion=="timed_out") | .name] | unique | join(", ")' 2>/dev/null)
    if [ -n "$FAILED" ] && [ "$FAILED" != "null" ]; then
      add_finding merged_then_red "$PROJECT" "$TICKET" "$SLUG" "$PR" "$AREA" \
        "merged green and main went red: ${MERGE_SHA:0:12} failed $FAILED"
    fi
  fi

  SCANNED=$((SCANNED+1))
  [ "$NUM" -gt "$CUR" ] && cursor_set "$SLUG" "$NUM"
done < "$LEDGER"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset

# ── 3b. reworked (BH-3956) — its own merged list, see bin/lib/outcome-rework.sh
# Knobs read HERE, after the second lane_env_apply, so a settings row wins; a
# value that is not a plain number is the default, never a guess.
RW_WINDOW="${REWORK_WINDOW_DAYS:-7}";      case "$RW_WINDOW" in ''|*[!0-9]*) RW_WINDOW=7 ;; esac
RW_SHARE="${REWORK_MIN_SHARE:-30}";        case "$RW_SHARE" in ''|*[!0-9]*) RW_SHARE=30 ;; esac
RW_BACKFILL="${REWORK_BACKFILL_DAYS:-60}"; case "$RW_BACKFILL" in ''|*[!0-9]*) RW_BACKFILL=60 ;; esac
RW_MAXFETCH="${REWORK_FETCH_CAP:-1500}";   case "$RW_MAXFETCH" in ''|*[!0-9]*) RW_MAXFETCH=1500 ;; esac
RW_RESERVE="${REWORK_GH_RESERVE:-1500}";   case "$RW_RESERVE" in ''|*[!0-9]*) RW_RESERVE=1500 ;; esac
RW_MARKER="$H/state/outcome-rework-backfill.done"
REWORK_ROWS=0; REWORK_COMPLETE=0; RW_SCAN="-"; RW_FIRST=""
if [ "$RW_WINDOW" -gt 0 ]; then
  if [ -f "$RW_MARKER" ]; then RW_SCAN=$((RW_WINDOW + 14)); RW_SRC=weekly
  else RW_SCAN=$RW_BACKFILL; RW_SRC=backfill; fi
  RW_CACHE="$H/state/outcome-rework/files"
  [ "$DRY" = 1 ] && RW_CACHE="$WORK/rework-cache"
  RW_ROLLUP="$H/logs/outcome-rework-rollup.csv"
  # BH-4609: the projects an active initiative measures are scanned first, so
  # a fetch cap reached partway never starves them. The order comes from the
  # initiatives table; unreadable = fleet order and one line.
  RW_RESP=$(command -v _jobs_req >/dev/null 2>&1 && _jobs_req GET "/api/initiatives?status=active&limit=100" 2>/dev/null) || RW_RESP=""
  if printf '%s' "$RW_RESP" | jq -e '.initiatives | type == "array"' >/dev/null 2>&1; then
    [ "$(printf '%s' "$RW_RESP" | jq -r '.truncated == true')" = true ] \
      && echo "$(STAMP) rework: more than 100 active initiatives; ordering by the first 100" >> "$LOG"
    RW_FIRST=$(printf '%s' "$RW_RESP" | jq -r '[.initiatives | sort_by(.id)[] | .metric_query // ""
        | capture("^csv:logs/outcome-rework-rollup\\.csv#[A-Za-z0-9_]+@project=(?<p>[A-Za-z0-9._-]+)$") | .p]
        | reduce .[] as $p ([]; if any(.[]; . == $p) then . else . + [$p] end) | join(" ")' 2>/dev/null)
  else
    echo "$(STAMP) rework: initiatives unreadable; fleet order" >> "$LOG"
  fi
  # shellcheck source=bin/lib/outcome-rework.sh
  if . "$BIN/lib/outcome-rework.sh" || { echo "$(STAMP) rework: bin/lib/outcome-rework.sh did not load — not measured" >> "$LOG"; false; }; then
    rework_scan "$CAND" "$WORK" "$RW_CACHE" "$RW_ROLLUP" "$RW_SCAN" "$RW_WINDOW" "$RW_SHARE" \
      "$RW_MAXFETCH" "$RW_RESERVE" "$BIN" "$DRY" "$LOG" "$RW_SRC" "$RW_FIRST" \
      || { REWORK_COMPLETE=0; echo "$(STAMP) rework: scan could not run — not measured" >> "$LOG"; }
    # The baseline is claimed only by a run that read every repo completely; a
    # capped run resumes off the file cache next time instead (D12).
    if [ "$DRY" != 1 ] && [ "$REWORK_COMPLETE" = 1 ] && [ ! -f "$RW_MARKER" ]; then
      echo "$(STAMP) backfill ${RW_SCAN}d complete" > "$RW_MARKER"
    fi
  fi
fi

# Every repo we asked GitHub about failed => the run measured nothing it could
# have measured. Partial failure is a log line, not an alert.
if [ -n "$REPO_BAD" ] && [ -z "$REPO_OK" ]; then
  RUN_RC=1; RUN_REASON="every repo's GitHub reads failed ($(echo "$REPO_BAD" | xargs))"
fi

# ── 4. Emit: one findings.log line + one CSV row per NEW finding ─────────────
# The family key is bin/alert_family.py, IMPORTED. Two implementations of one
# rule is this repo's named failure shape, and a findings family that disagreed
# with the alert family would make PROMOTE_MIN mean two different things.
# The `repairs` column was APPENDED (SDLC item 3), so every reader keyed on the
# first five columns is unchanged and rows written before it simply have no
# sixth field. An existing file gets its header line upgraded in place — once,
# idempotently — rather than left describing five columns while new rows carry
# six; python's csv.DictReader (bin/review-tighten.sh's fallback path) then
# reports repairs=None for the old rows, which is the honest answer.
if [ -s "$CSV" ]; then
  if [ "$DRY" != 1 ] && [ "$(head -1 "$CSV")" = "date,repo,pr,outcome,evidence" ]; then
    sed -i '1s/.*/date,repo,pr,outcome,evidence,repairs/' "$CSV" 2>/dev/null || true
  fi
else
  [ "$DRY" = 1 ] || echo "date,repo,pr,outcome,evidence,repairs" > "$CSV"
fi
NEW=$(python3 - "$CAND" "$SEEN" "$FINDINGS" "$CSV" "$TODAY" "$(STAMP)" "$BIN" "$DRY" <<'PYF'
import csv, os, sys

cand, seen_f, findings_f, csv_f, today, stamp, bindir, dry = sys.argv[1:9]
dry = dry == "1"
sys.path.insert(0, bindir)
try:
    from alert_family import family
except Exception:
    def family(_s):
        return "-"

try:
    seen = set(open(seen_f).read().split("\n"))
except Exception:
    seen = set()

rows = []
try:
    fh = open(cand)
except Exception:
    fh = []
for line in fh:
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 8:
        continue
    cls, project, ticket, repo, pr, area, evidence, repairs = parts
    key = "%s:%s" % (cls, pr)
    if key in seen:
        continue
    seen.add(key)
    rows.append((key, cls, project, ticket, repo, pr, area, evidence, repairs))

if not rows:
    print(0)
    sys.exit(0)

# The SIGNATURE, not the sentence, is what gets hashed. A finding's prose names
# a sha, a ticket and a file list, all of which differ every time — hashing it
# would give every outcome its own family and nothing could ever recur. The
# class plus the area is the thing that repeats.
flines, crows, keys = [], [], []
for key, cls, project, ticket, repo, pr, area, evidence, repairs in rows:
    crows.append([today, repo, pr, cls, evidence, repairs])
    keys.append(key)
    # BH-3956: reworked is a decomposition metric, not a reviewer-class
    # mistake, so it never feeds bin/rule-miner.sh's findings.log.
    if cls == "reworked":
        continue
    fam = family("outcome-%s %s" % (cls, area))
    text = "outcome %s: %s (%s)" % (cls, evidence, pr)
    text = " ".join(text.split())[:330]
    # Optional and placed before family=, the same shape bin/findings-log.sh
    # gives it: an unmeasured PR says nothing rather than claiming zero.
    rep = "repairs=%s " % repairs if repairs.isdigit() else ""
    flines.append("%s [%s] ticket=%s lens=outcome verdict=- rule=- outcome=%s %sfamily=%s :: %s"
                  % (stamp, project, ticket or "-", cls, rep, fam, text))

if dry:
    for l in flines:
        sys.stderr.write(l + "\n")
    for r in crows:
        if r[3] == "reworked":
            sys.stderr.write("outcome reworked: %s %s\n" % (r[2], r[4]))
else:
    if flines:
        with open(findings_f, "a") as fh:
            fh.write("\n".join(flines) + "\n")
    with open(csv_f, "a", newline="") as fh:
        csv.writer(fh).writerows(crows)
    with open(seen_f, "a") as fh:
        fh.write("\n".join(keys) + "\n")
print(len(rows))
PYF
) || NEW=0
case "$NEW" in ''|*[!0-9]*) NEW=0 ;; esac

# ── Push this run's NEW findings to the harness-jobs metrics ledger ──────────
# After the CSV and findings.log, fail-open: logs/outcome-metrics.csv stays the
# flat rollup and findings.log stays what bin/rule-miner.sh reads, so a worker
# outage costs DB rows and changes nothing about what gets mined. The upsert is
# keyed (repo, pr, outcome) — the same triple the SEEN file dedupes on, so the
# two ledgers cannot end up disagreeing about what is new.
# DRY never writes: a dry run must not leave rows behind in a shared database.
if [ "$NEW" -gt 0 ] && [ "$DRY" != 1 ] && command -v metric_outcomes >/dev/null 2>&1; then
  python3 - "$CSV" "$NEW" <<'PUSHEOF' 2>/dev/null | while IFS=$'\t' read -r _day _repo _pr _out _ev _rep; do
import csv, sys
rows = list(csv.reader(open(sys.argv[1], newline="")))[1:][-int(sys.argv[2]):]
for r in rows:
    if len(r) >= 5:
        # Tabs and newlines would split a field across the read loop below; the
        # evidence string is free text assembled from commit subjects. A short
        # row (written before the repairs column existed) pushes no count.
        # An empty cell is written as "-": tab is IFS whitespace, so two
        # adjacent tabs would read as one and every field after the empty one
        # would land in the wrong variable.
        r = (r + ["-"])[:6]
        print("\t".join((" ".join(str(c).split()) or "-") for c in r))
PUSHEOF
    metric_outcomes "$_repo" "$_pr" "$_out" "$_day" "$_ev" "$_rep" || true
  done
fi

BADN=$(echo "$REPO_BAD" | wc -w | tr -d ' ')
echo "$(STAMP) scanned=$SCANNED prs=$PRS source=$LEDGER_SRC new_findings=$NEW repos_failed=$BADN${REPO_BAD:+ ($(echo "$REPO_BAD" | xargs))} rework=$REWORK_ROWS rework_complete=$REWORK_COMPLETE rework_scan_days=$RW_SCAN rework_first=$([ -n "$RW_FIRST" ] && printf '%s' "$RW_FIRST" | tr ' ' ',' || echo -)$([ "$DRY" = 1 ] && echo " dry=1")" >> "$LOG"
exit "$RUN_RC"
