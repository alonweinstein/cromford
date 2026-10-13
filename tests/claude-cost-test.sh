#!/bin/bash
# tests/claude-cost-test.sh — bin/claude-cost.sh end to end, against a fake
# `claude` that writes a real-shaped session transcript.
#
# WHAT THIS WRAPPER IS FOR. bin/agent-call.sh is the instrumented lane, but it
# is a STAGE runner: it owns the model ladder, the failover, the budget flag,
# the no-tools contract. The callers that genuinely need raw claude — the
# orchestrator's turns, greenfield's pipeline, the per-box chat's `-c`
# continuation — could not use it, so they called the CLI and their spend was
# invisible. This is the thin path for exactly those callers.
#
# What is proved here:
#   1. TRANSPARENCY. Same stdout, same stderr, same exit code, same stdin as
#      `claude`. A wrapper that changes the answer is a wrapper nobody will
#      adopt, and adoption is the entire point.
#   2. A ROW LANDS, priced from the transcript, with row_source=transcript and
#      the session id it was priced from.
#   3. THE KILLED RUN STILL GETS A ROW. `timeout` signals the wrapper, not
#      claude, so the wrapper forwards the signal and still writes — this is
#      the case the old envelope-only path could never produce a number for
#      (16 of one day's 478 hub claude rows, 2,008 of 8,000 all-time).
#   4. THE TAGS. COST_STAGE / COST_PROJECT / COST_KEY / COST_JOB / COST_PR /
#      COST_RUN_ID land in their columns, and HARNESS_TICKET / JOB_ID are
#      picked up with no call-site change.
#   5. THE KILL SWITCHES turn off a NUMBER, never a row.
#   6. No --session-id is injected when the caller already passed one, or when
#      the call CONTINUES a conversation (the CLI owns the id there).
# Run from anywhere: tests/claude-cost-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/logs" "$T/h/locks" "$T/h/flags" "$T/h/bin/lib" "$T/fakebin" "$T/cfg/projects" "$T/work"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp "$DIR/bin/claude-cost.sh" "$DIR/bin/transcript-cost.sh" "$T/h/bin/"
cp "$DIR/bin/lib/cost-row.sh" "$T/h/bin/lib/"
chmod +x "$T/h/bin/"*.sh
# billing-mode.sh and auth-fingerprint.sh are resolved from $HARNESS/bin; stub
# them so this suite needs no credentials on the box running it.
printf '#!/bin/bash\necho subscription\n' > "$T/h/bin/billing-mode.sh"
printf 'auth_fp_for_runner() { echo fp-test; }\nauth_account_for_fp() { echo acct-test; }\n' \
  > "$T/h/bin/auth-fingerprint.sh"
chmod +x "$T/h/bin/billing-mode.sh"

cat > "$T/prices.json" <<'JSON'
{"per_token":{"test-model":{"prompt":0.00001,"completion":0.00002,"cache_read":0.000001,"cache_write":0.0000125}}}
JSON

# A fake `claude`: parses --session-id, writes a transcript for it under the
# config dir, echoes its argv marker, and exits with $FAKE_RC. FAKE_SLEEP makes
# it long enough to be killed.
cat > "$T/fakebin/claude" <<'FAKE'
#!/bin/bash
SID=""; prev=""
for a in "$@"; do
  [ "$prev" = "--session-id" ] && SID="$a"
  case "$a" in --session-id=*) SID="${a#--session-id=}" ;; esac
  prev="$a"
done
printf '%s\n' "ARGV:$*" >> "$FAKE_ARGV_LOG"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SLUG=$(pwd -P | tr '/' '-')
mkdir -p "$CFG/projects/$SLUG"
[ -n "$SID" ] || SID="cli-chosen-$$"
python3 - "$CFG/projects/$SLUG/$SID.jsonl" <<'PY'
import json, sys, datetime
open(sys.argv[1], "a").write(json.dumps({
  "type": "assistant", "uuid": "u1",
  "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
  "message": {"id": "msg_fake_1", "model": "test-model",
              "usage": {"input_tokens": 10, "output_tokens": 20,
                        "cache_read_input_tokens": 1000,
                        "cache_creation_input_tokens": 800,
                        "cache_creation": {"ephemeral_5m_input_tokens": 500,
                                           "ephemeral_1h_input_tokens": 300}}}}) + "\n")
PY
cat 2>/dev/null   # drain stdin so a piping caller does not see EPIPE
echo "FAKE-STDOUT"
echo "FAKE-STDERR" >&2
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/fakebin/claude"

FAKE_ARGV_LOG="$T/argv.log"; : > "$FAKE_ARGV_LOG"
# cc <args...> — run the wrapper with a clean cost.csv; stdout on fd 1.
cc() {
  rm -f "$T/h/logs/cost.csv"
  ( cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" \
      CLAUDE_CONFIG_DIR="$T/cfg" MODEL_PRICES="$T/prices.json" \
      FAKE_ARGV_LOG="$FAKE_ARGV_LOG" \
      "$T/h/bin/claude-cost.sh" "$@" )
}
row()  { tail -n +2 "$T/h/logs/cost.csv" 2>/dev/null | tail -1; }
col()  { printf '%s' "$(row)" | cut -d, -f"$1"; }
nrows() { local n; n=$(grep -c . "$T/h/logs/cost.csv" 2>/dev/null || echo 1); echo $((n - 1)); }

# ── 1. transparency ──────────────────────────────────────────────────────────
OUT=$(cc -p --model test-model "hello" 2>"$T/e"); RC=$?
[ "$OUT" = "FAKE-STDOUT" ] && ok || bad "stdout must be claude's, unchanged (got '$OUT')"
grep -q FAKE-STDERR "$T/e" && ok || bad "stderr must be claude's, unchanged"
[ "$RC" = 0 ] && ok || bad "exit code must be claude's (got $RC)"
FAKE_RC=7 cc -p --model test-model "hello" >/dev/null 2>&1; RC=$?
[ "$RC" = 7 ] && ok || bad "a nonzero exit must be passed through verbatim (got $RC)"
# stdin survives the backgrounding — bin/orchestrate.sh pipes its prompt in, and
# an async command in a non-interactive shell gets /dev/null unless redirected.
echo "PIPED-IN" | cc -p --model test-model >/dev/null 2>&1
grep -q 'PIPED-IN' "$T/h/logs/cost.csv" 2>/dev/null && bad "stdin must not leak into the row" || ok

# ── 2. the row, priced from the transcript ───────────────────────────────────
cc -p --model test-model "hello" >/dev/null 2>&1
[ "$(nrows)" = 1 ] && ok || bad "exactly one row per call (got $(nrows))"
[ "$(col 4)" = raw ]    && ok || bad "stage defaults to 'raw', got '$(col 4)'"
[ "$(col 5)" = claude ] && ok || bad "runner must be claude, got '$(col 5)'"
[ "$(col 6)" = test-model ] && ok || bad "the model must be the one that ran, got '$(col 6)'"
[ "$(col 9)"  = 10 ]   && ok || bad "input_toks from the transcript, got '$(col 9)'"
[ "$(col 10)" = 20 ]   && ok || bad "output_toks from the transcript, got '$(col 10)'"
[ "$(col 11)" = 1000 ] && ok || bad "cache_read from the transcript, got '$(col 11)'"
[ "$(col 12)" = 800 ]  && ok || bad "cache_write from the transcript, got '$(col 12)'"
[ "$(col 13)" = "0.013750" ] && ok || bad "cost_usd priced from the transcript, got '$(col 13)'"
[ "$(col 14)" = subscription ] && ok || bad "billing_mode must be resolved on the box, got '$(col 14)'"
[ "$(col 15)" = fp-test ] && ok || bad "auth_fp must be the live fingerprint, got '$(col 15)'"
[ "$(col 16)" = acct-test ] && ok || bad "auth_account must say which account paid, got '$(col 16)'"
[ -n "$(col 17)" ] && ok || bad "the row must carry the session id it was priced from"
[ "$(col 18)" = transcript ] && ok || bad "row_source must be 'transcript', got '$(col 18)'"
# The session id on the row is the one the wrapper minted and passed through.
grep -q -- "--session-id $(col 17)" "$FAKE_ARGV_LOG" \
  && ok || bad "the row's session id must be the --session-id the CLI was given"
# The header is the canonical 23 columns.
head -1 "$T/h/logs/cost.csv" | grep -q 'session_id,row_source,result_usd,ticket,job_id,pr,run_id' \
  && ok || bad "cost.csv must carry the canonical header"

# ── 3. THE KILLED RUN STILL GETS A ROW ───────────────────────────────────────
# `timeout` signals its direct child, which is now the wrapper rather than
# claude. Without the forwarding trap, two things break at once: the timeout
# stops cutting the call short (bash defers SIGTERM until a foreground child
# returns) and the row for the killed run — the row this whole wave exists to
# produce — is never written.
rm -f "$T/h/logs/cost.csv"
K0=$(date +%s)
( cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" \
    MODEL_PRICES="$T/prices.json" FAKE_ARGV_LOG="$FAKE_ARGV_LOG" FAKE_SLEEP=30 \
    timeout 3 "$T/h/bin/claude-cost.sh" -p --model test-model "hello" ) >/dev/null 2>&1
KRC=$?
K1=$(date +%s)
[ $((K1 - K0)) -lt 15 ] \
  && ok || bad "the timeout must actually cut the call short ($((K1-K0))s for a 3s timeout on a 30s call)"
[ "$(nrows)" = 1 ] && ok || bad "a KILLED run must still leave a row (got $(nrows)) — this is the whole point"
[ "$(col 18)" = transcript ] \
  && ok || bad "the killed run's row must be priced from its transcript, got row_source='$(col 18)'"
[ "$(col 13)" = "0.013750" ] \
  && ok || bad "the killed run's dollars must be real, got '$(col 13)'"
[ "$KRC" != 0 ] && ok || bad "a killed run must not report success (rc=$KRC)"

# ── 4. the tags ──────────────────────────────────────────────────────────────
rm -f "$T/h/logs/cost.csv"
( cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" \
    MODEL_PRICES="$T/prices.json" FAKE_ARGV_LOG="$FAKE_ARGV_LOG" \
    COST_STAGE=review COST_PROJECT=project-5 COST_KEY=TK-680 COST_JOB=job-9 \
    COST_PR=https://github.com/o/r/pull/12 COST_RUN_ID=build-42 \
    "$T/h/bin/claude-cost.sh" -p --model test-model "hello" ) >/dev/null 2>&1
[ "$(col 3)" = project-5 ] && ok || bad "COST_PROJECT must land in the project column, got '$(col 3)'"
[ "$(col 4)" = review ]    && ok || bad "COST_STAGE must land in the stage column, got '$(col 4)'"
[ "$(col 20)" = TK-680 ]   && ok || bad "COST_KEY must land in the ticket column, got '$(col 20)'"
[ "$(col 21)" = job-9 ]    && ok || bad "COST_JOB must land in the job_id column, got '$(col 21)'"
[ "$(col 22)" = "https://github.com/o/r/pull/12" ] \
  && ok || bad "COST_PR must land in the pr column, got '$(col 22)'"
[ "$(col 23)" = build-42 ] && ok || bad "COST_RUN_ID must land in the run_id column, got '$(col 23)'"

# The harness's OWN exports are picked up with no call-site change: a build lane
# already exports HARNESS_TICKET and JOB_ID.
rm -f "$T/h/logs/cost.csv"
( cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" \
    MODEL_PRICES="$T/prices.json" FAKE_ARGV_LOG="$FAKE_ARGV_LOG" \
    HARNESS_TICKET=TK-109 JOB_ID=job-77 \
    "$T/h/bin/claude-cost.sh" -p --model test-model "hello" ) >/dev/null 2>&1
[ "$(col 20)" = TK-109 ] && ok || bad "HARNESS_TICKET must be the ticket fallback, got '$(col 20)'"
[ "$(col 21)" = job-77 ] && ok || bad "JOB_ID must be the job fallback, got '$(col 21)'"

# A comma in a tag must not become a second column — every reader of this file
# splits on "," and a quoted field parses in some of them and not others.
rm -f "$T/h/logs/cost.csv"
( cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" \
    MODEL_PRICES="$T/prices.json" FAKE_ARGV_LOG="$FAKE_ARGV_LOG" \
    COST_KEY='a,b"c' "$T/h/bin/claude-cost.sh" -p --model test-model "hello" ) >/dev/null 2>&1
# TEST-CHANGE (BH-2303): the claude-cost row now writes the full canonical 25
# (an empty `note`, then `lane_id`) instead of stopping at run_id (23).
[ "$(printf '%s' "$(row)" | awk -F, '{print NF}')" = 25 ] \
  && ok || bad "a tag with a comma must not widen the row past 25 (got $(printf '%s' "$(row)" | awk -F, '{print NF}') fields)"

# ── 5. the kill switches turn off a NUMBER, never a row ─────────────────────
rm -f "$T/h/logs/cost.csv"
( cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" \
    MODEL_PRICES="$T/prices.json" FAKE_ARGV_LOG="$FAKE_ARGV_LOG" COST_TRANSCRIPT_ROWS=0 \
    "$T/h/bin/claude-cost.sh" -p --model test-model "hello" ) >/dev/null 2>&1
[ "$(nrows)" = 1 ] && ok || bad "COST_TRANSCRIPT_ROWS=0 must still write a row"
[ "$(col 18)" = none ] && ok || bad "with the switch off row_source must be 'none', got '$(col 18)'"
[ -z "$(col 13)" ] && ok || bad "with the switch off there is no priced number to report, got '$(col 13)'"
[ "$(col 7)" = 0 ] && ok || bad "the row must still carry the exit code"
: > "$FAKE_ARGV_LOG"
( cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" \
    COST_TRANSCRIPT_ROWS=0 "$T/h/bin/claude-cost.sh" -p --model test-model "x" ) >/dev/null 2>&1
grep -q -- '--session-id' "$FAKE_ARGV_LOG" \
  && bad "with the switch off no --session-id must be injected" || ok

touch "$T/h/flags/transcript-cost-off"
rm -f "$T/h/logs/cost.csv"
cc -p --model test-model "hello" >/dev/null 2>&1
[ "$(nrows)" = 1 ] && [ "$(col 18)" = none ] \
  && ok || bad "flags/transcript-cost-off must degrade to a row with row_source=none"
rm -f "$T/h/flags/transcript-cost-off"

# ── 6. --session-id is not injected over the caller's, nor onto a continuation ─
: > "$FAKE_ARGV_LOG"
cc -p --session-id caller-chosen-id --model test-model "hello" >/dev/null 2>&1
[ "$(grep -c -- '--session-id' "$FAKE_ARGV_LOG")" = 1 ] \
  && ok || bad "a caller's own --session-id must not be duplicated"
[ "$(col 17)" = caller-chosen-id ] \
  && ok || bad "the row must name the caller's session id, got '$(col 17)'"

: > "$FAKE_ARGV_LOG"
cc -p -c --model test-model "hello" >/dev/null 2>&1
grep -q -- '--session-id' "$FAKE_ARGV_LOG" \
  && bad "a continuation (-c) must not be given a --session-id: the CLI owns the id there" || ok
# ...and the row is still written, from the transcript the CLI chose.
[ "$(nrows)" = 1 ] && ok || bad "a continuation must still leave a row"
[ "$(col 18)" = transcript ] \
  && ok || bad "a continuation's row must be priced from the discovered transcript, got '$(col 18)'"

# ── 7. no library, no row — but the call still runs, and says so once ────────
rm -f "$T/h/logs/cost.csv" "$T/h/logs/ALERTS.log"
mv "$T/h/bin/lib/cost-row.sh" "$T/cost-row.sh.bak"
OUT=$(cd "$T/work" && HARNESS="$T/h" PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" \
      FAKE_ARGV_LOG="$FAKE_ARGV_LOG" "$T/h/bin/claude-cost.sh" -p "hello" 2>/dev/null)
[ "$OUT" = "FAKE-STDOUT" ] \
  && ok || bad "a missing row library must not stop the call (got '$OUT')"
grep -q 'UNBILLED' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "running unbilled must raise ONE alert naming what is missing"
mv "$T/cost-row.sh.bak" "$T/h/bin/lib/cost-row.sh"

echo "claude-cost: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
