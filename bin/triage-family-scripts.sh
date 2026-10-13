#!/bin/bash
# bin/triage-family-scripts.sh <filtered-file> <settled-file> <removed-fams-out>
#
# The alert-family registry pass of bin/alert-triage.sh (BH-2544). The lane
# calls it once per tick, between FIX-PR ANSWERED and DETERMINISTIC SETTLEMENT,
# unless the switch triage-registry-off is on. The lane reads it through
# lane_switch (BH-2320): the settings row switch.triage-registry-off.<box>, then
# switch.triage-registry-off, and flags/triage-registry-off only when no row
# exists. A non-zero exit is logged by the lane and the tick continues.
#
# One pass: fetch the enabled registry rows once, match whole families, run at
# most TRIAGE_VERIFY_MAX verify scripts inside TRIAGE_VERIFY_DEADLINE_S, settle
# or park what they decide, and log one summary line to stderr (the lane appends
# stderr to its log):
#   triage pass: REGISTRY rows=N matched=N cleared=N parked=N repro=N unknown=N unchecked=N
# A registry that cannot be read (no client, no route yet, worker down) is ONE
# `REGISTRY unavailable` line and exit 0 with no file touched: every family keeps
# its session, exactly as before the registry existed. No model is called here.
#
# ── THE PROTOCOL (what the runner sibling implements) ────────────────────────
# * Registry: rows come from D1 table `alert_family_scripts` through the client
#   function `alert_family_scripts` in bin/lib/jobs/alerts.sh. Enabled rows
#   only, in `priority`,`id` order. A row whose id, match_kind, match (empty
#   matches everything), verify name, on_clear/on_repro or line_regex (does not
#   compile) is invalid is refused with one log line and the tick goes on.
# * Matching: a family is handled only when EVERY one of its lines has the same
#   winner, the first row in that order that matches it. `akey_prefix` tests the
#   beat's `akey` and never its text; `line_regex` is re.match (anchored) on the
#   beat's `.line`. A payload that is not a JSON object matches nothing.
# * <filtered-file> is the lane's $FILTERED, `family<TAB>tier<TAB>raw line`. The
#   runner rewrites it IN PLACE and atomically (temp file + mv), removing every
#   family it settled or parked. Families it did not decide stay byte-for-byte.
# * <settled-file> is the lane's $SETTLED. The runner APPENDS one line per
#   settled alert line: `verify:<row-id>: <proof><TAB><raw line>`. The lane logs
#   each as NOISE-STALE in its settlement block.
# * <removed-fams-out> gets one family key per line for every family removed
#   from <filtered-file>. The lane puts each back at its pre-tick stamp
#   (triage_restore_stamp), so a family nobody judged is not inside the 6h brake.
# * Verify scripts live at $HARNESS/bin/alert-verify/<name>.sh, and <name> must
#   match ^[a-z0-9-]{1,48}$. Stdin is the family's raw quarantine lines
#   (`cut -f3-` of <filtered-file>: source<TAB>epoch<TAB>payload).
#     exit 0, first stdout line non-empty  -> cleared; that line is the proof
#     exit 0, empty stdout                 -> unknown, family kept
#     exit 1                               -> still reproduces (row's on_repro)
#     anything else (75, 124, missing file) -> unknown, family kept
#   Verify scripts are read-only and carry no model id and no LLM call. A
#   matched row with no verify is unknown, and uses no verify slot.
# * Cleared + on_clear=settle: settled lines are appended and the key written to
#   <removed-fams-out> BEFORE <filtered-file> is replaced, so a crash in between
#   leaves the family both settled and sessioned, never dropped. `model` keeps it.
# * Repro + on_repro=park: `PARKED by registry row <id>` is logged FIRST, then
#   alert_state_set <alertid> parked alert-triage for each `"dbrow":true` line.
#   The family is removed only when every one of those came back parked; a
#   refused write (409 on an already-parked row too), or a family with no alerts
#   row at all, keeps its session. `model` keeps it.
# * Bounds, from the lane's catalog knobs (catalog/lanes.d/alert-triage.json):
#   TRIAGE_VERIFY_TIMEOUT_S (default 20) seconds per verify script,
#   TRIAGE_VERIFY_MAX (default 20, 0 = off) verifies per tick,
#   TRIAGE_VERIFY_DEADLINE_S (default 120) seconds for the whole pass; each
#   verify's timeout is clamped to what is left of it. A value that is not an
#   integer falls back to the default.
#   Work past a bound is left in <filtered-file> for a session, never dropped,
#   and counted in unchecked=.
set -u
[ "$#" -eq 3 ] || { echo "usage: triage-family-scripts.sh <filtered-file> <settled-file> <removed-fams-out>" >&2; exit 64; }
FILTERED="$1" SETTLED="$2" REMOVED="$3"
HARNESS="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') triage pass: REGISTRY $*" >&2; }
knob() { case "${1:-}" in ''|*[!0-9]*) echo "$2" ;; *) echo "$((10#$1))" ;; esac; }
# One client call in a subshell: a missing or half-synced jobs client exits the
# subshell, not this pass.
jc() { ( . "$HARNESS/bin/jobs-client.sh" 2>/dev/null || exit 1; "$@" ); }
V_TIMEOUT=$(knob "${TRIAGE_VERIFY_TIMEOUT_S:-}" 20); [ "$V_TIMEOUT" -ge 1 ] || V_TIMEOUT=20
V_MAX=$(knob "${TRIAGE_VERIFY_MAX:-}" 20)
V_DEADLINE=$(knob "${TRIAGE_VERIFY_DEADLINE_S:-}" 120)

[ -s "$FILTERED" ] || exit 0
if [ "$V_MAX" -eq 0 ]; then say "off (TRIAGE_VERIFY_MAX=0) — every family kept"; exit 0; fi

ROWS=$(jc alert_family_scripts); RC=$?
if [ "$RC" -ne 0 ]; then say "unavailable rc=$RC — every family kept for a session"; exit 0; fi

ROWS_F=$(mktemp) && PARK_F=$(mktemp) || exit 1
PTMP=""
trap 'rm -f "$ROWS_F" "$PARK_F" ${PTMP:+"$PTMP"}' EXIT
[ -n "$ROWS" ] && printf '%s\n' "$ROWS" > "$ROWS_F"

COUNTS=$(python3 - "$FILTERED" "$SETTLED" "$REMOVED" "$ROWS_F" "$PARK_F" "$HARNESS/bin/alert-verify" \
  "$V_TIMEOUT" "$V_MAX" "$((V_DEADLINE - SECONDS))" <<'PY'
import json, math, os, re, subprocess, sys, tempfile, time
filtered, settled, removed, rowsf, parkf, vdir = sys.argv[1:7]
timeout, vmax, budget = int(sys.argv[7]), int(sys.argv[8]), int(sys.argv[9])
t0 = time.monotonic()
NAME = re.compile(r"[a-z0-9-]{1,48}")
ALERT_ID = re.compile(r"[A-Za-z0-9_.-]{1,120}")   # the worker's ALERT_ID_RE
ENC = dict(encoding="utf-8", errors="surrogateescape")


def log(msg):
    sys.stderr.write("%s triage pass: REGISTRY %s\n" % (time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime()), msg))
    sys.stderr.flush()


UN = {"\\": "\\", "t": "\t", "n": "\n", "r": "\r"}
def untsv(s):   # undo jq's @tsv escapes
    return re.sub(r"\\(.)", lambda m: UN.get(m.group(1), m.group(0)), s)


rows = []
for raw in open(rowsf, **ENC):
    raw = raw.rstrip("\n")
    if not raw:
        continue
    f = [untsv(x) for x in raw.split("\t")]
    if len(f) != 7:
        log("refused a row: %d fields, not 7 — skipped this tick" % len(f))
        continue
    rid, kind, match, verify, on_clear, on_repro = f[:6]
    why, rx = None, None
    if not NAME.fullmatch(rid):
        why, rid = "id is not ^[a-z0-9-]{1,48}$", repr(rid)
    elif kind not in ("akey_prefix", "line_regex"):
        why = "match_kind %r is unknown" % kind
    elif match == "":
        why = "empty match (it would match every line)"
    elif verify and not NAME.fullmatch(verify):
        why = "verify %r is not a script name (^[a-z0-9-]{1,48}$)" % verify
    elif on_clear not in ("settle", "model") or on_repro not in ("model", "park"):
        why = "on_clear=%r on_repro=%r is not settle|model / model|park" % (on_clear, on_repro)
    elif kind == "line_regex":
        try:
            rx = re.compile(match)
        except re.error as e:
            why = "line_regex %r does not compile (%s)" % (match, e)
    if why:
        log("refused row %s: %s — skipped this tick" % (rid, why))
        continue
    rows.append(dict(id=rid, kind=kind, match=match, rx=rx, verify=verify, on_clear=on_clear, on_repro=on_repro))

data = open(filtered, "rb").read().decode(**ENC)
lines = data.split("\n")
if lines and lines[-1] == "":
    lines.pop()
order, groups = [], {}
for l in lines:
    p = l.split("\t", 2)
    if len(p) < 3 or not p[0]:
        continue
    if p[0] not in groups:
        order.append(p[0]); groups[p[0]] = []
    groups[p[0]].append(p[2])   # the raw quarantine line: source<TAB>epoch<TAB>payload


def beat(raw):
    p = raw.split("\t", 2)
    try:
        o = json.loads(p[2]) if len(p) == 3 else None
    except ValueError:
        return None
    return o if isinstance(o, dict) else None


def winner(raw):
    o = beat(raw)
    if o is None:
        return None
    for r in rows:
        if r["kind"] == "akey_prefix":
            a = o.get("akey")
            if isinstance(a, str) and a.startswith(r["match"]):
                return r
        else:
            t = o.get("line")
            if isinstance(t, str) and r["rx"].match(t):
                return r
    return None


n = dict(matched=0, cleared=0, repro=0, unknown=0, unchecked=0)
remove, settle_out, parks, used = [], [], [], 0
for fam in order:
    ws = [winner(l) for l in groups[fam]]
    r = ws[0]
    if r is None or any(w is not r for w in ws):
        continue
    n["matched"] += 1
    remaining = budget - (time.monotonic() - t0)
    if used >= vmax or remaining <= 0:
        n["unchecked"] += 1
        continue
    path = os.path.join(vdir, r["verify"] + ".sh")
    if not r["verify"] or not (os.path.isfile(path) and os.access(path, os.X_OK)):
        n["unknown"] += 1
        log("family=%s row %s: no runnable verify %r — kept for a session" % (fam, r["id"], r["verify"]))
        continue
    used += 1
    stdin = "".join(l + "\n" for l in groups[fam]).encode(**ENC)
    try:
        pr = subprocess.run(["timeout", "-k", "5", str(min(timeout, max(1, math.ceil(remaining)))), path],
                            input=stdin, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        rc, first = pr.returncode, pr.stdout.decode("utf-8", "replace").split("\n", 1)[0].strip()
    except OSError as e:
        rc, first = "oserror:%s" % e.errno, ""
    if rc == 0 and first:
        n["cleared"] += 1
        if r["on_clear"] == "settle":
            proof = first.replace("\t", " ").replace("\r", " ")[:300]
            remove.append(fam)
            settle_out += ["verify:%s: %s\t%s\n" % (r["id"], proof, l.replace("\t", " ")) for l in groups[fam]]
    elif rc == 1:
        n["repro"] += 1
        if r["on_repro"] == "park":
            ids = []
            for l in groups[fam]:
                o = beat(l)
                a = o.get("alertid") if o and o.get("dbrow") is True else None
                if isinstance(a, str) and ALERT_ID.fullmatch(a) and a not in ids:
                    ids.append(a)
            parks.append("%s\t%s\t%s\n" % (fam, r["id"], ",".join(ids)))
    else:
        n["unknown"] += 1
        log("family=%s row %s: verify %s rc=%s%s — kept for a session"
            % (fam, r["id"], r["verify"], rc, " with no proof line" if rc == 0 else ""))

# Write order: settled lines and removed keys first, then the atomic rewrite.
if settle_out:
    with open(settled, "a", **ENC) as fh:
        fh.writelines(settle_out)
if remove:
    with open(removed, "a", **ENC) as fh:
        fh.writelines(f + "\n" for f in remove)
    gone = set(remove)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(filtered)), prefix=".registry-")
    try:
        with os.fdopen(fd, "wb") as o:
            for l in lines:
                if l.split("\t", 1)[0] not in gone:
                    o.write((l + "\n").encode(**ENC))
        os.replace(tmp, filtered)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
with open(parkf, "w", **ENC) as fh:
    fh.writelines(parks)
print(len(rows), n["matched"], n["cleared"], n["repro"], n["unknown"], n["unchecked"])
PY
); PRC=$?
[ "$PRC" -eq 0 ] || exit "$PRC"
read -r N_ROWS N_MATCHED N_CLEARED N_REPRO N_UNKNOWN N_UNCHECKED <<<"$COUNTS"

# Parks: log first, then write; the family leaves <filtered-file> only when every
# row it names came back parked.
N_PARKED=0
while IFS=$'\t' read -r PFAM PROW PIDS; do
  [ -n "$PFAM" ] || continue
  if [ -z "$PIDS" ]; then
    say "park skipped: no alerts row to park — family kept (row $PROW family=$PFAM)"; continue
  fi
  say "PARKED by registry row $PROW family=$PFAM ids=$PIDS"
  ALL=1
  for AID in ${PIDS//,/ }; do
    OUT=$(jc alert_state_set "$AID" parked alert-triage); SRC=$?
    if [ "$SRC" -ne 0 ] || [ "$OUT" != 1 ]; then
      say "park failed rc=$SRC id=$AID — family kept for a session"; ALL=0
    fi
  done
  [ "$ALL" = 1 ] || continue
  PTMP=$(mktemp "$(dirname "$FILTERED")/.registry-park.XXXXXX") \
    && awk -F'\t' -v f="$PFAM" '$1 != f' "$FILTERED" > "$PTMP" && mv "$PTMP" "$FILTERED" \
    || { say "park of family=$PFAM is in the table but $FILTERED could not be rewritten — family kept for a session"; continue; }
  printf '%s\n' "$PFAM" >> "$REMOVED"
  N_PARKED=$((N_PARKED + 1))
done < "$PARK_F"

say "rows=$N_ROWS matched=$N_MATCHED cleared=$N_CLEARED parked=$N_PARKED repro=$N_REPRO unknown=$N_UNKNOWN unchecked=$N_UNCHECKED"
exit 0
