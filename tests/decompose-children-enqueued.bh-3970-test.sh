#!/bin/bash
# tests/decompose-children-enqueued.bh-3970-test.sh — BH-3970 item 1: a child
# the board-lane decompose filed itself is ENQUEUED by the decompose, not left
# for triage to discover.
#
# THE DEFECT THIS PINS. bin/run-decompose.sh's board lane filed the children,
# re-mapped their labels to board keys, parked the parent and enqueued nothing.
# The only way a child could reach a build was triage noticing it, and on
# project-8 (2026-10-03) triage never did: 32 children sat buildable
# with empty queue-list and ready-list until a human ran `jobs-client.sh
# ready-put` by hand.
#
# Driven, not grepped. The REAL bin/run-decompose.sh runs on the board lane with
# a stub agent-call that writes children.txt, and the REAL bin/jobs-client.sh
# writes the ready rows — through a fake curl that plays BOTH the board API and
# the jobs worker's /api/queue, so a row in $T/rows.tsv is a POST the client
# really made. Order is asserted: child 1 is the contract and lands first.
#
# Run from anywhere: tests/decompose-children-enqueued.bh-3970-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "decompose-children-enqueued: jq missing, cannot run" >&2; exit 1; }

DEC="$DIR/bin/run-decompose.sh"
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" x-os ghproj || exit 1
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts" "$H/flags" "$T/fakebin"
# BH-3965: E1-E10 drive the model-filed board path (the stub agent writes
# children.txt and the board already holds the filed keys), which is now the
# path behind the decompose-board-filer-off switch. E11 drives the
# harness-filed default with the switch off.
touch "$H/flags/decompose-board-filer-off"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
cat > "$H/fleet.conf" <<'CONF'
x-os    example-org/x-os    https://x.example       /api/board  3 box-a
ghproj  example-org/ghproj  https://ghproj.example  -           4 box-a
CONF
: > "$H/env/global.env"
printf 'XOS_INTERNAL_API_TOKEN=tok-abc\nXOS_API_BASE=https://x.example\n' > "$H/env/x-os.env"

# The owning box is this one unless a case says otherwise.
cat > "$H/bin/box-for.sh" <<'SH'
#!/bin/bash
echo "${BOX_FOR_ANSWER:-local}"
SH
chmod +x "$H/bin/box-for.sh"

cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "call" >> "$AGENT_CALLS"
B=$(dirname "$5")
cat "$CHILDREN_FIXTURE" > "$B/children.txt"
printf 'DECOMPOSED: %s\n' "$(paste -sd, "$B/children.txt")" > "$5"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"

# The board: three children filed under the board's keys, contract first.
BOARD='{"tickets":[
  {"key":"TK-25","id":"9025","title":"TK-4.0: contract — shared types","status":"todo","createdAt":"2026-10-03T15:39:00Z"},
  {"key":"TK-26","id":"9026","title":"TK-4.1: ingest lane","status":"todo","createdAt":"2026-10-03T15:40:00Z"},
  {"key":"TK-27","id":"9027","title":"TK-4.2: the report screen","status":"todo","createdAt":"2026-10-03T15:41:00Z"}]}'
printf '%s\n' "$BOARD" > "$T/board.json"

# One fake curl, two services. The board half ignores -w (the decompose reads
# bodies only); the jobs half honours it, because bin/lib/jobs/req.sh splits the
# status code off the last line. /api/queue keeps rows in $T/rows.tsv
# (project, key, ticket_id, ready_line) and answers duplicate on a repeat key,
# which is the worker's own idempotency on project+key.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; BODY=""; METHOD=GET; FMT=""; IDEM=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data-binary|--data|-d) BODY="\$2"; shift 2 ;;
    -X) METHOD="\$2"; shift 2 ;;
    -w) FMT="\$2"; shift 2 ;;
    -H) case "\$2" in Idempotency-Key:*) IDEM="\${2##*-}" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s %s\n' "\$METHOD" "\$URL" "\$BODY" >> "$T/curl-calls.txt"
code() { [ -n "\$FMT" ] && printf '\n%s' "\$1"; return 0; }
case "\$URL" in
  http://jobs.test/api/queue*)
    if [ "\$METHOD" = POST ]; then
      P=\$(jq -r .project <<<"\$BODY"); K=\$(jq -r .key <<<"\$BODY")
      TID=\$(jq -r '.ticket_id // "-"' <<<"\$BODY"); L=\$(jq -r '(.meta // "{}" | fromjson | .ready_line) // "-"' <<<"\$BODY")
      if awk -F'\t' -v p="\$P" -v k="\$K" '\$1==p && \$2==k {f=1} END {exit !f}' "$T/rows.tsv" 2>/dev/null; then
        printf '{"duplicate":true}'; code 200; exit 0
      fi
      printf '%s\t%s\t%s\t%s\n' "\$P" "\$K" "\$TID" "\$L" >> "$T/rows.tsv"
      printf '{"ok":true}'; code 200; exit 0
    fi
    jq -Rn '{queue:[inputs | split("\t") | {project:.[0],ticket_key:.[1],ticket_id:.[2],status:"ready",meta:({ready_line:.[3]}|tojson)}]}' "$T/rows.tsv" 2>/dev/null
    code 200; exit 0 ;;
  http://jobs.test/*) printf '{}'; code 404; exit 0 ;;
  *"/api/board/tickets/1004/move") printf '{"status":"in_progress"}\n' ;;
  *"/api/board/tickets/1004")      printf '{"ticket":{"id":"1004","key":"TK-4","boardId":"bd-1"}}\n' ;;
  *"/api/board/boards")            printf '[{"id":"bd-1","capabilities":["reactions"]}]\n' ;;
  *"/api/board/boards/bd-1/tickets")
    # The harness filer's create (E11): child n is TK-<30+n>, id 90<30+n>.
    if [ "\$METHOD" = POST ]; then printf '{"ticket":{"id":%s,"key":"TK-%s"}}\n' "\$((9030 + IDEM))" "\$((30 + IDEM))"
    else cat "$T/board.json"; fi ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"

B="$T/b"
fresh() {
  scratch_rm "$B"; mkdir -p "$B"
  rm -f "$T/rows.tsv" "$H/logs/READY-QUEUE.log" "$H/flags/force-triage-x-os"
  touch "$T/rows.tsv"
}
run() { # run [env...]  -> prints the rc; reuses $B (a re-run on the same build dir)
  rm -f "$T/curl-calls.txt" "$T/agent.calls"
  ( env HARNESS="$H" FLEET_CONF="$H/fleet.conf" AGENT_CALLS="$T/agent.calls" \
        CHILDREN_FIXTURE="$T/children-fixture.txt" PATH="$T/fakebin:$PATH" \
        JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret READY_QUEUE_ROWS=1 "$@" \
        bash "$DEC" x-os 1004 TK-4 "$B" 300 12 ) >"$T/dec.out" 2>"$T/dec.err"
  echo $?
}
rows_keys() { cut -f2 "$T/rows.tsv" 2>/dev/null | paste -sd' '; }
file_keys() { grep -oE '^[A-Z]+-[0-9]+' "$H/logs/READY-QUEUE.log" 2>/dev/null | paste -sd' '; }

# ── E1: board keys in children.txt -> 3 ready rows, contract first ──────────
fresh; printf 'TK-25\nPB-26\nPB-27\n' > "$T/children-fixture.txt"
RC=$(run)
[ "$RC" = 0 ] && ok || bad "E1: decompose must exit 0 (rc=$RC): $(cat "$B/pipeline.log" 2>/dev/null)"
[ "$(rows_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E1: ready rows must be TK-25 TK-26 TK-27 in order, got [$(rows_keys)]"
# Board keys in children.txt need no re-map, and a split with nothing to re-map
# costs no board list read (tests/run-decompose-board-keys-test.sh pins that),
# so the ids are '-' here, never invented. E3 is the path that resolves them.
[ "$(cut -f3 "$T/rows.tsv" | paste -sd' ')" = "- - -" ] && ok \
  || bad "E1: no re-map, no list read, so the ids are '-', got [$(cut -f3 "$T/rows.tsv" | paste -sd' ')]"
grep -q '/boards/' "$T/curl-calls.txt" && bad "E1: the enqueue must not add a board list read: $(cat "$T/curl-calls.txt")" || ok
[ "$(cut -f4 "$T/rows.tsv" | grep -c 'project=x-os')" = 3 ] && ok \
  || bad "E1: every ready_line carries project=x-os: $(cut -f4 "$T/rows.tsv")"
# What the fleet reads back: the real client's ready-list.
RL=$(env HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret \
     bash "$DIR/bin/jobs-client.sh" ready-list x-os 2>/dev/null | cut -f2 | paste -sd' ')
[ "$RL" = "TK-25 TK-26 TK-27" ] && ok || bad "E1: jobs-client.sh ready-list x-os must list the 3 children contract first, got [$RL]"
grep -q 'enqueued 3 children ready: TK-25,TK-26,TK-27' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "E1: one pipeline.log line names what was enqueued: $(cat "$B/pipeline.log" 2>/dev/null)"

# ── E2: the box-local file half and the force-triage flag ───────────────────
[ "$(file_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E2: READY-QUEUE.log must hold the same 3 keys in order, got [$(file_keys)]"
[ "$(grep -c 'project=x-os' "$H/logs/READY-QUEUE.log" 2>/dev/null)" = 3 ] && ok || bad "E2: every file line carries project=x-os"
[ -e "$H/flags/force-triage-x-os" ] && ok || bad "E2: flags/force-triage-x-os must be touched"

# ── E4: a re-run on the same build dir is idempotent ────────────────────────
RC=$(run)
[ "$RC" = 0 ] && ok || bad "E4: re-run rc=$RC"
[ "$(rows_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E4: re-run must not add rows, got [$(rows_keys)]"
[ "$(file_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E4: re-run must not add file lines, got [$(file_keys)]"

# ── E3: labels are re-mapped first; rows are under board keys ───────────────
fresh; printf 'TK-4.0\nPB-4.1\nPB-4.2\n' > "$T/children-fixture.txt"
RC=$(run)
[ "$RC" = 0 ] && ok || bad "E3: rc=$RC: $(cat "$B/pipeline.log" 2>/dev/null)"
[ "$(rows_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E3: rows under the mapped board keys, got [$(rows_keys)]"
grep -qE 'TK-4\.[0-9]' "$T/rows.tsv" "$H/logs/READY-QUEUE.log" 2>/dev/null \
  && bad "E3: a title label must never be enqueued" || ok
[ "$(cut -f3 "$T/rows.tsv" | paste -sd' ')" = "9025 9026 9027" ] && ok \
  || bad "E3: the re-map's board list resolves each row's ticket id, got [$(cut -f3 "$T/rows.tsv" | paste -sd' ')]"
[ "$(grep -c '/boards/bd-1/tickets' "$T/curl-calls.txt")" = 1 ] && ok \
  || bad "E3: one board list read in total (the re-map's), got: $(grep '/boards/' "$T/curl-calls.txt")"

# ── E5: a missing or unreadable board never fails the enqueue: covered by E1
#        (no list read at all, ids '-'). A label split whose list is unreadable
#        is a DEC_FAIL (E7's arm), which enqueues nothing.

# ── E6: ready rows off -> the file line is the whole enqueue ────────────────
fresh; printf 'TK-25\nPB-26\nPB-27\n' > "$T/children-fixture.txt"
RC=$(run READY_QUEUE_ROWS=0)
[ "$RC" = 0 ] && ok || bad "E6: rc=$RC"
[ -s "$T/rows.tsv" ] && bad "E6: rows flag off must write no row: $(cat "$T/rows.tsv")" || ok
[ "$(file_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E6: file lines still written, got [$(file_keys)]"

# ── E9: decompose on a machine that does not own the project -> rows only ───
fresh; printf 'TK-25\nPB-26\nPB-27\n' > "$T/children-fixture.txt"
RC=$(run BOX_FOR_ANSWER=box-a)
[ "$RC" = 0 ] && ok || bad "E9: rc=$RC"
[ "$(rows_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E9: the fleet-visible rows are the enqueue off-box, got [$(rows_keys)]"
[ -e "$H/logs/READY-QUEUE.log" ] && bad "E9: no file line on a box that does not own the project" || ok

# ── E10: the owning box answers by its fleet name, not `local` -> file line ─
fresh; printf 'TK-25\nPB-26\nPB-27\n' > "$T/children-fixture.txt"
printf '#!/bin/bash\necho box-a\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"
RC=$(run BOX_FOR_ANSWER=box-a)
rm -f "$H/bin/box-name.sh"
[ "$RC" = 0 ] && ok || bad "E10: rc=$RC"
[ "$(file_keys)" = "TK-25 TK-26 TK-27" ] && ok || bad "E10: box-for naming THIS box is local, got [$(file_keys)]"

# ── E7: DEC_FAIL (an unmappable label) -> nothing enqueued ──────────────────
fresh; printf 'TK-4.0\nPB-4.1\nPB-4.9\n' > "$T/children-fixture.txt"
RC=$(run)
[ "$RC" = 1 ] && ok || bad "E7: an unmappable label fails the decompose (rc=$RC)"
[ -s "$T/rows.tsv" ] && bad "E7: a failed re-map must enqueue nothing: $(cat "$T/rows.tsv")" || ok
[ -e "$H/logs/READY-QUEUE.log" ] && bad "E7: a failed re-map must write no file line" || ok

# ── E11: the harness-filed default (switch off) enqueues what it filed ─────
# BH-3965 made the board lane file from children.json through file_children and
# exit there; the enqueue has to run on that path too, with each child's id
# from the filer's children-board.tsv.
fresh; rm -f "$H/flags/decompose-board-filer-off"
printf '%s\n' '[{"title":"contract","contract":"src/a.ts: A","after":[],"body":"Files: src/a.ts\n\n## Observable outcome\ntests/a.sh passes"},{"title":"ingest","after":[],"body":"Files: src/b.ts\n\n## Observable outcome\ntests/b.sh passes"},{"title":"report","after":[],"body":"Files: src/c.ts\n\n## Observable outcome\ntests/c.sh passes"}]' > "$B/children.json"
RC=$(run)
[ "$RC" = 0 ] && ok || bad "E11: rc=$RC: $(cat "$B/decompose-run.txt" "$B/pipeline.log" 2>/dev/null | tail -5)"
[ -s "$T/agent.calls" ] && bad "E11: a spec in the build dir buys no model call" || ok
[ "$(grep -c '^POST .*/api/board/boards/bd-1/tickets' "$T/curl-calls.txt")" = 3 ] && ok \
  || bad "E11: the harness files three children: $(grep '/boards/' "$T/curl-calls.txt")"
[ "$(rows_keys)" = "TK-31 TK-32 TK-33" ] && ok || bad "E11: ready rows for the filed keys, contract first, got [$(rows_keys)]"
[ "$(cut -f3 "$T/rows.tsv" | paste -sd' ')" = "9031 9032 9033" ] && ok \
  || bad "E11: each row's ticket id comes from children-board.tsv, got [$(cut -f3 "$T/rows.tsv" | paste -sd' ')]"
[ "$(file_keys)" = "TK-31 TK-32 TK-33" ] && ok || bad "E11: READY-QUEUE.log holds the 3 keys in order, got [$(file_keys)]"
[ -e "$H/flags/force-triage-x-os" ] && ok || bad "E11: flags/force-triage-x-os must be touched"
grep -q 'enqueued 3 children ready: TK-31,TK-32,TK-33' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "E11: one pipeline.log line names what was enqueued: $(cat "$B/pipeline.log" 2>/dev/null)"
RC=$(run)
[ "$RC" = 0 ] && ok || bad "E11: re-run rc=$RC"
[ "$(rows_keys)" = "TK-31 TK-32 TK-33" ] && ok || bad "E11: re-run must not add rows, got [$(rows_keys)]"
[ "$(file_keys)" = "TK-31 TK-32 TK-33" ] && ok || bad "E11: re-run must not add file lines, got [$(file_keys)]"
touch "$H/flags/decompose-board-filer-off"

# ── E8: issues lane -> run-decompose writes no ready row (orphan-reconcile
#        owns that lane: its children are open ai-build issues) ─────────────
fresh
# Since BH-3954 every child must name its observable outcome, or the decompose
# refuses before the filer and this case would test that refusal instead.
printf '%s\n' '[{"title":"contract","contract":"src/a.ts: A","after":[],"body":"Files: src/a.ts\n\n## Observable outcome\ntests/a.sh passes"},{"title":"tile","after":[1],"body":"Files: src/b.ts\n\n## Observable outcome\ntests/b.sh passes"}]' > "$B/children.json"
printf 'SIZE_VERDICT: over\n' > "$B/size-gate.txt"
( env HARNESS="$H" FLEET_CONF="$H/fleet.conf" AGENT_CALLS="$T/agent.calls" PATH="$T/fakebin:$PATH" \
      JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret READY_QUEUE_ROWS=1 DECOMPOSE_DRY_RUN=1 \
      bash "$DEC" ghproj 552 GH-552 "$B" 300 12 ) >"$T/dec.out" 2>&1
E8RC=$?
grep -q '^DRYRUN gh issue create ' "$T/dec.out" && ok \
  || bad "E8: the issues-lane drive must reach the filer (rc=$E8RC): $(head -c 600 "$T/dec.out")"
[ -s "$T/rows.tsv" ] && bad "E8: the issues lane must not write ready rows: $(cat "$T/rows.tsv")" || ok
[ -e "$H/logs/READY-QUEUE.log" ] && bad "E8: the issues lane must not write READY-QUEUE.log" || ok

echo "decompose-children-enqueued.bh-3970: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
