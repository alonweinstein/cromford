#!/bin/bash
# bin/triage-spool-retire.sh — STEP 0 of the alert-triage tick, done by the
# harness for $0 instead of by a model for $64/day (BH-979).
#
#   triage-spool-retire.sh <workfile>
#
# <workfile> is the tick's collected lines (the deferral spool + this tick's
# quarantine grabs), one per line, in the collector's format:
#
#   <source-box><TAB><epoch><TAB><beat-json>
#
# It is REWRITTEN IN PLACE with only the lines that still deserve a session.
# Every removed line is APPENDED to state/alert-triage-expired-<UTC-date>.tsv
# with the reason it went, so a retirement is a declared, auditable move and
# never the silent drop the deferral spool exists to prevent:
#
#   <retired-at ISO><TAB><reason><TAB><age-seconds><TAB><the original line>
#
# One line on stdout, for the caller to log:
#
#   aged=N condstate=N stale=N kept=N lookups=N unchecked=N archive=<path|->
#
# rc 0 always. EVERY DOUBT KEEPS THE LINE: an unparseable line, a missing
# epoch, a PR state that could not be read, the lookup budget running out, the
# kill switch — all of them leave the line in the workfile exactly as it
# arrived. A retirement may only ever follow a positive reading.
#
# ── WHY (measured on the hub 2026-09-19 15:50Z) ─────────────────────────────
# state/alert-triage-deferred.tsv held 2019 lines / 1136 families and had grown
# for 2.5 days: arrivals beat the TRIAGE_MAX_FAMILIES=4 per-tick cap (24
# families/h), so the oldest line was never reached. Median spooled age 24.5h,
# max 55h, 1038 over 24h. Meanwhile 93% of what a session looked at was noise it
# confirmed in its own STEP 0 — a PR already CLOSED/MERGED, a heartbeat already
# recovered — at 60K-900K input tokens a time. The model was being paid to
# rediscover, in English, three facts a clock and one REST read answer here.
#
# THE THREE RULES, in the order they are applied to each line:
#
#   1. EXPIRED-CONDSTATE — a merge-conductor per-PR BUDGET NOTE older than
#      TRIAGE_CONDSTATE_MAX_AGE_H (default 6). NOT because the note itself
#      re-pages: mc_budget_check marks `<STATE>@<since>` and pages ONCE per
#      (state, entry) for non-parks (once per UTC day for parks), so a WAIT_CI or
#      READY note is not re-sent while the condition holds. What covers the
#      CONDITION is mc_stuck_check, which pages once per (PR, state, head) on a
#      90m/20m TTL and re-arms on every new head — a STUCK line, which rule 1
#      deliberately excludes and which lives out the full 24h ceiling. So a 6h-old
#      budget note is a copy of a state the conductor is still watching and will
#      say so about again through the stuck detector; paying a strong model to
#      re-read the copy buys nothing the backstop does not already give.
#      THE SHAPE IS THE RULE, not the lane tag: `conductor: <key> <STATE> — <N>m
#      in <STATE>:` and never ` — STUCK:`, and never a PARK (BLOCKED_HUMAN,
#      RED_TWICE — mc_budget is 0 for both, so they page with --critical on the
#      first tick and a person owes them an answer; they age out on the 24h
#      ceiling below like any other alert). The first cut matched every line the
#      conductor emits, which also swept up the stuck detector's criticals and
#      the one-shots (CLOSED, DEPLOY_VERIFY, "production is unverified for this
#      sha") — 771 lines of the 09-19 archive where the hand drain retired 329.
#      Those are not re-decided every tick and this ticket never asked to age
#      them faster than the 24h ceiling below.
#   2. EXPIRED-AGE — any line older than TRIAGE_SPOOL_MAX_AGE_H (default 24).
#      Same argument with a wider margin: every lane that can raise an alert
#      re-raises it, so a day-old copy is either superseded or moot.
#   3. NOISE-STALE — the line names at least one pull request and EVERY pull
#      request it names reads MERGED or CLOSED on a fresh REST lookup
#      (bin/gh-pr-state.sh: App token, REST, never GraphQL). One lookup per
#      distinct PR per tick, capped at TRIAGE_PRSTATE_MAX_LOOKUPS (default 40) —
#      and readings PERSIST in state/triage-prstate.json for
#      TRIAGE_PRSTATE_TTL_H, so a PR already read costs no lookup and the next
#      tick's budget reaches the PRs the cap starved. Without that the walk is
#      oldest-first over the same spool every tick: with 105 distinct PRs and a
#      cap of 40, the same 40 were re-read forever and the other 65 waited for
#      the 24h ceiling. `unchecked=N` in the summary is how many went unread.
#      An OPEN PR, a 75 (unverifiable) or a 44 (GitHub says no such PR — which
#      is also what a token that cannot see the repo looks like) all KEEP the
#      line. Two more clocks bound the pass: TRIAGE_PRSTATE_TIMEOUT_S per call
#      and TRIAGE_PRSTATE_DEADLINE_S for the whole tick, because gh-rest.sh runs
#      `gh api` with no request timeout and this tick holds the lane's flock.
#      AND ONLY FOR AN OPEN-PR-PRESUMING SHAPE (presumes_open() below): the
#      conductor's per-PR line with a non-terminal state word, pipeline-health's
#      "OPEN and CLEAN and not landed", the merge-queue lanes, a RESPONDER line
#      carrying the `OPEN/<STATUS>` pair it read off a PR, and the one
#      pr-url-reconcile shape that is waiting on a verdict. Everything else
#      KEEPS its line. AN ENTRY IS A SHAPE, NEVER A LANE TAG: the reconcile lane
#      also pages BECAUSE a PR is closed, and admitting the tag put that page
#      back inside the rule this allowlist exists to bound (round 4).
#      Reading the PR terminal moots a stuck-PR alert; it CONFIRMS an alert that
#      was raised because the PR merged — "PROD QA FAILED after merge", "shipped
#      migration SQL — confirm it is applied to prod", "merged directly
#      (degraded)", "production is unverified for this sha" — and rule 3 was
#      archiving exactly those at age 0, for $0, before any human saw them
#      (round 3, measured on the live spool). A denylist could only name the
#      lanes that exist today, so the default is keep; post_terminal() below is
#      the second lock, for a line that is allowlisted and still says the merge
#      has already happened.
#
# Knobs (env, so an operator changes them without a deploy):
#   TRIAGE_SPOOL_MAX_AGE_H       24   hours before any line is retired
#   TRIAGE_CONDSTATE_MAX_AGE_H   6    hours for a conductor per-PR state note
#   TRIAGE_PRSTATE_MAX_LOOKUPS   40   REST reads per tick
#   TRIAGE_PRSTATE_TTL_H         6    hours a persisted PR reading is reused,
#                                     counted from when it was READ
#   TRIAGE_PRSTATE_TIMEOUT_S     15   seconds one gh-pr-state.sh read may take
#   TRIAGE_PRSTATE_DEADLINE_S    120  seconds the whole lookup pass may take;
#                                     past it every remaining ref is unchecked
#   TRIAGE_NOW                   now  epoch, so a fixture can pin the clock
#   TRIAGE_RETIRE_IDS_OUT        -    file to APPEND the `alertid` of every
#                                     NOISE-STALE `"dbrow":true` line to, one
#                                     per line, once the archive holds it
#                                     (BH-2570: the caller closes those rows)
#   switch.triage-spool-age-off       kill switch (settings row, or
#                                     flags/triage-spool-age-off when no row
#                                     exists; BH-2437): keep every line, look
#                                     nothing up, print kept=<all>
set -uo pipefail
# BH-1138: a line in every python caller, not a detector — this heredoc imports
# only stdlib so no __pycache__ lands under bin/ today, and the convention is
# what keeps that true when the next import is not stdlib.
export PYTHONDONTWRITEBYTECODE=1
# The caller passes HARNESS explicitly; the fallback is this script's own parent
# so a checkout run in place finds its own state/ and flags/ rather than the
# production hub's. It resolves to /root/harness on the hub either way.
if [ -z "${HARNESS:-}" ]; then
  HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  [ -n "$HARNESS" ] || HARNESS=/root/harness
fi
WORKFILE="${1:-}"
if [ -z "$WORKFILE" ] || [ ! -f "$WORKFILE" ]; then
  echo "usage: triage-spool-retire.sh <workfile>" >&2
  exit 2
fi

command -v lane_switch >/dev/null 2>&1 || . "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null \
  || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
OFF=0; lane_switch triage-spool-age-off && OFF=1
NOW="${TRIAGE_NOW:-$(date -u +%s)}"
DAY=$(date -u -d "@$NOW" +%Y%m%d 2>/dev/null) || DAY=$(date -u +%Y%m%d)
ARCHIVE="$HARNESS/state/alert-triage-expired-$DAY.tsv"
mkdir -p "$HARNESS/state" 2>/dev/null || true

PRCACHE="$HARNESS/state/triage-prstate.json"
python3 - "$WORKFILE" "$ARCHIVE" "$NOW" "$OFF" "$HARNESS/bin" \
         "${TRIAGE_SPOOL_MAX_AGE_H:-24}" "${TRIAGE_CONDSTATE_MAX_AGE_H:-6}" \
         "${TRIAGE_PRSTATE_MAX_LOOKUPS:-40}" "$PRCACHE" \
         "${TRIAGE_PRSTATE_TTL_H:-6}" "${TRIAGE_PRSTATE_TIMEOUT_S:-15}" \
         "${TRIAGE_PRSTATE_DEADLINE_S:-120}" <<'PYR'
import json
import os
import re
import subprocess
import sys
import time

(work, archive, nowstr, offstr, bindir, agestr, condstr, capstr,
 cachef, ttlstr, callstr, deadstr) = sys.argv[1:13]

def _num(s, dflt):
    try:
        v = float(s)
    except (TypeError, ValueError):
        return dflt
    return v

now = _num(nowstr, time.time())
off = offstr == "1"
age_s = _num(agestr, 24) * 3600
cond_s = _num(condstr, 6) * 3600
try:
    cap = max(0, int(float(capstr)))
except (TypeError, ValueError):
    cap = 40
cache_ttl = _num(ttlstr, 6) * 3600
# One call may take call_to seconds; the whole lookup pass may take deadline_s.
# Both are floors of 1 / 0-is-off, because a knob typo must not turn the guard
# into a hang. time.monotonic, not `now`: TRIAGE_NOW is a pinned fixture clock.
call_to = max(1.0, _num(callstr, 15))
deadline_s = _num(deadstr, 120)
_t0 = time.monotonic()

# A conductor per-PR BUDGET NOTE, in both shapes mc_alert can emit: through
# bin/lane-alert.sh ("[orchestrator/merge-conductor]") and, when that script is
# not installed, by hand ("[merge-conductor]"). BOTH the lane tag AND the note's
# own shape must match, because the tag alone is every alert the conductor
# raises — including the stuck detector's `— STUCK: 277m in one state (TTL 90m)`
# criticals and the one-shots ("merged … production is unverified for this
# sha", CLOSED, DEPLOY_VERIFY), which are NOT re-decided every tick and must
# live out the full 24h ceiling like any other alert.
#
# AND A PARK IS NOT A MACHINERY WAIT. mc_budget is 0 for BLOCKED_HUMAN and
# RED_TWICE (merge-conductor-lib.sh:555/561), so a park the resolver does not own
# pages `conductor: <key> BLOCKED_HUMAN — 0m in BLOCKED_HUMAN: tightened — <url>`
# WITH --critical on its first tick — the budget-note SHAPE, raised by the arm of
# mc_budget_check that exists to page a person. Rule 1's whole argument is "the
# conductor is still watching this and the stuck detector will say so again",
# which is an argument about a wait, not about a page somebody owes an answer to.
# So the two park states are excluded by name and live out the 24h ceiling like
# any other alert (tests/alert-triage-spool-age.bh-979-test.sh block 15 pins both
# halves: the park is kept at 7h, a STACKED_WAIT note at the same age is not).
COND = re.compile(r"\[(?:orchestrator/)?merge-conductor\]")
COND_NOTE = re.compile(
    r"conductor: \S+ [A-Z_]+ [-—]+ \d+m in (?!BLOCKED_HUMAN\b|RED_TWICE\b)[A-Z_]+\b")
COND_STUCK = re.compile(r"[-—]+ STUCK:")


def cond_note(payload):
    """True only for the per-PR budget note mc_budget_check emits every tick."""
    return (COND.search(payload) is not None
            and COND_NOTE.search(payload) is not None
            and COND_STUCK.search(payload) is None)
# ── RULE 3 IS AN ALLOWLIST OF OPEN-PR-PRESUMING SHAPES ─────────────────────
# Rule 3 reads "every PR this line names is MERGED/CLOSED" as "the condition it
# describes is moot". That inference only holds for a line whose condition
# PRESUMES AN OPEN PR — a stuck PR, a CI wait, a merge that never landed. For an
# alert raised BECAUSE the PR reached a terminal, the same reading CONFIRMS the
# alert, and rule 3 archives the fleet's loudest post-merge criticals at age 0,
# for $0, before any session or escalation ever sees them.
#
# Round 2 handled that with a denylist of the four conductor/resolver shapes then
# known. Round 3 measured the class still open on the live hub spool: with every
# read answering MERGED, rule 3 retired `PROD QA FAILED after merge …`
# (bin/postmerge-qa.sh:388), `PR #N shipped migration SQL — confirm it is applied
# to prod` (bin/check-migration-prs.sh:94), the conductor's own READY "mergify
# queue not answering … merged directly (degraded)" (merge-conductor-lib.sh:5163,
# a NON-terminal state word, so the denylist never saw it) and an `hb-alert`
# relay of a `MERGED PR …` line. A denylist can only ever name the lanes that
# exist today; every new lane that alerts about a merge is born wrong.
#
# So the default is now KEEP, and rule 3 judges only these shapes — each verified
# in the hub's live spool, each raised about a pull request that is still in
# flight, and each therefore genuinely moot once every PR it names is terminal:
#
#   1. the merge conductor's per-PR state line with a NON-terminal state word
#      (`conductor: <key> HEAD_MOVED|RED_TWICE|STACKED_WAIT|WAIT_CI|… — …`),
#      which is 499 of the 530 lines rule 3 retires on the live spool;
#   2. `[pipeline-health] <url> is APPROVE (…), OPEN and CLEAN for <N>m and the
#      merge sweep has not landed it` (bin/pipeline-health.sh);
#   3. `Merge queue: #N …` (mq-conflict / mq-headbound / mq-hb-lander);
#   4. a `RESPONDER:` line that says the PR it is waiting on is OPEN;
#   5. `[pr-url-reconcile] <url> owes a verdict and nothing can produce one`
#      (pr-url-reconcile.sh:342) — and ONLY that one of the lane's three
#      shapes. Its other two are raised because a PR is CLOSED without merging
#      (:492) or because a RECORD on disk is mislinked (:527); neither is made
#      moot by any PR state, and the first is confirmed by it.
#
# A shape that is not here KEEPS ITS LINE and buys a session, which is the same
# direction every other doubt in this script goes: a miss costs one session, and
# the thing it would otherwise cost is a post-merge critical nobody ever reads.
# Adding a shape is one regex plus a fixture — deliberately a decision somebody
# makes, not a default a new lane inherits.
PRESUMES_OPEN = (
    # 1. the conductor's own per-PR line, minus the terminal state words. The
    #    state word is mc_alert's first field, so this reads the conductor's
    #    machine state rather than guessing from prose.
    re.compile(r"conductor: \S+(?: \S+)? "
               r"(?!MERGED\b|CLOSED\b|DEPLOY_VERIFY\b|ABANDONED\b)[A-Z_]+ [-—]"),
    # 2. pipeline-health's "approved, open, clean, and still not landed"
    re.compile(r"\[pipeline-health\][^\n]*\bOPEN and CLEAN\b"),
    # 3. the merge-queue lanes
    re.compile(r"\bMerge queue: #\d+"),
    # 4. the responder, only where it says the PR is open — and ONLY in the
    #    status pair it copies out of a PR read (`OPEN/CLEAN`, `OPEN/BLOCKED`).
    #    watchdog-responder.sh:191 has the model write this line as free prose,
    #    so the bare word OPEN is as often the TICKET as the PR: "PR <url> was
    #    CLOSED without merging and the ticket is still OPEN on the board" read
    #    CLOSED and retired at age 0 (round 4). An entry keyed on one word of
    #    model prose is not a shape; the pair is.
    re.compile(r"\bRESPONDER:[^\n]*\bOPEN/[A-Z]"),
    # 5. record-vs-GitHub PR url reconciliation — ONE of that lane's three
    #    shapes. Round 3 admitted the lane by tag, and two of the three presume
    #    the opposite (round 4):
    #      :492 `review says APPROVE but the only PR on <branch> (<url>) is
    #           CLOSED without merging — reopen it, or open a new one` — the
    #           alert EXISTS because the read says CLOSED, so reading it CLOSED
    #           archived the page that asks for the PR to be reopened, at age 0;
    #      :527 `record <bd> carries PR: <a> but <branch> resolves to <b> —
    #           mislinked, left untouched` — the condition is a wrong record on
    #           DISK. Both urls reading terminal does not make the record right.
    #    Only :342 presumes an open PR: it is waiting for a verdict on one.
    re.compile(r"\[pr-url-reconcile\][^\n]*\bowes a verdict\b"),
)


def presumes_open(payload):
    """True when this alert's condition can only hold while a PR is open."""
    return any(p.search(payload) for p in PRESUMES_OPEN)


# ── AND THE VETO: AN ALERT WHOSE PREMISE IS THE TERMINAL ITSELF ─────────────
# The allowlist is the gate; this is the second lock on it, for a shape that is
# allowlisted and still talks about a merge that has already happened — the
# conductor's READY "merged directly (degraded)" is exactly that line. The four
# round-2 shapes stay, because they document the class:
#   merge-conductor-lib.sh:5252  MERGED — deploy-verify lane could not be
#                                spawned, production is unverified for this sha
#   merge-conductor.sh:314       MERGED — landed while the merge flag was off:
#                                the issue was NOT closed and NO deploy was made
#   merge-conductor.sh:2880      CLOSED — closed without merging and its issue
#                                is still open
#   blocked-resolver.sh:711/2953 the stale PR is already closed / ABANDONED
# plus the phrases the round-3 probe found outside them: "after merge"
# (postmerge-qa.sh:388), "merged at/directly" (the hb-alert relays and
# mc_queue_inactive_alert), "MERGED PR" (the relays) and "shipped migration"
# (check-migration-prs.sh:94). Both halves still age out on the 24h ceiling like
# any other alert; nothing here keeps a line forever.
COND_TERMINAL = re.compile(
    r"conductor: \S+(?: \S+)? (?:MERGED|CLOSED|DEPLOY_VERIFY|ABANDONED) [-—]")
POST_TERMINAL = (
    COND_TERMINAL,
    re.compile(r"\[blocked-resolver\][^\n]*\bABANDONED\b"),
    re.compile(r"\balready (?:closed|merged)\b"),
    re.compile(r"\bafter merge\b"),
    re.compile(r"\bmerged (?:at|directly)\b"),
    re.compile(r"\bMERGED PR\b"),
    re.compile(r"\bshipped migration\b"),
    # and the phrase the reconcile lane and the responder both use for it. The
    # allowlist above already keeps both of those shapes; this is the lock that
    # holds if a later entry widens again — a responder line is free prose and
    # can carry an OPEN/CLEAN pair (entry 4) and a closed-PR premise at once.
    re.compile(r"\bCLOSED without merging\b"),
)


def post_terminal(payload):
    """True when the alert's own premise is that the PR is already terminal."""
    return any(p.search(payload) for p in POST_TERMINAL)


# Only OWNER-QUALIFIED references, because those are the only two shapes that
# name a repo without guessing one. The conductor's own key (`project-5#1058`)
# has no owner, so it is deliberately not matched here — every conductor line
# also carries the full PR url, which is.
PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)")
PR_SLUG = re.compile(r"(?<![A-Za-z0-9_./-])([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#(\d+)\b")
# The collector's beat JSON carries the raising lane's MACHINE key, and some of
# them are owner-qualified: `"akey":"migration:example-org/project-4#1677"`. PR_SLUG
# matched it, so a line whose human text names no PR at all was still being
# judged — and retired — on a routing key. A reference has to be something the
# alert SAYS, so the akey is cut out of the text before the references are read.
AKEY_FIELD = re.compile(r'"akey"\s*:\s*"[^"]*"')


def split_line(line):
    """(epoch, payload) for a collector line; epoch None when it has none."""
    parts = line.split("\t")
    for i in (1, 0):
        if len(parts) > i + 1 and parts[i].strip().isdigit():
            return int(parts[i].strip()), "\t".join(parts[i + 1:])
    return None, line


def pr_refs(payload):
    """Every distinct owner/repo/number this line names, in first-seen order."""
    seen, out = set(), []
    payload = AKEY_FIELD.sub('"akey":""', payload)
    for m in PR_URL.finditer(payload):
        key = (m.group(1), m.group(2), m.group(3))
        if key not in seen:
            seen.add(key)
            out.append(key)
    for m in PR_SLUG.finditer(payload):
        key = (m.group(1), m.group(2), m.group(3))
        if key not in seen:
            seen.add(key)
            out.append(key)
    return out


# ── THE PERSISTED READING (state/triage-prstate.json) ───────────────────────
# {"owner/repo#n": {"state": "MERGED", "at": <epoch>}}. A reading costs one REST
# read and is true for hours; re-buying it every tick is what let the lookup cap
# starve the far end of the spool forever. UNKNOWN readings ('' from an rc 75/44
# or a timeout) are deliberately NOT cached — the doubt must be re-asked.
# Unreadable file == empty: this guard fails OPEN (more lookups), never closed.
#
# IN MEMORY IT IS (state, at), and `at` IS THE MOMENT THE READ HAPPENED — it
# travels with the entry through the rewrite below. Stamping `now` on every entry
# at write time (round 1) meant any tick that bought ONE new reading refreshed
# every other one, so on the hub — where nearly every tick reads something new —
# an OPEN reading never expired, the PR merged, and its lines kept buying
# sessions until the 24h ceiling. The TTL has to be the age of the READING.
_state_cache = {}
_cache_dirty = False
if not off:
    try:
        with open(cachef) as fh:
            _loaded = json.load(fh)
        if isinstance(_loaded, dict):
            for k, v in _loaded.items():
                if not isinstance(v, dict):
                    continue
                st, at = v.get("state"), v.get("at")
                try:
                    at = float(at)
                except (TypeError, ValueError):
                    continue
                if st and now - at < cache_ttl:
                    _state_cache[k] = (st, at)
    except Exception:
        pass

lookups = 0
starved = set()


def pr_state(key):
    """MERGED | CLOSED | OPEN | '' — one child read per PR per tick.

    bin/gh-pr-state.sh, never the GraphQL-backed CLI: it arms the repo-scoped App
    token, reads REST (so a rate limit answers 75 rather than the empty string #768
    was about) and it is a child, so the arming cannot touch this lane's own
    GH_TOKEN. '' means UNKNOWN and every caller keeps the line.
    """
    global lookups, _cache_dirty
    kname = "%s/%s#%s" % key
    if kname in _state_cache:
        return _state_cache[kname][0]
    # TWO BUDGETS, BOTH DECLARED AS unchecked=N: a count (the cap) and a clock.
    # gh-rest.sh runs `gh api` with no request timeout, so without the clock a
    # GitHub stall is cap × call_to of silence while this tick holds the lane's
    # flock and the drained spool sits in a mktemp — a reboot in that window
    # loses it. Past either budget the reference is NOT an answer, so every line
    # resting on it is kept.
    if lookups >= cap or (deadline_s > 0
                          and (time.monotonic() - _t0) >= deadline_s):
        starved.add(kname)
        return ""
    lookups += 1
    url = "https://github.com/%s/%s/pull/%s" % key
    try:
        r = subprocess.run([os.path.join(bindir, "gh-pr-state.sh"), url],
                           capture_output=True, text=True, timeout=call_to)
        st = r.stdout.strip().upper() if r.returncode == 0 else ""
    except Exception:
        # Including TimeoutExpired: a read that did not finish is UNKNOWN, never
        # a terminal, and it is not persisted — the doubt is re-asked next tick.
        st = ""
    _state_cache[kname] = (st, now)
    if st:
        _cache_dirty = True
    return st


try:
    with open(work, errors="ignore") as fh:
        lines = [l.rstrip("\n") for l in fh]
except OSError:
    # Same field set as the summary below, so a parser never sees two shapes.
    print("aged=0 condstate=0 stale=0 kept=0 lookups=0 unchecked=0 archive=-")
    raise SystemExit(0)

keep, retired = [], []
counts = {"EXPIRED-AGE": 0, "EXPIRED-CONDSTATE": 0, "NOISE-STALE": 0}

for line in lines:
    if not line.strip():
        continue
    if off:
        keep.append(line)
        continue
    epoch, payload = split_line(line)
    age = (now - epoch) if epoch is not None else None
    reason = None
    if age is not None and cond_note(payload) and age >= cond_s:
        reason = "EXPIRED-CONDSTATE"
    elif age is not None and age >= age_s:
        reason = "EXPIRED-AGE"
    elif age is None:
        # THE MISSING EPOCH IS NOT ONLY AN AGE PROBLEM. The header and the lane
        # doc promise a line with no readable epoch is left exactly as it
        # arrived; rule 3 does not read the clock, so it was retiring such a
        # line anyway and archiving it with age -1 — a receipt whose own age
        # column says the line was never dated. If the collector's format is
        # unreadable here, nothing about this line has been parsed reliably.
        pass
    elif not presumes_open(payload) or post_terminal(payload):
        # Rule 3 only judges a line whose condition presumes an OPEN PR, and
        # never one that says the merge already happened: reading THOSE PRs
        # terminal is agreement with the alert, not news about it. Everything
        # else keeps its line and buys a session — only the 24h ceiling above
        # retires it.
        pass
    else:
        refs = pr_refs(payload)
        if refs:
            states = [pr_state(r) for r in refs]
            # EVERY named PR must have READ as terminal. One OPEN, one unknown
            # (75/44/over the lookup cap) and the line stays: a retirement may
            # only follow a positive reading of every reference it rests on.
            if all(s in ("MERGED", "CLOSED") for s in states):
                reason = "NOISE-STALE"
    if reason is None:
        keep.append(line)
    else:
        counts[reason] += 1
        retired.append((reason, int(age) if age is not None else -1, line))

if retired:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    try:
        with open(archive, "a") as ar:
            for reason, a, line in retired:
                ar.write("%s\t%s\t%d\t%s\n" % (stamp, reason, a, line))
    except OSError as e:
        # An archive we could not write is a drop we cannot audit, so the lines
        # go back rather than out. The caller sees kept=<all> and pays for them —
        # and hears about it: bin/alert-triage.sh sends this stderr to the lane
        # log, because a STEP 0 that quietly stops retiring looks exactly like a
        # STEP 0 with nothing to do.
        sys.stderr.write(
            "triage-spool-retire: archive unwritable (%s: %s) — %d line(s) kept\n"
            % (archive, e, len(retired)))
        keep.extend(l for _, _, l in retired)
        retired = []
        counts = {k: 0 for k in counts}

if retired:
    tmp = work + ".retire"
    with open(tmp, "w") as out:
        for line in keep:
            out.write(line + "\n")
    os.replace(tmp, work)

# THE CLOSE HAND-OFF (BH-2570). Only here, after the archive holds the receipt:
# an unwritable archive emptied `retired` above, so it hands off nothing. Only
# NOISE-STALE (a positive reading that every PR is terminal) and only a
# `"dbrow":true` row, which this lane claimed from the table; the two clock
# rules say the line is old, not that its condition cleared.
ids_out = os.environ.get("TRIAGE_RETIRE_IDS_OUT")
if retired and ids_out:
    ids = []
    for reason, _a, line in retired:
        if reason != "NOISE-STALE":
            continue
        try:
            o = json.loads(split_line(line)[1])
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("dbrow") is True \
                and isinstance(o.get("alertid"), str) and o["alertid"]:
            ids.append(o["alertid"])
    if ids:
        try:
            with open(ids_out, "a") as fh:
                fh.write("".join(i + "\n" for i in ids))
        except OSError as e:
            sys.stderr.write("triage-spool-retire: ids hand-off unwritable (%s: %s) — %d row(s) not closed this tick\n"
                             % (ids_out, e, len(ids)))

# The readings this tick bought, so the next tick does not buy them again. A
# write that fails is a slower next tick, never a wrong one.
if _cache_dirty and not off:
    try:
        with open(cachef + ".tmp", "w") as fh:
            json.dump({k: {"state": v[0], "at": int(v[1])}
                       for k, v in _state_cache.items() if v[0]}, fh)
        os.replace(cachef + ".tmp", cachef)
    except OSError as e:
        sys.stderr.write("triage-spool-retire: pr-state cache unwritable (%s)\n" % e)

print("aged=%d condstate=%d stale=%d kept=%d lookups=%d unchecked=%d archive=%s" % (
    counts["EXPIRED-AGE"], counts["EXPIRED-CONDSTATE"], counts["NOISE-STALE"],
    len(keep), lookups, len(starved), archive if retired else "-"))
PYR
exit 0
