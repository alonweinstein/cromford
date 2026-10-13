#!/usr/bin/env python3
"""bin/triage-state-pr.py — the PR half of TRIAGE-STATE's input hashing (BH-3417).

bin/lib/triage-state-pr.sh (ts_pr_precheck) calls both subcommands per `pr-<n>`
key; an rc 1 there reads as "unhashable" (the model decides) / "not a draft".

  pr-hash  --thread F --pr F --reviews F --lead F   the PR's input hash
  pr-draft --title T --head-ref R                   is this PR a Mergify draft
  mergify_state(comments)                           the merge queue's word on a PR

pr-hash's files: --thread is bin/triage-gate.sh --thread's wrap ({kind:"gh",
self_apps, doc:{issue, comments}}), --pr the PR's row from the open-PR list,
--reviews the `pulls/<n>/reviews` array, --lead the lead's standing verdict on
the head (`none`, or vd_standing's verdict, source and id), hashed verbatim.

Doc: docs/notes/2026-09-29-BH-3419-pr-precheck-body.md.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PAYLOAD_RE = re.compile(r"-\*- Mergify Payload -\*-(.*?)-\*- Mergify Payload End -\*-", re.S)


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def newest_key(c):
    """(created_at, int id): the order every "newest comment" here is taken in."""
    try:
        cid = int(c.get("id") or 0)
    except (TypeError, ValueError):
        cid = 0
    return (str(c.get("created_at") or c.get("createdAt") or ""), cid)


def mergify_state(comments):
    """The merge queue's latest state for a PR: the newest mergify[bot] comment
    that carries a Mergify payload block -> that JSON's `state`. None when no
    such comment exists. A payload that does not parse to a dict with a string
    `state` answers `unparseable:<sha256(body)[:16]>`, so a change to it still
    moves the hash."""
    cands = [c for c in comments or [] if isinstance(c, dict)
             and isinstance(c.get("user"), dict) and c["user"].get("login") == "mergify[bot]"
             and isinstance(c.get("body"), str) and PAYLOAD_RE.search(c["body"])]
    if not cands:
        return None
    body = max(cands, key=newest_key)["body"]
    try:
        doc = json.loads(PAYLOAD_RE.search(body).group(1))
    except ValueError:
        doc = None
    if isinstance(doc, dict) and isinstance(doc.get("state"), str):
        return doc["state"]
    return "unparseable:" + hashlib.sha256(body.encode()).hexdigest()[:16]


def signal_module():
    spec = importlib.util.spec_from_file_location("triage_signal", os.path.join(HERE, "triage-signal.py"))
    if spec is None or spec.loader is None:
        sys.exit(1)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        sys.exit(1)


def pr_hash(a):
    wrap, pr, reviews = load(a.thread), load(a.pr), load(a.reviews)
    try:
        with open(a.lead) as f:
            lead = f.read().rstrip("\n")
    except OSError:
        sys.exit(1)
    if not isinstance(wrap, dict) or wrap.get("kind") != "gh" or not isinstance(wrap.get("doc"), dict):
        sys.exit(1)
    if not isinstance(pr, dict) or not isinstance(pr.get("head"), dict) or not isinstance(reviews, list):
        sys.exit(1)
    head = pr["head"].get("sha")
    if not isinstance(head, str) or not head:
        sys.exit(1)
    head = head.lower()
    labels = sorted(str(lb.get("name") if isinstance(lb, dict) else lb) for lb in pr.get("labels") or [])
    latest = {}
    for r in reviews:
        if not isinstance(r, dict) or str(r.get("commit_id") or "").lower() != head:
            continue
        login = str((r.get("user") or {}).get("login") or "")
        k = (str(r.get("submitted_at") or ""), newest_key(r)[1])
        if login not in latest or k >= latest[login][0]:
            latest[login] = (k, str(r.get("state") or ""))
    doc = wrap["doc"]
    # Our own App's comments are dropped by triage-signal.py's gh() filter, the
    # same rule the ticket hash uses. gh() exits 1 on a shape it cannot read.
    os.environ["SELF_APPS_JSON"] = json.dumps(wrap.get("self_apps") or [])
    kept = {str(c[0]) for c in signal_module().gh(doc)["comments"]}
    raw = [c for c in doc.get("comments") or [] if isinstance(c, dict) and str(c.get("id", "")) in kept]
    last = newest_key(max(raw, key=newest_key))[1] if raw else None
    print(hashlib.sha256(canon({
        "v": "pr1", "head": head, "state": "OPEN", "labels": labels,
        "mq": mergify_state(doc.get("comments")),
        "reviews": sorted([k, v[1]] for k, v in latest.items()),
        "lead": lead, "last_comment": last,
    }).encode()).hexdigest())
    return 0


def pr_draft(a):
    return 0 if re.match(r"merge queue: ", a.title) or a.head_ref.startswith("mergify/merge-queue/") else 1


def main(argv=None):
    ap = argparse.ArgumentParser(prog="triage-state-pr.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("pr-hash")
    for a in ("--thread", "--pr", "--reviews", "--lead"):
        h.add_argument(a, required=True)
    d = sub.add_parser("pr-draft")
    d.add_argument("--title", required=True)
    d.add_argument("--head-ref", required=True)
    a = ap.parse_args(argv)
    return pr_hash(a) if a.cmd == "pr-hash" else pr_draft(a)


if __name__ == "__main__":
    sys.exit(main())
