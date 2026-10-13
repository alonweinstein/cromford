#!/bin/bash
# tests/hotfix-lib-test.sh — the hotfix lane's VOCABULARY and its ANNOUNCEMENT
# (#368 slice 1/5, BH-414).
#
# WHAT THIS PINS AND WHY. One label on one issue is supposed to reorder the
# whole fleet, and six callers have to agree on what that label means before
# the sentence is true. So the predicates live in bin/lib/hotfix-lib.sh and the
# thing asserted here is their ANSWER — a return code, an ALERTS line, a beat
# payload, a marker file — never the shape of the source.
#
# The adversarial label names are the point: `hotfix-candidate` is somebody
# ASKING whether this is urgent and `not-hotfix` is somebody saying it is not,
# and either one reading as an emergency spends a cap exemption on a ticket
# nobody declared urgent. The failure this suite exists to catch is silent in
# both directions: a hotfix that reads as ordinary still ships, just late.
#
# ORDERING (which ticket bin/preplan-candidates.sh emits first) is NOT here —
# it belongs to the preplan slice's own file, because nothing on main sources
# this lib yet.
#
# Run from anywhere: tests/hotfix-lib-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/repos"
cp "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/" 2>/dev/null
cp "$DIR/bin/fleet-conf.sh" "$T/bin/" 2>/dev/null
export PATH="$T/bin:$PATH"
export BEAT_SINK="$T/beat.txt"; : > "$BEAT_SINK"
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEAT_SINK"
exit 0
SH
chmod +x "$T/bin/beat.sh"
# The gh stub: GH_MODE picks the answer, and every invocation appends one byte
# to $GH_CALLS so "this predicate must not call GitHub at all" is assertable.
# (BH-781) hotfix_issue_is reads GET /repos/{slug}/issues/{n}/labels through
# bin/lib/gh-rest.sh, so the stub answers in the wire shape that library reads:
# a status line, a blank line, then the body. `fail` is the 403 a rate-limited
# or dead token really returns, which is rc 75 in the library and UNKNOWN here.
export GH_CALLS="$T/gh-calls"; : > "$GH_CALLS"
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf 'x' >> "$GH_CALLS"
case "${GH_MODE:-none}" in
  fail) printf 'HTTP/2.0 403 Forbidden\nx-stub: 1\n\n{"message":"API rate limit exceeded"}\n'; exit 1 ;;
  hot)  printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[{"name":"hotfix"}]\n' ;;
  *)    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[]\n' ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"
calls() { wc -c < "$GH_CALLS" | tr -d ' '; }
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
bproj example-org/bproj  https://b.example /api/board  0 local -
CONF
: > "$T/env/global.env"

# ════════════════════════════════════════════════════════════════════════════
# 1. THE VOCABULARY — bin/lib/hotfix-lib.sh
# ════════════════════════════════════════════════════════════════════════════
if [ ! -r "$T/bin/lib/hotfix-lib.sh" ]; then
  bad "bin/lib/hotfix-lib.sh does not exist — every assertion below depends on it"
else
. "$T/bin/lib/hotfix-lib.sh"

[ "$(hotfix_label "$T")" = hotfix ] && ok || bad "the default label must be 'hotfix' (got '$(hotfix_label "$T")')"
printf 'HOTFIX_LABEL=urgent\n' > "$T/env/global.env"
[ "$(hotfix_label "$T")" = urgent ] && ok || bad "env/global.env must set HOTFIX_LABEL (got '$(hotfix_label "$T")')"
: > "$T/env/global.env"
[ "$(HOTFIX_LABEL=urgent hotfix_label "$T")" = urgent ] && ok || bad "the environment must set HOTFIX_LABEL"

# The JSON matcher: an EXACT whole-name match, case-insensitive. Everything
# below is a label a human would plausibly type on a ticket that is NOT the
# emergency one, and each of them reading as a hotfix is a cap exceeded and a
# queue jumped for a ticket nobody declared urgent.
hotfix_labels_json_has '[{"name":"hotfix"}]' "$T"  && ok || bad "an exact label must match"
hotfix_labels_json_has '[{"name":"Hotfix"}]' "$T"  && ok || bad "the match must be case-insensitive on the whole name"
hotfix_labels_json_has '[{"name":" hotfix "}]' "$T" && ok || bad "a padded label name must match"
hotfix_labels_json_has '[{"name":"bug"},{"name":"hotfix"}]' "$T" && ok || bad "a hotfix label beside others must match"
hotfix_labels_json_has '[{"name":"hotfix-candidate"},{"name":"bug"}]' "$T" \
  && bad "'hotfix-candidate' must NOT read as a hotfix" || ok
hotfix_labels_json_has '[{"name":"not-hotfix"}]' "$T" && bad "'not-hotfix' must NOT read as a hotfix" || ok
hotfix_labels_json_has '[{"name":"ai-build"}]' "$T"   && bad "a plain ai-build label is not a hotfix" || ok
hotfix_labels_json_has '[]' "$T"  && bad "an empty label list is not a hotfix" || ok
hotfix_labels_json_has '' "$T"    && bad "empty JSON is not a hotfix" || ok
hotfix_labels_json_has 'not json' "$T" && bad "unparseable JSON is not a hotfix" || ok
# the object form, which is what a ticket-meta.json carries
hotfix_labels_json_has '{"labels":[{"name":"hotfix"}]}' "$T" && ok || bad "an object with .labels must match"
# HOTFIX_LABEL moves the whole answer, so nothing is pinned to the literal word
HOTFIX_LABEL=urgent hotfix_labels_json_has '[{"name":"urgent"}]' "$T" && ok || bad "an overridden label must be the one that matches"
HOTFIX_LABEL=urgent hotfix_labels_json_has '[{"name":"hotfix"}]' "$T" \
  && bad "with HOTFIX_LABEL=urgent the word 'hotfix' must stop matching" || ok
# gh prints a bare array of strings in some shapes; it is the same answer
hotfix_labels_json_has '["hotfix"]' "$T" && ok || bad "a bare array of label strings must match"
hotfix_labels_json_has '["bug","HOTFIX"]' "$T" && ok || bad "a bare array must match case-insensitively"
hotfix_labels_json_has '[{"name":"HOTFIX"}]' "$T" && ok || bad "an all-caps label must match"
# near misses: none of these is the emergency label
hotfix_labels_json_has '[{"name":"Hotfix?"}]' "$T" && bad "'Hotfix?' must NOT read as a hotfix" || ok
hotfix_labels_json_has '[{"name":"hot fix"}]' "$T" && bad "'hot fix' must NOT read as a hotfix" || ok
hotfix_labels_json_has '[{"name":"hotfixes"}]' "$T" && bad "'hotfixes' must NOT read as a hotfix" || ok
# the WORD is not the LABEL: a title or body saying "hotfix" is not a label
hotfix_labels_json_has '{"title":"hotfix the roof","labels":[]}' "$T" \
  && bad "the word hotfix in a title is not a label" || ok
hotfix_labels_json_has '{"body":"hotfix please","labels":[]}' "$T" \
  && bad "the word hotfix in a body is not a label" || ok
hotfix_labels_json_has '"hotfix"' "$T" && bad "a bare JSON string is not a label list" || ok
hotfix_labels_json_has '{"labels":"hotfix"}' "$T" && bad "a .labels that is not an array is not a hotfix" || ok

printf '{"hotfix":true}\n'  > "$T/job-hot.json"
printf '{"hotfix":false}\n' > "$T/job-cold.json"
printf '{"key":"AB-1"}\n'   > "$T/job-plain.json"
printf '{"hotfix":"true"}\n' > "$T/job-str.json"
hotfix_job_is "$T/job-hot.json" "$T"   && ok || bad "a job file with hotfix:true is a hotfix"
hotfix_job_is "$T/job-cold.json" "$T"  && bad "hotfix:false is not a hotfix" || ok
hotfix_job_is "$T/job-plain.json" "$T" && bad "a job file with no hotfix key is not a hotfix" || ok
hotfix_job_is "$T/nope.json" "$T"      && bad "a missing job file is not a hotfix" || ok
# JSON true ONLY. The string "true" is a queue jump nobody wrote down.
hotfix_job_is "$T/job-str.json" "$T"   && bad "the STRING \"true\" is not the boolean true" || ok

printf '{"labels":[{"name":"hotfix"}]}\n' > "$T/meta-hot.json"
printf '{"labels":[{"name":"ai-build"}]}\n' > "$T/meta-cold.json"
hotfix_meta_is "$T/meta-hot.json" "$T"  && ok || bad "ticket-meta with a hotfix label is a hotfix"
hotfix_meta_is "$T/meta-cold.json" "$T" && bad "ticket-meta without the label is not a hotfix" || ok
hotfix_meta_is "$T/nope.json" "$T"      && bad "a missing ticket-meta is not a hotfix" || ok

# hotfix_issue_is — the ONE function that asks GitHub. Three answers, not two:
# 0 labelled hotfix, 1 labelled no, 2 the call itself failed so the answer is
# UNKNOWN. A dead token answering "not urgent" for every ticket in the fleet is
# exactly the silent failure this lane cannot afford, and rc 2 is still falsy
# for every `&&` caller, so nobody who does not care has to change.
: > "$GH_CALLS"
GH_MODE=fail hotfix_issue_is example-org/proj 5 "$T"; rc=$?
[ "$rc" = 2 ] && ok || bad "gh failure must be rc 2 (UNKNOWN), got $rc"
GH_MODE=none hotfix_issue_is example-org/proj 5 "$T"; rc=$?
[ "$rc" = 1 ] && ok || bad "an issue with no labels must be rc 1, got $rc"
GH_MODE=hot hotfix_issue_is example-org/proj 5 "$T"; rc=$?
[ "$rc" = 0 ] && ok || bad "an issue labelled hotfix must be rc 0, got $rc"
hotfix_issue_is '' 5 "$T"; rc=$?
[ "$rc" = 1 ] && ok || bad "an empty repo slug is a precondition failure (rc 1), got $rc"
BEFORE=$(calls)
GH_MODE=hot HOTFIX_LANE=0 hotfix_issue_is example-org/proj 5 "$T"; rc=$?
[ "$rc" = 1 ] && ok || bad "with the lane off the issue predicate must be rc 1, got $rc"
[ "$(calls)" = "$BEFORE" ] && ok || bad "with the lane off GitHub must not be called at all"

# hotfix_key_is — the build-time question, answered from fleet.conf + the issue.
GH_MODE=hot hotfix_key_is "$T" proj AB-5; rc=$?
[ "$rc" = 0 ] && ok || bad "a labelled issue on a GitHub-lane project is a hotfix, got $rc"
BEFORE=$(calls)
GH_MODE=hot hotfix_key_is "$T" bproj TK-5; rc=$?
[ "$rc" = 1 ] && ok || bad "a board project has no GitHub label and must be rc 1, got $rc"
[ "$(calls)" = "$BEFORE" ] && ok || bad "a board project must not ask GitHub anything"
GH_MODE=fail hotfix_key_is "$T" proj AB-5; rc=$?
[ "$rc" = 2 ] && ok || bad "rc 2 must propagate out of hotfix_key_is, got $rc"
GH_MODE=hot HOTFIX_LANE=0 hotfix_key_is "$T" proj AB-5; rc=$?
[ "$rc" = 1 ] && ok || bad "with the lane off hotfix_key_is must be rc 1, got $rc"
hotfix_key_is "$T" proj ''; rc=$?
[ "$rc" = 1 ] && ok || bad "an empty KEY is rc 1, got $rc"

# The announcement: ALERTS line first (local, durable), then the beat, then the
# marker. Exactly once per (project, KEY, event) for life. `seen`, `pr_open` and
# `merged` are the ALERTS line only (BH-2337, BH-2381: a notice is not an alert
# row); any other event beats.
: > "$T/logs/ALERTS.log"; : > "$BEAT_SINK"; rm -rf "$T/state/hotfix-announced"
hotfix_announce "$T" proj AB-5 seen "AB-5 — the roof is on fire" && ok || bad "hotfix_announce must return 0"
[ "$(grep -c 'HOTFIX seen' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "exactly one ALERTS line: $(cat "$T/logs/ALERTS.log")"
grep -q '\[proj/AB-5\] HOTFIX seen: AB-5 — the roof is on fire' "$T/logs/ALERTS.log" \
  && ok || bad "the ALERTS line must name the project, key, event and text: $(cat "$T/logs/ALERTS.log")"
[ "$(grep -c . "$BEAT_SINK")" = 0 ] && ok || bad "BH-2337: HOTFIX seen must not beat (no alert row): $(cat "$BEAT_SINK")"
[ -f "$T/state/hotfix-announced/proj/AB-5.seen" ] && ok || bad "the dedupe marker was not written"
hotfix_announce "$T" proj AB-5 seen "AB-5 — the roof is on fire"
[ "$(grep -c 'HOTFIX seen' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "a second call must add nothing to ALERTS"
[ "$(grep -c . "$BEAT_SINK")" = 0 ] && ok || bad "a second call must not beat either"
# ...but a DIFFERENT event on the same ticket is its own announcement
hotfix_announce "$T" proj AB-5 pr_open "PR opened https://github.com/o/r/pull/7"
grep -q '\[proj/AB-5\] HOTFIX pr_open: PR opened https://github.com/o/r/pull/7' "$T/logs/ALERTS.log" \
  && ok || bad "pr_open is a separate event and must write its ALERTS line: $(cat "$T/logs/ALERTS.log")"
[ "$(grep -c . "$BEAT_SINK")" = 0 ] && ok || bad "BH-2381: HOTFIX pr_open must not beat (no alert row): $(cat "$BEAT_SINK")"
[ -f "$T/state/hotfix-announced/proj/AB-5.pr_open" ] && ok || bad "the pr_open dedupe marker was not written"
# An event outside seen|pr_open|merged still beats, and the beat's shape holds.
hotfix_announce "$T" proj AB-5 failed "something broke"
[ "$(grep -c . "$BEAT_SINK")" = 1 ] && ok || bad "an unlisted event must beat: $(cat "$BEAT_SINK")"
grep -q '"kind":"fleet_alert"' "$BEAT_SINK" && ok || bad "the beat must be a fleet_alert: $(cat "$BEAT_SINK")"
# triaged:true is what keeps an emergency out of the 10-minute medic's quarantine
grep -q '"triaged":true' "$BEAT_SINK" && ok || bad "the beat must be pre-triaged, or it sits in quarantine: $(cat "$BEAT_SINK")"
grep -q '"akey":"hotfix:proj:AB-5:failed"' "$BEAT_SINK" && ok || bad "the akey is wrong: $(cat "$BEAT_SINK")"

# THE KILL FLAG. HOTFIX_LANE=0 / flags/hotfix-lane-off makes every predicate
# answer "not a hotfix" and the announcement a no-op, so a box can be put back
# to pre-#368 behaviour without editing a script.
: > "$T/logs/ALERTS.log"; : > "$BEAT_SINK"
HOTFIX_LANE=0 hotfix_announce "$T" proj AB-6 seen "quiet please"
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok || bad "HOTFIX_LANE=0 must silence the announcement"
[ ! -f "$T/state/hotfix-announced/proj/AB-6.seen" ] && ok || bad "HOTFIX_LANE=0 must not write a marker either"
HOTFIX_LANE=0 hotfix_labels_json_has '[{"name":"hotfix"}]' "$T" && bad "HOTFIX_LANE=0 must make the matcher answer no" || ok
HOTFIX_LANE=0 hotfix_job_is "$T/job-hot.json" "$T" && bad "HOTFIX_LANE=0 must make the job predicate answer no" || ok
HOTFIX_LANE=0 hotfix_meta_is "$T/meta-hot.json" "$T" && bad "HOTFIX_LANE=0 must make the meta predicate answer no" || ok
touch "$T/flags/hotfix-lane-off"
hotfix_labels_json_has '[{"name":"hotfix"}]' "$T" && bad "flags/hotfix-lane-off must make the matcher answer no" || ok
hotfix_announce "$T" proj AB-6 seen "quiet please"
[ ! -s "$BEAT_SINK" ] && ok || bad "flags/hotfix-lane-off must silence the announcement"
rm -f "$T/flags/hotfix-lane-off"
hotfix_labels_json_has '[{"name":"hotfix"}]' "$T" && ok || bad "removing the flag must turn the lane back on"

# NO NEW SINK (#368). The announcement rides the ALERTS.log + fleet_alert path
# that already reaches the console and Telegram; a new bin/alert-*.sh would be
# a second place to look when something is on fire. Guarded on the ref being
# there: CI's lint job checks out shallow, where this skips rather than fakes.
B=main; git -C "$DIR" rev-parse --verify -q main >/dev/null || B=origin/main
# BH-1261: this arm judges the hotfix libs' OWN slice. It runs on every branch
# CI builds, so on a branch that is not theirs — one adding a bin/alert-* sink
# for its own ticket — it must stay inert rather than go red on someone else's
# work. (2026-09-21: #1158 and #727 went red on the same ungated shape in
# tests/inapp-prompt-blocked-rule.bh-903-test.sh and file-children.bh-981.)
if git -C "$DIR" rev-parse --verify -q "$B" >/dev/null; then
  OWN=$(git -C "$DIR" diff --name-only "$B" 2>/dev/null; git -C "$DIR" diff --name-only 2>/dev/null)
  if ! grep -qE '^(bin/lib/hotfix-lib\.sh|bin/lib/triage-hotfix-lib\.sh)$' <<<"$(printf '%s\n' "$OWN")"; then  # own-slice: bin/lib/hotfix-lib.sh bin/lib/triage-hotfix-lib.sh
    echo "note: this branch is not hotfix-lib's slice — the no-new-sink arm judges only its own branch"
  else
  # BH-454: filtered to ADDED/RENAMED. A NEW sink is what #368 forbids; an
  # in-place edit of the two existing ones (the env-dir port) is not one.
  [ "$(git -C "$DIR" diff --name-only --diff-filter=AR "$B" -- bin/ | grep -c '^bin/alert-')" = 0 ] \
    && ok || bad "this slice must not add a new bin/alert-* sink"
  fi
fi
fi

echo "hotfix-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
