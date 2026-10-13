#!/bin/bash
# tests/hotfix-seen-standalone.bh-637-test.sh — adoption is by LABEL, never by
# title (BH-637 §1).
#
# WHAT HAPPENED. An orchestrator-side merge gate seeded its key set from the
# open `hotfix` issues but only ADDED an issue whose title matched
# `<KEY>.<n>:` — a decomposition child. Two standalone hotfix issues were
# therefore invisible to it: they built, opened green PRs, and sat unmerged
# while the operator believed the gate had them. That gate is not a file in this
# repo (it was a hub orchestrator session), so what ships here is the rule
# pinned on the harness's OWN selector, which every lane in this fleet uses:
# adopt any open issue carrying the label, child or not, and keep any explicit
# parents list as a seed rather than as the filter.
#
# WHY A SEPARATE SUITE. tests/hotfix-seen-test.sh already drives this script for
# the announcement and its negatives; this file pins the ADOPTION RULE, and the
# per-ticket test-home rule says a ticket's assertions live in its own file
# rather than appended to a shared one.
#
# What is asserted is the artifacts — ALERTS lines, beats, dedupe markers — and
# the gh argv, because "which issues were selected" is invisible in the output
# and lives entirely in the listing's flags.
#
# Run from anywhere: tests/hotfix-seen-standalone.bh-637-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/prompts" "$T/repos"
cp "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/" 2>/dev/null
for f in hotfix-seen.sh fleet-conf.sh; do cp "$DIR/bin/$f" "$T/bin/" 2>/dev/null; done
export PATH="$T/bin:$PATH"

export BEAT_SINK="$T/beat.txt"; : > "$BEAT_SINK"
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEAT_SINK"
exit 0
SH
chmod +x "$T/bin/beat.sh"

export GH_ARGS="$T/gh-args.txt"; : > "$GH_ARGS"
# (BH-781) The listing goes through bin/lib/gh-rest.sh, so the stub answers in
# the wire shape that library reads: a status line, a blank line, the body.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_ARGS"
case "$*" in
  *"/issues"*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n'; cat "$HARNESS/issues.json" ;;
esac
SH
chmod +x "$T/bin/gh"

cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -  -  0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
: > "$T/env/global.env"

[ -x "$T/bin/hotfix-seen.sh" ] && ok || { echo "FAIL: bin/hotfix-seen.sh is missing or not executable"; exit 1; }

# ONE listing, TWO shapes: a decomposition child (the only shape a title filter
# would have kept) beside a standalone. Both must be adopted.
cat > "$T/issues.json" <<'JSON'
[
 {"number":62,"title":"AB-50.1: dead sign-in anchor"},
 {"number":63,"title":"main-red static-guards drift"}
]
JSON

: > "$T/logs/ALERTS.log"; : > "$BEAT_SINK"; : > "$GH_ARGS"
rm -rf "$T/state/hotfix-announced"
"$T/bin/hotfix-seen.sh" proj; RC=$?
[ "$RC" = 0 ] && ok || bad "a mixed child/standalone listing must exit 0 (rc=$RC)"
[ "$(grep -c 'HOTFIX seen' "$T/logs/ALERTS.log")" = 2 ] && ok \
  || bad "both the split child and the standalone must be announced (got: $(cat "$T/logs/ALERTS.log"))"
# BH-2337: `seen` is a notice — ALERTS lines only, never a beat/alert row.
[ "$(grep -c . "$BEAT_SINK")" = 0 ] && ok || bad "HOTFIX seen must not beat (got: $(cat "$BEAT_SINK"))"
grep -q '\[proj/AB-62\] HOTFIX seen: AB-62 — AB-50.1: dead sign-in anchor' "$T/logs/ALERTS.log" \
  && ok || bad "the split child must be adopted: $(cat "$T/logs/ALERTS.log")"
grep -q '\[proj/AB-63\] HOTFIX seen: AB-63 — main-red static-guards drift' "$T/logs/ALERTS.log" \
  && ok || bad "a STANDALONE hotfix issue must be adopted too, title or no title: $(cat "$T/logs/ALERTS.log")"
[ -f "$T/state/hotfix-announced/proj/AB-62.seen" ] && ok || bad "the split child's dedupe marker was not written"
[ -f "$T/state/hotfix-announced/proj/AB-63.seen" ] && ok \
  || bad "the standalone must get its own marker, or it is re-announced for life"

# THE NEGATIVE THAT MATTERS: the listing is filtered by LABEL and STATE only. A
# title term or a search qualifier here is the defect, on the harness side.
LIST=$(grep '/issues' "$GH_ARGS" | head -1)
[ -n "$LIST" ] && ok || bad "no issue listing was recorded — the selector was never driven (got: $(cat "$GH_ARGS"))"
case "$LIST" in *"labels=ai-build,hotfix"*) ok ;;
  *) bad "the listing must AND ai-build with the hotfix label (got: $LIST)" ;; esac
case "$LIST" in *"state=open"*) ok ;;
  *) bad "the listing must select on state too (got: $LIST)" ;; esac
case "$LIST" in *--search*|*"in:title"*|*--title*) bad "the listing must carry no title term (got: $LIST)" ;; *) ok ;; esac

echo "hotfix-seen-standalone.bh-637: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
