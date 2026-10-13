#!/bin/bash
# bin/openrouter-audit.sh — the OpenRouter gap for a window, as one line
# (BH-3998, BH-3983.0). Read-only: two GETs to the jobs worker, nothing written.
#
# Compares what OpenRouter's own meter moved (the vendor_spend rows
# bin/vendor-spend-pull.sh polls hourly) with what our cost_rows say the
# openrouter runner spent over the same span. With OPENROUTER_RECONCILE_KEYS
# set (a comma list of key names, env or env/global.env) the vendor side is the
# summed usage of those keys only; unset, it is the whole account.
#
# usage: openrouter-audit.sh [--since <iso>] [--until <iso>] [--json] [--export <csv>]
#   ISO is YYYY-MM-DDTHH:MM:SSZ; defaults are the last 7 days.
#   e.g. bin/openrouter-audit.sh --since 2026-09-21T00:00:00Z --until 2026-10-03T23:59:59Z
# Output line 1: `openrouter scope= state= vendor_usd= rows_usd= rows_n= unpriced_n= killed_n= span=`
#   (bin/lib/openrouter-ledger.sh documents each field). After it (BH-4001,
#   BH-3983.3) the gap split into four buckets, as a `| bucket | count | usd |
#   attribution |` table, then the per-key table, the per day x model activity
#   section and the per-request section. --json prints the same as one object.
#   The buckets:
#     other-keys     usage on keys not in OPENROUTER_RECONCILE_KEYS (not ours)
#     unpriced-rows  openrouter cost_rows with a blank cost_usd ($ unknown)
#     killed-no-row  openrouter attempts killed with rc 143/137 (failovers.log,
#                    THIS box only) or reaped builds that ran openrouter
#     residual       vendor side minus priced rows, sign kept
#   Activity (GET /api/v1/activity per UTC day) runs only with a management key
#   (OPENROUTER_PROVISIONING_KEY) on this box; --export takes the dashboard's
#   activity CSV, because OpenRouter has no API that lists requests.
#   rc 0 when the ledgers were read; rc 1 and only `could not read: <what>` on
#   stdout when the tracer's read or the audit's own vendor/cost_rows read fails.
#   A refused or odd activity answer is its own state line and keeps rc 0.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# shellcheck source=/dev/null
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
export HARNESS="$H"

usage() { echo "usage: openrouter-audit.sh [--since <iso>] [--until <iso>] [--json] [--export <csv>]" >&2; exit 2; }
SINCE="" UNTIL="" JSON=0 EXPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
    --until) [ $# -ge 2 ] || usage; UNTIL="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --export) [ $# -ge 2 ] || usage; EXPORT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
iso_ago() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$1"; }
[ -n "$UNTIL" ] || UNTIL=$(iso_ago 0)
[ -n "$SINCE" ] || SINCE=$(iso_ago $((7 * 86400)))

# shellcheck source=bin/lib/openrouter-ledger.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/openrouter-ledger.sh"

# The ticket's match thresholds (BH-3983), env-overridable.
ORA_MATCH_SECS="${ORA_MATCH_SECS:-120}"             # a request and its cost row: at most this many seconds apart
ORA_MATCH_TOK_PCT="${ORA_MATCH_TOK_PCT:-2}"         # ...and input tokens within this % of the larger count
ORA_ACTIVITY_MAX_DAYS="${ORA_ACTIVITY_MAX_DAYS:-31}" # /api/v1/activity keeps 30 days; a wider window skips it

# Nothing prints until every required read is in. A failed one prints only this.
cant() {
  echo "could not read: $1"
  echo "openrouter: could not read $1 for $SINCE..$UNTIL" >&2
  exit 1
}

# A copy of env_get in bin/vendor-spend-pull.sh, which is a script with side
# effects and cannot be sourced: <VAR> from the env files, trimmed. The value
# is never printed here; it only goes into curl's Authorization header.
_ora_env_get() {
  local want="$1" f val
  for f in "$HENV/global.env" "$HENV"/*.env; do
    [ -r "$f" ] || continue
    val=$(sed -n "s/^\(export \)\{0,1\}$want=//p" "$f" 2>/dev/null | head -1 | tr -d "\"'\r" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  done
  return 1
}

tline=$(or_ledger_compare "$SINCE" "$UNTIL" "${OPENROUTER_RECONCILE_KEYS:-}"); rc=$?
[ "$rc" -eq 0 ] || cant "the vendor meter or cost_rows (tracer state=unread)"
line="openrouter $tline"
state=$(sed -n 's/.* state=\([^ ]*\).*/\1/p' <<<"$line")
span=$(sed -n 's/.* span=\([^ ]*\).*/\1/p' <<<"$line")
if [ "$state" != ok ] || [ -z "$span" ]; then
  # no-meter or meter-reset: both ledgers were read, there is no delta to split.
  if [ "$JSON" = 1 ]; then
    python3 -c 'import json, sys; print(json.dumps({"line": sys.argv[1], "since": sys.argv[2], "until": sys.argv[3], "span": None, "state": sys.argv[4], "buckets": None}))' "$line" "$SINCE" "$UNTIL" "$state"
  else
    printf '%s\nbuckets: not computed (state=%s)\n' "$line" "$state"
  fi
  exit 0
fi
A_TS=${span%%..*} B_TS=${span##*..}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/or-audit.XXXXXX") || cant "a temp dir"
trap 'rm -rf "$TMPD"' EXIT
# shellcheck source=bin/lib/cost-rows-read.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/cost-rows-read.sh" && _cost_rows_client || cant "the jobs client"
# The same two snapshots the tracer differenced, picked by its span below.
_jobs_req GET "/api/metrics/vendor-spend?vendor=openrouter&since=$A_TS&limit=1000" > "$TMPD/vendor.json" 2>/dev/null \
  || cant "vendor_spend"
# Rows over the span AND the whole UTC days of the window: the buckets read the
# span, the per-day activity join reads whole days.
read -r R_SINCE R_UNTIL DAYS_N DAYS <<<"$(python3 - "$SINCE" "$UNTIL" "$A_TS" "$B_TS" <<'PY'
import datetime as dt, sys
p = lambda s: dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
s, u, a, b = map(p, sys.argv[1:5])
d0, d1 = s.date(), u.date()
days = [(d0 + dt.timedelta(n)).isoformat() for n in range((d1 - d0).days + 1)]
lo = min(a, dt.datetime.combine(d0, dt.time()))
hi = max(b, dt.datetime.combine(d1, dt.time(23, 59, 59)))
f = "%Y-%m-%dT%H:%M:%SZ"
print(lo.strftime(f), hi.strftime(f), len(days), ",".join(days))
PY
)"
[ -n "${DAYS:-}" ] || cant "the window ($SINCE..$UNTIL is not YYYY-MM-DDTHH:MM:SSZ)"
cost_rows_fetch "$TMPD/rows.csv" "$R_SINCE" "$R_UNTIL" 2>/dev/null || cant "cost_rows"

# Per day x model, from OpenRouter itself. Optional: its state is its own line.
ACT_STATE=fetched
mkdir -p "$TMPD/act"
if ! okey=$(_ora_env_get OPENROUTER_PROVISIONING_KEY); then
  ACT_STATE="skipped (no management key on this box)"
elif [ "$DAYS_N" -gt "$ORA_ACTIVITY_MAX_DAYS" ]; then
  ACT_STATE="skipped (window over $ORA_ACTIVITY_MAX_DAYS days; the endpoint keeps 30)"
elif ! obase=$(. "$(dirname "${BASH_SOURCE[0]}")/lib/endpoints.sh" && endpoint_url openrouter 2>/dev/null); then
  ACT_STATE="skipped (no OpenRouter endpoint URL)"
else
  for d in ${DAYS//,/ }; do
    code=$(curl -sS -m "${ORA_HTTP_TIMEOUT:-30}" --connect-timeout 5 -H "Authorization: Bearer $okey" \
      -o "$TMPD/act/$d.json" -w '%{http_code}' "$obase/api/v1/activity?date=$d" 2>/dev/null)
    case "$code" in 2[0-9][0-9]) ;; *) ACT_STATE="could not read (HTTP ${code:-000})"; break ;; esac
  done
fi
unset okey

out=$(ORA_VF="$TMPD/vendor.json" ORA_RF="$TMPD/rows.csv" ORA_A="$A_TS" ORA_B="$B_TS" ORA_SINCE="$SINCE" \
  ORA_UNTIL="$UNTIL" ORA_KEYS="${OPENROUTER_RECONCILE_KEYS:-}" ORA_LINE="$line" ORA_ACT="$ACT_STATE" \
  ORA_ACT_DIR="$TMPD/act" ORA_DAYS="$DAYS" ORA_EXPORT="$EXPORT" ORA_JSON="$JSON" ORA_H="$H" \
  ORA_BOX="$(hostname 2>/dev/null)" ORA_SECS="$ORA_MATCH_SECS" ORA_PCT="$ORA_MATCH_TOK_PCT" \
  python3 - <<'PY'
import csv, datetime as dt, glob, json, os, re, sys
E = lambda k: os.environ.get(k, "")
A, B, SINCE, UNTIL, LINE = E("ORA_A"), E("ORA_B"), E("ORA_SINCE"), E("ORA_UNTIL"), E("ORA_LINE")
KEYS = [k.strip() for k in E("ORA_KEYS").split(",") if k.strip()]
num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
usd = lambda v: "unknown" if v is None else "%.2f" % v
cell = lambda v: "" if v is None else "%.2f" % v
row = lambda *c: "| " + " | ".join(str(x) for x in c) + " |"
norm = lambda m: re.sub(r"^openrouter/", "", (m or "").strip().lower())

# vendor: the tracer's a and b
try:
    vrows = json.load(open(E("ORA_VF")))["vendor_spend"]
    pick = lambda ts: next(r for r in vrows if r.get("ts") == ts and r.get("status") == "ok")
    a, b = pick(A), pick(B)
except Exception:
    sys.exit(3)

def keymap(r):
    try:
        raw = r.get("raw")
        raw = json.loads(raw) if isinstance(raw, str) else raw
        assert isinstance(raw["keys"], list)
        return {k["name"]: k.get("usage") for k in raw["keys"] if isinstance(k, dict) and k.get("name")}
    except Exception:
        return None

# per key
ka, kb = keymap(a), keymap(b)
keys = []
keys_state = "ok" if ka is not None and kb is not None else "unread (no per-key data in the vendor rows)"
if keys_state == "ok":
    for n in sorted(set(ka) | set(kb)):
        ua, ub = ka.get(n), kb.get(n)
        ua, ub = (float(ua) if num(ua) else None), (float(ub) if num(ub) else None)
        cls, delta = ("harness" if n in KEYS else "other") if KEYS else "unclassified", None
        if ua is None or ub is None:
            cls = "unreadable"
        elif ub - ua < 0:
            cls = "meter-reset"
        else:
            delta = round(ub - ua, 2)
        keys.append({"name": n, "class": cls, "usage_a": ua, "usage_b": ub, "delta": delta})
    keys.sort(key=lambda k: (-(k["delta"] or 0), k["name"]))
unreadable_n = sum(k["class"] in ("unreadable", "meter-reset") for k in keys)

# cost rows, openrouter only
allrows = [r for r in csv.DictReader(open(E("ORA_RF"), newline="")) if (r.get("runner") or "") == "openrouter"]
cost = lambda r: float(r["cost_usd"]) if (r.get("cost_usd") or "").strip() else None
span_rows = [r for r in allrows if A <= (r.get("ts") or "") <= B]
rows_usd = round(sum(cost(r) or 0 for r in span_rows), 2)

def attrib(rs):
    g = {}
    for r in rs:
        k = (r.get("runner") or "", r.get("stage") or "", r.get("host") or "", r.get("project") or "")
        x = g.setdefault(k, {"runner": k[0], "stage": k[1], "box": k[2], "project": k[3], "count": 0, "usd": None})
        x["count"] += 1
    return sorted(g.values(), key=lambda x: -x["count"])

buckets = []
# other-keys
if not KEYS:
    buckets.append({"name": "other-keys", "count": None, "usd": None, "attribution": [],
                    "note": "unread (OPENROUTER_RECONCILE_KEYS unset)"})
elif keys_state != "ok":
    buckets.append({"name": "other-keys", "count": None, "usd": None, "attribution": [], "note": keys_state})
else:
    oth = [k for k in keys if k["class"] == "other" and k["delta"] is not None]
    buckets.append({"name": "other-keys", "count": len(oth), "usd": round(sum(k["delta"] for k in oth), 2),
                    "attribution": [{"key": k["name"], "usd": k["delta"]} for k in oth]})
# unpriced-rows
unp = [r for r in span_rows if cost(r) is None]
buckets.append({"name": "unpriced-rows", "count": len(unp), "usd": None, "attribution": attrib(unp)})

# killed-no-row: this box's failovers.log, and reaped builds that ran openrouter
H, box = E("ORA_H"), E("ORA_BOX")
iso = lambda s: s.replace(" ", "T")
kills, knote = {}, "failovers.log is this box's only"
kre = re.compile(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}Z) \[([^\]]*)\] (\S+) "
                 r"(?:openrouter: .* rc=(?:143|137)\b|openrouter was killed from outside \(rc=(?:143|137)\))")
try:
    for ln in open(os.path.join(H, "logs", "failovers.log"), errors="replace"):
        m = kre.match(ln)
        if m and SINCE <= iso(m.group(1)) <= UNTIL:
            kills.setdefault((m.group(2), m.group(3)), 0)
            kills[(m.group(2), m.group(3))] += 1
except OSError:
    knote = "failovers.log absent on this box"
for d in sorted(glob.glob(os.path.join(H, "builds", "*", ""))):
    try:
        if not open(os.path.join(d, "RESULT")).read().startswith("ABANDONED_TIMEOUT"):
            continue
        t = dt.datetime.fromtimestamp(os.path.getmtime(os.path.join(d, "REAPED")), dt.timezone.utc)
        if not SINCE <= t.strftime("%Y-%m-%dT%H:%M:%SZ") <= UNTIL:
            continue
        if not any(open(f).readline().strip() == "openrouter" for f in glob.glob(os.path.join(d, "*.runner"))):
            continue
    except OSError:
        continue
    k = (os.path.basename(d.rstrip("/")), "")
    kills[k] = kills.get(k, 0) + 1
killed_n = re.search(r" killed_n=(\S*)", LINE)
buckets.append({"name": "killed-no-row", "count": sum(kills.values()), "usd": None,
                "attribution": [{"runner": "openrouter", "stage": s, "box": box, "project": p, "count": n, "usd": None}
                                for (p, s), n in sorted(kills.items())],
                "note": "rows_with_kill_note=%s; %s" % (killed_n.group(1) if killed_n else "", knote)})
# residual
if KEYS:
    vside = sum(k["delta"] for k in keys if k["class"] == "harness" and k["delta"] is not None)
else:
    vside = float(b["cumulative_usd"]) - float(a["cumulative_usd"])
buckets.append({"name": "residual", "count": 1, "usd": round(vside - rows_usd, 2), "attribution": [],
                "note": "see per-key / activity / requests sections"})

# per day x model
act_state, act_rows = E("ORA_ACT"), []
DAYS = [d for d in E("ORA_DAYS").split(",") if d]
if act_state == "fetched":
    vend = {}
    try:
        for d in DAYS:
            data = json.load(open(os.path.join(E("ORA_ACT_DIR"), d + ".json")))["data"]
            assert isinstance(data, list)
            for e in data:
                assert isinstance(e, dict) and isinstance(e.get("model"), str) and num(e.get("usage"))
                vend[(d, norm(e["model"]))] = vend.get((d, norm(e["model"])), 0.0) + e["usage"]
        act_state = "ok"
    except Exception:
        act_state = "unparseable"
    if act_state == "ok":
        mine = {}
        for r in allrows:
            day = (r.get("ts") or "")[:10]
            if day in DAYS:
                mine[(day, norm(r.get("model")))] = mine.get((day, norm(r.get("model"))), 0.0) + (cost(r) or 0)
        for k in sorted(set(vend) | set(mine)):
            v, m = round(vend.get(k, 0.0), 2), round(mine.get(k, 0.0), 2)
            g = round(v - m, 2)
            act_rows.append({"day": k[0], "model": k[1], "vendor_usd": v, "rows_usd": m, "gap_usd": g,
                             "unmatched": (v > 0 and m == 0) or abs(g) >= 0.01})

# per request, from the dashboard export
req = {"state": "not run (no --export csv)", "matched_n": None, "unmatched": []}
if E("ORA_EXPORT"):
    alias = [("ts", ("created_at", "timestamp", "date")), ("model", ("model", "model_permaslug")),
             ("input tokens", ("tokens_prompt", "prompt_tokens", "native_tokens_prompt")),
             ("usd", ("cost", "usage", "total_cost"))]
    try:
        rdr = csv.DictReader(open(E("ORA_EXPORT"), newline="", errors="replace"))
        hdr = {(h or "").strip().lower(): h for h in (rdr.fieldnames or [])}
        col = {}
        for want, names in alias:
            col[want] = next((hdr[n] for n in names if n in hdr), None)
            if col[want] is None:
                raise LookupError(want)
        reqs = []
        for r in rdr:
            ts = dt.datetime.strptime(r[col["ts"]].strip().replace(" ", "T")[:19], "%Y-%m-%dT%H:%M:%S")
            iz = ts.strftime("%Y-%m-%dT%H:%M:%SZ")
            if SINCE <= iz <= UNTIL:
                reqs.append((ts, iz, r[col["model"]].strip(), float(r[col["input tokens"]] or 0),
                             float(r[col["usd"]]) if (r[col["usd"]] or "").strip() else None))
        req["state"] = "ok"
    except LookupError as e:
        req["state"] = "unparseable (no %s column)" % e.args[0]
    except (OSError, ValueError, KeyError, TypeError):
        req["state"] = "unparseable (could not read %s)" % os.path.basename(E("ORA_EXPORT"))
    if req["state"] == "ok":
        cands = []
        for r in sorted(allrows, key=lambda r: r.get("ts") or ""):
            try:
                cands.append([dt.datetime.strptime(r["ts"][:19], "%Y-%m-%dT%H:%M:%S"), norm(r.get("model")),
                              float(r.get("input_toks") or ""), False])
            except ValueError:
                pass
        secs, pct = float(E("ORA_SECS")), float(E("ORA_PCT")) / 100.0
        for ts, iz, model, toks, u in sorted(reqs):
            c = next((c for c in cands if not c[3] and abs((c[0] - ts).total_seconds()) <= secs
                      and c[1] == norm(model) and abs(c[2] - toks) <= pct * max(c[2], toks)), None)
            if c:
                c[3] = True
            else:
                req["unmatched"].append({"ts": iz, "model": model, "usd": u})
        req["matched_n"] = len(reqs) - len(req["unmatched"])

if E("ORA_JSON") == "1":
    print(json.dumps({"line": LINE, "since": SINCE, "until": UNTIL, "span": A + ".." + B,
                      "keys_state": keys_state, "keys": keys,
                      "activity": {"state": act_state, "rows": act_rows}, "requests": req, "buckets": buckets}))
    sys.exit()

def top(parts, n=5):  # the markdown cell names the biggest groups; --json carries them all
    return parts[:n] + (["+%d more groups (--json lists them)" % (len(parts) - n)] if len(parts) > n else [])

o = [LINE, "", row("bucket", "count", "usd", "attribution"), "|---|---|---|---|"]
for bk in buckets:
    if bk["name"] == "other-keys":
        at = "; ".join("%s %.2f" % (x["key"], x["usd"]) for x in bk["attribution"]) or bk.get("note", "")
    elif bk["name"] == "unpriced-rows":
        at = "; ".join(top(["%s/%s@%s %s x%d" % (x["runner"], x["stage"], x["box"], x["project"], x["count"])
                            for x in bk["attribution"]]))
    elif bk["name"] == "killed-no-row":
        at = "; ".join(top(["%s/%s@%s x%d" % (x["project"], x["stage"], x["box"], x["count"])
                            for x in bk["attribution"]]) + [bk["note"]])
    else:
        at = bk["note"]
    o.append(row(bk["name"], "unread" if bk["count"] is None else bk["count"], usd(bk["usd"]), at))
o += ["", "keys: %s (OPENROUTER_RECONCILE_KEYS=%s)" % (keys_state, ",".join(KEYS) or "unset")]
if keys_state == "ok":
    o.append("keys unreadable (in one snapshot only): %d" % unreadable_n)
    o += [row("key", "class", "usage_a", "usage_b", "delta"), "|---|---|---|---|---|"]
    o += [row(k["name"], k["class"], cell(k["usage_a"]), cell(k["usage_b"]), cell(k["delta"])) for k in keys]
o.append("")
if act_state == "ok":
    um = [r for r in act_rows if r["unmatched"]]
    o.append("activity: ok (%d days, %d day x model cells, %d unmatched; models lowercased, openrouter/ stripped)"
             % (len(DAYS), len(act_rows), len(um)))
    if um:
        o += [row("cell", "day", "model", "vendor_usd", "rows_usd", "gap_usd"), "|---|---|---|---|---|---|"]
        o += [row("unmatched", r["day"], r["model"], usd(r["vendor_usd"]), usd(r["rows_usd"]), usd(r["gap_usd"]))
              for r in um]
else:
    o.append("activity: " + act_state)
o.append("")
if E("ORA_EXPORT"):
    o.append("requests: per-request match from the dashboard export; OpenRouter has no API that lists requests")
if req["state"] == "ok":
    o.append("requests: ok (matched %d, unmatched %d)" % (req["matched_n"], len(req["unmatched"])))
    if req["unmatched"]:
        o += [row("unmatched request", "ts", "model", "usd"), "|---|---|---|---|"]
        o += [row("request", r["ts"], r["model"], usd(r["usd"])) for r in req["unmatched"]]
else:
    o.append("requests: " + req["state"])
print("\n".join(o))
PY
)
prc=$?
[ "$prc" -eq 3 ] && cant "vendor_spend (the tracer's span rows are not in the answer)"
[ "$prc" -eq 0 ] || cant "the audit's own inputs (python rc=$prc)"
printf '%s\n' "$out"
