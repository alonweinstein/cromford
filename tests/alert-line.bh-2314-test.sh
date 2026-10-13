#!/bin/bash
# tests/alert-line.bh-2314-test.sh — bin/alert-line.sh, the synchronous alert
# writer, and the poll-commands re-beat skip that makes one emission one note.
#
# Driven, not grepped (D2/D3): every case runs the real bin/alert-line.sh from
# the checkout inside a scratch $HARNESS, against a stub bin/beat.sh that
# records its payload, BEAT_STRICT and whether ALERTS.log already held the line
# when it was called. The re-beat cases extract the `# >>> alerts re-beat`
# block from bin/poll-commands.sh by its markers and source it, the way
# tests/alerts-table-test.sh c8 does, so they test the code that ships. R3 runs
# the REAL bin/beat.sh with flags/alerts-db and a fake curl and counts the
# /api/alerts/note requests one emission produces.
#
#   L1 stamp + text verbatim, no prefix     L5 no beat.sh / no jq: appended, rc 0
#   L2 payload: strict, kind, line, akey    L6 beat runs BEFORE the append
#   L3 stub rc 0 -> marker                  L7 marker GC via ALERT_LINE_MARKER_TTL_S
#   L4 stub rc 1 -> no marker, appended     R1-R3 the re-beat skip
#
# Run from anywhere: tests/alert-line.bh-2314-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
countof() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
sha() { printf %s "$1" | sha1sum | cut -c1-40; }

export FLEET_CONF="$T/fleet.conf" ALERTS_CONF="$T/alerts.conf"
printf 'project-3 example-org/project-3 https://o.invalid /api/board 3 bx1\n' > "$FLEET_CONF"
: > "$ALERTS_CONF"

# mktree <dir> — a scratch harness with the helper and what it calls. The
# helper is the checkout's own file (a symlink), so the suite is red until
# bin/alert-line.sh exists.
mktree() {
  local d="$1" s
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags"
  for s in alert-line.sh alert_family.py project-of.sh fleet-conf.sh box-for.sh; do
    ln -sf "$DIR/bin/$s" "$d/bin/$s"
  done
  ln -sf "$DIR/bin/lib/alert-state.sh" "$d/bin/lib/alert-state.sh"
  ln -sf "$DIR/bin/lib/conf-row.sh" "$d/bin/lib/conf-row.sh"
  cat > "$d/bin/beat.sh" <<'EOF'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$1" >> "$H/beats.jsonl"
printf '%s\n' "${BEAT_STRICT:-unset}" >> "$H/beat-env"
L=$(jq -r '.line' <<<"$1")
if grep -qxF -- "$L" "$H/logs/ALERTS.log" 2>/dev/null; then echo present; else echo absent; fi >> "$H/beat-order"
exit "${STUB_RC:-0}"
EOF
  chmod +x "$d/bin/beat.sh"
}
emit() { # emit <dir> <args...> — run the helper as a caller would; prints its rc
  local d="$1"; shift
  ( export HARNESS="$d"; "$d/bin/alert-line.sh" "$@" >/dev/null 2>&1 ); echo $?
}

[ -x "$DIR/bin/alert-line.sh" ] && ok || bad "bin/alert-line.sh is missing or not executable"
awk '/^# >>> alerts re-beat/{f=1;next} /^# <<< alerts re-beat/{exit} f{print}' \
  "$DIR/bin/poll-commands.sh" > "$T/rebeat.body"
[ -s "$T/rebeat.body" ] && ok || bad "could not extract the '# >>> alerts re-beat' block from bin/poll-commands.sh"
cat > "$T/rec.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$REC"
EOF
chmod +x "$T/rec.sh"
rebeat() { # rebeat <dir> <rec-file> — one pass of the shipped re-beat block
  : > "$2"
  ( export HARNESS="$1" BEAT="$T/rec.sh" REC="$2"
    # shellcheck source=/dev/null
    . "$T/rebeat.body" ) >/dev/null 2>&1
}

echo "--- L1: the line is <stamp> <text>, byte for byte, no prefix"
mktree "$T/l1"
L1="2026-09-26 10:00:00Z project-3 build stuck [x]"
RC=$(ALERT_LINE_STAMP='2026-09-26 10:00:00Z' emit "$T/l1" 'project-3 build stuck [x]')
[ "$RC" = 0 ] && ok || bad "L1: helper exited $RC"
[ "$(tail -1 "$T/l1/logs/ALERTS.log" 2>/dev/null)" = "$L1" ] \
  && ok || bad "L1: last ALERTS.log line is '$(tail -1 "$T/l1/logs/ALERTS.log" 2>/dev/null)', want '$L1'"
[ "$(countof . "$T/l1/logs/ALERTS.log")" = 1 ] && ok || bad "L1: want exactly one ALERTS.log line"
# the default stamp is the fleet's `date -u '+%F %TZ'` shape
mktree "$T/l1b"; emit "$T/l1b" 'plain text' >/dev/null
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z plain text$' "$T/l1b/logs/ALERTS.log" \
  && ok || bad "L1: default stamp shape wrong: $(cat "$T/l1b/logs/ALERTS.log" 2>/dev/null)"
# no text = no line, still rc 0
mktree "$T/l1c"; RC=$(emit "$T/l1c")
[ "$RC" = 0 ] && [ ! -s "$T/l1c/logs/ALERTS.log" ] && ok || bad "L1: no text should write nothing and exit 0 (rc=$RC)"
# multi-line text is one line (A2)
mktree "$T/l1d"; ALERT_LINE_STAMP='2026-09-26 10:00:00Z' emit "$T/l1d" "$(printf 'a\nb')" >/dev/null
[ "$(cat "$T/l1d/logs/ALERTS.log" 2>/dev/null)" = "2026-09-26 10:00:00Z a b" ] \
  && ok || bad "L1: embedded newline not collapsed: $(cat "$T/l1d/logs/ALERTS.log" 2>/dev/null)"

echo "--- L2: the beat is strict, kind alert, the verbatim line, the re-beat's akey"
P1=$(head -1 "$T/l1/beats.jsonl" 2>/dev/null)
[ "$(head -1 "$T/l1/beat-env" 2>/dev/null)" = 1 ] && ok || bad "L2: beat.sh did not get BEAT_STRICT=1 ($(cat "$T/l1/beat-env" 2>/dev/null))"
[ "$(jq -r .kind <<<"$P1" 2>/dev/null)" = alert ] && ok || bad "L2: kind is not alert: $P1"
[ "$(jq -r .line <<<"$P1" 2>/dev/null)" = "$L1" ] && ok || bad "L2: line is not the stamped line: $P1"
[ "$(jq -r .project <<<"$P1" 2>/dev/null)" = project-3 ] && ok || bad "L2: project not read from the line: $P1"
[ "$(jq -r 'has("severity") or has("alertid")' <<<"$P1" 2>/dev/null)" = false ] \
  && ok || bad "L2: severity/alertid sent without the flags: $P1"
# the akey the shipped re-beat block mints for the same line
mktree "$T/l2"; printf '%s\n' "$L1" > "$T/l2/logs/ALERTS.log"
rebeat "$T/l2" "$T/l2.rec"
WANT=$(jq -r .akey < <(head -1 "$T/l2.rec") 2>/dev/null)
case "$WANT" in alert:*) ok ;; *) bad "L2: the re-beat block minted no row_key akey ('$WANT')" ;; esac
[ -n "$WANT" ] && [ "$(jq -r .akey <<<"$P1" 2>/dev/null)" = "$WANT" ] \
  && ok || bad "L2: akey '$(jq -r .akey <<<"$P1" 2>/dev/null)' != re-beat akey '$WANT'"
mktree "$T/l2b"
emit "$T/l2b" --severity warn --id K1 --project project-1 'project-3 disk low' >/dev/null
P2=$(head -1 "$T/l2b/beats.jsonl" 2>/dev/null)
[ "$(jq -r '[.project,.severity,.alertid]|join(",")' <<<"$P2" 2>/dev/null)" = "project-1,warn,K1" ] \
  && ok || bad "L2: --project/--severity/--id not carried: $P2"
[ "$(sed 's/^[^ ]* [^ ]* //' "$T/l2b/logs/ALERTS.log")" = "project-3 disk low" ] \
  && ok || bad "L2: flags leaked into the line: $(cat "$T/l2b/logs/ALERTS.log")"

echo "--- L3: beat rc 0 -> marker"
[ -e "$T/l1/state/alert-line-sent/$(sha "$L1")" ] && ok || bad "L3: no marker after a delivered beat"

echo "--- L4: beat rc 1 -> no marker, line still appended, exit 0"
mktree "$T/l4"
RC=$(STUB_RC=1 ALERT_LINE_STAMP='2026-09-26 10:00:00Z' emit "$T/l4" 'project-3 build stuck [x]')
[ "$RC" = 0 ] && ok || bad "L4: helper exited $RC on a failed beat"
[ "$(countof . "$T/l4/beats.jsonl")" = 1 ] && ok || bad "L4: beat not attempted"
[ -z "$(ls -A "$T/l4/state/alert-line-sent" 2>/dev/null)" ] && ok || bad "L4: marker written for an undelivered beat"
[ "$(tail -1 "$T/l4/logs/ALERTS.log" 2>/dev/null)" = "$L1" ] && ok || bad "L4: line not appended after a failed beat"

echo "--- L5: no beat.sh, no jq -> appended, exit 0"
mktree "$T/l5"; rm -f "$T/l5/bin/beat.sh"
RC=$(ALERT_LINE_STAMP='2026-09-26 10:00:00Z' emit "$T/l5" 'project-3 build stuck [x]')
[ "$RC" = 0 ] && [ "$(tail -1 "$T/l5/logs/ALERTS.log" 2>/dev/null)" = "$L1" ] \
  && ok || bad "L5: no beat.sh: rc=$RC line='$(cat "$T/l5/logs/ALERTS.log" 2>/dev/null)'"
[ -z "$(ls -A "$T/l5/state/alert-line-sent" 2>/dev/null)" ] && ok || bad "L5: marker without a beat.sh"
mkdir -p "$T/nojq"
for f in /usr/local/bin/* /usr/bin/* /bin/*; do
  b=${f##*/}; [ "$b" = jq ] && continue; [ -e "$T/nojq/$b" ] || ln -s "$f" "$T/nojq/$b" 2>/dev/null
done
mktree "$T/l5b"
RC=$( ( export HARNESS="$T/l5b" PATH="$T/nojq" ALERT_LINE_STAMP='2026-09-26 10:00:00Z'
        command -v jq >/dev/null && exit 99
        "$T/l5b/bin/alert-line.sh" 'project-3 build stuck [x]' >/dev/null 2>&1 ); echo $?)
[ "$RC" = 0 ] && [ "$(tail -1 "$T/l5b/logs/ALERTS.log" 2>/dev/null)" = "$L1" ] \
  && ok || bad "L5: no jq: rc=$RC line='$(cat "$T/l5b/logs/ALERTS.log" 2>/dev/null)'"
[ -z "$(ls -A "$T/l5b/state/alert-line-sent" 2>/dev/null)" ] && ok || bad "L5: marker without jq"

echo "--- L6: the beat runs before the append"
[ "$(head -1 "$T/l1/beat-order" 2>/dev/null)" = absent ] \
  && ok || bad "L6: the line was already in ALERTS.log when beat.sh ran ($(cat "$T/l1/beat-order" 2>/dev/null))"

echo "--- L7: markers older than ALERT_LINE_MARKER_TTL_S are GC'd"
mktree "$T/l7"; mkdir -p "$T/l7/state/alert-line-sent"
touch -d '2 days ago' "$T/l7/state/alert-line-sent/old"
emit "$T/l7" 'x' >/dev/null
[ ! -e "$T/l7/state/alert-line-sent/old" ] && ok || bad "L7: a 2-day-old marker survived the default 86400s TTL"
touch -d '2 days ago' "$T/l7/state/alert-line-sent/old"
ALERT_LINE_MARKER_TTL_S=999999 emit "$T/l7" 'y' >/dev/null
[ -e "$T/l7/state/alert-line-sent/old" ] && ok || bad "L7: ALERT_LINE_MARKER_TTL_S=999999 did not keep a 2-day-old marker"

echo "--- R1: the re-beat skips a helper line, beats a bare one, drops the marker"
mktree "$T/r1"
ALERT_LINE_STAMP='2026-09-26 10:00:00Z' emit "$T/r1" 'project-3 build stuck [x]' >/dev/null
echo "2026-09-26 10:00:05Z project-3 bare echo line" >> "$T/r1/logs/ALERTS.log"
rebeat "$T/r1" "$T/r1.rec"
[ "$(countof . "$T/r1.rec")" = 1 ] && ok || bad "R1: re-beat beat $(countof . "$T/r1.rec") lines, want 1"
[ "$(jq -r .line < <(head -1 "$T/r1.rec") 2>/dev/null)" = "2026-09-26 10:00:05Z project-3 bare echo line" ] \
  && ok || bad "R1: re-beat beat the wrong line: $(head -1 "$T/r1.rec")"
[ ! -e "$T/r1/state/alert-line-sent/$(sha "$L1")" ] && ok || bad "R1: marker not removed by the re-beat"

echo "--- R2: same text, helper then bare echo a second later: only the bare one is beaten"
mktree "$T/r2"
ALERT_LINE_STAMP='2026-09-26 10:00:00Z' emit "$T/r2" 'project-3 build stuck [x]' >/dev/null
echo "2026-09-26 10:00:01Z project-3 build stuck [x]" >> "$T/r2/logs/ALERTS.log"
rebeat "$T/r2" "$T/r2.rec"
[ "$(countof . "$T/r2.rec")" = 1 ] && [ "$(jq -r .line < <(head -1 "$T/r2.rec") 2>/dev/null)" = "2026-09-26 10:00:01Z project-3 build stuck [x]" ] \
  && ok || bad "R2: want one beat of the bare line, got: $(cat "$T/r2.rec")"

echo "--- R3: real beat.sh, flags/alerts-db: one emission = one /api/alerts/note"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "POST "*/api/alerts/note) printf '{"decision":"fire","count":1,"as_of":"t"}\n200\n' ;;
  "POST "*console.invalid/api/beat) printf '200' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
D="$T/r3"; mktree "$D"; rm -f "$D/bin/beat.sh"
ln -sf "$DIR/bin/beat.sh" "$D/bin/beat.sh"
ln -sf "$DIR/bin/jobs-client.sh" "$D/bin/jobs-client.sh"
ln -sf "$DIR/bin/lib/env-path.sh" "$D/bin/lib/env-path.sh"
mkdir -p "$D/bin/lib/jobs" "$D/env" && cp "$DIR"/bin/lib/jobs/*.sh "$D/bin/lib/jobs/"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\nJOBS_URL=https://jobs.invalid\n' > "$D/env/global.env"
printf 'r3\n' > "$D/state/box-name"
touch "$D/flags/alerts-db" "$D/flags/remediation-disabled"
: > "$T/r3.sink"
( export PATH="$T/fakebin:$PATH" REQ_SINK="$T/r3.sink" HARNESS="$D" \
         CONSOLE_URL=https://console.invalid HARNESS_SECRET=testsecret ALERT_LINE_STAMP='2026-09-26 10:00:00Z'
  "$D/bin/alert-line.sh" --severity critical 'project-3 build stuck [x]' >/dev/null 2>&1
  export BEAT="$D/bin/beat.sh"
  # shellcheck source=/dev/null
  . "$T/rebeat.body" >/dev/null 2>&1 )
[ "$(countof 'POST .*/api/alerts/note' "$T/r3.sink")" = 1 ] \
  && ok || bad "R3: want exactly 1 /api/alerts/note for one emission, got $(countof 'POST .*/api/alerts/note' "$T/r3.sink"): $(cat "$T/r3.sink")"
[ "$(countof . "$D/logs/ALERTS.log")" = 1 ] && ok || bad "R3: ALERTS.log should hold exactly the one line"

echo "alert-line: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
