#!/usr/bin/env python3
"""Self-write absorption for the triage gate (cost lever 2, the operator 2026-08-07).

Called by triage-gate.sh when the board fingerprint changed. Decides whether
EVERY change is one of our own writes (system-actor comments bumping
commentCount/lastActivityAt) — those re-triggered a full triage session per
tick and were the single biggest cost on the hub (~60 no-op sessions/day).

Prints exactly one token: ABSORB (all deltas are self-authored comment churn)
or RUN (anything else, including any doubt). FAIL-OPEN: every unexpected shape
or error prints RUN — a wrong ABSORB misses a client, a wrong RUN costs cents.

Env in: GATE_OLD, GATE_NEW (fingerprint JSON files: {boardId: [ticket,...]}),
BASE, BP, TOKEN (board API), SELF_ACTORS (comma-separated author names).
"""
import json
import os
import subprocess
import sys

ABSORB_FIELDS = {"commentCount", "lastActivityAt"}
MAX_CHANGED = 5  # more than this in one tick is real activity — just run


def run(reason=""):
    print("RUN")
    sys.exit(0)


def newest_comment_author(ticket_detail):
    t = ticket_detail.get("ticket", ticket_detail)
    comments = t.get("comments") or []
    # project-9 returns ticket metadata under .ticket but keeps the thread in the
    # sibling top-level .comments array. Prefer nested comments for the board
    # shapes that use them, then fall back to the sibling array.
    if not comments:
        comments = ticket_detail.get("comments") or []
    if not comments:
        return None
    def created(c):
        return c.get("createdAt") or ""
    c = max(comments, key=created)
    a = c.get("author")
    if isinstance(a, dict):
        return a.get("name") or a.get("displayName")
    return a or c.get("authorName")


def main():
    try:
        old = json.load(open(os.environ["GATE_OLD"]))
        new = json.load(open(os.environ["GATE_NEW"]))
        base, bp, token = os.environ["BASE"], os.environ["BP"], os.environ["TOKEN"]
        self_actors = {s.strip() for s in os.environ.get("SELF_ACTORS", "").split(",") if s.strip()}
        if not (isinstance(old, dict) and isinstance(new, dict) and self_actors):
            run()
    except Exception:
        run()

    changed_ids = []
    try:
        if set(old) != set(new):
            run()  # board added/removed
        for bid in new:
            o = {t["id"]: t for t in old[bid]}
            n = {t["id"]: t for t in new[bid]}
            if set(o) != set(n):
                run()  # ticket created or archived — always a session
            for tid, nt in n.items():
                ot = o[tid]
                if ot == nt:
                    continue
                diff_fields = {k for k in nt if nt.get(k) != ot.get(k)}
                if not diff_fields <= ABSORB_FIELDS:
                    run()  # status/turn/verdict/title moved — real work
                changed_ids.append(tid)
    except Exception:
        run()

    if not changed_ids or len(changed_ids) > MAX_CHANGED:
        run()

    for tid in changed_ids:
        try:
            out = subprocess.run(
                ["curl", "-sf", "-m", "20",
                 "-H", f"Authorization: Bearer {token}",
                 "-H", "User-Agent: curl/8",
                 f"{base}{bp}/tickets/{tid}"],
                capture_output=True, timeout=25, check=True)
            author = newest_comment_author(json.loads(out.stdout))
        except Exception:
            run()
        if author not in self_actors:
            run()

    print("ABSORB")


if __name__ == "__main__":
    main()
