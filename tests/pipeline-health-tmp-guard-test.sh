#!/bin/bash
# tests/pipeline-health-tmp-guard-test.sh — the /tmp headroom guard (section 11
# of bin/pipeline-health.sh), extracted VERBATIM by its markers and driven
# against a scratch tree with a pinned clock.
#
# WHY IT EXISTS (BH-486.4 / #544). A full tmpfs kills every lane on the box at
# once and reads like a vendor outage: on 2026-08-20 alert-triage burned through
# grok, codex, OpenRouter AND Fireworks in one minute, all ENOSPC on their
# output files, and the health layer never noticed. The guard that exists now
# pages at 85%, names no consumer, does not know about the conductor's
# mc-rebase-* scratch, and its key never retracted — so the one line it wrote
# stayed in ALERTS.log after the tmpfs drained.
#
# WHAT IS UNDER TEST is the whole artifact chain, not the arithmetic: the REAL
# alert() (TTL dedupe + ALERTS.log + pipeline-health.log + beat) and the REAL
# retraction epilogue, extracted from the same script, so "retractable" means
# the RESOLVED line actually appears in the log and the dedupe key actually
# clears.
#
# FAIL-OPEN IS THE PROPERTY UNDER TEST, in both directions. A df that gives no
# reading must NOT page (a missing reading is not a full disk) and must not
# crash — and it must say so in pipeline-health.log rather than going quiet.
# Below the threshold nothing is deleted: the self-clean is a side effect of
# being over the line, never of running.
#
# The fixture /tmp is $T/tmp (HEALTH_TMP_ROOT). find and rm are REAL against it;
# only df, du, hostname and beat.sh are stubbed. Nothing here can reach the real
# /tmp.
#
# Run from anywhere: tests/pipeline-health-tmp-guard-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The scratch lib owns $T where the box has it; where it does not, this suite
# owns its own tree. Sourced before the first mktemp/trap (checks/tests-scratch-only).
# shellcheck source=/dev/null
[ -r "$(dirname "$0")/lib/scratch.sh" ] && . "$(dirname "$0")/lib/scratch.sh"
if [ -z "${T:-}" ]; then T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fi
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/stubs" "$T/tmp"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read; every fixture age is derived from it.
NOW=$(date +%s)

# ── the block under test, assembled from the real script ────────────────────
# Four extractions, each asserted non-empty: a marker that moves or a function
# that is renamed must fail here, not silently test an empty file.
grep '^RETRACT_NS=' "$DIR/bin/pipeline-health.sh"                              > "$T/p1.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/p0.sh"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$T/p2.sh"
awk '/^# >>> tmp headroom/{f=1;next} /^# <<< tmp headroom/{exit} f' \
  "$DIR/bin/pipeline-health.sh"                                               > "$T/p3.sh"
awk '/^# ── Retraction epilogue/{f=1} f{print} /^rm -f "\$FIRED"$/&&f{exit}' \
  "$DIR/bin/pipeline-health.sh"                                               > "$T/p4.sh"
[ -s "$T/p1.sh" ] && ok || bad "no RETRACT_NS= line in bin/pipeline-health.sh"
[ -s "$T/p2.sh" ] && ok || bad "could not extract alert() from bin/pipeline-health.sh"
[ -s "$T/p3.sh" ] && ok || bad "could not extract the tmp headroom block — # >>> tmp headroom markers missing?"
[ -s "$T/p4.sh" ] && ok || bad "could not extract the retraction epilogue"
cat "$T/p1.sh" "$T/p0.sh" "$T/p2.sh" "$T/p3.sh" "$T/p4.sh" > "$T/block.sh"
bash -n "$T/block.sh" && ok || bad "the extracted block is not valid bash"

# ── stubs: only the readings, never find/rm ─────────────────────────────────
cat > "$T/stubs/df" <<'SH'
#!/bin/bash
cat "$DF_OUT" 2>/dev/null
exit 0
SH
cat > "$T/stubs/du" <<'SH'
#!/bin/bash
cat "$DU_OUT" 2>/dev/null
exit 0
SH
printf '#!/bin/bash\necho hub\n' > "$T/stubs/hostname"
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$BEATS"
exit 0
SH
chmod +x "$T/stubs/df" "$T/stubs/du" "$T/stubs/hostname" "$T/bin/beat.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"

FIRED="$T/state/health-fired.test"
ACTIVE="$T/state/health-active.txt"
DEDUP="$T/state/health-alerted.json"
: > "$ACTIVE"

reset() { : > "$T/logs/ALERTS.log"; : > "$T/logs/pipeline-health.log"; : > "$T/beats.txt"
          : > "$T/err.txt"; echo '{}' > "$DEDUP"; : > "$ACTIVE"; : > "$FIRED"
          printf '1700000 /tmp/brfix-abc\n42 /tmp/wt-OLD1\n' > "$T/du.out"; }

# The fixture tmpfs: two dirs older than a day (one of each self-clean class),
# two born now. Age decides, never the name.
mkfix() { rm -rf "$T/tmp"; mkdir -p "$T/tmp/mc-rebase-OLD1" "$T/tmp/wt-OLD1" \
            "$T/tmp/mc-rebase-NEW1" "$T/tmp/brfix-abc"
          touch -d "@$(( NOW - 172800 ))" "$T/tmp/mc-rebase-OLD1" "$T/tmp/wt-OLD1"
          touch -d "@$NOW" "$T/tmp/mc-rebase-NEW1" "$T/tmp/brfix-abc"; }

drive() { # drive [VAR=val ...] — one cron tick of the real block + real epilogue
  : > "$FIRED"          # production truncates the fired set every run
  ( export HARNESS="$T" T="$T" NOW="$NOW" FIRED="$FIRED" ACTIVE="$ACTIVE" \
      PATH="$T/stubs:$PATH" HEALTH_TMP_ROOT="$T/tmp" \
      DF_OUT="$T/df.out" DU_OUT="$T/du.out" BEATS="$T/beats.txt" "$@"
    bash -c '
      set -uo pipefail
      H="$T"; DEDUP="$T/state/health-alerted.json"
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      . "$0"' "$T/block.sh" >/dev/null 2>"$T/err.txt" )
  echo $? > "$T/rc.txt"
}

# ============================================================================
# (d) FAIL-OPEN FIRST: df gives no reading. Not a full disk, not an alert, not
#     a crash — and not silence either: one line saying the reading is missing.
# ============================================================================
reset; mkfix
: > "$T/df.out"
drive
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "(d) a missing reading must not fail the tick: rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
[ ! -s "$T/err.txt" ] && ok || bad "(d) a missing reading must not write to stderr: $(cat "$T/err.txt")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(d) a missing reading must not page: $(cat "$T/logs/ALERTS.log")"
[ "$(grep -c 'no reading' "$T/logs/pipeline-health.log")" = 1 ] \
  && ok || bad "(d) exactly one line must say the reading is missing: $(cat "$T/logs/pipeline-health.log")"
[ -d "$T/tmp/mc-rebase-OLD1" ] && ok || bad "(d) nothing may be deleted on a missing reading"

# (d-bis) df printing only its header is the same missing reading (tr -dc leaves
#         an empty string, and [ "" -ge 80 ] would be a crash, not a check).
reset; mkfix
printf 'Use%%\n' > "$T/df.out"
drive
[ "$(cat "$T/rc.txt")" = 0 ] && [ ! -s "$T/err.txt" ] \
  && ok || bad "(d-bis) a header-only df must not crash: rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(d-bis) a header-only df must not page: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# (c) Below the threshold nothing is cleaned. The self-clean is what being over
#     the line costs you, not something every tick does.
# ============================================================================
reset; mkfix
echo ' 70%' > "$T/df.out"
drive
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(c) 70% must not page: $(cat "$T/logs/ALERTS.log")"
[ -d "$T/tmp/mc-rebase-OLD1" ] && ok || bad "(c) a day-old mc-rebase dir must survive a tick under the threshold"
[ -d "$T/tmp/wt-OLD1" ] && ok || bad "(c) a day-old worktree dir must survive a tick under the threshold"

# ============================================================================
# (a) 81%: one page naming the top consumer, the aged scratch swept, the key
#     recorded under this host and left in the active set for the epilogue.
# ============================================================================
reset; mkfix
echo ' 81%' > "$T/df.out"
drive
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "(a) the tick must exit 0: rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
[ "$(wc -l < "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(a) exactly one ALERTS line: $(cat "$T/logs/ALERTS.log")"
AL=$(cat "$T/logs/ALERTS.log")
grep -q '81%' <<<"$AL" && ok || bad "(a) the line must carry the reading: $AL"
grep -q '/tmp/brfix-abc' <<<"$AL" && ok || bad "(a) the line must name the top consumer: $AL"
grep -q '1700000' <<<"$AL" && ok || bad "(a) the line must carry the consumer's size: $AL"
grep -q 'wt-OLD1' <<<"$AL" && bad "(a) the line must name the BIGGEST consumer, not the last one: $AL" || ok
grep -q 'tmp' "$T/logs/pipeline-health.log" && ok || bad "(a) the finding must reach pipeline-health.log too: $(cat "$T/logs/pipeline-health.log")"
[ "$(jq -r 'has("tmpfull:hub")' "$DEDUP")" = true ] \
  && ok || bad "(a) the dedupe key must be tmpfull:<host>: $(cat "$DEDUP")"
grep -qxF 'tmpfull:hub' "$ACTIVE" \
  && ok || bad "(a) the key must be left in the active set so it can retract: $(cat "$ACTIVE")"
[ ! -d "$T/tmp/mc-rebase-OLD1" ] && ok || bad "(a) the day-old mc-rebase scratch must be swept"
[ ! -d "$T/tmp/wt-OLD1" ] && ok || bad "(a) the day-old worktree scratch must still be swept"
[ -d "$T/tmp/mc-rebase-NEW1" ] && ok || bad "(a) a fresh mc-rebase dir is a LIVE rebase — it must survive"
[ -d "$T/tmp/brfix-abc" ] && ok || bad "(a) the self-clean must only touch the known scratch classes"

# (a-ter) du telling us nothing (empty tmpfs, permission wall) still pages, with
#         an honest "unknown" instead of a blank where the consumer goes.
: > "$T/logs/ALERTS.log"; echo '{}' > "$DEDUP"
: > "$T/du.out"
drive
grep -q 'unknown' "$T/logs/ALERTS.log" \
  && ok || bad "(a-ter) an unreadable du must still page, naming the consumer as unknown: $(cat "$T/logs/ALERTS.log")"
printf '1700000 /tmp/brfix-abc\n42 /tmp/wt-OLD1\n' > "$T/du.out"

# (a-bis) THE NEGATIVE THAT MAKES RETRACTION MEAN SOMETHING: still full on the
#         next tick = no second page (TTL) and no RESOLVED. Retraction is
#         condition-driven, not tick-driven.
: > "$T/logs/ALERTS.log"
jq -n --argjson t "$NOW" '{"tmpfull:hub":$t}' > "$DEDUP"
printf 'tmpfull:hub\n' > "$ACTIVE"
drive
[ ! -s "$T/logs/ALERTS.log" ] \
  && ok || bad "(a-bis) a still-full tmpfs must not page again inside the TTL: $(cat "$T/logs/ALERTS.log")"
grep -q 'RESOLVED' "$T/logs/ALERTS.log" \
  && bad "(a-bis) nothing is resolved while the condition still holds: $(cat "$T/logs/ALERTS.log")" || ok
grep -qxF 'tmpfull:hub' "$ACTIVE" \
  && ok || bad "(a-bis) the key must stay active while the tmpfs is still full: $(cat "$ACTIVE")"

# ============================================================================
# (b) It drains: exactly one RESOLVED tmpfull:hub, the dedupe stamp cleared so a
#     recurrence pages immediately, and the retraction beat sent.
# ============================================================================
echo ' 70%' > "$T/df.out"
drive
[ "$(grep -c 'RESOLVED tmpfull:hub' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(b) exactly one RESOLVED line when the tmpfs drains: $(cat "$T/logs/ALERTS.log")"
grep -q 'RESOLVED tmpfull:hub' "$T/logs/pipeline-health.log" \
  && ok || bad "(b) the resolve must reach pipeline-health.log too: $(cat "$T/logs/pipeline-health.log")"
[ "$(jq -r 'has("tmpfull:hub")' "$DEDUP")" = false ] \
  && ok || bad "(b) the resolve must clear the dedupe stamp: $(cat "$DEDUP")"
grep -q '"resolved":true' "$T/beats.txt" \
  && ok || bad "(b) the retraction must be beaten to the console: $(cat "$T/beats.txt")"
# and once, not every tick after
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
drive
[ ! -s "$T/logs/ALERTS.log" ] \
  && ok || bad "(b) the resolve must fire once, not on every quiet tick: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# (e) The threshold is operator data, not a constant in the script.
# ============================================================================
reset; mkfix
echo ' 81%' > "$T/df.out"
drive TMP_FULL_PCT=90
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(e) TMP_FULL_PCT must be read, not the constant: $(cat "$T/logs/ALERTS.log")"
[ -d "$T/tmp/mc-rebase-OLD1" ] && ok || bad "(e) under the operator's threshold nothing is swept either"

reset; mkfix
echo ' 80%' > "$T/df.out"
drive TMP_FULL_PCT=80
grep -q 'tmpfull\|80%' "$T/logs/ALERTS.log" \
  && ok || bad "(e) the threshold is a floor, not a fence — 80 at 80% pages: $(cat "$T/logs/ALERTS.log")"

reset; mkfix
echo ' 79%' > "$T/df.out"
drive TMP_FULL_PCT=80
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(e) one point under the threshold is quiet: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# (f) THE PRODUCTION ENTRY POINT: the whole cron script, not the extract. Same
#     fixture tmpfs, HARNESS pointed at the scratch tree, every outbound tool
#     stubbed to fail closed. The guard must page from a real end-to-end run —
#     this is what catches a block that is fine in isolation and unreachable in
#     the file (guarded by an early exit, a stray fi, a name the script shadows).
# ============================================================================
reset; mkfix
echo ' 81%' > "$T/df.out"
for C in gh git curl ssh flock timeout; do
  printf '#!/bin/bash\nexit 1\n' > "$T/stubs/$C"; chmod +x "$T/stubs/$C"
done
: > "$T/fleet.conf"
( export HARNESS="$T" PATH="$T/stubs:$PATH" HEALTH_TMP_ROOT="$T/tmp" \
    DF_OUT="$T/df.out" DU_OUT="$T/du.out" BEATS="$T/beats.txt"
  bash "$DIR/bin/pipeline-health.sh" >/dev/null 2>"$T/err-full.txt" )
echo $? > "$T/rc.txt"
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "(f) the whole script must still exit 0: rc=$(cat "$T/rc.txt")"
grep -q 'tmpfull\|81%' "$T/logs/ALERTS.log" \
  && ok || bad "(f) the guard must page from a real run of bin/pipeline-health.sh: $(cat "$T/logs/ALERTS.log")"
[ ! -d "$T/tmp/mc-rebase-OLD1" ] \
  && ok || bad "(f) the self-clean must run in a real run of the script too"
[ -d "$T/tmp/brfix-abc" ] && ok || bad "(f) a real run must not sweep anything outside the scratch classes"
for C in gh git curl ssh flock timeout; do rm -f "$T/stubs/$C"; done

echo "pipeline-health-tmp-guard-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
