#!/bin/bash
# bin/gate-diff.sh <project> — deterministic tick scope (context diet, the operator
# 2026-08-20). On a board-changed tick the gate already fetched the new
# fingerprint into state/<p>.gate.pending and kept the consumed one in
# state/<p>.gate.json. Diff them and print one line per moved ticket, so
# run-triage.sh can hand the session an exact reading list instead of letting
# it re-enumerate every board (~85% of triage input tokens were unchanged
# tickets being re-read every tick).
#
# stdout: one line per NEW/CHANGED/REMOVED ticket (both board shapes: in-app
#   {boardId:[tickets]} and GitHub-Issues {issues:[...], prs:[...]} — the prs
#   list is the open harness PRs, added 2026-09-12 so a merge wakes the tick).
# exit 0: a usable, bounded diff was printed.
# exit 2: fingerprints are identical — NO tickets moved (no output). Distinct
#   from failure so queue/sweep scoping (lever 5) can treat "board verified
#   unchanged" as safe-to-scope rather than falling back to full context.
# exit 1 with NO output on anything unusable — missing/unparseable state
#   (incl. the old pre-JSON text fingerprints) or more than MAX_CHANGES moved
#   tickets (a near-full-board diff deserves a full read, and a scope list
#   that long stops being a diet). Callers treat exit 1 as "no scope hint,
#   run with full context" — fail-open, never fail-closed.
set -uo pipefail
PROJECT="${1:?usage: gate-diff.sh <project>}"
HARNESS="${HARNESS:-/root/harness}"
OLD="$HARNESS/state/$PROJECT.gate.json"
NEW="$HARNESS/state/$PROJECT.gate.pending"
[ -s "$OLD" ] && [ -s "$NEW" ] || exit 1

python3 - "$OLD" "$NEW" <<'PYEOF'
import json, sys

MAX_CHANGES = 25

def load(path):
    with open(path, errors="ignore") as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise ValueError("fingerprint is not an object")
    # Normalize both shapes to {board_label: {ticket_key: ticket_dict}}
    out = {}
    if "issues" in d and isinstance(d["issues"], list):
        out["issues"] = {str(t.get("number")): t for t in d["issues"] if isinstance(t, dict)}
        # Open harness PRs (2026-09-12): number, head sha, mergeStateStatus,
        # state — a PR that merges LEAVES this set, so a merge reads as REMOVED.
        if isinstance(d.get("prs"), list):
            out["prs"] = {str(t.get("number")): t for t in d["prs"] if isinstance(t, dict)}
    else:
        for bid, tickets in d.items():
            if not isinstance(tickets, list):
                raise ValueError("board value is not a list")
            out[str(bid)] = {str(t.get("id")): t for t in tickets if isinstance(t, dict)}
    return out

def describe(old, new):
    # Name the fields that moved; unknown/extra fields fall under "changed".
    fields = [("status", "status"), ("state", "state"), ("waitingOn", "waitingOn"),
              ("triageVerdict", "verdict"), ("commentCount", "comments"),
              ("comments", "comments"), ("title", "title"),
              ("mergeStateStatus", "mergeState"), ("headRefOid", "head")]
    parts = []
    for key, label in fields:
        if old.get(key) != new.get(key) and (key in old or key in new):
            parts.append(f"{label}: {old.get(key)} -> {new.get(key)}")
    for key, label in (("lastActivityAt", "activity"), ("updatedAt", "activity")):
        if old.get(key) != new.get(key) and (key in old or key in new):
            parts.append(label)
            break
    return "; ".join(parts) or "changed"

try:
    old, new = load(sys.argv[1]), load(sys.argv[2])
except Exception:
    sys.exit(1)

lines = []
for board in sorted(set(old) | set(new)):
    o, n = old.get(board, {}), new.get(board, {})
    for tid in sorted(set(o) | set(n), key=str):
        if board == "prs":
            # PR rows carry no title; say what a reader needs to act.
            if tid not in o:
                t = n[tid]
                # mergeStateStatus left the fingerprint with BH-782 (REST list
                # responses do not carry it), so printing it here would render a
                # literal "mergeState None" on every new PR. describe() above
                # still maps the key for any fingerprint that predates the
                # change; only this line rendered it unconditionally.
                lines.append(f'board prs: NEW {tid} (open PR #{tid}: state {t.get("state")}, head {str(t.get("headRefOid") or "")[:12]})')
            elif tid not in n:
                lines.append(f'board prs: REMOVED {tid} (PR #{tid} is no longer open — merged or closed; check the issue it was built for and its Blocked-by children)')
            elif o[tid] != n[tid]:
                lines.append(f'board prs: CHANGED {tid} (open PR #{tid}: {describe(o[tid], n[tid])})')
            continue
        if tid not in o:
            t = n[tid]
            lines.append(f'board {board}: NEW {tid} "{t.get("title", "")}"')
        elif tid not in n:
            t = o[tid]
            lines.append(f'board {board}: REMOVED {tid} "{t.get("title", "")}"')
        elif o[tid] != n[tid]:
            lines.append(f'board {board}: CHANGED {tid} "{n[tid].get("title", "")}" ({describe(o[tid], n[tid])})')

if not lines:
    sys.exit(2)
if len(lines) > MAX_CHANGES:
    sys.exit(1)
print("\n".join(lines))
PYEOF
