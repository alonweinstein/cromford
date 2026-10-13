"""Which pipeline-health conditions hold right now, on the word of a complete pass (BH-4056).

bin/pipeline-health.sh touches state/health-active.txt at the START of every
pass, so the file's mtime only says a pass began: one that died midway leaves a
fresh mtime over the previous pass's keys, and a deleted file comes back fresh
and EMPTY. The pass therefore writes state/health-active.stamp after its
epilogue's mv ({"at":<epoch>,"n":<keys>,"retract_ns":"<RETRACT_NS>"}), and this
module answers only when that stamp is fresh and its n matches the file.
Anything else is a hold with a reason, never an empty answer: an empty set
would read as "every condition cleared".

The window is PH_ACTIVE_FRESH_MIN (settings row
lane.alerts-groom.ph_active_fresh_min), code fallback 30 minutes, three
10-minute passes. A value that is not a whole number >= 1 holds; it is never
clamped.
"""
import json, os, re, time

FRESH_MIN_DEFAULT = 30


def ph_id(key):
    """The console id alert() in bin/pipeline-health.sh gives <key>.

    Mirrors `tr -c 'A-Za-z0-9_.-' '_' | cut -c1-117` byte for byte: GNU tr and
    cut work on bytes, so a multibyte character folds to one '_' per byte.
    """
    b = key if isinstance(key, bytes) else key.encode("utf-8", "surrogateescape")
    return "ph-" + re.sub(rb"[^A-Za-z0-9_.-]", b"_", b)[:117].decode()


def ns_of(ph):
    """The check namespace of a ph id: ph-stalepr_ts -> stalepr."""
    s = ph[3:] if ph.startswith("ph-") else ph
    return s.split("_", 1)[0]


def load_active(harness, fresh_min=None, now=None):
    """({ids, retract_ns, age_m}, None) for a fresh complete pass, else (None, reason)."""
    if fresh_min is None:
        fresh_min = os.environ.get("PH_ACTIVE_FRESH_MIN", "")
        if fresh_min == "":
            fresh_min = str(FRESH_MIN_DEFAULT)
    w = str(fresh_min)
    if not re.fullmatch(r"[0-9]+", w) or int(w) < 1:
        return None, f"bad window {w}"
    window = int(w)
    now = time.time() if now is None else now

    state = os.path.join(harness, "state")
    try:
        with open(os.path.join(state, "health-active.stamp")) as f:
            raw = f.read()
    except FileNotFoundError:
        return None, "no stamp"
    except OSError:
        return None, "stamp unparseable"
    try:
        st = json.loads(raw)
        at, n, ns = st["at"], st["n"], st["retract_ns"]
        if not all(isinstance(v, int) and not isinstance(v, bool) for v in (at, n)) \
                or not isinstance(ns, str) or n < 0:
            raise ValueError
    except (ValueError, KeyError, TypeError):
        return None, "stamp unparseable"

    age_m = int((now - at) // 60)
    if at > now + 60:
        return None, "stamp in the future"
    if age_m > window:
        return None, f"stale: pass {age_m}m ago > {window}m"

    try:
        with open(os.path.join(state, "health-active.txt"), "rb") as f:
            lines = f.read().decode("utf-8", "surrogateescape").splitlines()
    except FileNotFoundError:
        return None, "active file missing"
    if len(lines) != n:
        return None, f"active file has {len(lines)} keys, stamp says {n}"

    retract = {x for x in ns.split("|") if x}
    if not retract:
        return None, "empty retract_ns"
    ids = {ph_id(k) for k in lines if k}
    return {"ids": ids, "retract_ns": retract, "age_m": max(age_m, 0)}, None
