#!/bin/bash
# bin/lib/openrouter-ledger.sh — the OpenRouter gap, from the two ledgers we
# already persist (BH-3998, BH-3983.0). Sourced, never executed; sourcing only
# defines or_ledger_compare.
#
# Vendor side: the hourly `vendor_spend` rows bin/vendor-spend-pull.sh writes.
# Read through GET /api/metrics/vendor-spend as JSON, not through
# `jobs-client.sh metric-vendor-spends`, because that verb's TSV drops
# `cumulative_usd` and `raw`, and both are what this compares.
# Rows side: `cost_rows` over the vendor's own span, via cost_rows_fetch, kept
# to runner == openrouter here (the worker's ?runner= filter is not passed:
# cost_rows_fetch is shared by seven callers and carries no runner argument).
#
# or_ledger_compare <since-iso> <until-iso> [keys-csv]
#   Prints exactly one line:
#     scope=<account|harness-keys> state=<ok|no-meter|meter-reset|unread>
#     vendor_usd= rows_usd= rows_n= unpriced_n= killed_n= span=<a.ts>..<b.ts>
#   A value that was not measured prints EMPTY, never 0. rc 1 on unread (a
#   failed or capped read, or a named key missing from either snapshot), rc 0
#   otherwise. Key names are never printed, only their summed usage.
#
# Root: ${HARNESS:-${H:-}} and nothing else (D43); with neither, unread.

or_ledger_compare() {
  local since="${1:-}" until="${2:-}" keys="${3:-}"
  local scope=account; [ -n "$keys" ] && scope=harness-keys
  local state=unread vusd="" a_ts="" b_ts="" rusd="" rn="" un="" kn="" vf="" rf="" pick vsince
  _orl_line() {
    printf 'scope=%s state=%s vendor_usd=%s rows_usd=%s rows_n=%s unpriced_n=%s killed_n=%s span=%s\n' \
      "$scope" "$state" "$vusd" "$rusd" "$rn" "$un" "$kn" "${a_ts:+$a_ts..$b_ts}"
    rm -f ${vf:+"$vf"} ${rf:+"$rf" "$rf.boxes"}
    [ "$state" != unread ]
  }
  [ -n "${HARNESS:-${H:-}}" ] && [ -n "$since" ] && [ -n "$until" ] || { _orl_line; return; }
  # shellcheck source=bin/lib/cost-rows-read.sh
  . "$(dirname "${BASH_SOURCE[0]}")/cost-rows-read.sh" 2>/dev/null && _cost_rows_client || { _orl_line; return; }

  vsince=$(python3 -c 'import sys, datetime as d
t = d.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ") - d.timedelta(hours=6)
print(t.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$since" 2>/dev/null) || { _orl_line; return; }
  vf=$(mktemp "${TMPDIR:-/tmp}/or-ledger-vendor.XXXXXX") || { _orl_line; return; }
  _jobs_req GET "/api/metrics/vendor-spend?vendor=openrouter&since=$vsince&limit=1000" > "$vf" 2>/dev/null \
    || { _orl_line; return; }

  pick=$(python3 - "$vf" "$since" "$until" "$keys" <<'PY'
import json, sys
f, since, until, keys = sys.argv[1:5]
try:
    rows = json.load(open(f))["vendor_spend"]
    assert isinstance(rows, list)
except Exception:
    print("unread"); sys.exit()
# The route caps at 1000, newest first: a full answer whose oldest row is after
# `since` lost the rows that would have been `a`.
if len(rows) >= 1000 and min(r.get("ts") or "" for r in rows) > since:
    print("unread"); sys.exit()
num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
ok = sorted((r for r in rows if r.get("status") == "ok" and num(r.get("cumulative_usd"))
             and (r.get("ts") or "") <= until), key=lambda r: r["ts"])
if len(ok) < 2:
    print("no-meter"); sys.exit()
before = [r for r in ok if r["ts"] <= since]
a, b = (before[-1] if before else ok[0]), ok[-1]
if a is b:
    print("no-meter"); sys.exit()
span = "%s %s" % (a["ts"], b["ts"])
if not keys:
    delta = b["cumulative_usd"] - a["cumulative_usd"]
else:
    def usage(r, name):
        raw = r.get("raw")
        raw = json.loads(raw) if isinstance(raw, str) else raw
        u = next(k for k in raw["keys"] if k.get("name") == name)["usage"]
        assert num(u)
        return u
    try:
        delta = sum(usage(b, n) - usage(a, n) for n in keys.split(",") if n)
    except Exception:
        print("unread - " + span); sys.exit()
print(("meter-reset - " if delta < 0 else "ok %.2f " % delta) + span)
PY
) || pick=unread
  read -r state vusd a_ts b_ts <<<"$pick"
  [ "$vusd" = - ] && vusd=""
  [ -n "$b_ts" ] && [ "$state" != unread ] || { _orl_line; return; }

  # Rows side. Any failure from here is unread, never a zero.
  local vstate="$state"; state=unread
  cost_rows_db_enabled || { _orl_line; return; }
  rf=$(mktemp "${TMPDIR:-/tmp}/or-ledger-rows.XXXXXX") || { _orl_line; return; }
  cost_rows_fetch "$rf" "$a_ts" "$b_ts" || { _orl_line; return; }
  local sums
  sums=$(python3 - "$rf" <<'PY'
import csv, sys
usd, n, un, kn = 0.0, 0, 0, 0
for r in csv.DictReader(open(sys.argv[1], newline="")):
    if (r.get("runner") or "") != "openrouter":
        continue
    n += 1
    c = (r.get("cost_usd") or "").strip()
    if c:
        usd += float(c)
    else:
        un += 1
    if "killed:sig=" in (r.get("note") or ""):
        kn += 1
print("%.2f %d %d %d" % (usd, n, un, kn))
PY
) || { _orl_line; return; }
  read -r rusd rn un kn <<<"$sums"
  state="$vstate"
  _orl_line
}
