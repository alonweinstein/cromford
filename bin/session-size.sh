#!/bin/bash
# bin/session-size.sh [session-dir] — how much context the newest session would
# re-send on its next turn, in TOKENS. Prints an integer; 0 when unknown.
#
# WHY. A continued claude session re-reads its accumulated tool results on every
# api call, so its cost per turn grows with the conversation and never shrinks.
# Measured on the hub: one session reached 5,070 api calls, 27MB on disk, 2,436
# tool results totalling 4.3MB (individual results 171-216KB), and a peak
# cache_read of 999,307 tokens — about 1M tokens of context re-sent per call.
# That is ~$666/day, and nothing about it errors or even looks unusual.
#
# WHAT THIS MEASURES. The largest cache_read_input_tokens the newest session has
# recorded — i.e. how big the context actually got, straight from the CLI's own
# ledger rather than inferred from file size. File size is a poor proxy: a
# session can be megabytes of small entries or a few enormous tool results, and
# only the second one costs per call.
#
# 0 ON ANY DOUBT. The caller uses this to decide whether to start fresh, and
# fresh is the safe direction — but returning a large number on a parse failure
# would force fresh forever and throw away working memory the orchestrator
# genuinely needs. So an unreadable or absent session reports 0 (no evidence of
# growth) and the caller's own default decides.
set -uo pipefail
DIR="${1:-$HOME/.claude/projects}"

python3 - "$DIR" <<'PY' 2>/dev/null || echo 0
import json, os, sys

ROOT = sys.argv[1]
newest, nt = None, -1
for root, _dirs, names in os.walk(ROOT):
    for fn in names:
        if not fn.endswith(".jsonl"):
            continue
        fp = os.path.join(root, fn)
        try:
            mt = os.path.getmtime(fp)
        except OSError:
            continue
        if mt > nt:
            newest, nt = fp, mt

if not newest:
    print(0)
    raise SystemExit

CR = ("cache_read_input_tokens", "cached_input_tokens", "cache_read_tokens")

def usage_of(o):
    if isinstance(o, dict):
        if any(k in o for k in CR) or "input_tokens" in o:
            return o
        for v in o.values():
            r = usage_of(v)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = usage_of(v)
            if r is not None:
                return r
    return None

peak = 0
try:
    for line in open(newest, errors="ignore"):
        if '"usage"' not in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        u = usage_of(o)
        if not u:
            continue
        for k in CR:
            try:
                v = int(u.get(k) or 0)
            except (TypeError, ValueError):
                continue
            if v > peak:
                peak = v
except Exception:
    print(0)
    raise SystemExit

print(peak)
PY
