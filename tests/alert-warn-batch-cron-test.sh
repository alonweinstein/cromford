#!/bin/bash
# tests/alert-warn-batch-cron-test.sh — the warn spool is drained on a CADENCE,
# not only when the next warn happens to arrive.
#
# WHY THIS EXISTS (2026-09-24). bin/lib/alert-state.sh spools every `warn` beat
# into state/alert-warn-batch.jsonl and `bin/alert-digest.sh --warn-batch` is
# the delivery half. Nothing scheduled that delivery half: the only cron line
# for the lane ran the DAILY triage digest (no argument), and the spool was
# flushed only inline, by alert_state_batch_warn, when a NEW warn arrived and
# the oldest spooled one was already ALERT_WARN_BATCH_MAX_AGE_S old. In a quiet
# stretch a warn could sit in the spool indefinitely: routed, logged, and never
# sent. A warn spools on whichever box RAISED it (review-prs, triage and the
# call-guard lines run on project boxes), so the flush runs on EVERY box, each
# draining only its own spool, and none of them behind the hub lease:
# cron/lanes/665-alert-warn-flush.cron, lane `alert-warn-flush`.
#
# WHAT IT ASSERTS:
#   W1  every box's render carries the */30 --warn-batch line exactly once and
#       UNGATED (no hub-lease prefix), and the hub keeps its daily 17:30 digest.
#   W2  the registry has the alert-warn-flush lane on every box at */30, and the
#       daily digest lane's cadence is its one daily schedule again.
#   W8  the batch id is warnbatch:<box>:<YYYYmmddHHMMSS>:<pid> and the body
#       names the box: every box's */30 fires in the same second, so without
#       the box two boxes' batches could share an akey and the console's
#       open-akey dedup would swallow the second one silently. Two batches in
#       one minute on one box also get two different akeys.
#   W9  flags/lane-off-alert-warn-flush stops the cron flush AND the inline
#       dead-man (both run --warn-batch): the spool is left intact, nothing is
#       sent, and clearing the flag delivers it.
#   W3  an absent spool and an empty spool are silent no-ops: no send.
#   W4  a spooled warn older than N is sent as ONE message by the cron flush,
#       and the spool is drained; a second flush sends nothing.
#   W5  the inline dead-man (a new warn with the oldest spooled older than N)
#       still flushes by itself: one send.
#   W6  the cron flush racing the inline flush over one aged spool: exactly
#       one send; the inline warn is either in it or still spooled.
#   W7  several drains at once: every warn is sent or still spooled exactly
#       once — never duplicated, never lost.
#
# No wall-clock read: spool epochs are fixed constants far in the past.
# Run from anywhere: bash tests/alert-warn-batch-cron-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── W1/W2. the schedule ─────────────────────────────────────────────────────
WANT='*/30 * * * * /root/harness/bin/alert-warn-flush.sh'
NBOX=0; W1BAD=0
while IFS= read -r b; do
  NBOX=$((NBOX+1))
  C=$(rendered_cron "$b")
  n=$(grep -v '^#' "$C" | grep -cE -- 'alert-warn-flush\.sh|alert-digest\.sh --warn-batch' || true)
  u=$(grep -v '^#' "$C" | grep -cF -- "$WANT" || true)
  g=$(grep -v '^#' "$C" | grep -cE -- 'hub-lease\.sh check && .*(alert-warn-flush\.sh|--warn-batch)' || true)
  [ "$n" = 1 ] && [ "$u" = 1 ] && [ "$g" = 0 ] \
    || { W1BAD=1; echo "  W1 $b: flush lines=$n ungated=$u gated=$g, want 1/1/0"; }
done < <(rendered_boxes)
[ "$NBOX" -ge 10 ] && ok || bad "W1 only $NBOX boxes rendered, want the whole fleet (10)"
[ "$W1BAD" = 0 ] && ok || bad "W1 not every box renders exactly one ungated */30 --warn-batch flush"
HUB=$(rendered_cron hub)
grep -qF -- '30 17 * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/alert-digest.sh' "$HUB" \
  && ok || bad "W1 the daily 17:30 digest line disappeared from the hub render"
REG=$(rendered_registry)
jq -e '.lanes[] | select(.id=="alert-warn-flush") | select(.cadence=="*/30 * * * *" and .scope=="box" and .script=="bin/alert-warn-flush.sh")' "$REG" >/dev/null 2>&1 \
  && ok || bad "W2 the registry has no box-scoped alert-warn-flush lane at */30"
MISSING=$(comm -23 <(rendered_boxes | sort) <(jq -r '.lanes[] | select(.id=="alert-warn-flush") | .boxes[]' "$REG" 2>/dev/null | sort))
[ -z "$MISSING" ] && ok || bad "W2 alert-warn-flush is not registered on: $MISSING"
CAD=$(jq -r '.lanes[] | select(.id=="alert-digest") | .cadence' "$REG" 2>/dev/null)
[ "$CAD" = '30 17 * * *' ] && ok || bad "W2 the alert-digest lane cadence is '$CAD', want its one daily schedule"

# ── the scratch harness: the real scripts, a fake wire ──────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub"
export HARNESS="$H"
export PATH="$T/stub:$PATH"
for s in beat.sh lane-alert.sh alert-digest.sh alert-warn-flush.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
ln -sf "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"
# Quarantine off puts beat.sh on its direct path: one send == one curl.
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"
printf 'testbox\n' > "$H/state/box-id"
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && { printf '%s\n' "\$a" >> "$T/sent.jsonl"; break; }
  prev="\$a"
done
echo '{"ok":true}'
STUB
chmod +x "$T/stub/curl"
SPOOL="$H/state/alert-warn-batch.jsonl"
sent()  { [ -f "$T/sent.jsonl" ] && grep -c . "$T/sent.jsonl" || echo 0; }
reset() { rm -f "$T/sent.jsonl" "$SPOOL" "$SPOOL.lock" "$SPOOL.tmp"; }
flush() { "$H/bin/alert-digest.sh" --warn-batch >/dev/null 2>&1; }
# A spool line exactly as alert_state_batch_warn writes it, at a fixed old epoch.
spool() { printf '%s\t%s\n' 1000 "$(jq -nc --arg id "$1" --arg l "$2" '{alertid:$id,line:$l}')" >> "$SPOOL"; }
inline_warn() { # the real writer, from a fresh shell, like beat.sh calls it
  ALERT_WARN_BATCH_MAX_AGE_S=60 bash -c '. "$HARNESS/bin/lib/alert-state.sh" && alert_state_batch_warn "$1"' _ \
    "$(jq -nc --arg id "$1" --arg l "$2" '{alertid:$id,line:$l}')" >/dev/null 2>&1
}

# ── W3. empty is silent ─────────────────────────────────────────────────────
reset
flush
[ "$(sent)" = 0 ] && ok || bad "W3 an absent spool sent a message (sent=$(sent))"
: > "$SPOOL"
flush
[ "$(sent)" = 0 ] && ok || bad "W3 an empty spool sent a message (sent=$(sent))"

# ── W4. the cron flush delivers an aged spool once ──────────────────────────
reset
spool w-a "quiet-period warn A"
spool w-b "quiet-period warn B"
spool w-a "quiet-period warn A"
"$H/bin/alert-warn-flush.sh" >/dev/null 2>&1   # the cron entry point itself
[ "$(sent)" = 1 ] && ok || bad "W4 an aged spool was not sent as one message (sent=$(sent))"
grep -q 'quiet-period warn A (x2)' "$T/sent.jsonl" 2>/dev/null && ok || bad "W4 the batch does not count the repeated warn"
grep -q 'quiet-period warn B' "$T/sent.jsonl" 2>/dev/null && ok || bad "W4 the batch dropped warn B"
[ ! -s "$SPOOL" ] && ok || bad "W4 the spool was not drained"
flush
[ "$(sent)" = 1 ] && ok || bad "W4 a second flush re-sent a drained spool (sent=$(sent))"

# ── W5. the inline dead-man still works on its own ──────────────────────────
reset
spool w-old "an old warn nobody flushed"
inline_warn w-new "a new warn"
[ "$(sent)" = 1 ] && ok || bad "W5 the inline dead-man did not flush an aged spool (sent=$(sent))"
grep -q 'an old warn nobody flushed' "$T/sent.jsonl" 2>/dev/null && ok || bad "W5 the inline flush lost the old warn"
[ ! -s "$SPOOL" ] && ok || bad "W5 the inline flush left the spool undrained"

# ── W6. the cron flush racing the inline flush: exactly one send ────────────
# Every round starts with an aged spool, so BOTH paths are entitled to flush it.
# Whatever the interleaving, the lock must make it one message: a drain that
# loses the race finds the spool already empty and sends nothing, and a warn
# the inline writer appends after the drain is fresh, so it stays spooled for
# the next tick — never sent twice and never gone.
W6BAD=0
for round in $(seq 1 12); do
  reset
  spool "w6-$round" "round $round spooled warn"
  flush & p1=$!
  inline_warn "w6i-$round" "round $round inline warn" & p2=$!
  wait "$p1" "$p2"
  S=$(sent)
  if [ "$S" != 1 ]; then W6BAD=1; echo "  W6 round $round: $S sends"; continue; fi
  grep -q "round $round spooled warn" "$T/sent.jsonl" || { W6BAD=1; echo "  W6 round $round: the spooled warn was not sent"; }
  inl_sent=$(grep -c "round $round inline warn" "$T/sent.jsonl" || true)
  inl_left=$(grep -c "round $round inline warn" "$SPOOL" 2>/dev/null || true)
  [ $(( inl_sent + inl_left )) = 1 ] || { W6BAD=1; echo "  W6 round $round: inline warn sent=$inl_sent spooled=$inl_left, want exactly one"; }
done
[ "$W6BAD" = 0 ] && ok || bad "W6 a cron flush racing the inline flush did not produce exactly one send"

# ── W7. many drains at once: every warn delivered exactly once ──────────────
# Stronger than cron ever does (one line, one tick), and it is the lock's real
# property: N drains over one spool may split it into batches, but no warn is
# in two of them and none is dropped between the read and the truncate.
W7BAD=0
for round in $(seq 1 8); do
  reset
  for i in 1 2 3 4 5; do spool "w7-$round-$i" "round $round warn $i"; done
  pids=""
  for j in 1 2 3; do flush & pids="$pids $!"; done
  inline_warn "w7i-$round" "round $round inline warn" & pids="$pids $!"
  # shellcheck disable=SC2086
  wait $pids
  for msg in "warn 1" "warn 2" "warn 3" "warn 4" "warn 5" "inline warn"; do
    n_sent=$(jq -r '.line' "$T/sent.jsonl" 2>/dev/null | grep -c "round $round $msg" || true)
    n_left=$(grep -c "round $round $msg" "$SPOOL" 2>/dev/null || true)
    [ $(( n_sent + n_left )) = 1 ] || { W7BAD=1; echo "  W7 round $round '$msg': sent=$n_sent spooled=$n_left, want exactly one"; }
  done
done
[ "$W7BAD" = 0 ] && ok || bad "W7 concurrent drains duplicated or lost a warn"

# ── W8. batch ids are unique per box and per batch ─────────────────────────
reset
spool w8-a "first batch warn"; flush
spool w8-b "second batch warn"; flush
AK=$(jq -r '.akey' "$T/sent.jsonl" 2>/dev/null)
[ "$(printf '%s\n' "$AK" | grep -c .)" = 2 ] && ok || bad "W8 want two batch sends, got: $AK"
BADK=$(printf '%s\n' "$AK" | grep -vE '^warnbatch:testbox:[0-9]{14}:[0-9]+$' || true)
[ -z "$BADK" ] && ok || bad "W8 a batch akey is not warnbatch:<box>:<YYYYmmddHHMMSS>:<pid>: $BADK"
[ "$(printf '%s\n' "$AK" | sort -u | grep -c .)" = 2 ] && ok || bad "W8 two batches shared one akey: $AK"
NOBOX=$(jq -r '.line' "$T/sent.jsonl" 2>/dev/null | grep -c '^Alerts (warn) on testbox' || true)
[ "$NOBOX" = 2 ] && ok || bad "W8 the batch message does not name the box ($NOBOX of 2 do)"
# Same second, same pid, two boxes: the akeys must still differ. The box part
# is the only thing that can make them differ, so prove it is read per box.
printf 'otherbox\n' > "$H/state/box-id"
reset; spool w8-c "other box warn"; flush
grep -q '"akey":"warnbatch:otherbox:' "$T/sent.jsonl" 2>/dev/null && ok || bad "W8 the akey does not follow state/box-id"
printf 'testbox\n' > "$H/state/box-id"

# ── W9. the lane switch leaves the spool intact ─────────────────────────────
# The real lane gate, the real registry. Off means off for BOTH drains: the
# cron flush and the inline dead-man each run --warn-batch, so while the flag
# is set the spool only grows (and trims at ALERT_WARN_BATCH_MAX). Nothing is
# sent and nothing is lost until it clears.
mkdir -p "$H/catalog"
ln -sf "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/lane-gate.sh"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
touch "$H/flags/lane-off-alert-warn-flush"
reset
spool w9-a "held warn A"
"$H/bin/alert-warn-flush.sh" >/dev/null 2>&1
flush
[ "$(sent)" = 0 ] && ok || bad "W9 the cron flush sent with lane-off-alert-warn-flush set (sent=$(sent))"
inline_warn w9-b "held warn B"
[ "$(sent)" = 0 ] && ok || bad "W9 the inline dead-man sent with lane-off-alert-warn-flush set (sent=$(sent))"
HELD=$(grep -c 'held warn' "$SPOOL" 2>/dev/null || true)
[ "$HELD" = 2 ] && ok || bad "W9 the spool was not left intact under the switch ($HELD of 2 lines)"
rm -f "$H/flags/lane-off-alert-warn-flush"
"$H/bin/alert-warn-flush.sh" >/dev/null 2>&1
[ "$(sent)" = 1 ] && grep -q 'held warn A' "$T/sent.jsonl" && grep -q 'held warn B' "$T/sent.jsonl" \
  && ok || bad "W9 clearing the switch did not deliver the held spool (sent=$(sent))"
rm -f "$H/bin/lib/lane-gate.sh"

echo "alert-warn-batch-cron: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
