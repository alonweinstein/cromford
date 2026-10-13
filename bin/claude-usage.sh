#!/bin/bash
# bin/claude-usage.sh <t0-epoch> [session-dir] — token usage from a claude run.
#
# Prints four '|'-separated fields: input|output|cache_read|cache_write
# Any field it cannot find is printed EMPTY. Never fails the caller.
#
# WHY. box-chat.sh calls `claude -p` directly and writes no cost row, so every
# per-box chat turn is spend nobody can see. That is the same class the
# orchestrator was in until it was instrumented, and the class the $18,863
# hid in: not a lane that reports wrong, a lane that reports nothing.
#
# SUMS, NOT MAX — and this is the one thing that must not be copied from
# codex-usage.sh. Codex writes a CUMULATIVE total_token_usage per session, so
# the largest sample is the answer there. Claude writes PER-TURN usage on each
# assistant message (.message.usage, verified against a real session file), so
# the answer here is the SUM over the turns in this call's window. Taking the
# max would report a single turn and undercount a long chat by however many
# turns it ran — silently, and in the direction that always looks fine.
#
# WINDOWING. Claude Code keys sessions by working directory, and box-chat uses
# a per-project directory, so several projects' sessions live side by side. The
# file filter is mtime >= T0 (the call's start), the same guard codex-usage.sh
# uses: an older session belongs to a different call and borrowing its tokens
# would invent spend. Within a chosen file, only entries whose own timestamp is
# at or after T0 are summed, so a CONTINUED conversation (`claude -c` appends
# to an existing session) contributes this turn's tokens rather than the whole
# history — the case that makes a per-turn sum wrong if you ignore it.
#
# THE ROOT IS THE SCOPE, and it must be passed — 2026-08-25. The first version
# walked ALL of ~/.claude/projects, sorted by mtime, and STOPPED at the first
# file containing any usage. On a box where several claude processes run at
# once that answers with whichever session happened to be written last, which
# is not the caller's. Measured on the hub: an orchestrator turn that really
# consumed 1,087,133 cache_read and 14,098 output reported `4|28|70548|0` —
# the tokens of an unrelated `-tmp` session, ~15x low, and it could as easily
# have been high. The caller knows its own working directory, so pass it:
#
#   claude-usage.sh <t0-epoch> --cwd=/root/orchestrator     (preferred)
#   claude-usage.sh <t0-epoch> /path/to/projects/-a-session-dir
#   claude-usage.sh <t0-epoch> --cwd=/root/orchestrator --session=<uuid>
#
# --session= (BH-5336) sums only <uuid>.jsonl under the scope. Parallel
# orchestrator turns share one cwd, so without it each turn would price every
# turn that ran beside it.
#
# --cwd= is converted with Claude Code's own rule (every "/" becomes "-"), so
# call sites read as the directory they ran in rather than as a slug nobody
# can verify by eye. With a scope there is no "pick one file" guess left: every
# file under the root touched since T0 is summed, because they all belong to
# this caller. Left unscoped it still answers, now for EVERY claude session on
# the box in the window — an honest over-count instead of a silent wrong one.
#
# FAIL-SOFT BY DESIGN. A miss leaves the fields empty, exactly as today. This
# can only add priced rows, never break a chat or invent a number.
set -uo pipefail
T0="${1:-0}"
SESSIONS="${2:-$HOME/.claude/projects}"
case "$SESSIONS" in
  --cwd=*) SESSIONS="$HOME/.claude/projects/$(printf '%s' "${SESSIONS#--cwd=}" | tr '/' '-')" ;;
esac
ONLY_SID=""
case "${3:-}" in --session=*) ONLY_SID="${3#--session=}" ;; esac

MAXF="${CLAUDE_USAGE_MAX_FILES:-200}"
ERRF=$(mktemp 2>/dev/null || echo /dev/null)
RES=$(MAXF="$MAXF" python3 - "$T0" "$SESSIONS" "$ONLY_SID" 2>"$ERRF" <<'PY'
import json, os, sys, datetime

T0 = float(sys.argv[1] or 0)
ROOT = sys.argv[2]
ONLY = (sys.argv[3] if len(sys.argv) > 3 else "") + ".jsonl"

IN_KEYS = ("input_tokens", "inputTokens", "prompt_tokens")
OUT_KEYS = ("output_tokens", "outputTokens", "completion_tokens")
# Names verified against a real Claude Code session file, not guessed.
CR_KEYS = ("cache_read_input_tokens", "cached_input_tokens", "cache_read_tokens")
CW_KEYS = ("cache_creation_input_tokens", "cache_write_input_tokens", "cache_creation_tokens")

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

def usage_of(o):
    """The usage dict on an assistant turn, at any depth."""
    if isinstance(o, dict):
        i, ou = pick(o, IN_KEYS), pick(o, OUT_KEYS)
        if i is not None or ou is not None:
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

def entry_epoch(o):
    """The entry's own timestamp, so a continued session contributes only this
    call's turns. Unparseable or absent -> counted, because dropping a turn
    undercounts and undercounting is the failure this exists to end."""
    ts = o.get("timestamp") if isinstance(o, dict) else None
    if not ts:
        return None
    try:
        d = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        if d.tzinfo is not None:
            d = d.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        return d.replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return None

files = []
for root, _dirs, names in os.walk(ROOT):
    for fn in names:
        if not fn.endswith(".jsonl"):
            continue
        if ONLY != ".jsonl" and fn != ONLY:
            continue          # --session=: this one session only
        fp = os.path.join(root, fn)
        try:
            mt = os.path.getmtime(fp)
        except OSError:
            continue
        if mt >= T0:
            files.append((mt, fp))
files.sort(reverse=True)

tot_i = tot_o = tot_cr = tot_cw = 0
found = False
# EVERY file in the scope, not the newest one that happens to parse. The break
# that used to sit at the bottom of this loop is what made a scoped question
# ("what did MY turn cost") get answered by somebody else's session.
#
# THE CAP DECLARES ITSELF. A magic number quietly doing safety work is the same
# bug one field over: a scope with more files than this (a long-lived or often
# rotated session) would sum a prefix and print a total that looks complete,
# which reads as a cheap turn — the failure mode that made this whole read
# wrong in the first place. mtime >= T0 already bounds this in practice, so the
# cap is a valve, not a policy; when it engages it says so and exits 3.
MAXF = int(os.environ.get("MAXF") or 200)
skipped = max(0, len(files) - MAXF)
for _mt, fp in files[:MAXF]:
    try:
        for line in open(fp, errors="ignore"):
            if '"usage"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            ep = entry_epoch(o)
            if ep is not None and ep < T0:
                continue          # a turn from before this call
            u = usage_of(o)
            if u is None:
                continue
            i, ou = pick(u, IN_KEYS), pick(u, OUT_KEYS)
            if i is None and ou is None:
                continue
            found = True
            tot_i += i or 0
            tot_o += ou or 0
            tot_cr += pick(u, CR_KEYS) or 0
            tot_cw += pick(u, CW_KEYS) or 0
    except Exception:
        continue

if not found:
    print("|||")
else:
    print(f"{tot_i}|{tot_o}|{tot_cr}|{tot_cw}")

if skipped:
    # Partial totals still go out — a bookkeeping caller is better off with a
    # declared partial than with nothing — but the exit code tells a caller
    # that cannot afford one. turn_cost_usd already treats a failed read as
    # "unchecked" rather than "under budget", so a truncated turn lands on the
    # honest path instead of being priced low.
    sys.stderr.write(
        f"claude-usage: {skipped} file(s) beyond the {MAXF}-file cap not summed "
        f"— TURN UNDERCOUNTED (scope {ROOT}). Raise CLAUDE_USAGE_MAX_FILES or narrow the scope.\n")
    sys.exit(3)
PY
)
RC=$?
[ -n "$RES" ] || RES="|||"
printf '%s\n' "$RES"
if [ "$RC" -eq 3 ]; then
  # Declared where someone will see it: callers redirect stderr to /dev/null by
  # design (instrumentation must never break the thing it measures), so an
  # undercount that only reached stderr would be a truncation nobody is told
  # about — the shape this cap exists to avoid.
  if [ -n "${HARNESS:-}" ] && [ -d "${HARNESS}/logs" ]; then
    FLAG="${HARNESS}/flags/alerted-usage-truncated-$(date -u +%Y%m%d)"
    [ -f "$FLAG" ] || { mkdir -p "${HARNESS}/flags" 2>/dev/null; touch "$FLAG" 2>/dev/null
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [claude-usage] $(cat "$ERRF")" >> "${HARNESS}/logs/ALERTS.log"; }
  fi
  cat "$ERRF" >&2
  rm -f "$ERRF" 2>/dev/null
  exit 3
fi
rm -f "$ERRF" 2>/dev/null
exit 0
