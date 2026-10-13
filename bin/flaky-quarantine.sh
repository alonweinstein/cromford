#!/bin/bash
# bin/flaky-quarantine.sh <project|owner/repo> [--apply] [--min N] [--days N]
#
# Proposes quarantine entries for a repo's ci/flaky.txt from the ci_flakes
# ledger: every test that flaked on at least --min DISTINCT heads inside the
# window and is not already listed.
#
# DRY-RUN BY DEFAULT, and that is the whole safety model. Quarantining a test
# makes it stop failing the build, so an automatic quarantine is a machine that
# can silently switch off the repo's own alarms. Everything here is a read
# until someone types --apply, and even --apply only opens a PULL REQUEST — a
# human still merges it, sees the diff, and owns the decision. Nothing in this
# file ever pushes to a default branch.
#
# WHY A FILE IN THE PRODUCT REPO AND NOT A ROW IN OUR DB. The list has to be
# readable by the repo's own test runner, on a developer's laptop, with no
# harness and no network. A committed ci/flaky.txt is reviewable in the PR that
# adds it, greppable, and it shows up in `git blame` when someone asks why a
# test stopped failing. See docs/FLAKY-TESTS.md for the runner snippet.
#
#   bin/flaky-quarantine.sh project-3              # what it WOULD add
#   bin/flaky-quarantine.sh project-3 --apply      # opens the PR
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
export HARNESS="$H"
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/flaky.sh
. "$H/bin/lib/flaky.sh"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
TARGET=""; APPLY=0; DAYS="$FLAKY_WINDOW_DAYS"; MIN="$FLAKY_MIN"
QFILE="${FLAKY_QUARANTINE_FILE:-ci/flaky.txt}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --days)  DAYS="${2:-14}"; shift 2 ;;
    --min)   MIN="${2:-3}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) [ -n "$TARGET" ] || TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "usage: flaky-quarantine.sh <project|owner/repo> [--apply] [--min N] [--days N]" >&2; exit 2; }
case "$DAYS" in ''|*[!0-9]*) DAYS=14 ;; esac
case "$MIN"  in ''|*[!0-9]*) MIN=3 ;; esac
case "$TARGET" in
  */*) SLUG="$TARGET" ;;
  *)   SLUG=$("$H/bin/fleet-conf.sh" "$TARGET" repo 2>/dev/null) ;;
esac
[ -n "${SLUG:-}" ] && [ "$SLUG" != "-" ] || { echo "flaky-quarantine: no repo for '$TARGET'" >&2; exit 2; }
if command -v gh_repo_use_token >/dev/null 2>&1; then
  gh_repo_use_token "$SLUG" || {
    command -v gh_repo_invisible_alert >/dev/null 2>&1 && \
      gh_repo_invisible_alert flaky-quarantine "$SLUG" "quarantine proposal cannot read the repo"
    exit 1; }
fi
# #425: one repo for the whole run — arm after the PAT probe so the App token wins when armed.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
SINCE=$(flaky_since_date "$DAYS")
LOG="$H/logs/flaky-detect.log"; mkdir -p "$H/logs" 2>/dev/null

# ── 1. the candidates, straight out of the ledger ───────────────────────────
# job:<name> and workflow:<path> rows are EXCLUDED: they are honest records of a
# red whose test names we could not read, and no test runner will ever match a
# name shaped like that. Quarantining one would be quarantining nothing while
# looking like it did something.
CAND=$(flaky_known_set "$SLUG" "$SINCE" "$MIN")
if [ -z "$CAND" ]; then
  echo "flaky-quarantine $SLUG — nothing at >=$MIN flaky heads since $SINCE"
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  exit 0
fi

# ── 2. what the repo already quarantines ────────────────────────────────────
CUR=""; CURSHA=""
META=$(gh api "repos/$SLUG/contents/$QFILE" -q '"\(.sha)\t\(.content)"' 2>/dev/null || true)
if [ -n "$META" ]; then
  CURSHA=$(cut -f1 <<<"$META")
  CUR=$(cut -f2 <<<"$META" | tr -d '\n' | base64 -d 2>/dev/null || true)
fi
NEW=""
while IFS= read -r N; do
  [ -n "$N" ] || continue
  grep -qxF -- "$N" <<<"$CUR" && continue
  NEW="${NEW}${N}"$'\n'
done <<<"$CAND"
NEW=$(printf '%s' "$NEW" | grep -av '^$' || true)
if [ -z "$NEW" ]; then
  echo "flaky-quarantine $SLUG — $(grep -c . <<<"$CAND") candidate(s), all already in $QFILE"
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  exit 0
fi

echo "flaky-quarantine $SLUG — $(grep -c . <<<"$NEW") new entr(ies) for $QFILE (>=$MIN flaky heads since $SINCE):"
while IFS= read -r N; do [ -n "$N" ] && echo "  + $N"; done <<<"$NEW"
if [ "$APPLY" != 1 ]; then
  echo ""
  echo "  dry run. Re-run with --apply to open a PR adding these to $QFILE."
  echo "$(STAMP) $SLUG quarantine: $(grep -c . <<<"$NEW") candidate(s), dry" >> "$LOG"
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  exit 0
fi

# ── 3. --apply: a BRANCH and a PULL REQUEST, never a push to the default ────
BASE=$(gh api "repos/$SLUG" -q .default_branch 2>/dev/null); BASE="${BASE:-main}"
BASESHA=$(gh api "repos/$SLUG/git/ref/heads/$BASE" -q .object.sha 2>/dev/null)
[ -n "$BASESHA" ] || { echo "flaky-quarantine: could not read $SLUG@$BASE" >&2; exit 1; }
BR="chore/quarantine-flaky-$(date -u +%Y%m%d%H%M)"
HEADER="# Quarantined flaky tests — retried, not ignored. See docs/FLAKY-TESTS.md.
# One test name per line, as the runner reports it. Lines starting with # are comments.
# Added by bin/flaky-quarantine.sh from the harness ci_flakes ledger.
# DELETE a line once the test is fixed: this file is a debt list, not a config."
BODYTXT="$CUR"
[ -n "$BODYTXT" ] || BODYTXT="$HEADER"
BODYTXT="$BODYTXT
$NEW"
CONTENT=$(printf '%s\n' "$BODYTXT" | base64 | tr -d '\n')
gh api -X POST "repos/$SLUG/git/refs" -f "ref=refs/heads/$BR" -f "sha=$BASESHA" >/dev/null 2>&1 || {
  echo "flaky-quarantine: could not create branch $BR on $SLUG" >&2; exit 1; }
PUTARGS=(-X PUT "repos/$SLUG/contents/$QFILE"
  -f "message=chore(ci): quarantine $(grep -c . <<<"$NEW") flaky test(s)"
  -f "content=$CONTENT" -f "branch=$BR")
[ -n "$CURSHA" ] && PUTARGS+=(-f "sha=$CURSHA")
gh api "${PUTARGS[@]}" >/dev/null 2>&1 || { echo "flaky-quarantine: could not write $QFILE on $BR" >&2; exit 1; }
PRBODY="Adds $(grep -c . <<<"$NEW") test(s) to \`$QFILE\`. Each one concluded BOTH failure and success on the same head sha (same tree, no push between) on at least $MIN distinct heads in the last $DAYS days, per the harness ci_flakes ledger.

$(printf '%s\n' "$NEW" | sed 's/^/- /')

Quarantine means the runner RETRIES these, not that it ignores them: a test that fails every attempt still fails the build. The entry is a debt line — delete it when the test is fixed.

Evidence: \`bin/flaky-detect.sh $TARGET\` on the harness hub. Policy: docs/FLAKY-TESTS.md."
# >>> pr trailers (BH-3987)
# The lane that runs this (flaky-detect) opened it. The body goes through a file
# so the block can be applied; with no file, the same create reads the plain
# body from stdin.
PRBF=$(mktemp "${TMPDIR:-/tmp}/fq-body-XXXX" 2>/dev/null) \
  && { printf '%s\n' "$PRBODY" > "$PRBF"; } 2>/dev/null || { rm -f "$PRBF"; PRBF=""; }
[ -r "${H:-}/bin/lib/pr-trailers.sh" ] && . "$H/bin/lib/pr-trailers.sh"
if [ -n "$PRBF" ] && command -v pr_trailers_apply >/dev/null 2>&1; then
  pr_trailers_apply "$PRBF" lane:flaky-detect none \
    || echo "flaky-quarantine: pr trailers: could not write $PRBF — PR opened without trailers" >&2
elif [ -z "$PRBF" ]; then
  echo "flaky-quarantine: pr trailers: no body file could be written in ${TMPDIR:-/tmp} — PR opened without trailers" >&2
fi
PRURL=$(gh pr create -R "$SLUG" --base "$BASE" --head "$BR" \
  --title "chore(ci): quarantine $(grep -c . <<<"$NEW") flaky test(s)" --body-file "${PRBF:--}" <<<"$PRBODY" 2>&1 | tail -1)
[ -z "$PRBF" ] || rm -f "$PRBF"
# <<< pr trailers
echo "  PR: $PRURL"
echo "$(STAMP) $SLUG quarantine: $(grep -c . <<<"$NEW") entr(ies) proposed on $BR -> $PRURL" >> "$LOG"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
