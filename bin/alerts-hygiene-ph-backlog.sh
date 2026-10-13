#!/bin/bash
# bin/alerts-hygiene-ph-backlog.sh — one-shot sweep of pipeline-health console
# rows still open under the keys used before #3997 (BH-4056).
#
# Since BH-4053 a pipeline-health condition keeps ONE row, alert:ph-<key>, and
# the groom closes it when the condition clears (bin/alerts-supersede.py,
# ph-absent pass). Rows opened before that sit under health:<key> (the beat's
# akey) or alert:auto-* / auto-* (the line's derived key) and nothing retires
# them but the 72h TTL. This lists them and, with --apply, closes the ones
# whose condition is no longer active:
#   health:<key>  closes when ph-<key> is absent from the last COMPLETE pass's
#                 state/health-active.txt and its namespace is retractable;
#                 a throttled namespace is held (cannot judge).
#   auto-*        ([pipeline-health] lines only) closes unless an open
#                 alert:ph-X row of the same shape() is still active.
# alert:ph-* rows are never touched here. Every decision needs a fresh
# completion stamp (bin/ph_active.py); without one nothing is closed.
#
# Usage: bin/alerts-hygiene-ph-backlog.sh [--dry-run | --apply]
#   --dry-run  (default) print what would close; no POST, no file written
#   --apply    one POST /api/alerts/resolve of exactly the close set, reason
#              "superseded by stable-key alerts (#3997)", one line to
#              logs/alerts-groom.log
# rc: 0 ok, 1 console GET/POST failed, 2 usage or no console env, 3 held.
set -uo pipefail
# BH-1138: it imports bin/ph_active.py and bin/alert_family.py; no __pycache__ beside them.
export PYTHONDONTWRITEBYTECODE=1
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# The groom's settings rows (PH_ACTIVE_FRESH_MIN), so both judge freshness by
# one window. Fails open to the code fallback, as in bin/alerts-groom.sh.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply alerts-groom
if [ -z "${CONSOLE_URL:-}" ] || [ -z "${HARNESS_SECRET:-}" ]; then
  echo "alerts-hygiene-ph-backlog: CONSOLE_URL and HARNESS_SECRET must be set (env/global.env)" >&2
  exit 2
fi
export HARNESS CONSOLE_URL HARNESS_SECRET
HYG_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export HYG_BIN
exec python3 - "$@" <<'PY'
import json, os, sys, time, urllib.error, urllib.request
sys.path.insert(0, os.environ["HYG_BIN"])
import ph_active
from alert_family import shape

USAGE = "usage: alerts-hygiene-ph-backlog.sh [--dry-run | --apply]"
REASON = "superseded by stable-key alerts (#3997)"
args = sys.argv[1:]
if any(a not in ("--dry-run", "--apply") for a in args) or ("--dry-run" in args and "--apply" in args):
    print(USAGE, file=sys.stderr)
    sys.exit(2)
APPLY = "--apply" in args
HARNESS = os.environ["HARNESS"]
CONSOLE = os.environ["CONSOLE_URL"].rstrip("/")
SECRET = os.environ["HARNESS_SECRET"]

def api(path, data=None):
    req = urllib.request.Request(
        f"{CONSOLE}/api/alerts/{path}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Authorization": f"Bearer {SECRET}", "Content-Type": "application/json",
                 "User-Agent": "harness-alerts-hygiene/1.0"},
    )
    return json.load(urllib.request.urlopen(req, timeout=30))

act, held = ph_active.load_active(HARNESS)
if held:
    print(f"held: {held} — nothing closed")
    sys.exit(3)

try:
    d = api("open")
except (urllib.error.URLError, ValueError) as e:
    print(f"GET /api/alerts/open failed: {e}", file=sys.stderr)
    sys.exit(1)
al = d["alerts"] if isinstance(d, dict) else d
ids, retract = act["ids"], act["retract_ns"]

# Shapes of the stable rows whose condition the last complete pass still found.
active_shape = {}
for a in al:
    k, line = a.get("akey") or "", a.get("line") or ""
    if k.startswith("alert:ph-") and k[len("alert:"):] in ids and line:
        active_shape.setdefault(shape(line), k)

rows = []  # (decision, id, akey, reason, line)
for a in al:
    k, line = a.get("akey") or "", a.get("line") or ""
    if k.startswith("health:"):
        pid = ph_active.ph_id(k[len("health:"):])
        if pid in ids:
            rows.append(("hold", a["id"], k, "still active", line))
        elif ph_active.ns_of(pid) not in retract:
            rows.append(("hold", a["id"], k, "throttled check, cannot judge", line))
        else:
            rows.append(("close", a["id"], k, f"absent from the pass {act['age_m']}m ago", line))
    elif (k.startswith("alert:auto-") or k.startswith("auto-")) and "[pipeline-health]" in line:
        hit = active_shape.get(shape(line))
        if hit:
            rows.append(("hold", a["id"], k, f"still active as {hit}", line))
        else:
            rows.append(("close", a["id"], k, "no active alert:ph-* row of its shape", line))

close = [r for r in rows if r[0] == "close"]
hold = [r for r in rows if r[0] == "hold"]
mode = "apply" if APPLY else "dry-run"
for r in hold:
    print(f"hold {r[1]} {r[2]} ({r[3]}) :: {r[4][:100]}")

if APPLY and close:
    try:
        api("resolve", {"ids": [str(r[1]) for r in close]})
    except (urllib.error.URLError, ValueError) as e:
        print(f"apply FAILED: {e}")
        print(f"legacy={len(rows)} close={len(close)} hold={len(hold)} mode={mode} (nothing closed)")
        sys.exit(1)
    for r in close:
        print(f"closed {r[1]} {r[2]} ({REASON}) :: {r[4][:100]}")
    os.makedirs(os.path.join(HARNESS, "logs"), exist_ok=True)
    with open(os.path.join(HARNESS, "logs", "alerts-groom.log"), "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime())
                + f" hygiene ph-backlog: closed {len(close)} legacy row(s) ({REASON}): "
                + " ".join(str(r[1]) for r in close) + "\n")
else:
    for r in close:
        print(f"would-close {r[1]} {r[2]} ({r[3]}) :: {r[4][:100]}")
print(f"legacy={len(rows)} close={len(close)} hold={len(hold)} mode={mode}")
PY
