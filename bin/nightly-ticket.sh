#!/bin/bash
# bin/nightly-ticket.sh <verdict-dir> — a red nightly run OPENS A TICKET
# (2026-09-28, the nightly tier).
#
# The suites in catalog/test-tiers.tsv's nightly and guard tiers no longer run
# in every merge-queue batch (bin/test-tiers.sh). What keeps that from being a
# place tests go to rot is this script: .github/workflows/harness-nightly.yml
# calls it whenever the nightly run on main is red, and it files the red where
# the fleet's work comes from — an issue on this repository. One ticket, not one
# a night: an OPEN issue carrying the marker below (found on any page of the
# open items) gets a comment instead, so a
# suite that stays red for a week is one thread with seven entries.
#
# It reads the shard logs the nightly shards upload next to their verdicts
# (`shard-<i>.log`, bin/test-trace-safety.sh --gate output): a
# `--- <suite> rc=<n> <s>s` line with n != 0 is a failed suite, a `HIT <name>`
# line a trace hit. A plan that failed or a shard that left no log is named as
# such: a red run with no suite to blame still files, never goes quiet.
#
# A red strict ratchet pass (bin/nightly-strict-ratchets.sh) arrives as
# strict.md in the same directory and is quoted whole.
#
# Environment: NT_REPO (owner/name), NT_RUN_URL, NT_SHA, NT_PLAN_RESULT,
# NT_STRICT_RESULT,
# NT_PLAN_N (the shard count the plan published), NT_GH (the gh binary; the
# test seam), GH_TOKEN (the workflow's own token — issues: write, nothing else).
# A new ticket is opened labelled `ai-build` (BH-3411); a comment on an open one
# never adds or re-adds the label, so a ticket a person unlabelled stays so.
# rc 0 when the ticket was filed or updated, 1 when GitHub refused (including a
# new ticket that could not be labelled ai-build), 2 on usage.
set -uo pipefail
VDIR="${1:-}"
[ -n "$VDIR" ] || { echo "nightly-ticket: usage: $0 <verdict-dir>" >&2; exit 2; }
REPO="${NT_REPO:-}"
[ -n "$REPO" ] || { echo "nightly-ticket: NT_REPO is not set" >&2; exit 2; }
GH="${NT_GH:-gh}"
MARK="<!-- harness-nightly-red -->"
TITLE="Nightly test tier is red on main"

FAILED=$(cat "$VDIR"/shard-*.log 2>/dev/null | sed -n 's/^--- \(tests\/[^ ]*\) rc=\([1-9][0-9]*\).*/\1 (rc \2)/p' | LC_ALL=C sort -u)
HITS=$(cat "$VDIR"/shard-*.log 2>/dev/null | sed -n 's/^HIT \([^ ]*\) .*/\1/p' | LC_ALL=C sort -u)
MISSING=""
N="${NT_PLAN_N:-0}"; case "$N" in ''|*[!0-9]*) N=0 ;; esac
for ((i = 0; i < N; i++)); do
  [ -r "$VDIR/shard-$i.txt" ] || MISSING="$MISSING $i"
done

{
  printf '%s\n' "$MARK"
  printf 'The nightly run of the `nightly` and `guard` tiers (catalog/test-tiers.tsv) failed on `%s`.\n\n' "${NT_SHA:-main}"
  printf 'Run: %s\n\n' "${NT_RUN_URL:-(no run url)}"
  if [ -n "$FAILED" ]; then
    printf 'Failing suites:\n'; printf '%s\n' "$FAILED" | sed 's/^/- `/; s/ (rc/` (rc/'; printf '\n'
  fi
  if [ -n "$HITS" ]; then
    printf 'Trace hits (a test deleted or redirected outside a temp root):\n'; printf '%s\n' "$HITS" | sed 's/^/- `/; s/$/`/'; printf '\n'
  fi
  if [ -s "$VDIR/strict.md" ]; then
    printf 'Strict ratchets (the whole tree against its baseline; catalog/nightly-strict.txt):\n\n'; cat "$VDIR/strict.md"
  elif [ "${NT_STRICT_RESULT:-success}" != success ]; then
    printf 'The strict ratchet pass did not succeed (%s) and left no summary.\n\n' "${NT_STRICT_RESULT:-}"
  fi
  [ "${NT_PLAN_RESULT:-success}" = success ] || printf 'The plan job did not succeed (%s), so no suite ran.\n\n' "${NT_PLAN_RESULT:-}"
  [ -z "$MISSING" ] || printf 'Shard(s)%s left no verdict: the job died, timed out or was cancelled before its scan finished.\n\n' "$MISSING"
  if [ -z "$FAILED$HITS$MISSING" ] && [ "${NT_PLAN_RESULT:-success}" = success ] \
     && [ ! -s "$VDIR/strict.md" ] && [ "${NT_STRICT_RESULT:-success}" = success ]; then
    printf 'No failing suite could be read from the shard logs; open the run.\n\n'
  fi
  printf 'These suites no longer run in every merge-queue batch, so this ticket is the only place their red shows up. Fix the suite or the code; to put a suite back in every batch, delete its row in catalog/test-tiers.tsv.\n'
} > "${TMPDIR:-/tmp}/nightly-ticket.$$.md"
BODY_FILE="${TMPDIR:-/tmp}/nightly-ticket.$$.md"
trap 'rm -f "$BODY_FILE"' EXIT

# EVERY page of the open items, not the first: issues?state=open lists pull
# requests too, and a repo with 100+ newer open items would push the ticket off
# page 1 and open a duplicate every night. gh applies --jq to each page.
OPEN=$("$GH" api --paginate "repos/$REPO/issues?state=open&per_page=100" \
         --jq ".[] | select(.pull_request == null) | select((.body // \"\") | contains(\"$MARK\")) | .number" 2>/dev/null) \
  || { echo "nightly-ticket: could not list the open issues of $REPO" >&2; exit 1; }
NUM=$(printf '%s\n' "$OPEN" | grep -E '^[0-9]+$' | head -1)

if [ -n "$NUM" ]; then
  "$GH" api -X POST "repos/$REPO/issues/$NUM/comments" -F "body=@$BODY_FILE" >/dev/null \
    || { echo "nightly-ticket: could not comment on #$NUM" >&2; exit 1; }
  echo "nightly-ticket: updated #$NUM"
else
  # Opened labelled ai-build so the red reaches a builder (BH-3411). GitHub
  # drops labels on create, silently, for a caller without push access, so the
  # answer is read back and a dropped label is added once through /labels.
  RESP=$("$GH" api -X POST "repos/$REPO/issues" -f "title=$TITLE" -F "body=@$BODY_FILE" -f 'labels[]=ai-build' \
           --jq '"\(.number) \([.labels[]?.name] | index("ai-build") != null)"') \
    || { echo "nightly-ticket: could not open an issue on $REPO" >&2; exit 1; }
  NEW="${RESP%% *}"
  if [ "${RESP##* }" != true ]; then
    "$GH" api -X POST "repos/$REPO/issues/$NEW/labels" -f 'labels[]=ai-build' >/dev/null \
      || { echo "nightly-ticket: opened #$NEW but could not label it ai-build" >&2; exit 1; }
  fi
  echo "nightly-ticket: opened #$NEW"
fi
