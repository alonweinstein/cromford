#!/bin/bash
# bin/cost-rows-lane-backfill.sh [--apply] [--since <iso>] [--max <rows>]
#
# BH-3220 one-shot: refill lane_id / guard_fp on cost_rows that the immediate
# emitter posted without them. Until BH-3220 _cost_row_emit_body cut every row
# at `note`, its row landed first, and ON CONFLICT DO NOTHING threw the */10
# mirror's full copy away. The stored `raw` still carries both values (fields
# 25 and 26), so nothing is lost; this reads them back out.
#
# HOW. It pages GET /api/metrics/cost-rows?since=&until= newest-first, walking
# `until` back the way bin/lib/cost-rows-read.sh does, and picks rows where
# lane_id or guard_fp is NULL, `raw` hashes to the row's own row_hash, and raw
# has at least 25 fields. It re-POSTs each such row to POST
# /api/metrics/cost-rows with its OWN stored row_hash and line_no and the
# rebuilt lane_id (field 25) and guard_fp (field 26), grouped by box, at most
# 2000 rows per request. The route's conflict clause does the repair: it fills
# a NULL from the incoming row and never overwrites a value that is set. No new
# route, no hand SQL against D1. It needs the BH-3220 worker deployed first.
#
# Dry-run is the DEFAULT: it prints what it would repair and sends nothing.
# `--apply` sends. `--since` defaults to 2026-09-25T00:00:00Z (the day BH-2303
# landed lane_id); `--max` defaults to 20000 rows read. Run it again and it
# finds nothing left to repair: repaired rows are no longer NULL.
#
# Exit: 0 done (dry-run, or every POST answered 2xx and the worker reported the
# repairs), 1 a GET or POST failed, or the worker repaired nothing it was sent
# (a worker that predates the repair clause), 2 usage or jobs not configured,
# 3 the run stopped at --max (or on a page it could not step past) and says
# the window was NOT fully read; what it did read was reported (and, with
# --apply, sent) as usual.
set -uo pipefail

APPLY=0 SINCE="2026-09-25T00:00:00Z" MAX=20000
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --since) SINCE="${2:-}"; shift 2 || { echo "--since needs a value" >&2; exit 2; } ;;
    --max)   MAX="${2:-}"; shift 2 || { echo "--max needs a value" >&2; exit 2; } ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SINCE" ] || { echo "--since must not be empty" >&2; exit 2; }
case "$MAX" in ''|*[!0-9]*|0) echo "--max must be a positive integer, got '$MAX'" >&2; exit 2 ;; esac

# shellcheck source=bin/jobs-client.sh
. "$(dirname "$0")/jobs-client.sh" || { echo "cannot load bin/jobs-client.sh" >&2; exit 2; }
jobs_configured || { echo "JOBS_URL is not configured — nothing read, nothing sent" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cost-rows-lane-backfill.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/seen"; : > "$WORK/repair.jsonl"

# _bf <mode> ... — the one python step. Modes:
#   absorb <page> <seen> <repair.jsonl>
#     print "<rows-in-page> <oldest-ts> <new-distinct> <new-repairable> <new-unrepairable>"
#   split <repair.jsonl> <outdir>
#     write one body per box per 2000 rows to <outdir>/NNNN.json, print the
#     per-box counts as "box=n box=n"
_bf() {
  python3 - "$@" <<'PYEOF'
import csv, hashlib, json, os, sys
mode = sys.argv[1]
if mode == "absorb":
    page, seen_path, out_path = sys.argv[2], sys.argv[3], sys.argv[4]
    try:
        rows = json.load(open(page, errors="replace")).get("cost_rows")
    except Exception:
        sys.exit(1)
    if not isinstance(rows, list):
        sys.exit(1)
    seen = set(l.rstrip("\n") for l in open(seen_path))
    oldest, new, rep, unrep = "", 0, 0, 0
    with open(seen_path, "a") as sf, open(out_path, "a") as of:
        for r in rows:
            if not isinstance(r, dict):
                continue
            ts = r.get("ts") or ""
            if ts and (not oldest or ts < oldest):
                oldest = ts
            box, rh = str(r.get("box") or ""), str(r.get("row_hash") or "")
            key = box + "\t" + rh
            # The `until` bound is inclusive: the rows sharing the oldest second
            # come back on the next page too, and are counted once.
            if not box or not rh or key in seen:
                continue
            seen.add(key); sf.write(key + "\n"); new += 1
            if r.get("lane_id") is not None and r.get("guard_fp") is not None:
                continue
            raw = r.get("raw")
            lane = gfp = None
            # Only a raw that hashes to its own row_hash is the line the box
            # wrote; a raw cut at the column's 4096 cap is not read for fields.
            if isinstance(raw, str) and hashlib.sha256(raw.encode("utf-8", "replace")).hexdigest() == rh:
                f = next(csv.reader([raw]), [])
                if len(f) >= 25:
                    lane = f[24] or None
                    gfp = (f[25] or None) if len(f) >= 26 else None
            fill_lane = r.get("lane_id") is None and lane is not None
            fill_gfp = r.get("guard_fp") is None and gfp is not None
            if not (fill_lane or fill_gfp):
                unrep += 1
                continue
            body = {k: v for k, v in r.items() if k not in ("box", "inserted_at")}
            if fill_lane:
                body["lane_id"] = lane
            if fill_gfp:
                body["guard_fp"] = gfp
            of.write(json.dumps({"box": box, "row": body}) + "\n")
            rep += 1
    print(len(rows), oldest, new, rep, unrep)
elif mode == "split":
    src, outdir = sys.argv[2], sys.argv[3]
    by = {}
    for line in open(src):
        e = json.loads(line)
        by.setdefault(e["box"], []).append(e["row"])
    n = 0
    for box in sorted(by):
        rows = by[box]
        for i in range(0, len(rows), 2000):
            n += 1
            with open(os.path.join(outdir, "%04d.json" % n), "w") as fh:
                json.dump({"box": box, "rows": rows[i:i + 2000]}, fh)
    print(" ".join("%s=%d" % (b, len(by[b])) for b in sorted(by)) or "none")
PYEOF
}

# ── read ───────────────────────────────────────────────────────────────────
FETCHED=0 SCANNED=0 REPAIRABLE=0 UNREPAIRABLE=0 UNTIL="" COMPLETE=1
while :; do
  LIM=$((MAX - FETCHED)); [ "$LIM" -gt 2000 ] && LIM=2000
  Q="/api/metrics/cost-rows?limit=$LIM&since=$SINCE"
  [ -n "$UNTIL" ] && Q="$Q&until=$UNTIL"
  if ! _jobs_req GET "$Q" > "$WORK/page" 2>/dev/null; then
    echo "GET $Q failed (http=${JOBS_HTTP:-none}) after $SCANNED rows scanned — nothing sent" >&2
    exit 1
  fi
  if ! OUT=$(_bf absorb "$WORK/page" "$WORK/seen" "$WORK/repair.jsonl"); then
    echo "GET $Q answered a body that is not a cost_rows page — nothing sent" >&2
    exit 1
  fi
  read -r GOT OLDEST NEW REP UNREP <<<"$OUT"
  FETCHED=$((FETCHED + GOT)); SCANNED=$((SCANNED + NEW))
  REPAIRABLE=$((REPAIRABLE + REP)); UNREPAIRABLE=$((UNREPAIRABLE + UNREP))
  [ "$GOT" -ge "$LIM" ] || break          # a short page is the end of the window
  [ -n "$OLDEST" ] || break
  if [ "$FETCHED" -ge "$MAX" ] || [ "$NEW" -eq 0 ]; then
    # --max reached, or a full page of rows all sharing one second that this
    # walk cannot step past: either way the window was not fully read.
    COMPLETE=0; break
  fi
  UNTIL="$OLDEST"
done
[ "$COMPLETE" = 1 ] || echo "stopped after $FETCHED rows read (--max $MAX, or a full page of one second): the window since $SINCE was NOT fully scanned; run again with a larger --max"

mkdir -p "$WORK/bodies"
BYBOX=$(_bf split "$WORK/repair.jsonl" "$WORK/bodies") || { echo "could not build the request bodies" >&2; exit 1; }

if [ "$APPLY" = 0 ]; then
  echo "would repair $REPAIRABLE of $SCANNED scanned (by box: $BYBOX); unrepairable $UNREPAIRABLE"
  echo "scanned $SCANNED, repairable $REPAIRABLE, unrepairable $UNREPAIRABLE, sent 0, repaired 0 (dry-run; --apply sends)"
  [ "$COMPLETE" = 1 ] || exit 3
  exit 0
fi

# ── apply ──────────────────────────────────────────────────────────────────
SENT=0 REPAIRED=0
for B in "$WORK"/bodies/*.json; do
  [ -f "$B" ] || continue
  N=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["rows"]))' "$B")
  if ! _jobs_req_file POST /api/metrics/cost-rows "$B" > "$WORK/resp" 2>/dev/null; then
    echo "POST failed (http=${JOBS_HTTP:-none}) after $SENT of $REPAIRABLE rows sent, $REPAIRED repaired — stopped; a re-run resumes, repaired rows are no longer NULL" >&2
    echo "scanned $SCANNED, repairable $REPAIRABLE, unrepairable $UNREPAIRABLE, sent $SENT, repaired $REPAIRED (from the worker's inserted)"
    exit 1
  fi
  INS=$(sed -n 's/.*"inserted":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$WORK/resp" | head -1)
  SENT=$((SENT + N)); REPAIRED=$((REPAIRED + ${INS:-0}))
done
echo "scanned $SCANNED, repairable $REPAIRABLE, unrepairable $UNREPAIRABLE, sent $SENT, repaired $REPAIRED (from the worker's inserted)"
if [ "$SENT" -gt 0 ] && [ "$REPAIRED" -eq 0 ]; then
  echo "the worker repaired none of the $SENT rows it was sent — it predates the BH-3220 repair clause; deploy the worker, then run this again" >&2
  exit 1
fi
[ "$COMPLETE" = 1 ] || exit 3
exit 0
