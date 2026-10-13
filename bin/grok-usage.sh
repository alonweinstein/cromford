#!/bin/bash
# bin/grok-usage.sh [--calls] [--envelope <file>] <t0-epoch> [grok-home] —
# token usage from a grok run.
#
# Prints five space-separated fields: input output cache_read cache_write usd
# Any field it cannot find is printed EMPTY. Never fails the caller.
#
# --envelope <file> (BH-1494) is the FIRST read in summary mode: the grok CLI's
# own `--output-format json` result document, which carries `usage.*` and a
# `total_cost_usd` the vendor computed from the same meter it bills. One parse,
# exact dollars, no guessing at which file in the tree belongs to this call —
# so when the lane has an envelope, that is the answer. The tree walk stays
# because a KILLED run never writes one and its tokens were still billed, and
# because an envelope that is not an envelope (stderr landed in $OUT) must fall
# through rather than blank the row. Ignored in --calls mode: the series is the
# LEDGER's, and one envelope row would hide the cliff the caller is looking for.
#
# --calls (BH-656) prints the SERIES instead of the summary: one line per
# usage-shaped record, in ledger order, `n input output cache_read cache_write`
# with n 1-based. Nothing found prints NOTHING at all — never the blank summary
# line, which a caller walking the series would read as a record with no tokens.
#
# THE RECORDS ARE CUMULATIVE on the verified shape (see the fixture's
# provenance: 120000 -> 310500 -> 402118 input over one session), so the context
# of call n is the DELTA between consecutive records, not the record itself.
# That delta is what the xAI cliff is stated in, and reading the raw record as
# "this call's context" would fire the warn a call early.
#
# ONE READER, extended — not a second one. "How big is this grok session now" is
# a question with one answer, and two implementations of it drift (which is the
# whole reason this file exists; see BH-406 below).
#
# WHY. This is the grok half of what bin/codex-usage.sh is for the codex lanes,
# and it exists because the inline parser it replaces was path-bound twice over
# (BH-406, 217 blank grok rows in one 24h window):
#
#   * it looked for exactly $HOME/.grok/sessions/**/updates.jsonl. The ledger
#     had already moved once (2026-08-20), and a second move put every row back
#     to blank with nothing on the box saying so.
#   * it matched a usage object only when the dict carried BOTH inputTokens AND
#     costUsdTicks. A session billed against the SuperGrok subscription pool has
#     no metered ticks to report, so a perfectly good token count was thrown
#     away and the row shipped with no tokens at all.
#
# So: assume neither. Walk the tree for any file touched since the call started,
# recurse each line for any dict carrying a recognisable INPUT+OUTPUT pair, and
# read the dollars only if they happen to be there. That is the same design
# codex-usage.sh adopted after the same incident, for the same reason.
#
# THE NAMING FAMILIES accepted (never a fixed path):
#   inputTokens/outputTokens          the shape verified on 2026-08-20
#   input_tokens/output_tokens        OpenAI Responses
#   prompt_tokens/completion_tokens   Chat Completions
# and the output field includes a sibling reasoning_tokens/reasoningTokens
# (BH-1636), which grok counts apart from output_tokens.
# and for money, costUsdTicks (1e-10 USD — a $0.9056 session reports
# 9056360000) or a direct costUsd/cost_usd/totalCostUsd figure.
#
# CREDENTIALS ARE NEVER OPENED. ~/.grok/auth.json lives in the same tree this
# walks and is refreshed on every call, so it is the NEWEST file in the tree
# exactly when this runs. It is skipped by NAME, before any open() — not by
# permissions, which are no barrier to the root user every box runs as.
#
# FAIL-SOFT BY DESIGN. A miss leaves the fields blank, never a zero: a zero
# reads as "this call was free", which is the same lie as the blank column but
# harder to spot because it looks measured. The call site turns a blank into one
# ALERTS line (cost_parity_alert in bin/lib/cost-row.sh) rather than silence.
#
# KNOWN LIMITATION — ATTRIBUTION IS NOT AIRTIGHT UNDER CONCURRENCY. Discovery
# picks the newest ledger touched at or after this call started. That is correct
# for one call at a time and WRONG when two grok calls run concurrently on the
# same box: call A can pick up call B's newer session and report B's tokens as
# its own. The direction is over-reporting, which is strictly safer than the
# $0.00 rows this replaces, and the fleet total stays roughly right even when a
# per-call row is not. Same limitation, same tracking issue as codex-usage.sh
# (#62); do not read the mtime window as proof of ownership.
#
# Run it by hand on a box that has the CLI, to capture what the ledger looks
# like there:  bin/grok-usage.sh 0 ~/.grok
set -uo pipefail
MODE=summary
ENVELOPE=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --calls)      MODE=calls; shift ;;
    --envelope)   ENVELOPE="${2:-}"; shift 2 ;;
    --envelope=*) ENVELOPE="${1#--envelope=}"; shift ;;
    *) break ;;
  esac
done
T0="${1:-0}"
GROK_HOME_ARG="${2:-${GROK_HOME:-$HOME/.grok}}"

# The fail-soft blank line belongs to the SUMMARY shape only: in --calls mode
# "nothing" is the empty output, and printing a blank record there would invent
# a call that never happened.
python3 - "$T0" "$GROK_HOME_ARG" "$MODE" "$ENVELOPE" <<'PY' 2>/dev/null || { [ "$MODE" = calls ] || echo "    "; }
import json, os, sys

T0   = float(sys.argv[1] or 0)
ROOT = sys.argv[2]
MODE = sys.argv[3] if len(sys.argv) > 3 else "summary"
ENV_FILE = sys.argv[4] if len(sys.argv) > 4 else ""

IN_KEYS  = ("inputTokens", "input_tokens", "prompt_tokens", "promptTokens")
OUT_KEYS = ("outputTokens", "output_tokens", "completion_tokens", "completionTokens")
# The last two of each cache family and costUSD are grok 1.0.x's own spellings
# (BH-1494): they are what modelUsage["<grok model id>"] prints, and their absence is
# exactly why a 1.0.40 session reported tokens with blank cache and blank
# dollars while the CLI knew all three.
CR_KEYS  = ("cachedReadTokens", "cachedPromptTokens", "cache_read_input_tokens",
            "cached_input_tokens", "cached_tokens", "cacheReadTokens", "cache_read_tokens",
            "cacheReadInputTokens")
CW_KEYS  = ("cacheCreationTokens", "cache_creation_input_tokens",
            "cache_write_input_tokens", "cacheWriteTokens", "cache_write_tokens",
            "cacheCreationInputTokens")
USD_KEYS = ("costUsd", "cost_usd", "totalCostUsd", "total_cost_usd", "costUSD")
# grok reports reasoning SEPARATELY from output (BH-1636): the one measured
# 1.0.40 envelope says output_tokens 1 beside reasoning_tokens 412, and one
# token cannot contain 412. So a reasoning count that is a SIBLING of the
# output key is added to it. Never a nested one: OpenAI's
# output_tokens_details.reasoning_tokens is already inside output_tokens, and
# codex's reasoning_output_tokens is not in this list. If a later grok folds
# reasoning into output_tokens this double counts, and a real 1.0.x capture
# (BH-1636 item 1b) is what would show it.
REASON_KEYS = ("reasoning_tokens", "reasoningTokens")

# Skipped by name, before any open(). auth.json is rewritten on every call, so
# it is reliably the newest file in this tree — a reader that did not skip it
# would price the call from whatever happened to be in the credential store.
SKIP_PREFIXES = ("auth", "credential", "token.json", "tokens.json", ".env")

MAX_FILES = 20


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


def pick_out(d):
    """Output tokens plus a sibling reasoning count; None when no output key.

    Reasoning alone never makes a dict a usage record, and a negative or
    non-numeric reasoning value is absent (pick's rule), not zero.
    """
    ou = pick(d, OUT_KEYS)
    if ou is None:
        return None
    r = pick(d, REASON_KEYS)
    return ou if r is None else ou + r


def pick_usd(d):
    """Dollars, if the ledger happens to carry them. Absent is absent.

    A reported ZERO is treated as absent on purpose: the shapes that report 0
    are the ones that are not metering this call at all (a subscription
    session), and the honest answer there is "price it from the table", not
    "this call was free".
    """
    t = d.get("costUsdTicks")
    if t is None:
        t = d.get("cost_usd_ticks")
    if t is None:
        t = d.get("total_cost_usd_ticks")   # grok 1.0.x
    if t is not None:
        try:
            t = float(t)
            if t > 0:
                return round(t / 1e10, 6)
        except (TypeError, ValueError):
            pass
    for k in USD_KEYS:
        if k in d:
            try:
                v = float(d[k])
                if v > 0:
                    return round(v, 6)
            except (TypeError, ValueError):
                pass
    return None


def walk(o, found):
    """Collect every usage-shaped dict, at any depth.

    The shape is an INPUT key AND an OUTPUT key in the same dict. A settings
    blob carrying maxInputTokens has no output sibling and is not a call, which
    is what keeps a config line from being priced as spend.
    """
    if isinstance(o, dict):
        i, ou = pick(o, IN_KEYS), pick_out(o)
        if i is not None and ou is not None:
            found.append((i, ou, pick(o, CR_KEYS), pick(o, CW_KEYS), pick_usd(o)))
        for v in o.values():
            walk(v, found)
    elif isinstance(o, list):
        for v in o:
            walk(v, found)


def envelope_summary(path):
    """The five fields, straight out of the CLI's own result document.

    Returns None — meaning "fall through to the walk" — for every shape that is
    not unambiguously a usage-carrying envelope: no file, unparseable, not an
    object, no `usage` dict, or a `usage` dict without BOTH an input and an
    output key. A half-read envelope priced as if it were whole is worse than a
    blank row: the blank pages through cost_parity_alert, the half does not.

    The dollars are read from the TOP level first (`total_cost_usd` sits beside
    `usage`, not inside it — that is half of what BH-1494 is about) and from the
    usage dict second, for a shape that nests them.
    """
    if not path or not os.path.exists(path):
        return None
    doc = None
    try:
        doc = json.load(open(path, errors="ignore"))
    except Exception:
        doc = None
    if doc is None:
        # A CLI that streams NDJSON ends on its result object; take the last
        # line that parses as one.
        try:
            for line in open(path, errors="ignore"):
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if isinstance(o, dict):
                    doc = o
        except Exception:
            return None
    if not isinstance(doc, dict):
        return None
    u = doc.get("usage")
    if not isinstance(u, dict):
        return None
    i, ou = pick(u, IN_KEYS), pick_out(u)
    if i is None or ou is None:
        return None
    usd = pick_usd(doc)
    if usd is None:
        usd = pick_usd(u)
    return (i, ou, pick(u, CR_KEYS), pick(u, CW_KEYS), usd)


def fmt(i, ou, cr, cw, usd):
    return "%s %s %s %s %s" % (
        i, ou,
        "" if cr is None else cr,
        "" if cw is None else cw,
        "" if usd is None else ("%.6f" % usd))


# The envelope is the first read, before the tree is even listed: it is the one
# source that belongs to THIS call by construction rather than by mtime.
if MODE != "calls":
    _e = envelope_summary(ENV_FILE)
    if _e is not None:
        print(fmt(*_e))
        sys.exit(0)


def interesting(fn):
    low = fn.lower()
    if low.startswith(SKIP_PREFIXES):
        return False
    return low.endswith(".jsonl") or low.endswith(".json")


# Newest first, and only files touched at or after the call started: an older
# ledger belongs to a different call, and borrowing its tokens would INVENT
# spend, which is worse than the blank fields this replaces. This rules out
# OLDER files only — see the concurrency limitation in the header.
files = []
for root, _dirs, names in os.walk(ROOT):
    for fn in names:
        if not interesting(fn):
            continue
        fp = os.path.join(root, fn)
        try:
            mt = os.path.getmtime(fp)
        except OSError:
            continue
        if mt >= T0:
            files.append((mt, fp))
files.sort(reverse=True)

found = []
for _mt, path in files[:MAX_FILES]:
    try:
        # The line filter first: a session ledger can be tens of megabytes and
        # almost none of it is usage.
        for line in open(path, errors="ignore"):
            if "oken" not in line:
                continue
            try:
                walk(json.loads(line), found)
            except Exception:
                continue
        # Some ledgers are one whole JSON document rather than JSONL.
        if not found:
            try:
                walk(json.load(open(path, errors="ignore")), found)
            except Exception:
                pass
    except Exception:
        continue
    if found:
        break

if MODE == "calls":
    # Ledger order, 1-based, blanks preserved. The caller differences these to
    # get per-call context; doing the differencing here would bake one reading
    # of the shape into the reader every other caller shares.
    for n, (i, ou, cr, cw, _usd) in enumerate(found, 1):
        print("%s %s %s %s %s" % (
            n, i, ou,
            "" if cr is None else cr,
            "" if cw is None else cw))
elif not found:
    print("    ")
else:
    # The LARGEST input count, not the last. On the verified shape the ledger is
    # cumulative, so the largest IS the last; on a per-turn shape the largest is
    # the biggest single turn rather than the sum, which under-reports — and
    # under-reporting is the failure that started this. Same reasoning, same
    # choice as codex-usage.sh.
    print(fmt(*max(found, key=lambda t: t[0])))
PY
