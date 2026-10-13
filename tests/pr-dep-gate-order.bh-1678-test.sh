#!/bin/bash
# tests/pr-dep-gate-order.bh-1678-test.sh — BH-1678 (BH-1669.2): the merge queue
# follows the child ISSUE's `Blocked-by:` and `Order: n of m`, not only the PR
# body's `Depends on`.
#
# THE INCIDENT. The 2026-09-23 project-5 wave queued contract #3215 beside the
# children that edit the same registry files: the decomposer writes
# `Blocked-by: #N` / `Part of #P` / `Order: n of m` on the child issue, and
# pdg_hold only read the PR body.
#
# Driven, not grepped. §1 and §3-§5 run the conductor's READY arm — the
# `# >>> dep gate` block lifted VERBATIM from bin/merge-conductor.sh — against
# the REAL bin/lib/pr-dep-gate.sh sourced through merge-conductor-lib.sh, with a
# fake gh that answers REST paths from JSON fixtures through real jq (the `-q`
# expression the lib sends is the one evaluated). A fall-through calls a fake
# mc_enqueue, which is the only thing that writes merges.txt.
#
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-dep-gate-order.bh-1678-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
APPSLUG=example-org/app-os
FX="$T/fx"
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state/merge-conductor" "$T/h/flags" "$T/fakebin" "$FX"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/pr-dep-gate.sh" "$DIR/bin/lib/block-gate.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
# demo-os is a GitHub-Issues board (board_prefix `-`); app-os has an in-app board.
printf 'demo-os %s - - 2 box-demo\napp-os %s https://app.example /api/board 3 box-app\n' "$SLUG" "$APPSLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"

# The fake gh: `gh api [--paginate] <path> [-q <jq>]`, answered from $FX through
# real jq. A missing fixture is a 404, a `fail-<name>` marker a 502. gh_rest's
# shape, `gh api -i -X GET <path>` (BH-1735: the gate's issue and PR reads go
# through it), gets the same answers as a whole HTTP response.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHCALLS"
[ "${1:-}" = api ] || exit 1; shift
path=""; q=""; rest=0
while [ $# -gt 0 ]; do
  case "$1" in --paginate) ;; -i) rest=1 ;; -X) shift ;; -q|--jq) q="$2"; shift ;; *) path="$1" ;; esac
  shift
done
case "$path" in
  repos/*/pulls\?*)  f=pulls-list ;;
  repos/*/issues\?*) f=issues-list ;;
  repos/*/pulls/*)   f="pull-${path##*/}" ;;
  repos/*/issues/*)  f="issue-${path##*/}" ;;
  *) exit 1 ;;
esac
if [ "$rest" = 1 ]; then
  [ -e "$GHFX/fail-$f" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{"message":"Bad Gateway"}'; exit 1; }
  [ -f "$GHFX/$f.json" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 1; }
  printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$GHFX/$f.json"; exit 0
fi
[ -e "$GHFX/fail-$f" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
[ -f "$GHFX/$f.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$q" ]; then jq -r "$q" "$GHFX/$f.json" || exit 1; else cat "$GHFX/$f.json"; fi
EOF
chmod +x "$T/fakebin/gh"
export GHFX="$FX" GHCALLS="$T/gh-calls.txt"

issue() { # issue <n> <open|closed> <body>
  jq -n --argjson n "$1" --arg s "$2" --arg b "$3" \
    '{number:$n, state:$s, body:$b, labels:[{name:"ai-build"}]}' > "$FX/issue-$1.json"
}
pull() { # pull <n> <head-ref> <body>
  jq -n --argjson n "$1" --arg r "$2" --arg b "$3" \
    '{number:$n, state:"open", head:{ref:$r}, body:$b}' > "$FX/pull-$1.json"
}
issues_list() { # issues_list <n>... — the OPEN ai-build list is those issue fixtures (plus one PR entry)
  local n
  { for n in "$@"; do cat "$FX/issue-$n.json"; done
    printf '{"number":999,"state":"open","body":"Part of #9\\nOrder: 1 of 2","pull_request":{"url":"x"}}\n'
  } | jq -s . > "$FX/issues-list.json"
}
pulls_list() { # pulls_list <n>...
  local n
  for n in "$@"; do cat "$FX/pull-$n.json"; done | jq -s . > "$FX/pulls-list.json"
}
row() { # row <pr> <state> — the conductor's own row, as mc_row_put writes it
  printf '%s\t%s\t0\thead\t-\t-\t-\thttps://github.com/%s/pull/%s\n' "$SLUG#$1" "$2" "$SLUG" "$1" > "$ROWS"
}
reset_fx() { rm -f "$FX"/*; : > "$ROWS"; : > "$GHCALLS"; : > "$T/merges.txt"; rm -f "$T/h/logs/"*.log "$T/h/state/merge-conductor/attempts.txt"; }
calls_to() { grep -c -- "$1" "$GHCALLS" 2>/dev/null || true; }

# ── The conductor READY arm, verbatim ───────────────────────────────────────
awk '/^      # >>> dep gate/{f=1;next} /^      # <<< dep gate/{exit} f' \
  "$DIR/bin/merge-conductor.sh" > "$T/dep-conductor.sh"
[ -s "$T/dep-conductor.sh" ] && ok || bad "could not extract the conductor's dep gate — markers missing?"
# Wrapped in a function because the block ends its hold arms with `return 0`;
# falling through reaches the enqueue, which is what the READY arm does next.
{ printf 'arm() {\n'; cat "$T/dep-conductor.sh"; printf '  mc_enqueue\n}\n'; } > "$T/conductor-arm.sh"
CLOG="$T/h/logs/merge-conductor.log"

conductor() { # conductor <pr> <head> [VAR=val...]
  local pr="$1" head="$2"; shift 2
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
      SLUG="$SLUG" NUM="$pr" URL="https://github.com/$SLUG/pull/$pr" KEY="$SLUG#$pr" HEAD="$head" \
      MSINK="$T/merges.txt" "$@" \
      bash -c 'set -uo pipefail
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        mc_transition() { :; }
        mc_enqueue() { printf "enqueue %s\n" "$KEY" >> "$MSINK"; }
        mc_merge()   { printf "merge %s\n" "$KEY" >> "$MSINK"; }
        . "$1"
        arm' bash "$T/conductor-arm.sh" 2>>"$T/conductor.err" )
}
enqueued() { grep -c "^enqueue $SLUG#$1\$" "$T/merges.txt" 2>/dev/null || true; }

# pdg <code> [VAR=val...] — the lib in a fresh `bash -u`, as every lane has it.
RC=0; OUT=""
pdg() {
  local code="$1"; shift
  OUT=$(cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" "$@" bash -u -c \
        ". \"\$HARNESS/bin/lib/merge-conductor-lib.sh\"; $code" 2>"$T/pdg.err")
  RC=$?
}
PLOG="$T/h/logs/pr-dep-gate.log"

# ══ §1. Blocked-by: #50 on the child issue holds the READY PR ════════════════
reset_fx
issue 41 open "$(printf 'Blocked-by: #50\nPart of #9\nOrder: 1 of 2')"
issue 50 open "the contract"
pull 101 ticket/demo-41 "$(printf 'What changed.\n\nCloses #41')"
issues_list 41; pulls_list 101; row 101 READY
conductor 101 h1
grep -q "HELD by the PR-dependency gate" "$CLOG" && ok || bad "§1 open-parent: the conductor log must say HELD by the PR-dependency gate (log: $(cat "$CLOG" 2>/dev/null) err: $(cat "$T/conductor.err"))"
grep -q "Blocked-by #50" "$CLOG" && ok || bad "§1 open-parent: the conductor log must name Blocked-by #50 (log: $(cat "$CLOG" 2>/dev/null))"
[ -s "$T/merges.txt" ] && bad "§1 open-parent: THE DEFECT — enqueued/merged beside an open Blocked-by parent ($(cat "$T/merges.txt"))" || ok
grep -q "Blocked-by #50 (issue #41) — HOLD" "$PLOG" && ok || bad "§1 open-parent: the gate's own log must name the parent and the issue (log: $(cat "$PLOG" 2>/dev/null))"
[ "$(wc -l < "$PLOG" | tr -d ' ')" = 1 ] && ok || bad "§1 open-parent: pdg_hold writes exactly one log line per call (got $(cat "$PLOG"))"
[ "$(calls_to 'issues?state=open')" = 0 ] && ok || bad "§1 open-parent: Order: 1 must never read the sibling list ($(cat "$GHCALLS"))"

issue 50 closed "the contract"
conductor 101 h2
[ "$(enqueued 101)" = 1 ] && ok || bad "§1 closed-parent: #50 closed must enqueue exactly once (merges: $(cat "$T/merges.txt") err: $(cat "$T/conductor.err"))"
grep -q "Blocked-by closed #50" "$PLOG" && ok || bad "§1 closed-parent: the pass line names the closed parent (log: $(cat "$PLOG"))"

# The reader itself.
issue 50 open "the contract"
pdg 'pdg_ticket_deps example-org/demo-os 41'
[ "$RC" = 0 ] && [ "$OUT" = 50 ] && ok || bad "§1 reader: pdg_ticket_deps must print 50 with rc 0 (rc=$RC out=[$OUT] err=$(cat "$T/pdg.err"))"
issue 41 open "$(printf 'Intro.\r\n**Blocked-by:** #50\r\nBlocked-by #51, #52\r\nblocked-by: #50 (hard)\r\nBlocked-by: #41\r\nsee #70\r\n')"
pdg 'pdg_ticket_deps example-org/demo-os 41'
[ "$RC" = 0 ] && [ "$OUT" = "$(printf '50\n51\n52')" ] && ok || bad "§1 reader: bold, comma list, CRLF, dedupe and self-reference (want 50 51 52, got rc=$RC out=[$OUT])"
issue 41 open "no declaration here"
pdg 'pdg_ticket_deps example-org/demo-os 41'
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "§1 reader: no Blocked-by line prints nothing with rc 0 (rc=$RC out=[$OUT])"
: > "$FX/fail-issue-41"
pdg 'pdg_ticket_deps example-org/demo-os 41'
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "§1 reader: an unreadable issue answers rc 2 and prints nothing (rc=$RC out=[$OUT])"
: > "$PLOG"
pdg 'pdg_hold example-org/demo-os 101 https://github.com/example-org/demo-os/pull/101 ""'
[ "$RC" = 2 ] && ok || bad "§1 unreadable: pdg_hold must answer rc 2 when the linked issue cannot be read (rc=$RC)"
grep -q "could not read.*issue #41" "$PLOG" && ok || bad "§1 unreadable: the log must say it could not read issue #41 (log: $(cat "$PLOG"))"
rm -f "$FX/fail-issue-41"

# ══ §1b. a partial build says `Refs #N` (BH-5798): the ticket half still runs ══
# bin/lib/rb/pr.sh writes `Refs #N` instead of `Closes #N` when an acceptance
# claim is REFUTED. The linked issue is the same ticket, so its Blocked-by holds.
reset_fx
issue 41 open "$(printf 'Blocked-by: #50\nPart of #9\nOrder: 1 of 2')"
issue 50 open "the contract"
: > "$PLOG"
pdg 'pdg_hold "$S" 101 https://github.com/x/pull/101 "$B"' S="$SLUG" B="$(printf 'What changed.\n\nRefs #41\n\n## Acceptance self-check\n- [ ] claim 2 (not met)')"
[ "$RC" = 0 ] && ok || bad "§1b refs: a Refs #41 body must HOLD on issue #41's open Blocked-by #50 (rc=$RC log: $(cat "$PLOG") err: $(cat "$T/pdg.err"))"
grep -q "Blocked-by #50 (issue #41) — HOLD" "$PLOG" && ok || bad "§1b refs: the gate log must name the parent and issue #41 (log: $(cat "$PLOG"))"
pdg '_pdg_linked_issue "$B"' B="$(printf 'Refs #9\nCloses #41\n')"
[ "$OUT" = 41 ] && ok || bad "§1b refs: a Closes line wins over an earlier Refs line (got [$OUT])"
pdg '_pdg_linked_issue "$B"' B="$(printf '> Refs #41\n')"
[ -z "$OUT" ] && ok || bad "§1b refs: a quoted Refs is not a link (got [$OUT])"

# ══ §2. negatives: none of these holds (rc 1) ════════════════════════════════
neg() { # neg <name> <issue-41 body> [pr body] [slug]
  local name="$1" ib="$2" pb="${3:-Closes #41}" slug="${4:-$SLUG}"
  issue 41 open "$ib"; issue 50 open "the contract"; : > "$GHCALLS"; : > "$PLOG"
  pdg 'pdg_hold "$S" 101 https://github.com/x/pull/101 "$B"' S="$slug" B="$pb"
  [ "$RC" = 1 ] && ok || bad "§2 $name: must pass, not hold (rc=$RC out=[$OUT] log: $(cat "$PLOG") err: $(cat "$T/pdg.err"))"
  [ "$(wc -l < "$PLOG" | tr -d ' ')" = 1 ] && ok || bad "§2 $name: exactly one log line (got $(cat "$PLOG"))"
}
reset_fx
neg quoted        "$(printf 'Intro\n> Blocked-by: #50\n')"
neg fenced        "$(printf 'Intro\n```\nBlocked-by: #50\n```\n')"
neg inline-code   "$(printf 'Write it as `Blocked-by: #50` on the child.\n')"
neg prose         "$(printf 'This is not Blocked-by: #50 at all.\n')"
issue 50 closed x
issue 41 open "Blocked-by: #50"; : > "$PLOG"
pdg 'pdg_hold "$S" 101 u "Closes #41"' S="$SLUG"
[ "$RC" = 1 ] && ok || bad "§2 closed-parent: #50 closed passes (rc=$RC log: $(cat "$PLOG"))"
neg no-closes-line "Blocked-by: #50" "$(printf 'What changed, no link.\n')"
[ "$(calls_to 'issues/41')" = 0 ] && ok || bad "§2 no-closes-line: no linked issue means zero issue reads ($(cat "$GHCALLS"))"
neg closes-in-fence "Blocked-by: #50" "$(printf '```\nCloses #41\n```\n')"
[ "$(calls_to 'issues/41')" = 0 ] && ok || bad "§2 closes-in-fence: a fenced Closes is not a link ($(cat "$GHCALLS"))"
neg quoted-closes "Blocked-by: #50" "$(printf '> Closes #41\n')"
[ "$(calls_to 'issues/41')" = 0 ] && ok || bad "§2 quoted-closes: a quoted Closes is not a link ($(cat "$GHCALLS"))"
neg pr-body-blocked-by "no declaration" "$(printf 'Blocked-by: #50\n')"
[ "$(calls_to 'issues/50')" = 0 ] && ok || bad "§2 pr-body-blocked-by: Blocked-by in the PR body is never read ($(cat "$GHCALLS"))"
neg in-app-board "Blocked-by: #50" "Closes #41" "$APPSLUG"
[ "$(calls_to 'issues/')" = 0 ] && ok || bad "§2 in-app-board: an in-app board makes zero issue reads ($(cat "$GHCALLS"))"
neg unknown-slug "Blocked-by: #50" "Closes #41" "example-org/nobody"
[ "$(calls_to 'issues/')" = 0 ] && ok || bad "§2 unknown-slug: a slug fleet.conf does not know makes zero issue reads ($(cat "$GHCALLS"))"
# Order: 1 of 5 never reads the sibling lists.
neg order-one "$(printf 'Part of #9\nOrder: 1 of 5\n')"
[ "$(calls_to 'state=open')" = 0 ] && ok || bad "§2 order-one: Order 1 makes zero list reads ($(cat "$GHCALLS"))"

# ══ §3. Order: a lower sibling READY or QUEUED holds the higher one ══════════
order_fx() {
  reset_fx
  issue 41 open "$(printf 'Part of #9\nOrder: 1 of 2\n')"
  issue 42 open "$(printf 'Part of #9\nOrder: 2 of 2\n')"
  pull 101 ticket/demo-41 "Closes #41"
  pull 102 ticket/demo-42 "Closes #42"
  issues_list 41 42; pulls_list 101 102
}
order_fx; row 101 READY
conductor 101 a1
conductor 102 b1
[ "$(enqueued 101)" = 1 ] && ok || bad "§3 both-ready: Order 1 must be enqueued (merges: $(cat "$T/merges.txt") err: $(cat "$T/conductor.err"))"
[ "$(enqueued 102)" = 0 ] && ok || bad "§3 both-ready: Order 2 must be held behind a READY Order 1 ($(cat "$T/merges.txt"))"
grep -q "Order 2 behind #41 (PR #101 READY)" "$CLOG" && ok || bad "§3 both-ready: the conductor log names the lower sibling (log: $(cat "$CLOG"))"
[ "$(calls_to 'issues?state=open')" = 1 ] && [ "$(calls_to 'pulls?state=open')" = 1 ] && ok \
  || bad "§3 both-ready: one sibling list and one pulls list read, and only for Order 2 ($(cat "$GHCALLS"))"
[ "$(calls_to 'pr-state')" = 0 ] && ok || bad "§3 both-ready: the row is read locally, never over the API"

row 101 QUEUED; : > "$T/merges.txt"
conductor 102 b2
[ "$(enqueued 102)" = 0 ] && ok || bad "§3 queued: Order 2 still held behind a QUEUED Order 1 ($(cat "$T/merges.txt"))"
grep -q "Order 2 behind #41 (PR #101 QUEUED)" "$CLOG" && ok || bad "§3 queued: the log names the QUEUED sibling (log: $(cat "$CLOG"))"

# Matched by the PR body's Closes line when the branch is not the harness's.
pull 101 feature/hand-made "$(printf 'Closes #41\n')"; pulls_list 101 102; : > "$T/merges.txt"
conductor 102 b3
[ "$(enqueued 102)" = 0 ] && ok || bad "§3 closes-match: a lower sibling's PR found by its Closes line holds too ($(cat "$T/merges.txt"))"
# Matched by the retry branch alone.
pull 101 ticket/demo-41-r2 "no link"; pulls_list 101 102; : > "$T/merges.txt"
conductor 102 b4
[ "$(enqueued 102)" = 0 ] && ok || bad "§3 branch-match: ticket/<key>-41-r2 is Order 1's PR ($(cat "$T/merges.txt"))"

# Order 1 MERGED: its PR leaves the open list and its issue closes.
issue 41 closed "$(printf 'Part of #9\nOrder: 1 of 2\n')"; issues_list 42; pulls_list 102
row 101 QUEUED; : > "$T/merges.txt"
conductor 102 b5
[ "$(enqueued 102)" = 1 ] && ok || bad "§3 merged: Order 2 is enqueued once Order 1 merged (merges: $(cat "$T/merges.txt") log: $(cat "$PLOG"))"

# A failed sibling read fails closed (rc 2), and is not a pass.
order_fx; row 101 READY; : > "$FX/fail-issues-list"
pdg 'pdg_hold "$S" 102 u ""' S="$SLUG"
[ "$RC" = 2 ] && ok || bad "§3 list-unreadable: a failed sibling list read is rc 2 (rc=$RC log: $(cat "$PLOG"))"
order_fx; row 101 READY; : > "$FX/fail-pulls-list"
pdg 'pdg_hold "$S" 102 u ""' S="$SLUG"
[ "$RC" = 2 ] && ok || bad "§3 pulls-unreadable: a failed pulls list read is rc 2 (rc=$RC log: $(cat "$PLOG"))"

# ══ §4. a stuck lower sibling does not freeze the wave ═══════════════════════
for st in BLOCKED_AGENT WAIT_CI MISSING; do
  order_fx
  [ "$st" = MISSING ] || row 101 "$st"
  conductor 102 "c-$st"
  [ "$(enqueued 102)" = 1 ] && ok || bad "§4 $st: Order 2 must be enqueued past a $st Order 1 (merges: $(cat "$T/merges.txt") log: $(cat "$PLOG"))"
done
# Lower sibling of a DIFFERENT parent, and a sibling whose Order is only quoted.
order_fx; row 101 READY
issue 41 open "$(printf 'Part of #8\nOrder: 1 of 2\n')"; issues_list 41 42
conductor 102 d1
[ "$(enqueued 102)" = 1 ] && ok || bad "§4 other-parent: a sibling of #8 never holds a child of #9 ($(cat "$T/merges.txt"))"
order_fx; row 101 READY
issue 41 open "$(printf 'Part of #9\n> Order: 1 of 2\n')"; issues_list 41 42
conductor 102 d2
[ "$(enqueued 102)" = 1 ] && ok || bad "§4 quoted-order: a quoted Order line is not an order ($(cat "$T/merges.txt"))"
# Only a LOWER Order holds: a READY sibling at the same Order, or a higher one,
# never holds this child (the check can only ever hold the higher of two).
order_fx
issue 43 open "$(printf 'Part of #9\nOrder: 2 of 3\n')"; issue 44 open "$(printf 'Part of #9\nOrder: 3 of 3\n')"
pull 103 ticket/demo-43 "Closes #43"; pull 104 ticket/demo-44 "Closes #44"
issues_list 42 43 44; pulls_list 102 103 104
printf '%s\tREADY\t0\th\t-\t-\t-\tu\n%s\tQUEUED\t0\th\t-\t-\t-\tu\n' "$SLUG#103" "$SLUG#104" > "$ROWS"
conductor 102 d0
[ "$(enqueued 102)" = 1 ] && ok || bad "§4 same-or-higher: a READY same-Order or higher-Order sibling never holds (merges: $(cat "$T/merges.txt") log: $(cat "$PLOG"))"
# The lower sibling's PR is not open (no PR in the list): nothing to wait on.
order_fx; row 101 READY; pulls_list 102
conductor 102 d3
[ "$(enqueued 102)" = 1 ] && ok || bad "§4 no-open-pr: a lower sibling with no open PR does not hold ($(cat "$T/merges.txt"))"

# ══ §5. PR_DEP_GATE_TICKET=0 is today's body-only gate ══════════════════════
reset_fx
issue 41 open "$(printf 'Blocked-by: #50\nPart of #9\nOrder: 2 of 2')"
issue 50 open "the contract"
pull 101 ticket/demo-41 "Closes #41"
issues_list 41; pulls_list 101
conductor 101 e1 PR_DEP_GATE_TICKET=0
[ "$(enqueued 101)" = 1 ] && ok || bad "§5 flag-off: PR_DEP_GATE_TICKET=0 enqueues with #50 open (merges: $(cat "$T/merges.txt"))"
[ "$(calls_to 'issues/41')" = 0 ] && [ "$(calls_to 'state=open')" = 0 ] && ok || bad "§5 flag-off: zero issue and list reads ($(cat "$GHCALLS"))"
: > "$T/merges.txt"
conductor 101 e2
[ "$(enqueued 101)" = 0 ] && ok || bad "§5 flag-on: the same fixture with the flag unset holds ($(cat "$T/merges.txt"))"

echo "pr-dep-gate-order.bh-1678: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
