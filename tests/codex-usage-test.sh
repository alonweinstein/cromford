#!/bin/bash
# tests/codex-usage-test.sh — bin/codex-usage.sh against synthetic ledgers.
#
# READ THIS BEFORE TRUSTING A GREEN RUN.
#
# Section 0 is the REAL shape, captured from a live hub session during the
# 2026-08-24 canary. It is no longer a guess: codex parks the counts at
# .payload.info.total_token_usage inside an event_msg line — a path nobody could
# have predicted, which is exactly why the parser recurses for the shape instead
# of assuming a location.
#
# The remaining sections are still only shape-coverage: they prove the parser
# handles those forms if codex ever emits them, and nothing stronger. What is
# NOT proven by any of this is that a full row prices end-to-end on a box — that
# needs the re-canary.
#
# The distinction matters because it is exactly the failure this ledger exists
# to fix: grok's usage object sat nested somewhere the code did not look, the
# lookup silently never matched, and the wallet metered ~$160/day while every
# row shipped blank. A fixture that matches my own assumption would reproduce
# that error with a green tick on top.
# Run from anywhere: tests/codex-usage-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CU="$DIR/bin/codex-usage.sh"
export HOME="$T"          # keep the real ~/.codex out of this entirely
mkdir -p "$T/.codex/sessions"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

got() { bash "$CU" 0 "$1" 2>/dev/null; }

# ---------- 0. THE REAL SHAPE (captured from a live hub session) ----------
# Verbatim from the canary: the counts live nested at
# .payload.info.total_token_usage inside an event_msg line. A path-based lookup
# would have missed it, which is the grok bug exactly.
cat > "$T/real.jsonl" <<'EOF'
{"timestamp":"2026-08-24T13:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":44450,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":18,"reasoning_output_tokens":0,"total_tokens":44468}}}}
EOF
[ "$(got "$T/real.jsonl")" = "44450 18 0 0" ] \
  && ok || bad "the REAL observed codex shape must parse (got: '$(got "$T/real.jsonl")')"

# The real cache key names, which the first version did not have. They were 0 on
# the canary run so pricing was unaffected — but a cache-heavy run would have
# under-captured, and understating is the direction that hides a burn.
cat > "$T/realcache.jsonl" <<'EOF'
{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"cache_write_input_tokens":120,"output_tokens":50}}}}
EOF
[ "$(got "$T/realcache.jsonl")" = "1000 50 800 120" ] \
  && ok || bad "cached_input_tokens / cache_write_input_tokens must be captured (got: '$(got "$T/realcache.jsonl")')"

# ---------- 1. the naming families these CLIs use in the wild ----------
printf '%s\n' '{"type":"usage","usage":{"input_tokens":1200,"output_tokens":340}}' > "$T/a.jsonl"
[ "$(got "$T/a.jsonl")" = "1200 340  " ] && ok || bad "OpenAI Responses shape (got: '$(got "$T/a.jsonl")')"

printf '%s\n' '{"usage":{"prompt_tokens":50,"completion_tokens":7}}' > "$T/b.jsonl"
[ "$(got "$T/b.jsonl")" = "50 7  " ] && ok || bad "Chat Completions shape (got: '$(got "$T/b.jsonl")')"

printf '%s\n' '{"usage":{"inputTokens":9,"outputTokens":3}}' > "$T/c.jsonl"
[ "$(got "$T/c.jsonl")" = "9 3  " ] && ok || bad "camelCase shape (got: '$(got "$T/c.jsonl")')"

# ---------- 2. NESTED, which is the whole point ----------
# grok's usage rode inside params.update and a path-based lookup never matched.
# Depth must not matter.
printf '%s\n' '{"jsonrpc":"2.0","params":{"update":{"meta":{"usage":{"input_tokens":77,"output_tokens":11}}}}}' > "$T/d.jsonl"
[ "$(got "$T/d.jsonl")" = "77 11  " ] && ok || bad "deeply nested usage must be found (got: '$(got "$T/d.jsonl")')"

# ...including inside a list.
printf '%s\n' '{"events":[{"noise":1},{"usage":{"input_tokens":5,"output_tokens":2}}]}' > "$T/e.jsonl"
[ "$(got "$T/e.jsonl")" = "5 2  " ] && ok || bad "usage inside a list must be found (got: '$(got "$T/e.jsonl")')"

# ---------- 3. cache fields when present, blank when not ----------
printf '%s\n' '{"usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":8,"cache_creation_input_tokens":4}}' > "$T/f.jsonl"
[ "$(got "$T/f.jsonl")" = "10 2 8 4" ] && ok || bad "cache fields (got: '$(got "$T/f.jsonl")')"
printf '%s\n' '{"usage":{"input_tokens":10,"output_tokens":2,"cached_tokens":6}}' > "$T/g.jsonl"
[ "$(got "$T/g.jsonl")" = "10 2 6 " ] && ok || bad "cached_tokens alias (got: '$(got "$T/g.jsonl")')"

# ---------- 4. cumulative vs per-turn ----------
# Codex emits usage per turn AND cumulatively; which lands last is unverified.
# The max is the cumulative figure under either ordering, and understating
# spend is the failure mode that started this whole wave.
cat > "$T/h.jsonl" <<'EOF'
{"usage":{"input_tokens":100,"output_tokens":10}}
{"usage":{"input_tokens":250,"output_tokens":30}}
{"usage":{"input_tokens":180,"output_tokens":20}}
EOF
[ "$(got "$T/h.jsonl")" = "250 30  " ] && ok || bad "must take the largest, not the last (got: '$(got "$T/h.jsonl")')"

# ---------- 5. fail-soft: every miss is blank, never a crash, never a zero ----
# A zero would read as "this call was free", which is precisely the lie the
# blank fields already tell — but harder to spot, because it looks measured.
for BAD in '{"no":"usage"}' 'not json at all' '' '{"usage":{"input_tokens":"abc","output_tokens":null}}'; do
  printf '%s\n' "$BAD" > "$T/bad.jsonl"
  OUT=$(got "$T/bad.jsonl"); RC=$?
  [ "$RC" = 0 ] || bad "must never fail the caller (rc=$RC on: $BAD)"
  [ -z "$(tr -d ' ' <<<"$OUT")" ] || bad "a miss must be blank, not a number (got '$OUT' on: $BAD)"
done
ok
# A missing file, and no arguments at all.
[ -z "$(tr -d ' ' <<<"$(got "$T/nonexistent.jsonl")")" ] && ok || bad "missing file must be blank"
[ -z "$(tr -d ' ' <<<"$(bash "$CU" 0 2>/dev/null)")" ] && ok || bad "no events file must be blank"

# ---------- 6. it reads the session ledger when the events file has nothing ---
printf '%s\n' '{"nothing":"here"}' > "$T/empty-events.jsonl"
printf '%s\n' '{"usage":{"input_tokens":42,"output_tokens":9}}' > "$T/.codex/sessions/s.jsonl"
[ "$(got "$T/empty-events.jsonl")" = "42 9  " ] \
  && ok || bad "must fall back to the codex session ledger (got: '$(got "$T/empty-events.jsonl")')"

# ---------- 6b. an OLD session must NOT be attributed to this call ----------
# This is a correctness guard, not an optimisation: a session from a previous
# run belongs to a different call, and borrowing its tokens would INVENT spend.
# Blank is the honest answer; a wrong number is worse than no number.
rm -f "$T/.codex/sessions"/*.jsonl
printf '%s\n' '{"usage":{"input_tokens":999999,"output_tokens":999999}}' > "$T/.codex/sessions/old.jsonl"
touch -t 202001010000 "$T/.codex/sessions/old.jsonl"
NOWEP=$(date +%s)
OUT=$(bash "$CU" "$NOWEP" "$T/empty-events.jsonl" 2>/dev/null)
[ -z "$(tr -d ' ' <<<"$OUT")" ] \
  && ok || bad "a session older than the call must be ignored, not attributed (got: '$OUT')"
# ...and a session touched DURING the call is still picked up.
printf '%s\n' '{"usage":{"input_tokens":31,"output_tokens":4}}' > "$T/.codex/sessions/new.jsonl"
OUT=$(bash "$CU" "$NOWEP" "$T/empty-events.jsonl" 2>/dev/null)
[ "$OUT" = "31 4  " ] \
  && ok || bad "a session from this call must still be read (got: '$OUT')"
rm -f "$T/.codex/sessions"/*.jsonl
printf '%s\n' '{"usage":{"input_tokens":42,"output_tokens":9}}' > "$T/.codex/sessions/s.jsonl"

# ---------- 6c. BUG 2: discovery across a REAL session tree ----------
# The hub has 645 session files under dated subdirs. The first version ran
# `find … | head -50`, which returns DIRECTORY order, so the session we wanted
# fell outside the window and the lookup returned blank while appearing to have
# searched. Recreate that shape: many files, in nested dated dirs, with the
# target NOT first alphabetically.
rm -rf "$T/.codex/sessions"; mkdir -p "$T/.codex/sessions/2026/08/23" "$T/.codex/sessions/2026/08/24"
for i in $(seq 1 80); do
  printf '%s\n' '{"noise":true}' > "$T/.codex/sessions/2026/08/23/rollout-a$i.jsonl"
done
printf '%s\n' '{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":31337,"output_tokens":42}}}}' \
  > "$T/.codex/sessions/2026/08/24/rollout-zzz-target.jsonl"
OUT=$(bash "$CU" 0 2>/dev/null)
[ "$OUT" = "31337 42  " ] \
  && ok || bad "must find the target among 80+ files in dated subdirs (got: '$OUT')"

# ...and the mtime guard still holds across that tree: a target older than the
# call must not be borrowed.
touch -t 202001010000 "$T/.codex/sessions/2026/08/24/rollout-zzz-target.jsonl"
OUT=$(bash "$CU" "$(date +%s)" 2>/dev/null)
[ -z "$(tr -d ' ' <<<"$OUT")" ] \
  && ok || bad "an old session must still be excluded when walking the tree (got: '$OUT')"
rm -rf "$T/.codex/sessions"; mkdir -p "$T/.codex/sessions"

# ---------- 6e. THE SORT IS LOAD-BEARING: newest session, not first found ----
# 6c above proved discovery REACHES a target in a big tree, but its 80 decoys
# carried no tokens — so the walk fell through them either way and the
# `sessions.sort(reverse=True)` line could be deleted with the suite still green.
# That is the same untested-load-bearing-line shape as the `find | head -50` bug
# this section exists to fix.
#
# The case that needs the sort is decoys that DO carry tokens: the reader stops
# at the first file with usage in it, so whichever file is examined first wins
# outright. Files at the sessions ROOT are walked before any subdirectory
# (os.walk yields the top directory first), so the stale rows are reached first
# by construction — no reliance on filesystem ordering luck.
rm -rf "$T/.codex/sessions"; mkdir -p "$T/.codex/sessions/2026/08/24"
for i in $(seq 1 60); do
  printf '%s\n' '{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":111,"output_tokens":9}}}}' \
    > "$T/.codex/sessions/stale-$i.jsonl"
  touch -t 202001010100 "$T/.codex/sessions/stale-$i.jsonl"
done
printf '%s\n' '{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":55555,"output_tokens":77}}}}' \
  > "$T/.codex/sessions/2026/08/24/rollout-target.jsonl"
OUT=$(bash "$CU" 0 2>/dev/null)
[ "$OUT" = "55555 77  " ] \
  && ok || bad "must attribute the NEWEST session, not the first one walked (got: '$OUT')"
# Both directions: the stale figure must not be what comes back. Asserting the
# absence separately means a future change that returns blank cannot pass this
# by accident.
[ "${OUT%% *}" != "111" ] \
  && ok || bad "a stale session's tokens were billed to this call (got: '$OUT')"
rm -rf "$T/.codex/sessions"; mkdir -p "$T/.codex/sessions"

# ---------- 6d. BUG 1: a PLAIN-TEXT events file must not derail discovery ----
# $OUT.events is the agent's final message, not JSON. The lanes no longer pass
# it, but a caller that does must still fall through to the session ledger
# rather than returning blank.
printf 'I have finished the task.\nNo JSON here at all.\n' > "$T/plain.txt"
printf '%s\n' '{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":7,"output_tokens":2}}}}' \
  > "$T/.codex/sessions/s.jsonl"
[ "$(got "$T/plain.txt")" = "7 2  " ] \
  && ok || bad "a plain-text events file must fall through to the session (got: '$(got "$T/plain.txt")')"

# ---------- 7. the output is consumable by `read -r IN OUTT CR CW` ----------
# That is how agent-call consumes it; four fields, always, blanks included.
read -r I O CRD CWR < <(got "$T/f.jsonl")
[ "$I" = 10 ] && [ "$O" = 2 ] && [ "$CRD" = 8 ] && [ "$CWR" = 4 ] \
  && ok || bad "read -r must bind four fields (got '$I' '$O' '$CRD' '$CWR')"
read -r I O CRD CWR < <(got "$T/a.jsonl")
[ "$I" = 1200 ] && [ "$O" = 340 ] && [ -z "$CRD" ] && [ -z "$CWR" ] \
  && ok || bad "absent cache fields must bind empty, not shift the columns"

# ---------- 7b. ONE-SIDED cache emit: the column must not slide --------------
# A provider that reports cache_write but not cache_read prints an EMPTY middle
# column: "1234 56  4096". Splitting that on spaces slides cache_write into the
# cache_read variable, so it prices at the read rate — wrong data, no error.
#
# WORTH KNOWING, because the obvious fix is a no-op: `IFS=' ' read` behaves
# EXACTLY like the default, since space is IFS *whitespace* and bash collapses
# runs of IFS whitespace into a single delimiter no matter how IFS is set. Only
# a NON-whitespace delimiter preserves an empty field, hence the `${line// /|}`
# substitution at the call sites. Both facts are asserted below rather than
# asserted in a comment, because this one is easy to get wrong twice.
printf '%s\n' '{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":1234,"output_tokens":56,"cache_write_input_tokens":4096}}}}' \
  > "$T/onesided.jsonl"
ONE=$(got "$T/onesided.jsonl")
[ "$ONE" = "1234 56  4096" ] \
  && ok || bad "a one-sided cache emit must keep the empty column (got: '$ONE')"

# The shipped parse: substitute to a non-whitespace delimiter, then split.
IFS='|' read -r I O CRD CWR <<<"${ONE// /|}"
[ "$I" = 1234 ] && [ "$O" = 56 ] && [ -z "$CRD" ] && [ "$CWR" = 4096 ] \
  && ok || bad "the '|' split must bind cache_write to CW, not CR (got CR='$CRD' CW='$CWR')"

# Both no-op alternatives must be shown to FAIL, or the fix above looks
# arbitrary and the next person "simplifies" it back into the bug.
read -r _I _O DCRD _DCWR <<<"$ONE"
[ "$DCRD" = 4096 ] && ok || bad "default IFS was expected to mis-bind — re-check why the fix is needed"
IFS=' ' read -r _I _O SCRD _SCWR <<<"$ONE"
[ "$SCRD" = 4096 ] \
  && ok || bad "IFS=' ' was expected to mis-bind too (it is IFS whitespace) — re-check the fix"

# ...and a fully-populated line must still bind identically, so the fix is a
# strict improvement rather than a behaviour change for the normal case.
FULL="10 2 8 4"
IFS='|' read -r I O CRD CWR <<<"${FULL// /|}"
[ "$I" = 10 ] && [ "$O" = 2 ] && [ "$CRD" = 8 ] && [ "$CWR" = 4 ] \
  && ok || bad "a fully-populated line must bind unchanged (got '$I' '$O' '$CRD' '$CWR')"

# The call sites must actually parse this way. The assertions above test a local
# emulation of the consumer; this ties them to the shipped code. STRUCTURAL
# (grep) — it proves the lines are written that way, not that bash honours
# them, which the assertions above cover.
AC="$DIR/bin/agent-call.sh"
# EVERY capture site, not a fixed count. The count version broke the moment a
# fourth lane was instrumented — a test that fails because the codebase grew a
# correct new call site teaches people to edit the number, which is how the
# assertion stops meaning anything. The property is "no capture site splits on
# whitespace", and that holds at any number of lanes.
CAP_SITES=$(grep -cE 'read -r IN OUTT CR CW( USD)? <<<' "$AC")
[ "${CAP_SITES:-0}" -ge 3 ] \
  && ok || bad "expected at least the 3 original usage-capture sites, found $CAP_SITES"
BAD_SITES=$(grep -nE 'read -r IN OUTT CR CW( USD)? <<<' "$AC" | grep -cv "IFS='|'" || true)
[ "${BAD_SITES:-0}" -eq 0 ] \
  && ok || bad "$BAD_SITES usage-capture site(s) do not split on '|' — an absent cache field will slide a column"
# No site may still split the capture line on spaces. Anchored to the capture
# reads specifically so an unrelated `read` elsewhere cannot trip it.
grep -qv "IFS='|'" <(grep -nE "read -r IN OUTT CR CW( USD)? < " "$AC") \
  && bad "a usage-capture site still splits on whitespace" || ok

echo "codex-usage-test: $PASS pass, $FAIL fail"
echo "NOTE: section 0 is the REAL observed codex shape (canary 2026-08-24). The rest is shape-coverage."
echo "      Still UNPROVEN end-to-end: that a full row prices on a box. That needs the re-canary."
[ "$FAIL" -eq 0 ]
