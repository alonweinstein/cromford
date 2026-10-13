#!/bin/bash
# tests/triage-gate-keymap-stale.bh-1042-test.sh — BH-1042 bullet 4: a CLOSED
# ticket must never sit in state/<project>.keymap.json, and the client-court
# guard must believe the queue row over that map.
#
# THE DEFECT, in one sentence: bin/triage-gate.sh writes EVERY listed ticket
# into the keymap — closed ones included — and the only reader
# (bin/lib/rt/shards.sh, between the `# >>> client-court guard` markers)
# resolves a queue unit's board key through that map and then asks the gate
# about whatever ticket id it found. Board keys get RECYCLED: TK-218 named a
# ticket that is long since done and waiting on the client, a fresh build got
# queued under the same key, and the guard dropped the fresh unit because the
# stale map still pointed at the closed one. The queue row
# (state/build-queue/<project>/<KEY>.json, written by bin/fly-dispatch.sh)
# carried the RIGHT ticket id the whole time and nobody asked it.
#
# TWO HALVES, and they are independent fixes:
#   T4a — the keymap jq drops tickets whose status is done/closed/cancelled/
#         canceled/archived (case-insensitive). Anything else counts as open:
#         fail-open, because a status word this harness has not seen must never
#         make a live ticket unresolvable.
#   T4b — inside the guard's marker block, a non-`board` unit reads the queue
#         row's own `.ticket_id` FIRST and only falls back to the keymap when
#         that is `-`, null, empty or absent. `board` lines already carry the
#         raw ticket id and must consult neither.
#
# DRIVEN, NOT GREPPED. Half of this ticket is one jq filter and the other half
# is four lines of shell; a source-text assertion would pass against a filter
# that is spelled right and wrong, and it would go red the first time someone
# reformats the pipeline. So K1 runs the REAL bin/triage-gate.sh --seed against
# a stubbed curl and asserts on the KEYMAP FILE IT WROTE, and K2/K3 extract the
# guard block verbatim by its markers (the tests/client-court-gate-test.sh
# fixture-5 pattern) and assert on the FILTERED UNITS FILE and the LOG.
#
# RED-FIRST: K1 and K2 are expected to fail until T4a/T4b land. K3 is the
# fail-open floor — those cases pass today and must still pass afterwards, or
# the fix has taken the guard's teeth out along with its blind spot.
#
# No network, no model, no clock reads. Everything lives under the scratch tree.
# Run from anywhere: tests/triage-gate-keymap-stale.bh-1042-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

# The one time anchor; every fixture timestamp below is derived from it, so this
# file reads the same on any wall clock.
NOW=2026-09-19T00:00:00Z

DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE_SRC="$DIR/bin/triage-gate.sh"
SHARDS_SRC="$DIR/bin/lib/rt/shards.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "triage-gate-keymap-stale: jq missing, cannot run" >&2; exit 1; }
[ -r "$GATE_SRC" ]   || { echo "triage-gate-keymap-stale: no bin/triage-gate.sh at $GATE_SRC" >&2; exit 1; }
[ -r "$SHARDS_SRC" ] || { echo "triage-gate-keymap-stale: no bin/lib/rt/shards.sh at $SHARDS_SRC" >&2; exit 1; }

# ── K1: the keymap the real gate writes ──────────────────────────────────────
# Scratch harness shaped like the bh-899 fingerprint suite: the real gate, the
# real board-fetch.sh, a fleet.conf stand-in where x-os is an in-app board, and
# a curl that serves files out of $T/fixture.
mkdir -p "$T/bin" "$T/env" "$T/state" "$T/logs" "$T/fixture"
cp "$GATE_SRC"               "$T/bin/triage-gate.sh"
# BH-1955: the generic arm resolves its token through these two libs.
mkdir -p "$T/bin/lib" && cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$T/bin/lib/"
cp "$DIR/bin/board-fetch.sh" "$T/bin/board-fetch.sh"
chmod +x "$T/bin/triage-gate.sh" "$T/bin/board-fetch.sh"

cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os)
    case "${2:-}" in
      repo) echo "" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
chmod +x "$T/bin/fleet-conf.sh"

# Credentials found by suffix — the generic in-app arm (bin/triage-gate.sh:84-86).
cat > "$T/env/x-os.env" <<'EOC'
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=tok
EOC

cat > "$T/bin/curl" <<EOC
#!/bin/bash
OUT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -H) shift; : ;;
    -m) shift; : ;;
    -w) shift; : ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift || true
done
F=""
case "\$URL" in
  */boards/*/tickets) F="$T/fixture/tickets.json" ;;
  */boards)           F="$T/fixture/boards.json" ;;
esac
[ -n "\$F" ] && [ -f "\$F" ] || exit 22
if [ -n "\$OUT" ]; then cat "\$F" > "\$OUT"; else cat "\$F"; fi
exit 0
EOC
chmod +x "$T/bin/curl"

printf '[{"id":"b1"}]\n' > "$T/fixture/boards.json"

# The listing the board really serves. The four dependency fields are present
# because `key` only reaches the fingerprint (and therefore the keymap) when
# `blocked` is a JSON boolean — see bin/triage-gate.sh:139-142. TK-2 is the
# closed row that must not survive; TK-3's `Review` is there so the status test
# is proven case-insensitive rather than accidentally lower-case everywhere.
cat > "$T/fixture/tickets.json" <<EOC
{
  "tickets": [
    {
      "id": 1,
      "key": "TK-1",
      "status": "todo",
      "waitingOn": "team",
      "triageVerdict": "ready",
      "commentCount": 1,
      "lastActivityAt": "$NOW",
      "title": "Open ticket, resolvable",
      "blocked": false,
      "parentId": null,
      "dependsOn": [],
      "children": []
    },
    {
      "id": 2,
      "key": "TK-2",
      "status": "done",
      "waitingOn": "client",
      "triageVerdict": "needs_clarification",
      "commentCount": 4,
      "lastActivityAt": "$NOW",
      "title": "Closed ticket, the stale map entry",
      "blocked": false,
      "parentId": null,
      "dependsOn": [],
      "children": []
    },
    {
      "id": 3,
      "key": "TK-3",
      "status": "Review",
      "waitingOn": "team",
      "triageVerdict": "ready",
      "commentCount": 2,
      "lastActivityAt": "$NOW",
      "title": "Open ticket whose status is not lower-case",
      "blocked": false,
      "parentId": null,
      "dependsOn": [],
      "children": []
    }
  ],
  "capped": false
}
EOC

KEYMAP="$T/state/x-os.keymap.json"
rm -f "$KEYMAP" "$T/state/x-os.gate.json" "$T/state/x-os.gate-meta"
HARNESS="$T" PATH="$T/bin:$PATH" bash "$T/bin/triage-gate.sh" x-os --seed >"$T/logs/seed.out" 2>"$T/logs/seed.err"

if [ -s "$KEYMAP" ]; then ok; else
  bad "K1: --seed wrote no keymap at all (seed said: $(cat "$T/logs/seed.out" 2>/dev/null))"
fi

KM=$(cat "$KEYMAP" 2>/dev/null)
[ "$(jq -r '."TK-1" // "MISSING"' "$KEYMAP" 2>/dev/null)" = "1" ]    && ok || bad "K1: keymap must resolve TK-1 -> \"1\", got: $KM"
[ "$(jq -r '."1" // "MISSING"'    "$KEYMAP" 2>/dev/null)" = "TK-1" ] && ok || bad "K1: keymap must resolve \"1\" -> TK-1, got: $KM"
[ "$(jq -r '."TK-3" // "MISSING"' "$KEYMAP" 2>/dev/null)" = "3" ]    && ok || bad "K1: keymap must resolve TK-3 -> \"3\" (Review is OPEN, the match is case-insensitive), got: $KM"
[ "$(jq -r '."3" // "MISSING"'    "$KEYMAP" 2>/dev/null)" = "TK-3" ] && ok || bad "K1: keymap must resolve \"3\" -> TK-3, got: $KM"

# THE DEFECT ITSELF, both directions of the closed ticket's pair.
[ "$(jq -r 'has("TK-2")' "$KEYMAP" 2>/dev/null)" = "false" ] && ok \
  || bad "K1: a status=done ticket must NOT put its key in the keymap, but TK-2 is there: $KM"
[ "$(jq -r 'has("2")' "$KEYMAP" 2>/dev/null)" = "false" ] && ok \
  || bad "K1: a status=done ticket must NOT put its id in the keymap, but \"2\" is there: $KM"

# ── the guard rig, shared by K2 and K3 ───────────────────────────────────────
# The block is lifted between its markers so the test runs exactly the bytes
# production runs (tests/client-court-gate-test.sh fixture 5).
GUARD="$T/guard.sh"
sed -n '/# >>> client-court guard/,/# <<< client-court guard/p' "$SHARDS_SRC" | sed '1d;$d' > "$GUARD"
if [ -s "$GUARD" ]; then ok; else
  bad "the client-court guard markers produced no block from $SHARDS_SRC — the rig, not the rule, is broken"
fi

# The gate the guard consults: only tk-needs-clarify is in client court.
cat > "$T/gate-stub.sh" <<'EOC'
#!/bin/bash
TID="${3:-}"
case "$TID" in
  tk-needs-clarify) echo "BLOCKED $TID" ;;
  *) echo "OK" ;;
esac
EOC

guard_prep() { # guard_prep <case> -> GD is the case's scratch harness root
  GD="$T/g/$1"
  mkdir -p "$GD/bin" "$GD/state/build-queue/x-os" "$GD/logs"
  cp "$T/gate-stub.sh" "$GD/bin/triage-gate.sh"
  chmod +x "$GD/bin/triage-gate.sh"
  # Every case carries one unit that must survive, so a guard that blew up and
  # emptied the file cannot masquerade as a correct drop.
  printf 'tk-ready\tboard\tboard b1: CHANGED tk-ready "control unit"\n' > "$GD/state/shard.units"
}

guard_run() { # guard_run <case> -> $GD/out.txt = SHARD_ON line + surviving units
  local d="$T/g/$1"
  SHARD_ON=1 HARNESS="$d" PROJECT="x-os" LOG="$d/logs/run-triage.log" \
    SHARD_UNITS="$d/state/shard.units" PATH="$d/bin:$PATH" TMPDIR="$d" GUARD="$GUARD" \
    bash -c '
      . "$GUARD"
      printf "SHARD_ON=%s\n" "$SHARD_ON"
      cat "$SHARD_UNITS" 2>/dev/null || true
    ' > "$d/out.txt" 2>"$d/err.txt"
}

guard_kept()    { grep -qE "^$1"$'\t' "$T/g/$2/out.txt"; }
guard_log()     { cat "$T/g/$1/logs/run-triage.log" 2>/dev/null; }
guard_control() { # the control unit and SHARD_ON survive every case
  grep -q 'SHARD_ON=1' "$T/g/$1/out.txt" && guard_kept tk-ready "$1"
}

QLINE="TK-218 (target main, attempt 0, queued $NOW)"

# ── K2: the queue row's own ticket_id wins over a stale keymap ───────────────
guard_prep k2
printf '{"TK-218":"tk-needs-clarify","tk-needs-clarify":"TK-218"}\n' > "$GD/state/x-os.keymap.json"
printf '{"ticket_id":"tk-ready","key":"TK-218"}\n' > "$GD/state/build-queue/x-os/TK-218.json"
printf 'TK-218\tqueue\t%s\n' "$QLINE" >> "$GD/state/shard.units"
guard_run k2
guard_control k2 && ok || bad "K2: the rig broke — control unit or SHARD_ON=1 did not survive: $(cat "$T/g/k2/out.txt" 2>/dev/null) $(cat "$T/g/k2/err.txt" 2>/dev/null)"
guard_kept TK-218 k2 && ok \
  || bad "K2: the queue row names tk-ready, so TK-218 must be KEPT — the stale keymap entry (TK-218 -> tk-needs-clarify) must not be consulted. Surviving units: $(cat "$T/g/k2/out.txt" 2>/dev/null)"
case "$(guard_log k2)" in
  *'client-court skipped'*) bad "K2: nothing was in client court, but the guard logged a skip: $(guard_log k2)" ;;
  *) ok ;;
esac

# ── K3: the fail-open floor. Green today, and still green after the fix. ─────
# K3a: ticket_id "-" is the dispatcher's own placeholder, not an answer.
guard_prep k3a
printf '{"TK-219":"tk-needs-clarify","tk-needs-clarify":"TK-219"}\n' > "$GD/state/x-os.keymap.json"
printf '{"ticket_id":"-","key":"TK-219"}\n' > "$GD/state/build-queue/x-os/TK-219.json"
printf 'TK-219\tqueue\tPB-219 (target main, attempt 0, queued %s)\n' "$NOW" >> "$GD/state/shard.units"
guard_run k3a
guard_control k3a && ok || bad "K3a: the rig broke: $(cat "$T/g/k3a/out.txt" 2>/dev/null) $(cat "$T/g/k3a/err.txt" 2>/dev/null)"
guard_kept TK-219 k3a && bad "K3a: ticket_id \"-\" must fall through to the keymap, which puts TK-219 in client court — it must be DROPPED: $(cat "$T/g/k3a/out.txt" 2>/dev/null)" || ok

# K3b: a JSON null ticket_id is the same non-answer.
guard_prep k3b
printf '{"TK-220":"tk-needs-clarify","tk-needs-clarify":"TK-220"}\n' > "$GD/state/x-os.keymap.json"
printf '{"ticket_id":null,"key":"TK-220"}\n' > "$GD/state/build-queue/x-os/TK-220.json"
printf 'TK-220\tqueue\tPB-220 (target main, attempt 0, queued %s)\n' "$NOW" >> "$GD/state/shard.units"
guard_run k3b
guard_control k3b && ok || bad "K3b: the rig broke: $(cat "$T/g/k3b/out.txt" 2>/dev/null) $(cat "$T/g/k3b/err.txt" 2>/dev/null)"
guard_kept TK-220 k3b && bad "K3b: a null ticket_id must fall through to the keymap and DROP TK-220: $(cat "$T/g/k3b/out.txt" 2>/dev/null)" || ok

# K3c: an older queue row that predates the ticket_id field at all.
guard_prep k3c
printf '{"TK-221":"tk-needs-clarify","tk-needs-clarify":"TK-221"}\n' > "$GD/state/x-os.keymap.json"
printf '{"key":"TK-221","attempt":0}\n' > "$GD/state/build-queue/x-os/TK-221.json"
printf 'TK-221\tqueue\tPB-221 (target main, attempt 0, queued %s)\n' "$NOW" >> "$GD/state/shard.units"
guard_run k3c
guard_control k3c && ok || bad "K3c: the rig broke: $(cat "$T/g/k3c/out.txt" 2>/dev/null) $(cat "$T/g/k3c/err.txt" 2>/dev/null)"
guard_kept TK-221 k3c && bad "K3c: a queue row with no ticket_id key must fall through to the keymap and DROP TK-221: $(cat "$T/g/k3c/out.txt" 2>/dev/null)" || ok

# K3d: today's byte-for-byte path — no queue row exists, the keymap is all there is.
guard_prep k3d
printf '{"TK-222":"tk-needs-clarify","tk-needs-clarify":"TK-222"}\n' > "$GD/state/x-os.keymap.json"
printf 'TK-222\tqueue\tPB-222 (target main, attempt 0, queued %s)\n' "$NOW" >> "$GD/state/shard.units"
guard_run k3d
guard_control k3d && ok || bad "K3d: the rig broke: $(cat "$T/g/k3d/out.txt" 2>/dev/null) $(cat "$T/g/k3d/err.txt" 2>/dev/null)"
guard_kept TK-222 k3d && bad "K3d: with no queue row the keymap is the only answer and TK-222 must be DROPPED: $(cat "$T/g/k3d/out.txt" 2>/dev/null)" || ok
case "$(guard_log k3d)" in
  *'client-court skipped'*TK-222*) ok ;;
  *) bad "K3d: the guard must name the dropped key in the log, got: $(guard_log k3d)" ;;
esac

# K3e: a board line carries the RAW ticket id. It must consult neither the queue
# row nor the keymap, even when a file sits there with the same name.
guard_prep k3e
printf '{"tk-needs-clarify":"TK-223","TK-223":"tk-needs-clarify"}\n' > "$GD/state/x-os.keymap.json"
printf '{"ticket_id":"tk-ready","key":"tk-needs-clarify"}\n' > "$GD/state/build-queue/x-os/tk-needs-clarify.json"
printf 'tk-needs-clarify\tboard\tboard b1: CHANGED tk-needs-clarify "discount toggle"\n' >> "$GD/state/shard.units"
guard_run k3e
guard_control k3e && ok || bad "K3e: the rig broke: $(cat "$T/g/k3e/out.txt" 2>/dev/null) $(cat "$T/g/k3e/err.txt" 2>/dev/null)"
guard_kept tk-needs-clarify k3e && bad "K3e: a board-class unit names the ticket id directly — a same-named queue row must not rescue it, it must be DROPPED: $(cat "$T/g/k3e/out.txt" 2>/dev/null)" || ok

echo "triage-gate-keymap-stale: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
