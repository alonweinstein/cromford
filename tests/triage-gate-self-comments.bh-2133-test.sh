#!/bin/bash
# tests/triage-gate-self-comments.bh-2133-test.sh — A LANE'S OUTPUT IS NEVER ITS
# OWN INPUT, on the GitHub-Issues gate (BH-2133, 2026-09-24).
#
# THE LOOP THIS PINS. On a GitHub-Issues board the gate fingerprint carries each
# ai-build issue's comment COUNT and updatedAt. A triage shard's own note ("still
# blocked, nothing edited", posted as cromford-board[bot]) moved both, so
# the next tick read `RUN board-changed`, bought another shard for the same
# ticket, and that shard posted another note. #1389 carried six such notes in
# one afternoon; #2040 was re-triaged after the operator's HOLD; shards ran every 30-60 s
# on 2025, 2040, 2133, 1941, 1657 and 1174 until the board was paused.
#
# The fix keeps the stored count/updatedAt for a row when EVERY comment added
# since the stored row was written by a Bot (`user.type == "Bot"`, the same
# reading bin/lib/hold.sh uses for "the harness's own voice"). A human comment,
# a state or title change, an unreadable thread, or an updatedAt that moved past
# the bot comment all still wake the tick. Nothing here makes a model call.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-self-comments.bh-2133-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/state" "$T/flags" "$T/logs" "$T/env" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
# The harness-App allowlist (HARNESS_SELF_APPS) is a registry knob: compose the
# registry from this tree so the lib resolves it the way a box does.
REG="$T/lanes.json"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 \
  || bad "setup: bin/lanes-build.sh --to could not compose the registry"
export LANE_REGISTRY="$REG" LANE_GATE_NOW=""
unset HARNESS_SELF_APPS GATE_SELF_FAILOPEN_ALERT 2>/dev/null

cat > "$T/bin/fleet-conf.sh" <<'SH'
case "$1 ${2:-}" in "p board_prefix") echo "-" ;; "p repo") echo "o/r" ;; *) exit 1 ;; esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# The fake gh answers the three REST reads the gate makes: the ai-build issue
# list, the open PR list, and (new) one issue's comments. The per-issue comment
# route is matched FIRST — `repos/o/r/issues*` would otherwise swallow it.
cat > "$T/fakebin/gh" <<'SH'
printf '%s\n' "$*" >> "$GH_SINK"
[ "${1:-}" = api ] || exit 1
shift
P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
ST=200; BODY=""
case "$P" in
  repos/o/r/issues/*/comments*)
    n="${P#repos/o/r/issues/}"; n="${n%%/*}"
    if [ -f "$T/cfail" ]; then ST=500; BODY='{"message":"boom"}'
    elif [ -f "$T/comments-$n.json" ]; then BODY=$(cat "$T/comments-$n.json")
    else BODY='[]'; fi ;;
  repos/o/r/issues*) BODY=$(cat "$T/issues.json") ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 %s\r\n' "$ST"
printf '\r\n'
[ -n "$BODY" ] && printf '%s\n' "$BODY"
case "$ST" in 2*) exit 0 ;; *) exit 1 ;; esac
SH
chmod +x "$T/fakebin/gh"

# issues <count> <updatedAt> [state] [title] — the one ai-build issue, #7, with
# the fields a human edits without commenting (B1): IBODY, ILABELS (comma
# list), IASSIGNEE and IMILESTONE override the defaults.
issues() {
  jq -nc --argjson c "$1" --arg u "$2" --arg s "${3:-open}" --arg t "${4:-Add sort}" \
    --arg b "${IBODY:-Sort the name column.}" --arg l "${ILABELS:-ai-build}" \
    --arg a "${IASSIGNEE:-}" --arg m "${IMILESTONE:-}" \
    '[{number:7, state:$s, title:$t, comments:$c, updated_at:$u, body:$b,
       labels: ($l | split(",") | map({name: .})),
       assignees: (if $a == "" then [] else [{login: $a}] end),
       milestone: (if $m == "" then null else {number: 1, title: $m} end)}]' > "$T/issues.json"
}
# cm <id> <login> <type> <created_at> <body> [updated_at] — one REST issue comment.
cm() {
  jq -nc --argjson id "$1" --arg l "$2" --arg ty "$3" --arg at "$4" --arg b "$5" --arg up "${6:-$4}" \
    '{id:$id, user:{login:$l, type:$ty}, created_at:$at, updated_at:$up, body:$b,
      issue_url:"https://api.github.com/repos/o/r/issues/7"}'
}
# thread <comment-json>... — the full thread of #7 as GET .../comments answers it.
thread() { printf '%s\n' "$@" | jq -sc . > "$T/comments-7.json"; }

gate() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt"; : > "$T/gh.txt"; \
           "$DIR/bin/triage-gate.sh" p "$@" 2>"$T/err.txt" ); }
ncomments() { grep -c 'issues/7/comments' "$T/gh.txt" 2>/dev/null || true; }
# consume — what bin/lib/rt/gate.sh rt_gate_consume does after a paid tick.
consume() { [ -f "$T/state/p.gate.pending" ] && mv -f "$T/state/p.gate.pending" "$T/state/p.gate.json"; date +%s > "$T/state/p.gate-meta"; }

H1=$(cm 101 operator User 2026-09-24T10:00:00Z "please add a sort on the name column")
H2=$(cm 102 cromford-board\[bot\] Bot 2026-09-24T11:00:00Z "Picked this up, building now.")

# ── G0 — baseline: two comments, seeded ──────────────────────────────────────
issues 2 2026-09-24T11:00:00Z; thread "$H1" "$H2"
OUT=$(gate --seed); grep -q '^SEEDED' <<<"$OUT" && ok || bad "G0: seed '$OUT' err=$(cat "$T/err.txt")"
date +%s > "$T/state/p.gate-meta"
OUT=$(gate); grep -q '^SKIP no-change' <<<"$OUT" && ok || bad "G0: an unchanged board must SKIP: '$OUT'"

# ── G1 — THE LOOP: only a bot note was added. SKIP, not a paid tick. ─────────
B1=$(cm 103 cromford-board\[bot\] Bot 2026-09-24T12:00:00Z "Still on hold: this run hit PLAN_BLOCKED again, nothing edited.")
issues 3 2026-09-24T12:00:00Z; thread "$H1" "$H2" "$B1"
OUT=$(gate)
grep -q '^SKIP' <<<"$OUT" && ok || bad "G1: a bot-only comment bump bought a tick: '$OUT'"
! grep -q '^RUN' <<<"$OUT" && ok || bad "G1: RUN on the harness's own note: '$OUT'"
# the event-wake arm (bin/lib/rt/scope.sh) takes its scope from --pending +
# bin/gate-diff.sh: the key must not be in that diff either, or the webhook
# delivery of our own comment buys the shard the gate just refused.
gate --pending; rc=$?
[ "$rc" = 0 ] && ok || bad "G1: --pending rc $rc"
HARNESS="$T" "$DIR/bin/gate-diff.sh" p >/dev/null 2>&1; drc=$?
[ "$drc" = 2 ] && ok || bad "G1: gate-diff rc $drc (2 = verified unchanged): $(HARNESS="$T" "$DIR/bin/gate-diff.sh" p 2>&1)"
# the shard dedup key reads the PENDING row: it must equal the consumed one.
[ "$(jq -c '.issues[0]' "$T/state/p.gate.pending")" = "$(jq -c '.issues[0]' "$T/state/p.gate.json")" ] && ok \
  || bad "G1: pending row moved: $(jq -c '.issues[0]' "$T/state/p.gate.pending") vs $(jq -c '.issues[0]' "$T/state/p.gate.json")"
# G1b — the same bot-only world again costs no second thread read.
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && [ "$(ncomments)" = 0 ] && ok \
  || bad "G1b: repeat tick '$OUT', $(ncomments) comment reads (want 0: the absorbed row is remembered)"

# ── G2 — a NEW HUMAN comment always wakes the tick ───────────────────────────
C2=$(cm 104 operator User 2026-09-24T13:00:00Z "Looks good, also add it to the export")
issues 4 2026-09-24T13:00:00Z; thread "$H1" "$H2" "$B1" "$C2"
OUT=$(gate); grep -q '^RUN board-changed' <<<"$OUT" && ok || bad "G2: a human comment must RUN: '$OUT'"
consume

# ── G3 — HOLD by the principal, then the bot's "still on hold" note: SKIP ────
HOLD=$(cm 105 operator User 2026-09-24T14:00:00Z "HOLD")
issues 5 2026-09-24T14:00:00Z; thread "$H1" "$H2" "$B1" "$C2" "$HOLD"
OUT=$(gate); grep -q '^RUN board-changed' <<<"$OUT" && ok || bad "G3: the principal's HOLD is a human comment and wakes once: '$OUT'"
consume
N1=$(cm 106 cromford-board\[bot\] Bot 2026-09-24T14:05:00Z "Holding per your HOLD, nothing edited.")
issues 6 2026-09-24T14:05:00Z; thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1"
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G3: a bot note after HOLD bought a tick: '$OUT'"
N2=$(cm 107 cromford-board\[bot\] Bot 2026-09-24T14:40:00Z "Still on hold, nothing edited.")
issues 7 2026-09-24T14:40:00Z; thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1" "$N2"
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G3: a second bot note after HOLD bought a tick: '$OUT'"

# ── G4 — bot + human in the same window: RUN (never miss a human) ────────────
N3=$(cm 108 cromford-board\[bot\] Bot 2026-09-24T15:00:00Z "note")
H3=$(cm 109 operator User 2026-09-24T15:01:00Z "RESUME")
issues 9 2026-09-24T15:01:00Z; thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1" "$N2" "$N3" "$H3"
OUT=$(gate); grep -q '^RUN board-changed' <<<"$OUT" && ok || bad "G4: bot+human must RUN: '$OUT'"
consume

# ── G5 — the thread cannot be read: fail OPEN, never SKIP off a guess ────────
N4=$(cm 110 cromford-board\[bot\] Bot 2026-09-24T16:00:00Z "note")
issues 10 2026-09-24T16:00:00Z
touch "$T/cfail"
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G5: an unreadable thread must RUN: '$OUT'"
rm -f "$T/cfail"

# ── G6 — count moved but the new comments do not add up (a deletion): RUN ───
thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1" "$N2" "$N3" "$H3"   # N4 not in the thread
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G6: count delta with no matching comments must RUN: '$OUT'"

# ── G7 — a bot comment, but updatedAt moved well past it (a label/edit): RUN ─
thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1" "$N2" "$N3" "$H3" "$N4"
issues 10 2026-09-24T16:30:00Z
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G7: updatedAt past the bot comment must RUN: '$OUT'"

# ── G8 — a state or title change on a bot-only comment bump still wakes ──────
issues 10 2026-09-24T16:00:00Z closed
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G8: a close must RUN: '$OUT'"
issues 10 2026-09-24T16:00:00Z open "Add sort (renamed)"
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G8: a retitle must RUN: '$OUT'"

# ── G9 — control: with the same bot-only delta, the absorb is what SKIPs ─────
issues 10 2026-09-24T16:00:00Z
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G9: control bot-only delta: '$OUT'"
# ...and a `[bot]` login spelled as a User (older API shapes) counts as ours.
N5=$(cm 111 cromford-builders\[bot\] User 2026-09-24T16:10:00Z "note")
issues 11 2026-09-24T16:10:00Z
thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1" "$N2" "$N3" "$H3" "$N4" "$N5"
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G9: a [bot] login must count as ours: '$OUT'"
# ...and the PAT login posting as a User is NOT ours: it is also the operator's hand.
N6=$(cm 112 operator User 2026-09-24T16:20:00Z "ok")
issues 12 2026-09-24T16:20:00Z
thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1" "$N2" "$N3" "$H3" "$N4" "$N5" "$N6"
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G9: a operator User comment must RUN: '$OUT'"

# ── G10 — flags/gate-self-absorb-off puts back the old behaviour exactly ─────
consume
N7=$(cm 113 cromford-board\[bot\] Bot 2026-09-24T17:00:00Z "note")
issues 13 2026-09-24T17:00:00Z
thread "$H1" "$H2" "$B1" "$C2" "$HOLD" "$N1" "$N2" "$N3" "$H3" "$N4" "$N5" "$N6" "$N7"
touch "$T/flags/gate-self-absorb-off"
OUT=$(gate); grep -q '^RUN board-changed' <<<"$OUT" && [ "$(ncomments)" = 0 ] && ok \
  || bad "G10: kill switch: '$OUT', $(ncomments) comment reads"
rm -f "$T/flags/gate-self-absorb-off"
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G10: switch removed, bot-only delta: '$OUT'"

# ── G11 — the lib directly: anything it cannot reason about passes through ───
LIB="$DIR/bin/lib/gate-self-comments.sh"
[ -r "$LIB" ] && ok || bad "G11: $LIB is missing"
out=$( . "$LIB"; gh_rest() { return 75; }; gate_self_absorb "$T" p o/r 'not json' "$T/state/p.gate.json" )
[ "$out" = 'not json' ] && ok || bad "G11: a non-array input was not passed through: '$out'"
live='[{"number":7,"state":"OPEN","title":"Add sort","comments":99,"updatedAt":"2026-09-24T18:00:00Z"}]'
out=$( . "$LIB"; gh_rest() { return 75; }; gate_self_absorb "$T" q o/r "$live" "$T/state/p.gate.json" )
[ "$out" = "$live" ] && ok || bad "G11: a failed thread read must leave the live row: '$out'"

# ═══════════════════════════════════════════════════════════════════════════
# Review of #2208 (B1, I1, N1, I3, I2). Each case starts from a freshly seeded
# board: base = 1 human comment at 20:00.
# ═══════════════════════════════════════════════════════════════════════════
BASE_C=$(cm 201 operator User 2026-09-24T20:00:00Z "base")
fresh() { rm -f "$T/state/p.gate.json" "$T/state/p.gate.pending" "$T/state/p.gate-self.json"; thread "$BASE_C"; issues 1 2026-09-24T20:00:00Z; gate --seed >/dev/null; date +%s > "$T/state/p.gate-meta"; }
NOTE=$(cm 202 cromford-board\[bot\] Bot 2026-09-24T20:10:00Z "Still blocked, nothing edited.")

# G12 (B1) — a human EDIT between the consumed fetch and the bot note: T0 base,
# T1 the client edits the body / labels / assignees / milestone, T2 the note.
# Count +1, the one new comment is ours, updatedAt == the note: it used to be
# absorbed and the edit vanished. It must wake the tick.
for edit in body labels assignee milestone; do
  fresh
  thread "$BASE_C" "$NOTE"
  case "$edit" in
    body)      OUT=$(IBODY="Sort the name column, and the date column too." issues 2 2026-09-24T20:10:00Z; gate) ;;
    labels)    OUT=$(ILABELS="ai-build,bug" issues 2 2026-09-24T20:10:00Z; gate) ;;
    assignee)  OUT=$(IASSIGNEE="someone" issues 2 2026-09-24T20:10:00Z; gate) ;;
    milestone) OUT=$(IMILESTONE="v2" issues 2 2026-09-24T20:10:00Z; gate) ;;
  esac
  grep -q '^RUN' <<<"$OUT" && ok || bad "G12 B1 ($edit): an edit before our note was absorbed: '$OUT' pending=$(jq -c '.issues[0]' "$T/state/p.gate.pending" 2>/dev/null)"
done
# ...and the control: the same note with NO edit is still absorbed.
fresh; thread "$BASE_C" "$NOTE"; issues 2 2026-09-24T20:10:00Z
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G12 control: a bare note after the base was not absorbed: '$OUT'"

# G13 (I1) — a THIRD-PARTY bot (a relay carrying a client's words) is not us.
fresh
RELAY=$(cm 203 intercom\[bot\] Bot 2026-09-24T20:10:00Z "Client says: the sort is backwards")
thread "$BASE_C" "$RELAY"; issues 2 2026-09-24T20:10:00Z
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G13 I1: intercom[bot] was absorbed as ours: '$OUT'"
# performed_via_github_app with one of our slugs IS ours.
fresh
VIA=$(cm 204 some-bot Bot 2026-09-24T20:10:00Z "note" | jq -c '. + {performed_via_github_app: {slug: "cromford"}}')
thread "$BASE_C" "$VIA"; issues 2 2026-09-24T20:10:00Z
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G13: performed_via_github_app cromford was not ours: '$OUT'"
# HARNESS_SELF_APPS is the list: emptied, nothing is ours (a trust list, env only).
fresh; thread "$BASE_C" "$NOTE"; issues 2 2026-09-24T20:10:00Z
OUT=$(HARNESS_SELF_APPS=" " gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G13: an empty allowlist still absorbed: '$OUT'"

# G14 (N1) — a client EDITS an OLD comment (created before the base, updated
# after it), then our note lands within the slack: the edit must wake.
fresh
EDITED=$(cm 201 operator User 2026-09-24T20:00:00Z "base, and ALSO the export please" 2026-09-24T20:09:58Z)
thread "$EDITED" "$NOTE"; issues 2 2026-09-24T20:10:00Z
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G14 N1: an edited human comment was absorbed: '$OUT'"

# G15 — the FIRST tick after this ships: the consumed fingerprint predates the
# per-issue content hash (no `meta`). Nothing else moved, so it must not buy a
# session just for the shape change; the new shape is stored.
fresh
jq -c 'del(.meta)' "$T/state/p.gate.json" > "$T/g.tmp" && mv "$T/g.tmp" "$T/state/p.gate.json"
OUT=$(gate); grep -q '^SKIP' <<<"$OUT" && ok || bad "G15: the one-time shape change bought a tick: '$OUT'"
jq -e '.meta["7"] | type == "string"' "$T/state/p.gate.json" >/dev/null 2>&1 && ok || bad "G15: the upgraded fingerprint was not stored: $(cat "$T/state/p.gate.json")"
# ...and without a stored hash nothing is absorbed (unknown = wake).
jq -c 'del(.meta)' "$T/state/p.gate.json" > "$T/g.tmp" && mv "$T/g.tmp" "$T/state/p.gate.json"
thread "$BASE_C" "$NOTE"; issues 2 2026-09-24T20:10:00Z
OUT=$(gate); grep -q '^RUN' <<<"$OUT" && ok || bad "G15: absorbed with no stored content hash: '$OUT'"

# G16 (I3) — a fail-open streak is visible: one ALERTS line at the threshold.
fresh; thread "$BASE_C" "$NOTE"; issues 2 2026-09-24T20:10:00Z
: > "$T/logs/ALERTS.log"; touch "$T/cfail"
for i in 1 2; do OUT=$(GATE_SELF_FAILOPEN_ALERT=3 gate); done
[ "$(grep -c 'gate-self-comments' "$T/logs/ALERTS.log")" = 0 ] && ok || bad "G16: alerted before the threshold"
OUT=$(GATE_SELF_FAILOPEN_ALERT=3 gate)
grep -q '^RUN' <<<"$OUT" && [ "$(grep -c 'gate-self-comments' "$T/logs/ALERTS.log")" = 1 ] && ok \
  || bad "G16: 3rd fail-open: '$OUT', $(grep -c 'gate-self-comments' "$T/logs/ALERTS.log") alert lines"
OUT=$(GATE_SELF_FAILOPEN_ALERT=3 gate)
[ "$(grep -c 'gate-self-comments' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "G16: the streak alerted twice"
rm -f "$T/cfail"; OUT=$(GATE_SELF_FAILOPEN_ALERT=3 gate)
grep -q '^SKIP' <<<"$OUT" && [ "$(cat "$T/state/p.gate-self.failopen" 2>/dev/null || echo 0)" = 0 ] && ok \
  || bad "G16: a good read did not reset the streak: '$OUT' count=$(cat "$T/state/p.gate-self.failopen" 2>/dev/null)"

# G17 (I2) — a triage tick on a GitHub-Issues board that will post as the PAT
# (no App token) says so once a day: its notes cannot be told from the operator's.
( export HARNESS="$T" PROJECT=p STAMP=x LOG="$T/logs/p.log" ALERTS="$T/logs/ALERTS.log"
  . "$DIR/bin/lib/rt/gate.sh"
  : > "$ALERTS"
  GH_TOKEN=ghp_personal rt_gate_pat_note_alert; GH_TOKEN=ghp_personal rt_gate_pat_note_alert
  [ "$(grep -c 'PAT' "$ALERTS")" = 1 ] && echo ok1 || echo "bad1 $(cat "$ALERTS")"
  rm -f "$T"/flags/alerted-pat-note-*; : > "$ALERTS"
  GH_TOKEN=ghs_installation rt_gate_pat_note_alert; unset GH_TOKEN
  [ ! -s "$ALERTS" ] && echo ok2 || echo "bad2 $(cat "$ALERTS")"
) > "$T/g17.out" 2>&1
grep -q '^ok1' "$T/g17.out" && ok || bad "G17 I2: PAT tick not alerted exactly once: $(cat "$T/g17.out")"
grep -q '^ok2' "$T/g17.out" && ok || bad "G17 I2: an App-token tick alerted: $(cat "$T/g17.out")"

echo "triage-gate-self-comments: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
