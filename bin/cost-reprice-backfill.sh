#!/bin/bash
# bin/cost-reprice-backfill.sh [--since <iso>] [--until <iso>] [--max <rows>] [--sql <file>]
#
# BH-3984 one-off, run BY HAND: reprice historic cost_rows in D1 from their own
# tokens with the fleet's one pricer, cost_price_tokens (bin/lib/cost-row.sh).
# Two populations are wrong in the window:
#   * grok rows that recorded the vendor's costUsdTicks as cost_usd. From
#     BH-3984 on, the grok writers record cost_price_tokens and keep the
#     vendor's figure in result_usd. Historic rows still carry the ticks.
#   * rows with tokens and a BLANK cost_usd (the pool machines whose price
#     table lacked a model when they wrote).
# Rows with no tokens stay blank: there is nothing to price.
#
# HOW. It pages GET /api/metrics/cost-rows?since=&until= newest-first, walking
# `until` back the way bin/cost-rows-lane-backfill.sh does. A candidate is a row
# with any token count where cost_usd IS NULL (any runner) or runner = grok.
# A grok row already within $0.005 of its reprice is skipped. A model the price
# table cannot price is skipped and counted as unpriceable.
#
# IT NEVER WRITES D1 (iron guardrail 2). The default is a dry run: one summary
# block on stdout (rows scanned, candidates by runner|model|stage, recorded vs
# repriced totals, unpriceable models, blank rows without tokens by
# runner|stage) and nothing else. `--sql <file>` also writes one guarded
# UPDATE per candidate, keyed on the (box, row_hash) primary key:
#   ... WHERE box = '..' AND row_hash = '..' AND cost_usd IS NULL;   (blank row)
#   ... WHERE box = '..' AND row_hash = '..' AND cost_usd = <old>;   (grok row)
# so a re-apply, or a row that changed since the read, is a no-op. A human
# applies it from worker/jobs/:
#   npx wrangler d1 execute harness-jobs --remote --file=<file>
# `raw` stays the box's verbatim line, and the vendor's figure stays in
# result_usd. Run it again after the apply and it finds no candidates.
#
# --since defaults to 2026-09-21T00:00:00Z, --until to now, --max (rows read)
# to 30000.
#
# Exit: 0 done, 1 a GET failed or answered something that is not a cost_rows
# page (no SQL file is left behind), 2 usage or jobs not configured, 3 the read
# stopped at --max (or on a page it could not step past) and says the window
# was NOT fully read; what it did read was reported (and, with --sql, written).
set -uo pipefail

SINCE="2026-09-21T00:00:00Z" UNTIL="" MAX=30000 SQL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 || { echo "--since needs a value" >&2; exit 2; } ;;
    --until) UNTIL="${2:-}"; shift 2 || { echo "--until needs a value" >&2; exit 2; } ;;
    --max)   MAX="${2:-}"; shift 2 || { echo "--max needs a value" >&2; exit 2; } ;;
    --sql)   SQL="${2:-}"; shift 2 || { echo "--sql needs a file" >&2; exit 2; } ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SINCE" ] || { echo "--since must not be empty" >&2; exit 2; }
case "$MAX" in ''|*[!0-9]*|0) echo "--max must be a positive integer, got '$MAX'" >&2; exit 2 ;; esac

export HARNESS="${HARNESS:-/root/harness}"
# shellcheck source=bin/jobs-client.sh
. "$(dirname "$0")/jobs-client.sh" || { echo "cannot load bin/jobs-client.sh" >&2; exit 2; }
jobs_configured || { echo "JOBS_URL is not configured — nothing read, nothing written" >&2; exit 2; }
# shellcheck source=bin/lib/cost-row.sh
. "$(dirname "$0")/lib/cost-row.sh" || { echo "cannot load bin/lib/cost-row.sh" >&2; exit 2; }
command -v cost_price_tokens >/dev/null 2>&1 || { echo "bin/lib/cost-row.sh has no cost_price_tokens" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cost-reprice-backfill.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/seen"; : > "$WORK/cand.tsv"; : > "$WORK/blank-notok.tsv"

# _rb <mode> ... — the one python step. Modes:
#   absorb <page> <seen> <cand.tsv> <blank-notok.tsv>
#     print "<rows-in-page> <oldest-ts> <new-distinct>"; append candidates as
#     box|row_hash|runner|model|stage|in|out|cr|cw|old|ttl ('|', which keeps
#     an empty field in `read` where a tab would collapse; old
#     empty for a blank row) and one runner<TAB>stage line per blank row
#     without tokens.
#   report <priced.tsv> <blank-notok.tsv> <scanned>   the summary block
#   sql <priced.tsv> <out>                            the guarded UPDATEs
_rb() {
  python3 - "$@" <<'PYEOF'
import json, re, sys
from collections import Counter
mode = sys.argv[1]
TOK = ("input_toks", "output_toks", "cache_read", "cache_write")
def cell(v):
    return "" if v is None else str(v).replace("|", " ").replace("\t", " ").replace("\n", " ")
if mode == "absorb":
    page, seen_path, cand_path, blank_path = sys.argv[2:6]
    try:
        rows = json.load(open(page, errors="replace")).get("cost_rows")
    except Exception:
        sys.exit(1)
    if not isinstance(rows, list):
        sys.exit(1)
    seen = set(l.rstrip("\n") for l in open(seen_path))
    oldest, new = "", 0
    with open(seen_path, "a") as sf, open(cand_path, "a") as cf, open(blank_path, "a") as bf:
        for r in rows:
            if not isinstance(r, dict):
                continue
            ts = r.get("ts") or ""
            if ts and (not oldest or ts < oldest):
                oldest = ts
            box, rh = str(r.get("box") or ""), str(r.get("row_hash") or "")
            key = box + "\t" + rh
            # `until` is inclusive: rows sharing the oldest second come back on
            # the next page too, and are counted once.
            if not box or not rh or key in seen:
                continue
            seen.add(key); sf.write(key + "\n"); new += 1
            usd = r.get("cost_usd")
            has_tok = any(r.get(k) is not None for k in TOK)
            if not has_tok:
                if usd is None:
                    bf.write("%s\t%s\n" % (cell(r.get("runner")), cell(r.get("stage"))))
                continue
            if usd is not None and r.get("runner") != "grok":
                continue
            # The exact double the route returned: repr() round-trips, so the
            # `cost_usd = <old>` guard matches the stored REAL.
            old = "" if usd is None else repr(float(usd))
            ttl = "1h" if re.search(r"(^|[;\s])cache_ttl=1h($|[;\s])", str(r.get("note") or "")) else ""
            cf.write("|".join([box, rh, cell(r.get("runner")), cell(r.get("model")), cell(r.get("stage"))]
                               + [cell(r.get(k)) for k in TOK] + [old, ttl]) + "\n")
    print(len(rows), oldest, new)
elif mode == "report":
    priced, blank, scanned = sys.argv[2], sys.argv[3], sys.argv[4]
    by, unp = Counter(), Counter()
    n_grok = n_blank = 0
    rec = rep = 0.0
    near = 0
    for line in open(priced):
        f = line.rstrip("\n").split("\t")
        status, runner, model, stage, old, new = f[0], f[3], f[4], f[5], f[10], f[12]
        if status == "unpriceable":
            unp[model] += 1; continue
        if status == "near":
            near += 1; continue
        by["%s|%s|%s" % (runner, model, stage)] += 1
        rep += float(new)
        if old == "":
            n_blank += 1
        else:
            n_grok += 1; rec += float(old)
    nb = Counter(tuple(l.rstrip("\n").split("\t")) for l in open(blank) if l.strip())
    print("scanned %s rows" % scanned)
    print("candidates %d: %d grok rows with a vendor figure, %d blank rows with tokens" % (n_grok + n_blank, n_grok, n_blank))
    for k, v in sorted(by.items(), key=lambda kv: (-kv[1], kv[0])):
        print("  candidate %s %d" % (k, v))
    print("recorded $%.6f on the %d grok candidates (the %d blank candidates record nothing); repriced $%.6f on all %d" % (rec, n_grok, n_blank, rep, n_grok + n_blank))
    print("grok rows already within $0.005 of their reprice: %d (left alone)" % near)
    print("unpriceable %d%s" % (sum(unp.values()), "".join(" unpriceable:%s=%d" % (m, c) for m, c in sorted(unp.items()))))
    print("blank cost_usd rows WITHOUT tokens, left blank: %d" % sum(nb.values()))
    for (rn, st), v in sorted(nb.items(), key=lambda kv: (-kv[1], kv[0])):
        print("  blank-no-tokens %s|%s %d" % (rn or "-", st or "-", v))
elif mode == "sql":
    priced, out = sys.argv[2], sys.argv[3]
    q = lambda s: "'" + s.replace("'", "''") + "'"
    n = 0
    with open(out, "w") as fh:
        fh.write("-- BH-3984 cost_usd reprice, generated by bin/cost-reprice-backfill.sh.\n")
        fh.write("-- Apply by hand, from worker/jobs/:\n")
        fh.write("--   npx wrangler d1 execute harness-jobs --remote --file=<this file>\n")
        fh.write("-- Every statement is guarded on the row's current cost_usd, so a re-apply or a\n")
        fh.write("-- row changed since the read updates nothing. `raw` is left verbatim as the box\n")
        fh.write("-- wrote it, and the vendor's figure stays in result_usd.\n")
        for line in open(priced):
            f = line.rstrip("\n").split("\t")
            if f[0] != "fix":
                continue
            box, rh, old, new = f[1], f[2], f[10], f[12]
            guard = "cost_usd IS NULL" if old == "" else "cost_usd = %s" % old
            fh.write("UPDATE cost_rows SET cost_usd = %s WHERE box = %s AND row_hash = %s AND %s;\n" % (new, q(box), q(rh), guard))
            n += 1
    print(n)
PYEOF
}

# ── read ───────────────────────────────────────────────────────────────────
FETCHED=0 SCANNED=0 COMPLETE=1
while :; do
  LIM=$((MAX - FETCHED)); [ "$LIM" -gt 2000 ] && LIM=2000
  Q="/api/metrics/cost-rows?limit=$LIM&since=$SINCE"
  [ -n "$UNTIL" ] && Q="$Q&until=$UNTIL"
  if ! _jobs_req GET "$Q" > "$WORK/page" 2>/dev/null; then
    echo "GET $Q failed (http=${JOBS_HTTP:-none}) after $SCANNED rows scanned — nothing written" >&2
    exit 1
  fi
  if ! OUT=$(_rb absorb "$WORK/page" "$WORK/seen" "$WORK/cand.tsv" "$WORK/blank-notok.tsv"); then
    echo "GET $Q answered a body that is not a cost_rows page — nothing written" >&2
    exit 1
  fi
  read -r GOT OLDEST NEW <<<"$OUT"
  FETCHED=$((FETCHED + GOT)); SCANNED=$((SCANNED + NEW))
  [ "$GOT" -ge "$LIM" ] || break          # a short page is the end of the window
  [ -n "$OLDEST" ] || break
  if [ "$FETCHED" -ge "$MAX" ] || [ "$NEW" -eq 0 ]; then
    COMPLETE=0; break
  fi
  UNTIL="$OLDEST"
done

# ── price, with the fleet's own pricer ─────────────────────────────────────
# priced.tsv: <status> then the candidate's eleven fields, then the new price.
# status is fix | near (a grok row within $0.005) | unpriceable.
: > "$WORK/priced.tsv"
while IFS='|' read -r box rh runner model stage i o cr cw old ttl; do
  new=$(cost_price_tokens "$model" "$i" "$o" "$cr" "$cw" "$ttl") || new=""
  if [ -z "$new" ]; then st=unpriceable
  elif [ -n "$old" ] && awk -v a="$new" -v b="$old" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=0.005)}'; then st=near
  else st=fix; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$st" "$box" "$rh" "$runner" "$model" "$stage" "$i" "$o" "$cr" "$cw" "$old" "$ttl" "$new" >> "$WORK/priced.tsv"
done < "$WORK/cand.tsv"

_rb report "$WORK/priced.tsv" "$WORK/blank-notok.tsv" "$SCANNED" || { echo "could not build the summary" >&2; exit 1; }
[ "$COMPLETE" = 1 ] || echo "stopped after $FETCHED rows read (--max $MAX, or a full page of one second): the window since $SINCE was NOT fully read; run again with a larger --max"

if [ -z "$SQL" ]; then
  echo "dry run: nothing written (--sql <file> writes the guarded UPDATEs for a human to apply)"
else
  N=$(_rb sql "$WORK/priced.tsv" "$SQL.tmp") && mv -f "$SQL.tmp" "$SQL" || {
    rm -f "$SQL.tmp"; echo "could not write $SQL" >&2; exit 1; }
  echo "wrote $N UPDATE statements to $SQL; apply from worker/jobs/: npx wrangler d1 execute harness-jobs --remote --file=$SQL"
fi
[ "$COMPLETE" = 1 ] || exit 3
exit 0
