#!/bin/bash
# bin/review-paid-unchanged.sh <fleet-cost.csv> [days=7] [NOW] — BH-3941
# (BH-3930.4): how often a review or lead review was PAID AGAIN on a PR head it
# had already been paid for. Pure: it reads the CSV, prints one JSON object,
# and the only clock is NOW (unix epoch seconds; this wrapper supplies the
# current time when it is absent). bin/cost-rollup.sh runs it every run and
# stores the answer as summary.json's review_paid_unchanged.
#
# Rules (plan D-7):
#   paid     row_source is not refused, settled or unbilled (cost-rollup's agg()).
#   key      guard_fp `<prefix>:<owner>/<repo>#<n>@<40-hex sha>`. The prefixes
#            review, review-prs, review-autopilot and mc-rereview share the key
#            review:<slug>#<n>@<sha>; lead keeps lead:<slug>#<n>@<sha>.
#   reason   `~<reason>` after the sha (stored as `_<reason>`, because
#            call_guard_fp rewrites `~` to `_`) is a named exception: it counts in
#            exempt_by_reason / exempt_by_day and never in the metric or a key's
#            first-free. Trailing digits are dropped (rebuy<epoch> = rebuy).
#   repeat   rows in ts order; the first paid row of a key is free, even before
#            the window. Each later paid row inside the window counts on
#            days[<UTC day>][<lane_id, empty = "null">] and total_by_day.
#   unkeyed  in-window paid lead-review rows whose fp is not lead:-shaped (the
#            legacy `-:-:p<prompt>` rows from before the per-head fp).
#   window   exactly `days` UTC days ending on NOW's day (up to NOW); printed
#            as {from, to}. days, total_by_day and exempt_by_day carry EVERY day
#            of it, zero-filled, so a quiet day is a computed 0, never absent.
# Output: {days, total_by_day, exempt_by_reason, exempt_by_day, unkeyed, top,
#   window, bad_ts}.
#   top: up to 5 keys with a repeat, by repeats, then usd, then key:
#   {key, lane, calls (paid in the window, the free one included), usd (the
#   repeats' cost; usd_partial:true when a cost did not parse)}.
#   bad_ts: review/lead rows whose ts did not parse, left out of every count.
# rc 0 = the JSON; rc 1 = the CSV is unreadable or has no guard_fp column (one
# stderr line, nothing printed); rc 2 = usage.
set -uo pipefail
F="${1:-}"; DAYS="${2:-7}"; NOW="${3:-}"
[ -n "$F" ] && [ -r "$F" ] && [ -f "$F" ] || { echo "usage: bin/review-paid-unchanged.sh <fleet-cost.csv> [days=7] [NOW]: '${F}' is not a readable file" >&2; exit 2; }
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$((10#$DAYS))" -ge 1 ] || { echo "review-paid-unchanged: days '$DAYS' is not a whole number >= 1" >&2; exit 2; }
[ -n "$NOW" ] || NOW=$(date -u +%s)
[[ "$NOW" =~ ^[0-9]+$ ]] || { echo "review-paid-unchanged: NOW '$NOW' is not unix epoch seconds" >&2; exit 2; }
exec python3 - "$F" "$((10#$DAYS))" "$NOW" <<'PY'
import csv, datetime, json, re, sys

path, days, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
UNPAID = ("refused", "settled", "unbilled")
FP = re.compile(r"^(review|review-prs|review-autopilot|mc-rereview|lead):"
                r"([A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+@[0-9a-f]{40})(?:[~_]([a-z0-9]{1,24}))?$")
UTC = datetime.timezone.utc

def epoch(ts):
    ts = (ts or "").strip()
    if not ts:
        return None
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    try:
        d = datetime.datetime.fromisoformat(ts.replace(" ", "T", 1))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=UTC)
    return d.timestamp()

try:
    with open(path, newline="", errors="replace") as fh:
        rd = csv.DictReader(fh)
        if not rd.fieldnames or "guard_fp" not in rd.fieldnames:
            print(f"review-paid-unchanged: {path} has no guard_fp column in its header", file=sys.stderr)
            sys.exit(1)
        rows = list(rd)
except (OSError, csv.Error) as e:
    print(f"review-paid-unchanged: {path} unreadable: {e}", file=sys.stderr)
    sys.exit(1)

today = datetime.datetime.fromtimestamp(now, UTC).date()
first = today - datetime.timedelta(days=days - 1)
d_from, d_to = first.isoformat(), today.isoformat()
window_days = [(first + datetime.timedelta(days=i)).isoformat() for i in range(days)]

seq, bad_ts = [], 0
for i, r in enumerate(rows):
    fp = (r.get("guard_fp") or "").strip()
    lane = (r.get("lane_id") or "").strip() or (r.get("stage") or "").strip()
    m = FP.match(fp)
    if not m and lane != "lead-review":
        continue
    t = epoch(r.get("ts"))
    if t is None:
        bad_ts += 1
        continue
    seq.append((t, i, r, m))
seq.sort(key=lambda x: (x[0], x[1]))

out_days = {d: {} for d in window_days}
total = {d: 0 for d in window_days}
exempt_day = {d: {} for d in window_days}
exempt, unkeyed = {}, 0
keys = {}  # key -> {"paid": bool, "calls": n, "repeats": n, "usd": x, "partial": bool, "lanes": set}
for t, _, r, m in seq:
    if (r.get("row_source") or "").strip() in UNPAID or t > now:
        continue
    day = datetime.datetime.fromtimestamp(t, UTC).date().isoformat()
    inwin = d_from <= day <= d_to
    lane = (r.get("lane_id") or "").strip()
    if not m:
        if inwin:
            unkeyed += 1
        continue
    if m.group(3):
        reason = m.group(3).rstrip("0123456789") or m.group(3)
        if inwin:
            exempt[reason] = exempt.get(reason, 0) + 1
            exempt_day[day][reason] = exempt_day[day].get(reason, 0) + 1
        continue
    key = ("lead" if m.group(1) == "lead" else "review") + ":" + m.group(2)
    k = keys.setdefault(key, {"paid": False, "calls": 0, "repeats": 0, "usd": 0.0, "partial": False, "lanes": set()})
    if inwin:
        k["calls"] += 1
    if not k["paid"]:
        k["paid"] = True
        continue
    if not inwin:
        continue
    ln = lane or "null"
    out_days[day][ln] = out_days[day].get(ln, 0) + 1
    total[day] += 1
    k["repeats"] += 1
    k["lanes"].add(ln)
    try:
        k["usd"] += float((r.get("cost_usd") or "").strip())
    except ValueError:
        k["partial"] = True

top = []
for key, k in sorted(((key, k) for key, k in keys.items() if k["repeats"]),
                     key=lambda kv: (-kv[1]["repeats"], -kv[1]["usd"], kv[0]))[:5]:
    e = {"key": key, "lane": ",".join(sorted(k["lanes"])), "calls": k["calls"], "usd": round(k["usd"], 4)}
    if k["partial"]:
        e["usd_partial"] = True
    top.append(e)

print(json.dumps({"days": out_days, "total_by_day": total, "exempt_by_reason": exempt, "exempt_by_day": exempt_day,
                  "unkeyed": unkeyed,
                  "top": top, "window": {"from": d_from, "to": d_to}, "bad_ts": bad_ts},
                 sort_keys=True))
PY
