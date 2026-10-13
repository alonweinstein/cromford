"""The root-cause family key — ONE implementation, imported by every lane.

Two implementations of one rule is this repo's named failure shape, and this
rule already had two: alert-triage.sh normalized hex runs of 8+ and then digits,
in two passes, case-sensitively; alerts-medic.sh lowercased the line and
normalized hex runs of 7+ and digits in a single pass. Both called themselves
"the family brake" and the medic's comment even claimed it was the "same
normalization as alert-triage's". They were not the same, so the same incident
could be one family to one lane and two to the other — silently, forever.

The surviving semantics are alert-triage's, byte for byte, deliberately:
  * they are what tests/triage-split-test.sh's divergent-key mutation defends,
  * and alert-triage's per-tick cost measurement is in flight, so changing that
    lane's keys mid-measurement would corrupt the number the whole wave is
    being judged on.
The medic's keys therefore change once, on deploy — see the note in
alerts-medic.sh about what that costs (one pass of cache misses, nothing lost).

Change this function and BOTH lanes change together. That is the point.
"""

import hashlib
import re


# ── THE VOLATILE TOKENS family() ALSO HAS TO FOLD (BH-979) ──────────────────
# Digit and hex folding is not enough for the fleet's highest-volume alert
# producer. Measured on the hub's 434 merge-conductor lines in
# state/alert-triage-deferred.tsv (2026-09-19), families per state:
#
#   state          lines  digits+hex only  + branch  + branch + status
#   HEAD_MOVED       198               59        59                 14
#   BLOCKED_HUMAN     59               29        29                 13
#   RED_TWICE         50               12        12                  8
#   STACKED_WAIT      48               30        28                  5
#   NEEDS_REBASE      16               10        10                  3
#
# The branch slug is what the ticket blamed and it is almost never the variance;
# the STATUS PARENTHETICAL — `(verdict=APPROVE ci=red mergeState=BLOCKED
# mode=merge)`, a fresh four-way combination on every PR — is. Both are folded,
# because both name the alert's OBJECT rather than its CONDITION, and a family
# key answers "what condition is this" (see row_key for "which object").
#
# IT IS FOLDED HERE AND NOT IN THE ALERT TEXT. The first cut of BH-979 folded
# the branch out of what mc_alert sends, which took the branch away from the
# human reading ALERTS.log and the --critical DM and bought 59 -> 59 families for
# it. A grouping key may erase a name; an alert may not.
#
# ON DEPLOY this changes keys for every lane that uses it (alert-triage's 6h
# brake, alerts-medic, findings-log, fleet-status-push, bin/lib/alert-state.sh's
# rows) — one pass of cache misses, the same cost the medic paid when it adopted
# this module, and nothing is lost: a changed key re-triages, it never drops.
_BRANCH = re.compile(
    r'(?<![A-Za-z0-9_./-])'
    r'(?:ticket|feature|fix|hotfix|bugfix|chore|release|bh|up10)/[A-Za-z0-9._/-]+')
_STATUS = re.compile(r'\(?verdict=[^ )]* ci=[^ )]* mergeState=[^ )]* mode=[^ )]*\)?')


def fold_volatile(line):
    """Fold the per-object tokens that are not part of the condition."""
    s = _STATUS.sub('<status>', line)
    return _BRANCH.sub('<branch>', s)


def family(line):
    # normalize: drop branch slugs, PR status, numbers, hashes, timestamps,
    # machine ids -> stable signature
    s = fold_volatile(line)
    s = re.sub(r'[0-9a-f]{8,}', 'H', s)
    s = re.sub(r'\d+', 'N', s)
    return hashlib.sha1(s.encode()).hexdigest()[:12]


# The NAMES family() deliberately erased. family() folds every digit run to `N`
# so that "3 builds stuck" and "17 builds stuck" are one condition — which is
# right for magnitudes and catastrophic for identities: it also folds TK-1 and
# TK-99, two different stuck builds, into one signature. Anywhere a family key
# decides whether something gets its own ROW (as opposed to its own LLM
# session), pair it with these, or the second incident is never reported.
#
# NOT the same thing as alerts-supersede.py's subject(), and they must not be
# merged: that one answers "which bucket does this alert collapse INTO" and is
# deliberately coarse (every project-5 alert shares a subject on purpose). This
# one answers "which specific thing is this alert about" and is deliberately
# narrow — only tokens that name one durable object.
_TICKET = re.compile(r'\b(?:TK)-\d+\b', re.I)
_PR = re.compile(r'(?:pull/|#)(\d{2,6})\b')
# The branch slug family() now folds is a durable object name too — two red
# builds on two branches are two incidents — so it re-enters HERE, where the
# question is "which specific thing is this about". Without this, folding the
# branch into the family would silently cost the second branch its own row,
# which is exactly the failure this block of comments exists to prevent.
#
# AND IT STOPS ON A NON-DOT, which _BRANCH above deliberately does not. A branch
# named at the END OF A SENTENCE ("drift on ticket/bh-900-widget.") captured the
# full stop, so one incident produced two identities and two console rows through
# bin/lib/alert-state.sh. The FOLD wants the greedy class — eating the trailing
# dot is what makes the same sentence with and without it one FAMILY — and the
# IDENTITY wants the name, so the two regexes differ on purpose. An inner dot is
# still part of the slug (`ticket/bh-478.1` is a real branch here).
_BRANCHID = re.compile(
    r'(?<![A-Za-z0-9_./-])'
    r'((?:ticket|feature|fix|hotfix|bugfix|chore|release|bh|up10)/'
    r'[A-Za-z0-9._/-]*[A-Za-z0-9_/-])')


def identifiers(line):
    """Stable object names in `line`, sorted and comma-joined; '' if none.

    Bare counts and durations have no `#`, no ticket prefix and no branch slug,
    so they stay folded — only things that name a ticket, a PR or a branch
    separate."""
    ids = {m.group(0).upper() for m in _TICKET.finditer(line)}
    ids |= {"#" + m.group(1) for m in _PR.finditer(line)}
    ids |= {m.group(1) for m in _BRANCHID.finditer(line)}
    return ",".join(sorted(ids))


# shape() — "is this the same CONDITION, whatever objects it lists" (BH-4053).
# bin/alerts-supersede.py uses it to retire console rows opened under the old
# alert:auto-<row_key> scheme once the condition declares its own id. family()
# alone cannot answer it: it folds digits but not list length, so "#50" and
# "#50,#51" are N vs N,N, two families. A PR list is collapsed to one #N first.
# family(), identifiers() and row_key() are deliberately left as they are:
# alert-triage and the medic key on them.
_STAMP = re.compile(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}Z? ')
_TAIL = re.compile(r'(?: \(still firing, n=\d+\)| \[remediator tried: [^\]]*\])+\s*$')
_PRLIST = re.compile(r'#\d+(?:\s*,\s*#\d+)*')


def shape(line):
    """family() of `line` with its stamp, re-fire suffixes and PR list folded."""
    s = _TAIL.sub('', _STAMP.sub('', line.strip()))
    return family(_PRLIST.sub('#N', s))


def row_key(line):
    """The key for 'does this alert deserve its own row': family + identities."""
    ids = identifiers(line)
    if not ids:
        return family(line)
    return family(line) + "-" + hashlib.sha1(ids.encode()).hexdigest()[:8]


# ── CLI (2026-09-15) ────────────────────────────────────────────────────────
# `python3 bin/alert_family.py row_key "<line>"` — the shell half of the fleet
# needs this rule too (bin/lib/alert-state.sh keys every alert on it), and the
# alternative was a sed/sha1sum re-implementation in bash. Two implementations
# of one rule is this module's own opening paragraph; the import path and this
# entry point are the same code, so they cannot drift.
if __name__ == "__main__":
    import sys

    _FN = {"family": family, "identifiers": identifiers, "row_key": row_key,
           "fold": fold_volatile, "shape": shape}
    if len(sys.argv) != 3 or sys.argv[1] not in _FN:
        sys.stderr.write(
            "usage: alert_family.py {family|identifiers|row_key|fold|shape} <line>\n")
        raise SystemExit(2)
    print(_FN[sys.argv[1]](sys.argv[2]))
