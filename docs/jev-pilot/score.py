#!/usr/bin/env python3
"""BH-5024 decision rule over a replay.jsonl written by replay.py.

usage: score.py <replay.jsonl>

Shared set: rows with no skip_reason where jev_status == ok AND haiku_status ==
ok, so both models are judged on the same PRs. Every other row is excluded and
counted by reason.

For each model:
  block_low_rate = lead-BLOCK rows it called low / lead-BLOCK rows
  merge_low_rate = lead-MERGE rows it called low / lead-MERGE rows

PASS iff jev block_low_rate < MAX_BLOCK_LOW (strict)
     AND jev block_low_rate <= haiku block_low_rate
     AND jev merge_low_rate >  haiku merge_low_rate.
Zero BLOCK or zero MERGE rows on the shared set, or no readable input, is
INCONCLUSIVE: no evidence is never a pass.

Also printed: would-lower, the rows where the rule said medium and Jev said low
(the only move Jev could ever make), and how many of those the lead BLOCKed.

Output: a markdown table and one line `VERDICT: PASS|FAIL|INCONCLUSIVE ...`.
rc 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
"""
import json
import sys

# PRE-REGISTERED (BH-5024). Fixed before any replay data was read, and it must
# stay a constant in this file, never a settings row: a threshold someone can
# edit after seeing the data is no longer "set before the data is seen".
MAX_BLOCK_LOW = 0.02


def pct(x):
    return "n/a" if x is None else "%.1f%%" % (100.0 * x)


def rate(rows, label, field):
    sub = [r for r in rows if r.get("lead_verdict") == label]
    if not sub:
        return None, 0, 0
    low = sum(1 for r in sub if r.get(field) == "low")
    return low / len(sub), low, len(sub)


def inconclusive(why):
    print("VERDICT: INCONCLUSIVE %s" % why)
    return 2


def main(argv):
    if len(argv) != 2:
        print("usage: score.py <replay.jsonl>", file=sys.stderr)
        return inconclusive("no input file given")
    path = argv[1]
    try:
        with open(path, encoding="utf-8") as f:
            lines = [ln for ln in f.read().splitlines() if ln.strip()]
    except (OSError, UnicodeDecodeError) as e:
        return inconclusive("input unreadable: %s" % e.__class__.__name__)

    rows, excluded = [], {}

    def ex(why):
        excluded[why] = excluded.get(why, 0) + 1

    for ln in lines:
        try:
            r = json.loads(ln)
        except ValueError:
            ex("unparseable line")
            continue
        if not isinstance(r, dict):
            ex("unparseable line")
        elif r.get("skip_reason"):
            ex("skipped: %s" % str(r["skip_reason"]).split(":")[0])
        elif r.get("lead_verdict") not in ("MERGE", "BLOCK"):
            ex("no MERGE/BLOCK label")
        elif r.get("jev_status") != "ok" and r.get("haiku_status") != "ok":
            ex("neither model ok")
        elif r.get("jev_status") != "ok":
            ex("jev %s" % r.get("jev_status"))
        elif r.get("haiku_status") != "ok":
            ex("haiku %s" % r.get("haiku_status"))
        else:
            rows.append(r)
    if not lines:
        return inconclusive("input is empty")

    jb, jbl, nb = rate(rows, "BLOCK", "jev_tier")
    hb, hbl, _ = rate(rows, "BLOCK", "haiku_tier")
    jm, jml, nm = rate(rows, "MERGE", "jev_tier")
    hm, hml, _ = rate(rows, "MERGE", "haiku_tier")

    # Would-lower: every row Jev answered, shared set or not, since this is
    # about Jev alone. Only rule medium -> jev low counts.
    wl = [r for r in (json.loads(ln) for ln in lines if _is_obj(ln))
          if not r.get("skip_reason") and r.get("jev_status") == "ok"
          and r.get("rule_tier") == "medium" and r.get("jev_tier") == "low"]
    wl_block = sum(1 for r in wl if r.get("lead_verdict") == "BLOCK")

    print("| model | BLOCK called low | block_low_rate | MERGE called low | merge_low_rate |")
    print("|---|---|---|---|---|")
    print("| jev | %d/%d | %s | %d/%d | %s |" % (jbl, nb, pct(jb), jml, nm, pct(jm)))
    print("| haiku | %d/%d | %s | %d/%d | %s |" % (hbl, nb, pct(hb), hml, nm, pct(hm)))
    print("")
    print("rows read: %d, shared set: %d, excluded: %d" % (len(lines), len(rows), sum(excluded.values())))
    for k in sorted(excluded):
        print("excluded %s: %d" % (k, excluded[k]))
    print("would-lower (rule medium, jev low): %d, of them lead BLOCK: %d" % (len(wl), wl_block))
    print("rule: jev block_low_rate < %s, jev block_low_rate <= Haiku's, jev merge_low_rate > Haiku's"
          % pct(MAX_BLOCK_LOW))

    if nb == 0:
        return inconclusive("no lead BLOCK rows on the shared set")
    if nm == 0:
        return inconclusive("no lead MERGE rows on the shared set")

    fails = []
    if not jb < MAX_BLOCK_LOW:
        fails.append("jev block_low_rate %s is not under the pre-registered 2%%" % pct(jb))
    if not (jb <= hb and jm > hm):
        fails.append("jev does not beat the Haiku baseline (block_low %s vs Haiku %s, merge_low %s vs Haiku %s)"
                     % (pct(jb), pct(hb), pct(jm), pct(hm)))
    if fails:
        print("VERDICT: FAIL %s" % "; ".join(fails))
        return 1
    print("VERDICT: PASS jev block_low_rate %s under 2%%, at or below Haiku %s, merge_low %s over Haiku %s"
          % (pct(jb), pct(hb), pct(jm), pct(hm)))
    return 0


def _is_obj(ln):
    try:
        return isinstance(json.loads(ln), dict)
    except ValueError:
        return False


if __name__ == "__main__":
    sys.exit(main(sys.argv))
