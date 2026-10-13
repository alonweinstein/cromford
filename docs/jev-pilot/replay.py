#!/usr/bin/env python3
"""BH-5024 replay pilot: ask Jev and a Haiku baseline about every PR the lead
judged since a date, and write one row per PR to <out>/replay.jsonl.

usage:
  replay.py --repo <owner/repo> --since <YYYY-MM-DD> --out <dir>
            [--harness <H>] [--limit N] [--dry-run --fixtures <dir>]

Real run (spends money, the hub only):
  1. PRs updated since --since: gh api repos/<r>/pulls?state=all&sort=updated
     (paged by hand, stops at the first PR older than --since).
  2. GET /api/verdicts?repo=&pr= through bin/jobs-client.sh (_jobs_req), so the
     bearer stays inside bash and is never seen or printed here.
  3. A PR is kept when it has a source=lead row, verdict MERGE,
     MERGE-WITH-NOTES (counts as MERGE) or BLOCK, created_at >= --since. The
     newest such row is the label and its head_sha is the head replayed.
  4. gh api repos/<r>/compare/<base>...<head> cached in <out>/cmp/ (never
     fetched twice), rule tier from bin/lib/risk-tier.sh rt_classify.
  5. Jev: JEV_CALLER=pilot bin/jev-risk.sh ask (one ledger with the shadow, so
     a head already asked is never paid twice).
  6. Haiku: the model from lane_model JEV_BASELINE_MODEL jev-pilot.baseline
     (rc 75 stops the run), the same question text from bin/jev-risk.sh
     question, through bin/agent-call.sh with AGENT_CALL_NO_TOOLS=1 and
     AGENT_CALL_RUNNERS=claude (no tools, claude only; a refusal, rc 78, stops
     the run). Each answer is cached in
     <out>/haiku.jsonl keyed repo|pr|head|qv|model before the next PR, and a
     cached answer is never asked again.

A PR it cannot read is still a row, with skip_reason set, and is counted.
Rerun is resumable: a settled row (no skip_reason) is never redone; a skipped
row is dropped and retried. A Jev `failed` answer is a skip row ("jev failed"),
so a rerun asks again until the ledger answers attempt_cap.

--dry-run --fixtures <dir> reads everything from <dir> and never runs gh,
curl, bin/jev-risk.sh or bin/agent-call.sh:
  prs.json            list of GitHub pull objects (number, updated_at,
                      base.sha); the order does not matter
  verdicts/<pr>.json  the /api/verdicts answer {rows, truncated}; absent =
                      unreadable
  cmp/<pr>.json       the compare JSON; absent = unreadable
  rule/<pr>.txt       the rt_classify line <tier>\t<reasons>\t<lines>\t<files>
  jev/<pr>.json       {"rc": <int>, "out": "<the ask TSV line>"}
  haiku/<pr>.json     {"rc": <int>, "out": "<the model's raw answer text>"}
  model.txt           the baseline model name (default "fixture-model")
  question.txt        the question text (default a fixed fixture line)

Exit: 0 done, 1 bad arguments or an unreadable PR list, 3 stopped because
nothing is configured (jev-risk rc 3 or no baseline model route, rc 75) or
agent-call refused the no-tools baseline call (rc 78).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

QV = "v1"  # question version: part of the Haiku cache key
KEEP = {"MERGE": "MERGE", "MERGE-WITH-NOTES": "MERGE", "BLOCK": "BLOCK"}
TIERS = ("low", "medium", "high")
# bin/agent-call.sh: AGENT_CALL_NO_TOOLS=1 runs claude with every tool off, and
# AGENT_CALL_RUNNERS=claude keeps the survival ladder off the runners that have
# no verified tool-disable flag. A refusal anyway is rc 78 and stops the run.
NO_TOOLS_ENV = {"AGENT_CALL_RUNNERS": "claude", "AGENT_CALL_NO_TOOLS": "1"}
REFUSED_RC = 78
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HAIKU_INSTRUCTION = (
    "\n\nAnswer with one JSON object and nothing else: "
    '{"choice":"low|medium|high","probability":<0..1>}'
)


class Stop(Exception):
    """Nothing is configured: end the whole run."""


def die(msg, rc=1):
    print("replay: " + msg, file=sys.stderr)
    sys.exit(rc)


def run(argv, env=None, timeout=600):
    """(rc, stdout) of a command; rc 127 when it cannot start."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           env=env, timeout=timeout, check=False)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


class Fixtures:
    """--dry-run source: every answer comes from the fixture dir."""

    def __init__(self, d):
        self.d = d

    def _p(self, *parts):
        return os.path.join(self.d, *parts)

    def prs(self, repo, since):
        v = read_json(self._p("prs.json"))
        if not isinstance(v, list):
            return None
        return [p for p in v if isinstance(p, dict) and str(p.get("updated_at") or "") >= since]

    def verdicts(self, repo, pr):
        return read_json(self._p("verdicts", "%d.json" % pr))

    def compare(self, repo, base, head, dest):
        v = read_json(self._p("cmp", "%d.json" % pr_of(dest)))
        return v

    def rule(self, cmp_path, repo, pr):
        t = read_text(self._p("rule", "%d.txt" % pr))
        return (0, t) if t is not None else (1, "")

    def question(self, rule_tier, cmp_path, pr):
        t = read_text(self._p("question.txt"))
        return (0, t if t is not None else "fixture question for PR %d (rule tier %s)" % (pr, rule_tier))

    def ask(self, repo, pr, head, rule_tier, cmp_path):
        v = read_json(self._p("jev", "%d.json" % pr))
        if not isinstance(v, dict):
            return 1, "failed\t-\t-\t%s\tno fixture" % rule_tier
        return int(v.get("rc", 0)), str(v.get("out", ""))

    def model(self):
        t = read_text(self._p("model.txt"))
        return (t or "fixture-model").strip()

    def haiku(self, model, prompt_file, out_file, pr):
        v = read_json(self._p("haiku", "%d.json" % pr))
        if not isinstance(v, dict):
            return 1
        with open(out_file, "w", encoding="utf-8") as f:
            f.write(str(v.get("out", "")))
        return int(v.get("rc", 0))


class Live:
    """The real path: gh, the jobs worker, bin/jev-risk.sh, bin/agent-call.sh."""

    def __init__(self, h):
        self.h = h
        self.env = dict(os.environ, HARNESS=h, H=h)

    def _gh(self, path):
        rc, out = run(["gh", "api", path], env=self.env, timeout=120)
        if rc != 0:
            return None
        try:
            return json.loads(out)
        except ValueError:
            return None

    def prs(self, repo, since):
        got, page = [], 1
        while True:
            v = self._gh("repos/%s/pulls?state=all&sort=updated&direction=desc&per_page=100&page=%d"
                         % (repo, page))
            if not isinstance(v, list):
                return None if page == 1 else got
            for p in v:
                if str(p.get("updated_at") or "") < since:
                    return got
                got.append(p)
            if len(v) < 100:
                return got
            page += 1

    def verdicts(self, repo, pr):
        rc, out = run(["bash", "-c",
                       '. "$H/bin/jobs-client.sh" >/dev/null 2>&1 || exit 9; '
                       'JOBS_ALERT=0 _jobs_req GET "$1" 2>/dev/null', "_",
                       "/api/verdicts?repo=%s&pr=%d" % (repo, pr)], env=self.env, timeout=120)
        if rc != 0:
            return None
        try:
            return json.loads(out)
        except ValueError:
            return None

    def compare(self, repo, base, head, dest):
        return self._gh("repos/%s/compare/%s...%s" % (repo, base, head))

    def rule(self, cmp_path, repo, pr):
        return run(["bash", "-c",
                    '. "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/risk-tier.sh" || exit 9; '
                    'rt_classify "$1" "$2"', "_", cmp_path, repo], env=self.env, timeout=120)

    def question(self, rule_tier, cmp_path, pr):
        return run([os.path.join(self.h, "bin", "jev-risk.sh"), "question", rule_tier, cmp_path],
                   env=self.env, timeout=120)

    def ask(self, repo, pr, head, rule_tier, cmp_path):
        env = dict(self.env, JEV_CALLER="pilot")
        return run([os.path.join(self.h, "bin", "jev-risk.sh"), "ask", repo, str(pr), head,
                    rule_tier, cmp_path], env=env, timeout=900)

    def model(self):
        rc, out = run(["bash", "-c",
                       '. "$H/bin/lib/lane-model.sh" || exit 75; '
                       'lane_model JEV_BASELINE_MODEL jev-pilot.baseline'], env=self.env, timeout=60)
        m = out.strip().splitlines()[0].strip() if out.strip() else ""
        if rc != 0 or not m:
            raise Stop("no baseline model route (lane_model jev-pilot.baseline rc %d)" % rc)
        return m

    def haiku(self, model, prompt_file, out_file, pr):
        # A decision-only call over untrusted diff text: no tools, and pinned to
        # the claude rung (the watchdog-responder.sh decide-call contract). With
        # tools the baseline could read the repo or the verdicts, and would not
        # be answering the question Jev answers from the text alone.
        env = dict(self.env, **NO_TOOLS_ENV)
        rc, _ = run([os.path.join(self.h, "bin", "agent-call.sh"), "triage", "fleet", model, "180",
                     out_file, "@" + prompt_file], env=env, timeout=900)
        return rc


def pr_of(dest):
    return int(os.path.basename(dest).split("-", 1)[0])


def lead_label(vd, since):
    """(verdict, head, why) from the newest kept lead row; why set when none."""
    if not isinstance(vd, dict) or not isinstance(vd.get("rows"), list):
        return None, None, "verdicts unreadable"
    best = None
    for r in vd["rows"]:
        if not isinstance(r, dict) or r.get("source") != "lead":
            continue
        v = KEEP.get(str(r.get("verdict") or "").strip().upper())
        ts = str(r.get("created_at") or "")
        if v is None or ts < since:
            continue
        key = (ts, str(r.get("id") or ""))
        if best is None or key > best[0]:
            best = (key, v, str(r.get("head_sha") or "").strip().lower())
    if best is None:
        return None, None, "no lead verdict"
    return best[1], best[2], None


def parse_haiku(text):
    """(status, tier, prob) from the model's raw text."""
    if not text or not text.strip():
        return "empty", None, None
    for m in re.finditer(r"\{[^{}]*\}", text):
        try:
            v = json.loads(m.group(0))
        except ValueError:
            continue
        c = str(v.get("choice") or "").strip().lower()
        p = v.get("probability")
        if c in TIERS and isinstance(p, (int, float)) and 0 <= p <= 1:
            return "ok", c, float(p)
    return "failed", None, None


def load_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return rows


def append(path, row):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--since", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--harness", default=os.environ.get("HARNESS") or "/root/harness")
    ap.add_argument("--limit", type=int, default=0, help="at most N new PRs asked (0 = all)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--fixtures")
    a = ap.parse_args()
    if not re.match(r"^[\w.-]+/[\w.-]+$", a.repo):
        die("--repo must be owner/name")
    if not re.match(r"^\d{4}-\d{2}-\d{2}", a.since):
        die("--since must be YYYY-MM-DD")
    if a.dry_run != bool(a.fixtures):
        die("--dry-run and --fixtures go together")
    src = Fixtures(a.fixtures) if a.dry_run else Live(a.harness)

    os.makedirs(os.path.join(a.out, "cmp"), exist_ok=True)
    out_path = os.path.join(a.out, "replay.jsonl")
    haiku_path = os.path.join(a.out, "haiku.jsonl")

    # Resume: settled rows stay, skipped rows are dropped and retried.
    old = load_jsonl(out_path)
    done = {}
    for r in old:
        if isinstance(r, dict) and not r.get("skip_reason"):
            done["%s|%s|%s" % (r.get("repo"), r.get("pr"), r.get("head"))] = r
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for r in done.values():
            f.write(json.dumps(r, sort_keys=True) + "\n")
    os.replace(tmp, out_path)
    hcache = {}
    for r in load_jsonl(haiku_path):
        if isinstance(r, dict) and r.get("key"):
            hcache[r["key"]] = r

    prs = src.prs(a.repo, a.since)
    if prs is None:
        die("could not read the PR list for %s" % a.repo)

    stats = {"kept": 0, "present": 0, "not_lead": 0, "asked": 0}
    skips = {}
    model = None
    rc_final = 0
    try:
        # Resolved before any ask, so a missing route stops the run with nothing spent.
        model = src.model()
        for p in sorted(prs, key=lambda x: int(x.get("number") or 0)):
            n = int(p.get("number") or 0)
            if n <= 0:
                continue
            row = {"repo": a.repo, "pr": n, "head": None, "lead_verdict": None, "rule_tier": None,
                   "jev_status": None, "jev_tier": None, "jev_prob": None,
                   "haiku_status": None, "haiku_tier": None, "skip_reason": None}

            def skip(why):
                row["skip_reason"] = why
                skips[why.split(":")[0]] = skips.get(why.split(":")[0], 0) + 1
                append(out_path, row)

            vd = src.verdicts(a.repo, n)
            verdict, head, why = lead_label(vd, a.since)
            if why == "no lead verdict":
                stats["not_lead"] += 1
                continue
            if why:
                skip(why)
                continue
            row["lead_verdict"] = verdict
            row["head"] = head or None
            if "%s|%d|%s" % (a.repo, n, head) in done:
                stats["present"] += 1
                continue
            stats["kept"] += 1
            if not SHA_RE.match(head or ""):
                skip("lead row head unreadable")
                continue
            if isinstance(vd, dict) and vd.get("truncated"):
                skip("verdicts truncated")
                continue
            if a.limit and stats["asked"] >= a.limit:
                skip("over --limit")
                continue

            cmp_path = os.path.join(a.out, "cmp", "%d-%s.json" % (n, head[:12]))
            if read_json(cmp_path) is None:
                base = str((p.get("base") or {}).get("sha") or "")
                cmp = src.compare(a.repo, base, head, cmp_path)
                if not isinstance(cmp, dict) or not isinstance(cmp.get("files"), list):
                    skip("compare unreadable")
                    continue
                with open(cmp_path + ".tmp", "w", encoding="utf-8") as f:
                    json.dump(cmp, f)
                os.replace(cmp_path + ".tmp", cmp_path)

            rrc, rout = src.rule(cmp_path, a.repo, n)
            rt = rout.split("\t", 1)[0].strip() if rrc == 0 else ""
            if rt not in TIERS:
                skip("rule tier unreadable")
                continue
            row["rule_tier"] = rt

            stats["asked"] += 1
            jrc, jout = src.ask(a.repo, n, head, rt, cmp_path)
            f5 = (jout.strip().splitlines() or [""])[0].split("\t")
            if jrc == 3:
                raise Stop("jev-risk is not configured (ask rc 3)")
            if jrc == 4:
                skip("jev skipped: %s" % (f5[4] if len(f5) > 4 else "worker unreachable or in flight"))
                continue
            st = f5[0] if f5[0] in ("ok", "empty", "failed") else "failed"
            if st == "failed":
                # Retryable in the ledger (up to jev_risk.max_attempts): a skip
                # row, so the next run asks again instead of keeping the failure.
                skip("jev failed")
                continue
            row["jev_status"] = st
            if st == "ok" and len(f5) > 2 and f5[1] in TIERS:
                row["jev_tier"] = f5[1]
                try:
                    row["jev_prob"] = float(f5[2])
                except ValueError:
                    row["jev_prob"] = None
            elif st == "ok":
                row["jev_status"] = "failed"

            key = "|".join([a.repo, str(n), head, QV, model])
            hit = hcache.get(key)
            if hit is None:
                qrc, qtext = src.question(rt, cmp_path, n)
                if qrc != 0 or not qtext.strip():
                    skip("question unreadable")
                    continue
                with tempfile.TemporaryDirectory() as td:
                    pf = os.path.join(td, "prompt.txt")
                    of = os.path.join(td, "answer.txt")
                    with open(pf, "w", encoding="utf-8") as f:
                        f.write(qtext.rstrip("\n") + HAIKU_INSTRUCTION + "\n")
                    hrc = src.haiku(model, pf, of, n)
                    if hrc == REFUSED_RC:
                        raise Stop("agent-call refused the no-tools baseline call (rc %d)" % hrc)
                    if 74 <= hrc <= 79:
                        skip("haiku not called: rc %d" % hrc)
                        continue
                    text = read_text(of) or ""
                hs, ht, hp = parse_haiku(text) if hrc == 0 else ("failed", None, None)
                hit = {"key": key, "repo": a.repo, "pr": n, "head": head, "qv": QV, "model": model,
                       "status": hs, "tier": ht, "prob": hp, "rc": hrc}
                append(haiku_path, hit)
                hcache[key] = hit
            row["haiku_status"] = hit.get("status")
            row["haiku_tier"] = hit.get("tier")
            append(out_path, row)
    except Stop as e:
        print("replay: STOPPED: %s" % e, file=sys.stderr)
        rc_final = 3

    nskip = sum(skips.values())
    print("replay: %s since %s: kept %d, already present %d, no lead verdict %d, skipped %d"
          % (a.repo, a.since, stats["kept"], stats["present"], stats["not_lead"], nskip))
    for k in sorted(skips):
        print("replay:   skipped %s: %d" % (k, skips[k]))
    print("replay: rows in %s" % out_path)
    return rc_final


if __name__ == "__main__":
    sys.exit(main())
