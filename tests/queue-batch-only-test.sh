#!/bin/bash
# tests/queue-batch-only-test.sh — bin/lib/queue-batch-only.sh: which repos
# run their test corpus ONLY in the merge-queue batch (2026-09-24).
#
# On such a repo a green PR head is a fast-checks green, so the conductor's
# degraded direct merge and Mission Control's merge_pr must stand down
# (tests/hotfix-conductor-degraded-test.sh section 7,
# tests/poll-commands-merge-pr.bh-892-test.sh section 7). The predicate reads
# the repo's own .mergify.yml: merge_conditions asking for a check that
# queue_conditions do not.
#
#   Y1  this repo's .mergify.yml is batch-only
#   Y2  identical lists (project-5's shape) are not
#   Y3  both quoting styles and `=` spacing parse the same
#   Y4  a config with no conditions at all is not
#   Y5  the live predicate: not Mergify -> no; Mergify + split -> yes;
#       Mergify + unreadable config -> no (the caller keeps its old behaviour)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LIB="$DIR/bin/lib/queue-batch-only.sh"
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "queue-batch-only: 0 pass, 1 fail"; exit 1; }
# shellcheck source=bin/lib/queue-batch-only.sh
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

mc_queue_batch_only_yml < "$DIR/.mergify.yml" && ok || bad "Y1: cromford's .mergify.yml must read as batch-only"

SAME='queue_rules:
  - name: default
    queue_conditions:
      - base=main
      - "check-success=Build + Unit tests"
    merge_conditions:
      - "check-success=Build + Unit tests"
    merge_method: squash'
printf '%s\n' "$SAME" | mc_queue_batch_only_yml && bad "Y2: identical queue and merge checks are not batch-only" || ok

MIXED="queue_rules:
  - name: default
    queue_conditions:
      - check-success = \"Lint\"
    merge_conditions:
      - 'check-success=Lint'
      - check-success = \"Corpus\"
    merge_method: merge"
printf '%s\n' "$MIXED" | mc_queue_batch_only_yml && ok || bad "Y3: a merge-only check in any quoting must read as batch-only"
MIXED2="queue_rules:
  - name: default
    queue_conditions:
      - check-success = \"Lint\"
    merge_conditions:
      - 'check-success=Lint'
    merge_method: merge"
printf '%s\n' "$MIXED2" | mc_queue_batch_only_yml && bad "Y3: the same check in two quoting styles is one check" || ok

printf 'queue_rules:\n  - name: default\n' | mc_queue_batch_only_yml && bad "Y4: no conditions is not batch-only" || ok

# Y5: the live predicate over stubbed provider/policy reads.
B64=$(base64 < "$DIR/.mergify.yml" | tr -d '\n')
PROV=mergify; POL="{\"content\":\"$B64\"}"; POLRC=0
mc_queue_provider() { printf '%s' "$PROV"; }
mc_policy_get() { printf -v "$1" '%s' "$POL"; return "$POLRC"; }
mc_queue_batch_only o/r && ok || bad "Y5: Mergify + a split config must be batch-only"
PROV=none
mc_queue_batch_only o/r && bad "Y5: a repo not on Mergify is never batch-only" || ok
# FAIL CLOSED (2026-09-25). A config that cannot be read is not evidence that
# the repo tests its PR heads: answering "no" there let a caller believe a
# fast-checks green (and, before BH-2199, take a degraded direct merge of a
# tree no corpus ran on). TEST-CHANGE: Y5's old "an unreadable config must
# answer no" is reversed on purpose, by the #2220 rebase directive.
PROV=mergify; POLRC=1
mc_queue_batch_only o/r && ok || bad "F1: a .mergify.yml read that fails (403, outage) must answer yes (fail closed)"
POLRC=0; POL='{"message":"Server Error"}'
mc_queue_batch_only o/r && ok || bad "F2: a read with no content must answer yes (fail closed)"
POL='{"content":"!!!not-base64!!!"}'
mc_queue_batch_only o/r && ok || bad "F3: undecodable content must answer yes (fail closed)"
PROV=unknown; POL="{\"content\":\"$B64\"}"
mc_queue_batch_only o/r && ok || bad "F4: an unknown provider (unreadable probe, BH-2275) must answer yes (fail closed)"
PROV=mergify
( unset -f mc_policy_get; mc_queue_batch_only o/r ) && ok || bad "F5: no policy reader loaded must answer yes (fail closed)"
( unset -f mc_queue_provider; mc_queue_batch_only o/r ) && ok || bad "F6: no provider reader loaded must answer yes (fail closed)"
PROV=github
mc_queue_batch_only o/r && bad "F7: a known non-Mergify repo still answers no" || ok
PROV=mergify; POLRC=0
POLRC=0; POL="{\"content\":\"$(printf '%s\n' "$SAME" | base64 | tr -d '\n')\"}"
mc_queue_batch_only o/r && bad "Y5: Mergify with identical lists is not batch-only" || ok

echo "queue-batch-only: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
