#!/bin/bash
# tests/alert-line-stable-id.bh-4053-test.sh — bin/alert-line.sh --id gives the
# condition ONE console row: the akey is alert:<id>, the PR set rides in the
# line (the payload), never in the key (BH-4053).
#
# Driven, not grepped (D2/D3): every case runs the real bin/alert-line.sh inside
# a scratch $HARNESS against a stub bin/beat.sh that records its payload. The
# back-compat and alias cases source the shipped `# >>> alerts re-beat` block of
# bin/poll-commands.sh, as tests/alert-line.bh-2314-test.sh L2 does, so the akey
# the overflow/failed-beat path mints is the one that ships.
#
#   S1 two --id emits, different PR sets -> one akey, alertid raw
#   S2 latest line is the last beat on that akey; no PR ref in the akey
#   S3 no --id -> today's akey (the re-beat's alert:auto-…), no alertid
#   S4 --id "" -> same as S3
#   S5 --id with colons -> akey folded, alertid raw
#   S6 the alias makes the re-beat of the same text land on alert:<id>
#   S7 no lib/alert-state.sh -> akey still alert:<id>, rc 0
#   S8 rc 0 and one ALERTS.log line per emit
#
# Run from anywhere: tests/alert-line-stable-id.bh-4053-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

export FLEET_CONF="$T/fleet.conf" ALERTS_CONF="$T/alerts.conf"
printf 'ts example-org/ts https://t.invalid /api/board 3 bx1\n' > "$FLEET_CONF"
: > "$ALERTS_CONF"

mktree() { # mktree <dir> [nolib]
  local d="$1" s
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags"
  for s in alert-line.sh alert_family.py project-of.sh fleet-conf.sh box-for.sh; do
    ln -sf "$DIR/bin/$s" "$d/bin/$s"
  done
  if [ "${2:-}" != nolib ]; then
    ln -sf "$DIR/bin/lib/alert-state.sh" "$d/bin/lib/alert-state.sh"
    ln -sf "$DIR/bin/lib/conf-row.sh" "$d/bin/lib/conf-row.sh"
  fi
  cat > "$d/bin/beat.sh" <<'EOF'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$1" >> "$H/beats.jsonl"
exit "${STUB_RC:-0}"
EOF
  chmod +x "$d/bin/beat.sh"
}
emit() { # emit <dir> <args...> — prints the helper's rc
  local d="$1"; shift
  ( export HARNESS="$d" ALERT_LINE_STAMP='2026-10-02 10:00:00Z'; "$d/bin/alert-line.sh" "$@" >/dev/null 2>&1 ); echo $?
}
nth() { sed -n "${2}p" "$1/beats.jsonl" 2>/dev/null; }

awk '/^# >>> alerts re-beat/{f=1;next} /^# <<< alerts re-beat/{exit} f{print}' \
  "$DIR/bin/poll-commands.sh" > "$T/rebeat.body"
[ -s "$T/rebeat.body" ] && ok || bad "could not extract the '# >>> alerts re-beat' block"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$REC"\n' > "$T/rec.sh"; chmod +x "$T/rec.sh"
rebeat() { # rebeat <dir> <rec-file>
  : > "$2"
  ( export HARNESS="$1" BEAT="$T/rec.sh" REC="$2"
    # shellcheck source=/dev/null
    . "$T/rebeat.body" ) >/dev/null 2>&1
}

TX1='[pipeline-health] ts: harness PR(s) #50 open >12h awaiting merge — built work aging'
TX2='[pipeline-health] ts: harness PR(s) #50,#51 open >12h awaiting merge — built work aging'

echo "--- S1: two --id emits with different PR sets share one akey"
mktree "$T/s1"
R1=$(emit "$T/s1" --id ph-stalepr "$TX1"); R2=$(emit "$T/s1" --id ph-stalepr "$TX2")
P1=$(nth "$T/s1" 1); P2=$(nth "$T/s1" 2)
[ "$(jq -r .akey <<<"$P1" 2>/dev/null)" = alert:ph-stalepr ] && ok || bad "S1: first akey: $P1"
[ "$(jq -r .akey <<<"$P2" 2>/dev/null)" = alert:ph-stalepr ] && ok || bad "S1: second akey: $P2"
[ "$(jq -r .alertid <<<"$P2" 2>/dev/null)" = ph-stalepr ] && ok || bad "S1: alertid: $P2"

echo "--- S2: the latest PR list is the body of the last beat on that akey"
LAST=$(jq -rs 'map(select(.akey=="alert:ph-stalepr"))|last|.line' "$T/s1/beats.jsonl" 2>/dev/null)
case "$LAST" in *'#50,#51'*) ok ;; *) bad "S2: last line on the akey is '$LAST'" ;; esac
[ "$(jq -rs 'map(.akey)|map(select(contains("#")))|length' "$T/s1/beats.jsonl" 2>/dev/null)" = 0 ] \
  && ok || bad "S2: a PR ref leaked into an akey: $(cat "$T/s1/beats.jsonl")"

echo "--- S3: no --id is today's akey, byte for byte the re-beat's"
mktree "$T/s3"; emit "$T/s3" "$TX2" >/dev/null
P3=$(nth "$T/s3" 1)
mktree "$T/s3r"; printf '2026-10-02 10:00:00Z %s\n' "$TX2" > "$T/s3r/logs/ALERTS.log"
rebeat "$T/s3r" "$T/s3.rec"
WANT=$(head -1 "$T/s3.rec" | jq -r .akey 2>/dev/null)
case "$WANT" in alert:auto-*) ok ;; *) bad "S3: re-beat minted '$WANT', want alert:auto-…" ;; esac
[ -n "$WANT" ] && [ "$(jq -r .akey <<<"$P3")" = "$WANT" ] && ok || bad "S3: akey '$(jq -r .akey <<<"$P3")' != re-beat '$WANT'"
[ "$(jq -r 'has("alertid")' <<<"$P3")" = false ] && ok || bad "S3: alertid sent without --id: $P3"

echo "--- S4: --id \"\" is no id"
mktree "$T/s4"; emit "$T/s4" --id "" "$TX2" >/dev/null
P4=$(nth "$T/s4" 1)
[ -n "$WANT" ] && [ "$(jq -r .akey <<<"$P4")" = "$WANT" ] && ok || bad "S4: akey '$(jq -r .akey <<<"$P4")' != '$WANT'"
[ "$(jq -r 'has("alertid")' <<<"$P4")" = false ] && ok || bad "S4: empty alertid sent: $P4"

echo "--- S5: an id outside [A-Za-z0-9_.-] folds in the akey, stays raw as alertid"
mktree "$T/s5"; emit "$T/s5" --id 'tripwire:p:k:b' "ts tripwire fired" >/dev/null
P5=$(nth "$T/s5" 1)
[ "$(jq -r .akey <<<"$P5")" = alert:tripwire_p_k_b ] && ok || bad "S5: akey: $P5"
[ "$(jq -r .alertid <<<"$P5")" = tripwire:p:k:b ] && ok || bad "S5: alertid: $P5"

echo "--- S6: the alias carries the re-beat of the same text onto alert:<id>"
AK=$(python3 "$DIR/bin/alert_family.py" row_key "$TX2")
[ "$(head -1 "$T/s1/state/alerts/alias/auto-$AK" 2>/dev/null)" = ph-stalepr ] \
  && ok || bad "S6: alias state/alerts/alias/auto-$AK: '$(cat "$T/s1/state/alerts/alias/auto-$AK" 2>/dev/null)'"
# a fresh line with that text and no marker: the overflow / failed-beat path
printf '2026-10-02 11:00:00Z %s\n' "$TX2" >> "$T/s1/logs/ALERTS.log"
rebeat "$T/s1" "$T/s6.rec"
[ "$(jq -r .akey < <(tail -1 "$T/s6.rec") 2>/dev/null)" = alert:ph-stalepr ] \
  && ok || bad "S6: re-beat minted '$(cat "$T/s6.rec")', want alert:ph-stalepr"

echo "--- S7: without the alert-state lib the akey is still alert:<id>"
mktree "$T/s7" nolib; R7=$(emit "$T/s7" --id ph-x "$TX1")
[ "$R7" = 0 ] && ok || bad "S7: rc $R7"
[ "$(jq -r .akey < <(nth "$T/s7" 1) 2>/dev/null)" = alert:ph-x ] && ok || bad "S7: akey: $(cat "$T/s7/beats.jsonl" 2>/dev/null)"
[ "$(wc -l < "$T/s7/logs/ALERTS.log")" = 1 ] && ok || bad "S7: ALERTS.log lines: $(wc -l < "$T/s7/logs/ALERTS.log")"

echo "--- S8: rc 0, one ALERTS.log line per emit, also when the beat fails"
[ "$R1" = 0 ] && [ "$R2" = 0 ] && ok || bad "S8: rc $R1/$R2"
mktree "$T/s8"; R8=$(STUB_RC=1 emit "$T/s8" --id ph-stalepr "$TX1")
[ "$R8" = 0 ] && ok || bad "S8: rc $R8 on a failed beat"
[ "$(wc -l < "$T/s8/logs/ALERTS.log")" = 1 ] && ok || bad "S8: failed-beat ALERTS.log lines"
[ "$(grep -c . "$T/s1/logs/ALERTS.log")" = 3 ] && ok || bad "S8: s1 ALERTS.log should hold 2 emits + 1 hand line"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
