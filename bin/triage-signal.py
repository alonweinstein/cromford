#!/usr/bin/env python3
"""bin/triage-signal.py --kind inapp|gh — the SIGNAL digest of one ticket thread
(BH-2542).

Reads one ticket thread on stdin and prints 16 hex chars: a hash of only what a
human wrote. bin/lib/triage-signal.sh puts it in place of the ticket's live
board entry in the per-ticket fingerprint, so a change that moved only the
harness's own bookkeeping settles without a triage session.

IN:  title, body/description, status (in-app) or state (GitHub), priority
     (in-app field; GitHub priority labels), the ticket's attachments (in-app,
     by identity: id/name/size, never a signed URL's query string), and every
     comment that is NOT ours as (id, author, body). An edit, a deletion or a
     new comment by anyone else moves the digest.
OUT: labels other than priority ones, assignees, milestone, comment counts,
     every timestamp, waitingOn, triageVerdict, turn, and our own comments.
     A human's waitingOn flip TO the team is not lost: bin/lib/triage-signal.sh
     compares the turn itself (stamp line 4), because the digest cannot tell a
     person's flip from the one our own session writes.

"Ours" is decided by WHO WROTE IT, never by where it sits:
  inapp  the author object's name or userId (or, only when author is not an
         object, the bare author string / authorName) equal (whole string,
         case-insensitive) to one of the comma-separated SELF_ACTORS the gate
         uses for this board or SELF_IDENTITIES, or an author_actor /
         authorActor marker equal to one of those. SELF_IDENTITIES is this
         project's lib.triage-signal[.<p>].triage_signal_self_identities row
         (BH-2604, registry default `agent:build-harness`); unset or empty means
         no identities, so a marker alone is never ours and the key dispatches.
         Never a displayName, nor an authorName beside an
         author object: a human can set either to our actor's name. NOT isInternal: on the project-9 contract
         (docs/board-api.md) isInternal also marks a HUMAN on the delivery team,
         and a note a person typed is exactly the signal this digest exists for
         (PR #2593 review, B1). A comment a machine recorded FOR a person
         (author.recordedBy set) is that person's words and always stays IN.
         THE ONE BODY READ (BH-2604): a comment that would be ours stays IN
         when the first non-blank line of its body (else content, else text)
         starts, after leading whitespace, with `[human]` (any case) or the
         exact `SIGNAL:` — a person's words our actor posted for them — or
         when that same first non-blank line contains, anywhere, the whole
         word `Unblocked` (any case) or `RESUME` (exact upper case): an
         operator's nudge posted as the system actor (BH-3825). Only the first
         line is read, so our own triage prose that says "unblocked once ..."
         further down never re-buys a session. The body only ever moves a
         comment OUT -> IN, never IN -> OUT, so a mistake there costs a
         dispatch, never a lost client turn. gh() never makes this body read.
  gh     the rule of bin/lib/harness-self.sh's hs_ours over SELF_APPS_JSON:
         one of our own Apps. The PAT login and any other bot stay IN.

Input:
  inapp  the raw `bin/board-fetch.sh --full` body: the ticket at the top level,
         under .ticket or under .data, its thread in the ticket's own .comments
         or in a top-level sibling .comments.
  gh     {"issue": <REST issue>, "comments": [<REST comment>, ...]}

Any shape it does not recognise, a comments field that is not a list, a JSON
error, or more than 300 GitHub comments: rc 1 and nothing on stdout. The caller
then dispatches — an unread thread is never "unchanged".
"""
import hashlib
import json
import os
import re
import sys

GH_MAX_COMMENTS = 300
# A comment we posted that relays a person's words opts back IN with one of
# these at the start of its first non-blank line (BH-2604).
HUMAN_MARK = re.compile(r"\[human\]", re.I)
SIGNAL_MARK = "SIGNAL:"
# An operator's nudge posted as our system actor opts back IN with one of these
# as a whole word anywhere in its first non-blank line (BH-3825).
UNBLOCK_MARK = re.compile(r"\bunblocked\b", re.I)
RESUME_MARK = re.compile(r"\bRESUME\b")
# A GitHub board has no priority field; a person sets it with a label. The other
# labels stay OUT (ai-build, needs-info and the like are ours to write).
PRIORITY_LABEL = re.compile(r"^(p[0-4]|priority\b.*|prio\b.*|urgent|critical|sev[0-9: -].*)$")
ATTACHMENT_KEYS = ("id", "name", "filename", "fileName", "size", "mimeType", "contentType")


def fail():
    sys.exit(1)


def low(v):
    return str(v).strip().lower() if v is not None else ""


def attachment_ids(v):
    """The identity of each attachment, sorted: a signed URL re-mints its query
    string on every read and must not move the digest by itself."""
    if not isinstance(v, list):
        return None
    out = []
    for a in v:
        if isinstance(a, dict):
            out.append({k: a.get(k) for k in ATTACHMENT_KEYS if a.get(k) is not None})
        else:
            out.append(str(a).split("?", 1)[0])
    return sorted(out, key=lambda r: json.dumps(r, sort_keys=True))


def relayed(c):
    """True when the first non-blank line of the comment's text starts with
    `[human]` (any case) or the exact `SIGNAL:`, or contains the whole word
    `Unblocked` (any case) or `RESUME` (exact upper case) anywhere in it
    (BH-3825). Later lines are never read. A body that is not a string carries
    no marker."""
    for k in ("body", "content", "text"):
        v = c.get(k)
        if v is None:
            continue
        if not isinstance(v, str):
            return False
        for line in v.splitlines():
            line = line.lstrip()
            if line:
                return (bool(HUMAN_MARK.match(line)) or line.startswith(SIGNAL_MARK)
                        or bool(UNBLOCK_MARK.search(line)) or bool(RESUME_MARK.search(line)))
        return False
    return False


def inapp_ours(c, actors):
    """True only when the AUTHOR is us, and the comment does not open with a
    relay marker. A human quoting our text stays human; a name that merely
    contains ours stays human."""
    a = c.get("author")
    if isinstance(a, dict) and a.get("recordedBy"):
        return False
    marks = [c.get("author_actor"), c.get("authorActor")]
    if isinstance(a, dict):
        marks += [a.get("author_actor"), a.get("authorActor")]
    # The author object's name / userId, or only when there is no object the
    # bare author string / authorName. Never displayName, and never an
    # authorName beside an object: a human can set either to our actor's name.
    ids = [a.get("name"), a.get("userId")] if isinstance(a, dict) else [a, c.get("authorName")]
    if not any(low(n) in actors for n in marks + ids if low(n)):
        return False
    return not relayed(c)


def inapp(doc):
    if not isinstance(doc, dict):
        fail()
    t = doc
    for k in ("ticket", "data"):
        if isinstance(doc.get(k), dict):
            t = doc[k]
            break
    comments = t.get("comments")
    if not isinstance(comments, list):
        comments = doc.get("comments")
    if not isinstance(comments, list):
        fail()
    actors = {low(a) for k in ("SELF_ACTORS", "SELF_IDENTITIES")
              for a in os.environ.get(k, "").split(",") if low(a)}
    out = []
    for c in comments:
        if not isinstance(c, dict):
            fail()
        if inapp_ours(c, actors):
            continue
        a = c.get("author")
        names = [a.get("name"), a.get("displayName"), a.get("userId")] if isinstance(a, dict) else [a]
        names.append(c.get("authorName"))
        out.append([str(c.get("id", "")), [low(n) for n in names],
                    [c.get("body"), c.get("content"), c.get("text")]])
    return {"kind": "inapp", "title": t.get("title"), "description": t.get("description"),
            "body": t.get("body"), "status": t.get("status"), "priority": t.get("priority"),
            "attachments": attachment_ids(t.get("attachments")), "comments": out}


def gh(doc):
    if not isinstance(doc, dict) or not isinstance(doc.get("issue"), dict):
        fail()
    comments = doc.get("comments")
    if not isinstance(comments, list) or len(comments) > GH_MAX_COMMENTS:
        fail()
    try:
        apps = json.loads(os.environ.get("SELF_APPS_JSON") or "[]")
    except ValueError:
        apps = []
    apps = {low(a) for a in apps} if isinstance(apps, list) else set()
    issue = doc["issue"]
    prio = sorted(low(lb.get("name") if isinstance(lb, dict) else lb) for lb in (issue.get("labels") or [])
                  if PRIORITY_LABEL.match(low(lb.get("name") if isinstance(lb, dict) else lb)))
    out = []
    for c in comments:
        if not isinstance(c, dict):
            fail()
        u = c.get("user") if isinstance(c.get("user"), dict) else {}
        login = low(u.get("login") or c.get("author") or "")
        via = c.get("performed_via_github_app")
        slug = low(via.get("slug")) if isinstance(via, dict) else ""
        bare = login[:-5] if login.endswith("[bot]") else login
        isbot = login.endswith("[bot]") or low(u.get("type")) == "bot"
        if (isbot and bare in apps) or (slug and slug in apps):
            continue
        out.append([str(c.get("id", "")), login, c.get("body")])
    return {"kind": "gh", "title": issue.get("title"), "body": issue.get("body"),
            "state": low(issue.get("state")).upper(), "priority": prio, "comments": out}


def main():
    kind = sys.argv[2] if len(sys.argv) == 3 and sys.argv[1] == "--kind" else ""
    if kind not in ("inapp", "gh"):
        fail()
    try:
        doc = json.loads(sys.stdin.read())
    except ValueError:
        fail()
    sig = inapp(doc) if kind == "inapp" else gh(doc)
    sig["comments"].sort(key=lambda r: json.dumps(r, sort_keys=True))
    text = json.dumps(sig, sort_keys=True, separators=(",", ":"))
    print(hashlib.sha256(text.encode()).hexdigest()[:16])


if __name__ == "__main__":
    main()
