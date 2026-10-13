#!/usr/bin/env python3
"""tests/evals/capture-fixture.py — freeze ONE real historical triage decision
into a replay fixture under tests/evals/fixtures/.

WHY A SCRIPT AND NOT HAND-WRITING THE JSON. A fixture is only worth what its
provenance is worth. Hand-editing a board payload into a markdown file loses
the one property the eval depends on: that the input is what the triage prompt
ACTUALLY saw. So the capture is mechanical, it records the rule it used, and the
same command re-runs to show its work.

HUB ONLY. It reads the live board APIs with the per-project internal tokens from
/root/harness/env/<project>.env (source them first) — it cannot run in CI and it
is never called by the runner. It writes fixtures; run-evals.sh only reads them.

STATE AT A PAST MOMENT IS REPLAYED, NOT GUESSED. With --as-of, status and
waitingOn come from the ticket's own activity feed (the last status_change /
turn at or before that instant, falling back to the create-time defaults), and
comments newer than that instant are dropped. triageVerdict has no activity row
carrying its value, so the CURRENT verdict is used and the capture REFUSES
unless the ticket was demonstrably triaged before --as-of (a triage activity or
triagedAt). Every one of those choices is written into meta.json.

REDACTION. Emails, avatar URLs, attachment URLs, activity feeds, watcher and
stakeholder ids never reach a fixture: they are not decision inputs, and a
fixture is read by every future eval session. Comment bodies are kept (they ARE
the decision input) but capped, and the whole fixture is scanned for
token-shaped strings before it is written — a hit refuses the capture.

usage:
  capture-fixture.py --project project-1 --key TK-90 --id <dir-name>
                     --expect 'skip' --note '...' [--as-of 2026-08-19T13:59:00Z]
                     [--gate board-changed] [--last 6]
"""
import argparse, json, os, re, subprocess, sys, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")

# Board wiring per project: env var names + API prefix + the client-side turn
# label. Kept here rather than derived, because the prefix already lives in
# fleet.conf and the token names already live in each SOP — this is the third
# place and it is a capture-time convenience, not a runtime dependency.
BOARDS = {
    "project-1":   dict(base="PROJECT_1_API_BASE", tok="PROJECT_1_INTERNAL_API_TOKEN",
                          prefix="/api/board", client="client", detail_root=None),
    "project-2": dict(base="PROJECT_2_APP_BASE", tok="PROJECT_2_INTERNAL_API_TOKEN",
                          prefix="/api/board", client="client", detail_root=None),
    "project-3":       dict(base="PROJECT_3_APP_BASE", tok="PROJECT_3_INTERNAL_API_TOKEN",
                          prefix="/api/feature-board", client="requester", detail_root=None),
    "project-4":       dict(base="PROJECT_4_API_BASE", tok="PROJECT_4_INTERNAL_API_TOKEN",
                          prefix="/api/accounting/requests-board", client="requester",
                          detail_root="ticket"),
}
# Anything that looks like a credential refuses the capture. Deliberately broad:
# a false positive costs one edit, a false negative puts a token in git forever.
SECRETISH = re.compile(
    r"(Bearer\s+[A-Za-z0-9._\-]{12,}|sk-[A-Za-z0-9._\-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}"
    r"|eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}|xox[baprs]-[A-Za-z0-9-]{10,})")
EMAILISH = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")

ACTIONS = {"launch", "queue", "comment", "status", "skip", "defer", "close", "escalate"}


def die(msg):
    sys.stderr.write("capture-fixture: %s\n" % msg)
    raise SystemExit(2)


def api(project, path):
    cfg = BOARDS[project]
    base = os.environ.get(cfg["base"], "")
    tok = os.environ.get(cfg["tok"], "")
    if not base or not tok:
        die("source /root/harness/env/%s.env first (need %s and %s)"
            % (project, cfg["base"], cfg["tok"]))
    url = base.rstrip("/") + cfg["prefix"] + path
    out = subprocess.run(["curl", "-sS", "-m", "60", "-H", "Authorization: Bearer " + tok,
                          "-H", "User-Agent: curl/8", url],
                         capture_output=True, text=True)
    if out.returncode != 0:
        die("curl failed for %s: %s" % (path, out.stderr.strip()[:200]))
    try:
        return json.loads(out.stdout)
    except ValueError:
        die("non-JSON from %s (first 200B: %r) — an error page is NOT a ticket"
            % (path, out.stdout[:200]))


def as_list(payload, key="tickets"):
    return payload.get(key, []) if isinstance(payload, dict) else payload


def ticket_key(t, prefix):
    return t.get("key") or "%s-%s" % (prefix, t.get("number"))


def strip(obj):
    """Drop what a decision never reads and a fixture must not carry."""
    DROP = {"email", "image", "avatarUrl", "mentions", "watcherIds", "watcherCount",
            "watching", "stakeholderIds", "stakeholders", "attachments", "activity",
            "activities", "users", "boardId", "searchText", "assigneeId", "reporterId",
            "editedAt", "deletedAt", "updatedAt", "sortOrder", "ackSlaAlertedAt",
            "staleSlaAlertedAt", "asanaTaskUrl"}
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in obj.items() if k not in DROP}
    if isinstance(obj, list):
        return [strip(v) for v in obj]
    return obj


def state_at(activities, when, client_label):
    """Replay status/waitingOn forward to `when` from the ticket's own activity
    feed. Returns (status, waitingOn, replayed) — replayed=False means the feed
    had nothing at or before `when` and the create-time defaults were used."""
    status, turn, replayed = "todo", "team", False
    for a in sorted(activities, key=lambda x: x.get("createdAt") or ""):
        ts = a.get("createdAt") or ""
        if when and ts > when:
            break
        if a.get("type") == "status_change" and a.get("toValue"):
            status, replayed = a["toValue"], True
        if a.get("type") == "turn" and a.get("toValue"):
            turn, replayed = a["toValue"], True
    return status, turn, replayed


def triaged_before(ticket, activities, comments, when):
    """Did the app's triage agent already rule on this ticket at `when`?

    Three independent witnesses, because no board exposes all three: the
    ticket's own triagedAt, a triage row in the activity feed, or the triage
    agent's comment in the thread. Any one is proof; none means the verdict at
    that instant is unknown and the capture refuses."""
    if not when:
        return True
    if (ticket.get("triagedAt") or "") and ticket["triagedAt"] <= when:
        return True
    if any("triage" in (a.get("type") or "") and (a.get("createdAt") or "") <= when
           for a in activities):
        return True
    return any("[AI Triage]" in (c.get("body") or "") and (c.get("createdAt") or "") <= when
               for c in comments)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True, choices=sorted(BOARDS))
    ap.add_argument("--key", required=True, help="ticket key, e.g. TK-90 / TK-119 / TK-1285")
    ap.add_argument("--id", required=True, help="fixture directory name")
    ap.add_argument("--expect", required=True,
                    help="pipe-separated allowed actions, e.g. 'skip' or 'launch|queue'")
    ap.add_argument("--note", required=True, help="why this decision is the right one")
    ap.add_argument("--as-of", default="", help="freeze the ticket as it stood at this UTC instant")
    ap.add_argument("--gate", default="board-changed")
    ap.add_argument("--last", type=int, default=6, help="how many trailing comments to keep")
    ap.add_argument("--body-cap", type=int, default=1400)
    a = ap.parse_args()

    for act in a.expect.split("|"):
        if act.strip() not in ACTIONS:
            die("'%s' is not a DECISION-log action (%s)" % (act, "|".join(sorted(ACTIONS))))

    cfg = BOARDS[a.project]
    prefix = a.key.split("-")[0]
    boards = as_list(api(a.project, "/boards"), "boards")
    board = next((b for b in boards if (b.get("keyPrefix") or "") == prefix), boards[0])

    rows = as_list(api(a.project, "/boards/%s/tickets" % urllib.parse.quote(str(board["id"]))))
    row = next((t for t in rows if ticket_key(t, prefix) == a.key), None)
    if row is None:
        die("%s is not on %s's board" % (a.key, a.project))

    detail = api(a.project, "/tickets/%s" % urllib.parse.quote(str(row["id"])))
    ticket = detail.get(cfg["detail_root"]) if cfg["detail_root"] else detail
    ticket = dict(ticket)
    activities = detail.get("activity") or detail.get("activities") or []
    users = {u["id"]: u.get("name") for u in detail.get("users", [])}
    comments = detail.get("comments") or []

    if a.as_of and not triaged_before(ticket, activities, comments, a.as_of):
        die("%s shows no triage before %s — its triageVerdict at that instant is unknown, "
            "so an expected verdict here would be a guess. Rejected." % (a.key, a.as_of))

    status, waiting, replayed = state_at(activities, a.as_of, cfg["client"])
    if not a.as_of:                      # capturing the ticket as it stands now
        status, waiting = ticket.get("status"), ticket.get("waitingOn")

    def cauthor(c):
        au = c.get("author")
        if isinstance(au, dict):
            return au.get("name") or "?"
        return users.get(c.get("authorId")) or c.get("authorId") or "?"

    kept = sorted([c for c in comments if not a.as_of or (c.get("createdAt") or "") <= a.as_of],
                  key=lambda c: c.get("createdAt") or "")
    total = len(kept)
    if total > a.last + 1:
        omitted, kept = total - (a.last + 1), [kept[0]] + kept[-a.last:]
    else:
        omitted = 0
    thread = [{"author": cauthor(c), "createdAt": c.get("createdAt"),
               "body": (c.get("body") or "")[:a.body_cap]
                       + ("  …[body truncated by capture]" if len(c.get("body") or "") > a.body_cap else "")}
              for c in kept]

    frozen = strip({k: ticket.get(k) for k in
                    ("key", "number", "title", "description", "priority", "createdAt")})
    frozen["key"] = a.key
    frozen["status"] = status
    frozen["waitingOn"] = waiting
    frozen["triageVerdict"] = ticket.get("triageVerdict")
    frozen["commentCount"] = total
    frozen["comments"] = thread
    if omitted:
        frozen["_thread_note"] = ("%d older comments omitted by board-fetch.sh's trim "
                                  "(first + last %d kept)" % (omitted, a.last))
    listrow = {"key": a.key, "title": ticket.get("title"), "status": status,
               "waitingOn": waiting, "triageVerdict": ticket.get("triageVerdict"),
               "commentCount": total, "priority": row.get("priority")}

    when = a.as_of or (ticket.get("updatedAt") or ticket.get("lastActivityAt") or "")
    inputs = [
        "# Board state — %s, tick at %s" % (a.project, when),
        "",
        "## GET %s/boards" % cfg["prefix"],
        "```json",
        json.dumps([{"id": board["id"], "name": board.get("name"),
                     "keyPrefix": board.get("keyPrefix")}]),
        "```",
        "",
        "## GET %s/boards/%s/tickets" % (cfg["prefix"], board["id"]),
        "(filtered to this tick's scope — the rest of the board did not change and is",
        "omitted from the fixture, exactly as a scoped tick would leave it unread)",
        "```json",
        json.dumps([listrow], indent=1),
        "```",
        "",
        "## GET %s/tickets/%s  (via board-fetch.sh)" % (cfg["prefix"], ticket.get("id", row["id"])),
        "```json",
        json.dumps(frozen, indent=1),
        "```",
        "",
        "## Harness state",
        "```",
        "$ cat /root/harness/flags/build-slots",
        "2",
        # free-slots.sh, not count-builds.sh (2026-09-11): the SOP's launch rule
        # names it, so an orientation that showed the other command would be
        # asking the model to reason from a reading it was never told to take.
        "$ /root/harness/bin/free-slots.sh %s" % a.project,
        "2 (0 build(s) running, 2 box slot(s))",
        "$ cat /root/harness/logs/READY-QUEUE.log",
        "(empty)",
        "$ ls /root/harness/builds/%s-*/RESULT 2>/dev/null" % a.project,
        "(none)",
        "```",
        "",
        "(Harness-side state is NORMALISED to 'idle, slots free' — it was not recorded",
        "per-tick and reconstructing it would be invention. Every fixture here is a",
        "THREAD-driven decision, so an idle harness is the setting in which the recorded",
        "verdict is the only correct one.)",
        "",
    ]
    text = "\n".join(inputs)
    text = EMAILISH.sub("<email redacted>", text)
    hit = SECRETISH.search(text)
    if hit:
        die("token-shaped string in the captured text (%r…) — refusing to write a fixture"
            % hit.group(0)[:12])

    d = os.path.join(FIXTURES, a.id)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "inputs.md"), "w").write(text)
    open(os.path.join(d, "scope.txt"), "w").write(
        'board %s: CHANGED %s "%s" (comments: %d -> %d; activity)\n'
        % (board["id"], ticket.get("number"), (ticket.get("title") or "").replace('"', "'"),
           max(total - 1, 0), total))
    open(os.path.join(d, "expected.txt"), "w").write(
        "# %s\n%s :: %s\n" % (a.note, a.key, a.expect))
    json.dump({
        "gate": a.gate,
        "project": a.project,
        "board_shape": "board-api",
        "verdict_class": a.expect,
        "note": a.note,
        "source": {
            "captured_by": "tests/evals/capture-fixture.py",
            "board_api": cfg["prefix"] + "/tickets/" + str(ticket.get("id", row["id"])),
            "as_of": a.as_of or "current board state at capture",
            "state_at_as_of": ("replayed from the activity feed (status_change / turn rows)"
                               if replayed else
                               "create-time defaults (status=todo, waitingOn=team) — the feed "
                               "holds no transition at or before as_of, so the ticket had not "
                               "moved yet") if a.as_of else "live values at capture",
            "triage_verdict_source": ("current value; ticket proven triaged before as_of"
                                      if a.as_of else "current value"),
            "comments_kept": "first + last %d of %d" % (a.last, total),
            "harness_state": "normalised to idle/slots-free (never recorded per tick)",
            "redaction": "emails, avatars, attachments, activity feeds and ids removed",
        },
    }, open(os.path.join(d, "meta.json"), "w"), indent=1)
    print("wrote %s  (%s :: %s, %d comments kept of %d)"
          % (d, a.key, a.expect, len(thread), total))


if __name__ == "__main__":
    main()
