#!/bin/bash
# tests/pipeline-health-repo-shallow-test.sh — "a hub repo is a SHALLOW clone",
# the block extracted VERBATIM from bin/pipeline-health.sh by its markers and
# driven against a scratch /root/repos.
#
# WHY IT EXISTS (BH-517). /root/repos/<project> is what the merge conductor
# rebases in. Restored by hand with a --depth, it has no merge base with
# origin/main for any PR that forked before the boundary, so every rebase of an
# older PR dies "refusing to merge unrelated histories" and the PR loops
# NEEDS_REBASE. Nothing in the harness ever asked whether the hub's clones were
# complete — this is the check that asks, once a day, per repo.
#
# FAIL-OPEN IS THE PROPERTY UNDER TEST: a zero-byte .git/shallow is still a
# shallow clone and must still page. The negatives matter as much — a complete
# clone, an empty /root/repos, a missing /root/repos, the .preplan-* copies and
# a stray file must all stay silent, because a check that pages on nothing gets
# muted and then pages on nothing forever.
#
# Run from anywhere: tests/pipeline-health-repo-shallow-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The scratch lib owns $T where the box has it; where it does not (it is not
# tracked on main yet) this suite owns its own tree.
# shellcheck source=/dev/null
[ -r "$(dirname "$0")/lib/scratch.sh" ] && . "$(dirname "$0")/lib/scratch.sh"
if [ -z "${T:-}" ]; then T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read; nothing below derives an age from a second one.
NOW=$(date +%s)

awk '/^# >>> hub repo shallow/{f=1;next} /^# <<< hub repo shallow/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "could not extract the hub-repo-shallow block — markers missing?"

mkdir -p "$T/repos" "$T/logs" "$T/state"

mkrepo() { # <name> [shallow-lines] — a repo dir, shallow when a count is given
  mkdir -p "$T/repos/$1/.git"
  if [ -n "${2:-}" ]; then
    if [ "$2" = 0 ]; then : > "$T/repos/$1/.git/shallow"
    else seq 1 "$2" | sed 's/.*/0000000000000000000000000000000000000000/' > "$T/repos/$1/.git/shallow"
    fi
  fi
}
reset() { rm -rf "$T/repos"; mkdir -p "$T/repos"; : > "$T/alerts.txt"; }
drive() { # drive [VAR=val ...] — runs the block with a recording alert()
  : > "$T/alerts.txt"
  ( export HARNESS="$T" T="$T" NOW="$NOW" "$@"
    bash -c '
      set -uo pipefail
      H="$T"
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$0"' "$T/block.sh" >/dev/null 2>"$T/err.txt" )
}

# ============================================================================
# (a) one shallow hub repo: exactly one alert, keyed for retraction, carrying
#     the ticket's name, the path, the boundary count and the fix command.
# ============================================================================
reset; mkrepo demo-os 1
drive HUB_REPOS="$T/repos"
[ "$(wc -l < "$T/alerts.txt")" = 1 ] && ok || bad "(a) expected one alert, got: $(cat "$T/alerts.txt")"
L=$(head -1 "$T/alerts.txt")
grep -q '^86400|hubreposhallow:demo-os|' <<<"$L" \
  && ok || bad "(a) once a day, under a per-repo key: $L"
grep -q 'hub-repo-shallow-demo-os' <<<"$L" \
  && ok || bad "(a) the line must lead with the ticket's alert name: $L"
grep -qF "$T/repos/demo-os" <<<"$L" \
  && ok || bad "(a) the line must name the repo path: $L"
grep -q '1 boundary commit' <<<"$L" \
  && ok || bad "(a) the line must carry the boundary count: $L"
grep -q 'fetch --unshallow origin' <<<"$L" \
  && ok || bad "(a) the line must name the fix command: $L"
[ ! -s "$T/err.txt" ] && ok || bad "(a) the block must be quiet on stderr: $(cat "$T/err.txt")"

# ============================================================================
# (b) two shallow repos page once each; a COMPLETE repo beside them is silent.
# ============================================================================
reset; mkrepo demo-os 2; mkrepo other-os 3; mkrepo fine-os
drive HUB_REPOS="$T/repos"
[ "$(wc -l < "$T/alerts.txt")" = 2 ] && ok || bad "(b) expected two alerts, got: $(cat "$T/alerts.txt")"
grep -q 'hubreposhallow:demo-os' "$T/alerts.txt" && grep -q 'hubreposhallow:other-os' "$T/alerts.txt" \
  && ok || bad "(b) one key per shallow repo: $(cat "$T/alerts.txt")"
grep -q 'fine-os' "$T/alerts.txt" && bad "(b) a complete clone must never page: $(cat "$T/alerts.txt")" || ok
grep -q '3 boundary commit' "$T/alerts.txt" \
  && ok || bad "(b) each line carries its own boundary count: $(cat "$T/alerts.txt")"

# ============================================================================
# (c) NEGATIVES: nothing shallow, an empty tree, and a missing tree — all
#     silent, and none of them may spray stderr into the cron's mailbox.
# ============================================================================
reset; mkrepo demo-os; mkrepo other-os
drive HUB_REPOS="$T/repos"
[ ! -s "$T/alerts.txt" ] && ok || bad "(c) complete clones must be silent: $(cat "$T/alerts.txt")"
reset
drive HUB_REPOS="$T/repos"
[ ! -s "$T/alerts.txt" ] && ok || bad "(c) an empty /root/repos must be silent: $(cat "$T/alerts.txt")"
drive HUB_REPOS="$T/nope"
[ ! -s "$T/alerts.txt" ] && ok || bad "(c) a missing /root/repos must be silent: $(cat "$T/alerts.txt")"
[ ! -s "$T/err.txt" ] && ok || bad "(c) a missing /root/repos must not write stderr: $(cat "$T/err.txt")"

# ============================================================================
# (d) NEGATIVE: the .preplan-* copies are `git clone`s of the local repo, not
#     what the conductor rebases; a stray file and a non-repo dir are neither.
# ============================================================================
reset; mkrepo .preplan-demo-os 1; echo x > "$T/repos/README"; mkdir -p "$T/repos/dirnogit"
drive HUB_REPOS="$T/repos"
[ ! -s "$T/alerts.txt" ] && ok || bad "(d) only /root/repos/<project>/.git/shallow pages: $(cat "$T/alerts.txt")"
[ ! -s "$T/err.txt" ] && ok || bad "(d) stray entries must not write stderr: $(cat "$T/err.txt")"

# ============================================================================
# (e) FAIL-OPEN: a zero-byte .git/shallow is still a shallow clone.
# ============================================================================
reset; mkrepo demo-os 0
drive HUB_REPOS="$T/repos"
[ "$(wc -l < "$T/alerts.txt")" = 1 ] \
  && ok || bad "(e) an unreadable boundary count must still page: $(cat "$T/alerts.txt")"
grep -q '^86400|hubreposhallow:demo-os|' "$T/alerts.txt" \
  && ok || bad "(e) same key on the fail-open path: $(cat "$T/alerts.txt")"

# ============================================================================
# (f) the key is RETRACTABLE: an unshallowed repo must earn its one RESOLVED
#     line through the epilogue, which only fires for namespaces in RETRACT_NS.
#     The namespace list is read from the script itself — an absent line makes
#     the regex empty and this check fail, which is the point.
# ============================================================================
RETRACT_NS=""
eval "$(grep -m1 '^RETRACT_NS=' "$DIR/bin/pipeline-health.sh")"
grep -qE "^($RETRACT_NS):" <<<"hubreposhallow:demo-os" \
  && ok || bad "(f) hubreposhallow is not in RETRACT_NS, so a healed repo never retracts"

echo "pipeline-health-repo-shallow: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
