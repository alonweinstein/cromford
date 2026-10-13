#!/usr/bin/env python3
# tests/lib/fake-fix-round-worker.bh-2530.py — BH-2674 (BH-2530.3): a
# file-persisted stand-in for the jobs worker, invoked AS `curl`.
#
# A suite puts a two-line shim named `curl` first on PATH:
#   #!/bin/bash
#   FRW_STATE=<dir> exec python3 <this file> "$@"
# and every request bin/lib/jobs/req.sh (_jobs_req) makes lands here. The shim
# is argv-compatible with the one curl call shape req.sh uses (-X, -H,
# --data-binary [@file], -m, --connect-timeout, -w, -sS, then the URL), and
# the answer is printed the way `-w '\n%{http_code}'` prints it: body, newline,
# status.
#
# State lives in $FRW_STATE and survives every process, which is the point: a
# "hub restart" in a suite kills processes and wipes tmp/ and locks/, and the
# rows are still here.
#   rows.json      fix_round_jobs, a list of row objects
#   ledger.json    ledgers, {"<kind>\t<key>": {status, detail}}
#   requests.log   one "<METHOD> <path>" line per request
#   down           present: every request exits 7 (curl's "could not connect")
#   down.<METHOD>  present: only that method's requests exit 7 (the reads
#                  answer, the writes do not)
#   now            optional epoch seconds; the clock stamps are derived from it
#   adopt409       present: every adopt answers 409, as when another tick won
#
# The fix-round routes keep worker/jobs/src/routes/fix-rounds.js semantics: the
# partial unique (project, cap_key) over queued/claimed/done answers a 200
# duplicate, claim is queued -> claimed for the named box, finish is a CAS on
# claimed + claimed_by, adopt a CAS on done; each refusal is a 409, an unknown
# id a 404. The ledger routes are GET (404 when absent) and PUT. Every other
# path is 404, which the jobs client reads as "none", never as an outage.
import json, os, sys, time
from urllib.parse import urlsplit, parse_qs

S = os.environ["FRW_STATE"]
RESULTS = ("done", "terminal", "rebuild-fresh")


def load(name, empty):
    p = os.path.join(S, name)
    return json.load(open(p)) if os.path.exists(p) else empty


def save(name, obj):
    p = os.path.join(S, name)
    with open(p + ".tmp", "w") as f:
        json.dump(obj, f)
    os.replace(p + ".tmp", p)


def now_iso():
    p = os.path.join(S, "now")
    t = int(open(p).read().strip()) if os.path.exists(p) else int(time.time())
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def out(code, obj):
    sys.stdout.write(json.dumps(obj) + "\n" + str(code))
    sys.exit(0)


def result_ok(r):
    if not isinstance(r, str):
        return False
    if r in RESULTS:
        return True
    head, _, tok = r.partition(" ")
    return head in ("setup-blocked", "box-paused") and tok != "" and " " not in tok


method, body, url = "GET", "", ""
a = sys.argv[1:]
i = 0
while i < len(a):
    x = a[i]
    if x == "-X":
        method = a[i + 1]; i += 2
    elif x == "--data-binary":
        body = a[i + 1]; i += 2
    elif x in ("-H", "-m", "--connect-timeout", "-w"):
        i += 2
    elif x.startswith("-"):
        i += 1
    else:
        url = x; i += 1
if body.startswith("@"):
    body = open(body[1:]).read()

os.makedirs(S, exist_ok=True)
if os.path.exists(os.path.join(S, "down")) or os.path.exists(os.path.join(S, "down." + method)):
    sys.exit(7)
u = urlsplit(url)
path, q = u.path, {k: v[0] for k, v in parse_qs(u.query).items()}
with open(os.path.join(S, "requests.log"), "a") as f:
    f.write(f"{method} {path}\n")
b = {}
if body:
    try:
        b = json.loads(body)
    except ValueError:
        out(400, {"error": "body is not json"})
    if not isinstance(b, dict):
        b = {}

rows = load("rows.json", [])
t = now_iso()
OPEN = ("queued", "claimed", "done")

if method == "POST" and path == "/api/fix-rounds":
    args = b.get("args")
    if not (isinstance(args, list) and len(args) == 6 and all(isinstance(x, str) for x in args)):
        out(400, {"error": "args must be an array of exactly 6 strings"})
    for k in ("project", "cap_key", "box"):
        if not isinstance(b.get(k), str) or not b[k]:
            out(400, {"error": f"{k} is required"})
    for r in reversed(rows):
        if r["project"] == b["project"] and r["cap_key"] == b["cap_key"] and r["status"] in OPEN:
            out(200, {"job": r, "duplicate": True, "as_of": t})
    r = {"id": max([x["id"] for x in rows] or [0]) + 1, "project": b["project"],
         "cap_key": b["cap_key"], "box": b["box"], "args": args,
         "record_in": b.get("record_in"), "hotfix": 1 if b.get("hotfix") in (1, True) else 0,
         "status": "queued", "attempt": 0, "claimed_by": None, "claimed_at": None,
         "result": None, "record_out": None, "enqueued_at": t, "updated_at": t,
         "finished_at": None, "adopted_at": None}
    rows.append(r)
    save("rows.json", rows)
    out(201, {"job": r, "duplicate": False, "as_of": t})

if method == "GET" and path == "/api/fix-rounds":
    if "limit" in q and not (q["limit"].isdigit() and 1 <= int(q["limit"]) <= 500):
        out(400, {"error": "limit must be an integer from 1 to 500"})
    lim = int(q.get("limit", "500"))
    sel = [r for r in rows if all(k not in q or r.get(k) == q[k]
                                  for k in ("project", "cap_key", "box", "status"))]
    out(200, {"fix_round_jobs": sel[:lim], "truncated": len(sel) > lim, "as_of": t})

if method == "POST" and path == "/api/fix-rounds/claim":
    for r in rows:
        if r["box"] == b.get("box") and r["status"] == "queued":
            r.update(status="claimed", claimed_by=b["box"], claimed_at=t,
                     attempt=r["attempt"] + 1, updated_at=t)
            save("rows.json", rows)
            out(200, {"job": r, "claimed": True, "as_of": t})
    out(404, {"error": "nothing queued"})

if method == "POST" and path == "/api/fix-rounds/finish":
    if not result_ok(b.get("result")):
        out(400, {"error": "bad result"})
    for r in rows:
        if r["id"] == b.get("id"):
            if r["status"] == "claimed" and r["claimed_by"] == b.get("box"):
                r.update(status="done", result=b["result"], record_out=b.get("record_out"),
                         finished_at=t, updated_at=t)
                save("rows.json", rows)
                out(200, {"job": r, "as_of": t})
            out(409, {"error": f"finish refused: row is {r['status']}", "job": r})
    out(404, {"error": "no such fix round"})

if method == "POST" and path == "/api/fix-rounds/adopt":
    if os.path.exists(os.path.join(S, "adopt409")):
        out(409, {"error": "adopt refused: row is adopted, not done"})
    for r in rows:
        if r["id"] == b.get("id"):
            if r["status"] == "done":
                r.update(status="adopted", adopted_at=t, updated_at=t)
                save("rows.json", rows)
                out(200, {"job": r, "as_of": t})
            out(409, {"error": f"adopt refused: row is {r['status']}, not done", "job": r})
    out(404, {"error": "no such fix round"})

if path == "/api/ledger":
    led = load("ledger.json", {})
    if method == "GET":
        row = led.get(f"{q.get('kind', '')}\t{q.get('key', '')}")
        if row is None:
            out(404, {"error": "not found"})
        out(200, {"ledger": row})
    if method == "PUT":
        k = f"{b.get('kind', '')}\t{b.get('key', '')}"
        row = {"kind": b.get("kind"), "key": b.get("key"), "status": b.get("status"),
               "detail": b.get("detail", (led.get(k) or {}).get("detail", ""))}
        led[k] = row
        save("ledger.json", led)
        out(200, {"ok": True, "ledger": row})

out(404, {"error": "not found"})
