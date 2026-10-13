#!/bin/bash
# bin/codex-usage.sh <t0-epoch> [events-file] [session-id] — token usage from a codex run.
#
# Prints four space-separated fields: input output cache_read cache_write
# Any field it cannot find is printed EMPTY. Never fails the caller.
#
# WHY. The openrouter and fireworks lanes drive the codex CLI and record no
# tokens at all, so their cost rows ship with every count blank. row_cost() then
# has nothing to multiply and prices them at $0.00 — which is how ~82 hub runs
# of real metered spend became invisible. Same bug grok had, and the same fix:
# read the CLI's own ledger instead of hoping the wrapper reported.
#
# WHAT THIS DOES NOT KNOW. The exact JSON shape codex emits for usage on these
# providers is UNVERIFIED — I have no box to run it on. So this does not assume
# a path. It recurses for any object carrying a recognisable token pair and
# accepts the naming families these CLIs actually use in the wild:
#
#   input_tokens/output_tokens        OpenAI Responses
#   prompt_tokens/completion_tokens   Chat Completions
#   inputTokens/outputTokens          camelCase variants
#
# That is exactly the lesson from the grok fix: its usage object was NOT at the
# top level, it rode nested inside params.update, and the original path-based
# lookup silently never matched while the wallet metered ~$160/day unseen.
# Assuming a path is the bug; recursing for the shape is the fix.
#
# FAIL-SOFT BY DESIGN. A miss leaves the fields blank, exactly as today. This
# can only ever add priced rows, never break a lane or invent a number.
#
# ATTRIBUTION (issue #62). A session id, when given, binds the call to ITS OWN
# session: only a file named rollout-<ts>-<id>.jsonl, or whose first line is a
# session_meta record with payload.id == <id>, is read — no mtime window, the id
# is the proof of ownership. A newer session belonging to a concurrent call on
# the same box is ignored. If no file carries the id, the fields print BLANK;
# borrowing another call's tokens would charge A for B's spend and count B's
# twice, and a blank row is what the [cost-parity] UNPRICED alert exists for.
#
# REMAINING GAP. With no id (a CLI that prints no `session id:` banner, or a
# direct caller that passes none) discovery falls back to the old heuristic:
# the newest session file touched at or after this call started. That is still
# wrong under concurrency — call A can pick up call B's newer session — so do
# not read the fallback as an attribution guarantee. It is kept because it is
# strictly better than the $0.00 rows it replaced.
set -uo pipefail
T0="${1:-0}"
EVENTS="${2:-}"
SID="${3:-}"

# Discovery happens in python, walking the tree itself. The first version ran
# `find … | head -50`, which returns DIRECTORY order, not mtime order — and the
# hub has 645 session files under dated subdirs (sessions/2026/08/24/rollout-*),
# so the session we wanted was never inside the window and the lookup returned
# blank while looking like it had searched. Filter by mtime FIRST, sort by mtime
# descending, then limit.
# CODEX_HOME, not a bare $HOME/.codex (2026-09-06, account routing): a routed
# codex attempt runs with CODEX_HOME pointing at that account's own ledger, and
# reading the default dir would price the call from another account's sessions.
# Unset — every call today — this is byte-identical to the old path.
python3 - "$T0" "$EVENTS" "${CODEX_HOME:-$HOME/.codex}/sessions" "$SID" <<'PY' 2>/dev/null || echo "   "
import json, os, sys
T0 = float(sys.argv[1] or 0)
EVENTS = sys.argv[2]
SESSIONS = sys.argv[3]
SID = sys.argv[4]

IN_KEYS    = ("input_tokens", "inputTokens", "prompt_tokens", "promptTokens")
OUT_KEYS   = ("output_tokens", "outputTokens", "completion_tokens", "completionTokens")
# Cache accounting is named inconsistently across providers and is often absent
# entirely; missing is fine, it just prices at the uncached rate.
# cached_input_tokens / cache_write_input_tokens are the names codex ACTUALLY
# emits — confirmed against a real hub session, not guessed. The rest stay as
# fallbacks for the other shapes.
CR_KEYS    = ("cached_input_tokens", "cache_read_input_tokens", "cached_tokens",
              "cachedReadTokens", "cache_read_tokens", "cacheReadTokens")
CW_KEYS    = ("cache_write_input_tokens", "cache_creation_input_tokens",
              "cache_write_tokens", "cacheCreationTokens", "cacheWriteTokens")

def pick(d, keys):
    for k in keys:
        if k in d:
            try:
                v = int(d[k])
                if v >= 0:
                    return v
            except (TypeError, ValueError):
                pass
    return None

def walk(o, found):
    """Collect every usage-shaped dict, at any depth."""
    if isinstance(o, dict):
        i, ou = pick(o, IN_KEYS), pick(o, OUT_KEYS)
        if i is not None and ou is not None:
            found.append((i, ou, pick(o, CR_KEYS), pick(o, CW_KEYS)))
        for v in o.values():
            walk(v, found)
    elif isinstance(o, list):
        for v in o:
            walk(v, found)

# The events file, if one was given, is this call's by construction.
#
# With a session id, a session file counts only if it carries that id — in its
# name or its session_meta record. No mtime filter: the id proves ownership.
#
# Without one, a session file counts only if it was touched at or after the
# call started — an older session belongs to a different call, and borrowing
# its tokens would INVENT spend. That rules out OLDER sessions only, not a
# NEWER one from a concurrent call — see REMAINING GAP in the header.
paths = []
if EVENTS and os.path.isfile(EVENTS):
    paths.append(EVENTS)

def owned(fp, fn):
    if fn.endswith("-" + SID + ".jsonl"):
        return True
    try:
        with open(fp, errors="ignore") as f:
            first = json.loads(f.readline())
        return (first.get("type") == "session_meta"
                and (first.get("payload") or {}).get("id") == SID)
    except Exception:
        return False

sessions = []
for root, _dirs, files in os.walk(SESSIONS):
    for fn in files:
        if not fn.endswith(".jsonl"):
            continue
        fp = os.path.join(root, fn)
        try:
            mt = os.path.getmtime(fp)
        except OSError:
            continue
        if SID:
            if owned(fp, fn):
                sessions.append((mt, fp))
        elif mt >= T0:
            sessions.append((mt, fp))
sessions.sort(reverse=True)
paths.extend(fp for _mt, fp in sessions[:10])

found = []
for path in paths:
    try:
        for line in open(path, errors="ignore"):
            line = line.strip()
            if not line or ("token" not in line.lower()):
                continue
            try:
                walk(json.loads(line), found)
            except Exception:
                continue
        # Some events files are one whole JSON document rather than JSONL.
        if not found:
            try:
                walk(json.load(open(path, errors="ignore")), found)
            except Exception:
                pass
    except Exception:
        continue
    if found:
        break

if not found:
    print("   ")
else:
    # Take the LARGEST input count rather than the last. Codex emits usage per
    # turn as well as cumulatively, and which one lands last is not something I
    # can verify without a real run — the max is the cumulative figure in both
    # orderings, and understating spend is the failure mode that started this.
    i, ou, cr, cw = max(found, key=lambda t: t[0])
    print(f"{i} {ou} {cr if cr is not None else ''} {cw if cw is not None else ''}")
PY
