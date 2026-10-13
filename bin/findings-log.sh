#!/bin/bash
# bin/findings-log.sh <build-dir> <project> <ticket-key>
#
# Findings observability (Wave A, 2026-08-25). The review prompt already tells
# every reviewer to cite build-discipline rule numbers (D1-D34) in its findings
# "so recurrence stays measurable" — and then nothing measured it. Three review
# lenses wrote review.md / security-review.md / refute-review.md, the pipeline
# read exactly one line of each (the verdict), and every finding underneath it
# died with the build dir. So the same comment could be written a hundred times
# across the fleet and nobody could name it.
#
# This extracts, per lens: the final verdict, each finding headline, its cited
# D-rule, and its root-cause family key — and appends one greppable line each to
# logs/findings.log:
#   <stamp> [<project>] ticket=<key> lens=<general|security|refuter|prodqa> \
#     verdict=<APPROVE|BLOCK|PASS|FAIL|BLOCKED|-> rule=<Dn|-> [fraud=<class>] \
#     [repairs=<n>] [kind=<bug|feature|copy|migration|infra>] family=<key> :: <finding>
# rule-miner.sh reads that file as a fifth incident source: a family crossing
# PROMOTE_MIN in 30 days is a recurring review comment, which is a bug in the
# guardrails rather than a bug in this week's build.
#
# `fraud=` (2026-08-26) is OPTIONAL and appears only when the reviewer tagged the
# finding as one of the six named fraud classes. Optional rather than a `-`
# placeholder on every row: two other scripts parse these lines by walking
# fields and keying on prefixes (rule-miner.sh source (e), repeat-family.sh), so
# an added field is invisible to them — but a mandatory field would rewrite the
# shape of ~11K existing rows for nothing. family= stays the LAST field before
# `::`, which is the one anchor hand-written greps reach for.
#
# ONLY THE SIX KNOWN CLASSES BECOME A FIELD. The tag is written by an LLM in
# free prose, so an unrecognized class name stays prose: it is logged inside the
# finding text where it belongs, and never promoted into metadata a consumer
# might group by. Same reasoning as the `::` stop in the consumers' field walk —
# a parser an author can steer is a parser that reports what the author wants.
#
# `kind=` (2026-09-06, SDLC item 7) is OPTIONAL on the same terms, and it is
# the field that makes the other two answerable per WORKFLOW: "which findings
# come from bug fixes" is a different question from "which come from features",
# and until now the log could not tell them apart. It is bin/kind-gate.sh's
# settled KIND, imported the same way the repair count and the family key are —
# never re-derived here. Absent when the kind is `unknown`, because a row that
# said kind=unknown on every pre-item-7 build would be noise with a field name.
#
# `repairs=` (2026-09-06, SDLC item 3) is OPTIONAL on the same terms as `fraud=`
# and for the same reason: an added field is invisible to the consumers that
# walk these rows by prefix, and it appears only when there is something to say.
# It is the number of times THIS build had been sent back when this lens was
# harvested, counted by bin/repair-count.sh — imported the same way the family
# key is, so the number here and the number the tier gate acts on cannot become
# two different rules. A row with no repairs= is a build that had not been
# repaired yet (or one from before this shipped); both are correctly outside the
# question "which findings come from builds that needed fixing".
#
# The family key is bin/alert_family.py — imported, never re-implemented. Two
# implementations of one rule is this repo's named failure shape (see the module
# docstring); a findings family that disagreed with the alert family would make
# the promotion threshold mean two different things at once.
#
# EXACTLY ONCE per lens per build: run-build.sh calls this once per lens and
# every call can see all four files, so a `.findings-<lens>` marker in the
# build dir records what has been harvested. A resumed build re-harvests
# nothing; a lens that lands after an earlier call is still picked up. The
# marker means "this content was harvested": bin/review-rescue.sh removes
# `.findings-general` when its re-review rewrites review.md (BH-118), so a
# rescued review is harvested once more, as new content.
#
# WHAT IT DOES NOT DO, stated rather than papered over: it extracts headlines by
# SHAPE (bullet / numbered item / sub-header, 30+ chars), not by meaning. So a
# refuter's "here is what I attacked and could not break" list lands in the log
# as three rows too. That is noise, and it is the right trade: rule-miner only
# looks at families that recur PROMOTE_MIN+ times in 30 days, and one build's
# prose does not recur. `verdict=APPROVE` is the tell if you are reading by eye.
#
# The one exception is the review format's own SCAFFOLDING, which DOES recur on
# every build (BH-123: 4 of the top 5 families in the 2026-08-26 bootstrap were
# "Validation trace (...)", "`npx tsc --noEmit` — clean", "`semgrep.txt` does
# not exist — nothing to triage" and "Findings (all minor, none blocking)").
# is_scaffold() drops two shapes and nothing else: a section opener whose text
# is one of a closed set of labels (plus a parenthetical; only a "Validation
# trace" heading or fully bold line may also carry "— text" after it), and a
# tool-clean status line (one backticked tool, then clean/green/pass/ok/exit 0
# followed by nothing or only ", zero errors [on HEAD]"-style text, or
# empty/does not exist ending in "nothing to triage"). A line that
# cites a D-rule, a FRAUD: class or an uppercase BLOCK/BLOCKING is always kept:
# a dropped real finding is worse than a kept boilerplate line. There is no
# positive filter because the review prompt marks no finding by a mandatory tag.
# Rows already in the log are NOT rewritten: this script stays append-only, and
# old scaffold rows age out of rule-miner's 30-day window (see
# docs/notes/2026-09-23-BH-123-findings-scaffold-filter.md).
#
# Fail-open on every branch, like decision-log.sh: missing dir, missing args,
# unreadable file, a review that is half-written binary, a python that will not
# import — all exit 0 and never break a build. Caps: 40 lines per invocation,
# 330 chars of finding per line (a lens that floods the log is telling us
# something else is wrong).
set -uo pipefail
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
HARNESS="${HARNESS:-/root/harness}"
BUILD="${1:-}"; P="${2:-}"; KEY="${3:-}"
[ -n "$BUILD" ] && [ -n "$P" ] && [ -n "$KEY" ] && [ -d "$BUILD" ] || exit 0
SELF="$(cd "$(dirname "$0")" && pwd)" || exit 0
mkdir -p "$HARNESS/logs" 2>/dev/null || exit 0
FLOG="$HARNESS/logs/findings.log"
STAMP=$(date -u '+%Y-%m-%d %H:%M:%SZ')

# Which lenses have a file AND have not been harvested from this build yet.
TODO=""
# qa-prod.md joins the three review lenses 2026-08-29 (SDLC 3b). It is not a
# review — it is what a browser OBSERVED on the production domain after the
# merge — and that is exactly why it belongs here: rule-miner.sh's promotion
# threshold counts a family, not a lens, so a defect that keeps reaching
# production now recurs in the same ledger as the review comment that keeps
# being written. Written by bin/postmerge-qa.sh; absent on every other build,
# where this loop skips it exactly as it skips a missing security-review.md.
for PAIR in review.md:general security-review.md:security refute-review.md:refuter qa-prod.md:prodqa; do
  F="${PAIR%%:*}"; L="${PAIR##*:}"
  [ -f "$BUILD/$F" ] || continue
  [ -f "$BUILD/.findings-$L" ] && continue
  TODO="$TODO $PAIR"
done
[ -n "$TODO" ] || exit 0

# Repairs so far, from the one implementation of that rule. Fail-open like every
# other branch here: no helper, no count, and the rows lose a field rather than
# the build losing its findings.
REPAIRS=$("$SELF/repair-count.sh" "$BUILD" 2>/dev/null | cut -f1)
case "${REPAIRS:-}" in ''|*[!0-9]*) REPAIRS=0 ;; esac

# The build's KIND, from the one implementation of that rule. The gate re-reads
# $BUILD/plan.md and ticket-meta.json, so this is the same verdict run-build.sh
# routed on — and fail-open in the same way: no gate, no field.
KIND=$("$SELF/kind-gate.sh" "$BUILD" 2>/dev/null | sed -n 's/^KIND:[[:space:]]*//p' | tail -1)
case "${KIND:-}" in bug|feature|copy|migration|infra) ;; *) KIND="" ;; esac

# WRITE-THROUGH (BH-436): the hub wipe on 2026-09-15 took this log with it, so
# the rows are mirrored to the coordination DB's append log as well. FILE FIRST,
# ROW SECOND: the python's stdout goes to $TMP/rows.txt, the append to $FLOG
# happens next and unconditionally, and only then is anything sent. No `tee` and
# no process substitution — the `.findings-<lens>` markers are written by the
# same python, and a sequential redirect keeps "marker written" strictly after
# "rows produced". If mktemp fails we append straight to $FLOG exactly as before
# and mirror nothing: a full /tmp must never cost the log a BLOCK row.
TMP=$(mktemp -d 2>/dev/null) || TMP=""
[ -n "$TMP" ] && trap 'rm -rf "$TMP"' EXIT
# A failed redirect on `exec` EXITS a non-interactive shell, and the header
# above promises exit 0 on every branch — so both targets are proven writable
# with a `:` redirect (which only fails the builtin) before exec touches them.
ROWS="$FLOG"
[ -n "$TMP" ] && : > "$TMP/rows.txt" 2>/dev/null && ROWS="$TMP/rows.txt" || TMP=""
: >> "$FLOG" 2>/dev/null || exit 0
exec 3>> "$ROWS"
# shellcheck disable=SC2086  # TODO is a deliberate word list of <file>:<lens>
python3 - "$BUILD" "$P" "$KEY" "$STAMP" "$SELF" "$REPAIRS" "$KIND" $TODO <<'PYF' >&3 2>/dev/null
import os, re, sys

build, project, key, stamp, bindir, repairs, kind = sys.argv[1:8]
REPAIRS = 'repairs=%s ' % repairs if repairs.isdigit() and int(repairs) > 0 else ''
KIND = 'kind=%s ' % kind if kind else ''
sys.path.insert(0, bindir)
try:
    from alert_family import family
except Exception:
    def family(_line):        # fail-open: an unkeyed row still records the finding
        return "-"

# A finding headline is a bullet, a numbered item, or a sub-header whose text is
# long enough to be a sentence. The 30-char floor is what keeps section labels
# ("## Blocking findings", "## Non-blocking notes") out of the log; is_scaffold()
# below catches the longer ones.
MARKER = re.compile(r'^\s*(?:[-*+]|\d+[.)]|#{2,6})\s+(.*)$')
RULE = re.compile(r'(?<![A-Za-z0-9])D(\d{1,3})(?![A-Za-z0-9])')
VERDICT = re.compile(r'VERDICT:\s*(APPROVE|BLOCK)')
# The prod-QA lens states its verdict in its own vocabulary — `QA: PASS` /
# `QA: FAIL` is what bin/qa-drive.mjs and the prodqa agent both end on (plus
# `QA: BLOCKED`, which postmerge-qa.sh writes when the harness never got to look
# at all — a state the review vocabulary has no word for), and the
# tier-1 gate already keys on that exact line. Rewriting it to APPROVE/BLOCK
# here would put a word in the log that appears nowhere in the file it came
# from, which is the shape of annotation a reader cannot check.
QA_VERDICT = re.compile(r'^QA:\s*(PASS|FAIL|BLOCKED)\s*$', re.MULTILINE)
LENS_VERDICT = {'prodqa': QA_VERDICT}
# The six fraud classes the review lenses are told to hunt by name. Closed set
# on purpose: an invented class must not become a field consumers can group by.
FRAUD_CLASSES = ('weakened-tests', 'false-completion', 'scope-creep',
                 'unauthorized-action', 'spec-betrayal', 'debris')
# The lookahead covers digits and underscore as well as letters and the hyphen:
# without them `FRAUD: weakened-tests2` would log as `weakened-tests`, which is
# a mislabel rather than a rejection — the failure this closed set exists to
# prevent. (IGNORECASE makes the letter range cover A-Z too.)
FRAUD = re.compile(r'FRAUD:\s*(' + '|'.join(FRAUD_CLASSES) + r')(?![a-z0-9_-])',
                   re.IGNORECASE)
MIN_FINDING, MAX_CHARS, MAX_LINES = 30, 330, 40
# BH-123: review-format scaffolding, recognised by shape. Closed grammar on
# purpose, same reasoning as FRAUD_CLASSES: an editable deny-list would be a way
# to mute findings silently.
KEEP_BLOCK = re.compile(r'\bBLOCK(?:ING)?\b')          # case-sensitive: not "none blocking"
SCAFFOLD_LABEL = (r'(?:validation trace|requirements coverage(?: vs (?:the )?ticket)?'
                  r'|system invariants|findings|blocking findings'
                  r'|non-blocking (?:findings|notes)|verdict|summary|test honesty'
                  r'|mechanical gates|tool status)(?:\s*\([^()]*\))?')
SCAFFOLD_EXACT = re.compile(r'^' + SCAFFOLD_LABEL + r'$', re.I)
# A "Validation trace" heading is structural by position, so it alone may run on
# after a separator; every other label must match exactly (a "## Summary — ..."
# heading can carry a finding).
SCAFFOLD_HEADING = re.compile(r'^validation trace(?:\s*\([^()]*\))?'
                              r'(?:\s*[\u2014\u2013:]\s*.*|\s+-\s+.*)?$', re.I)
TOOL_LINE = re.compile(r'^`[^`]+`(?:\s*[\u2014\u2013:,-]\s*|\s+(?:is|was|are)\s+|\s+)(.*)$', re.I)
# Closed grammar: the clean word, then nothing or a no-new-information tail.
# Any other text after it could be a finding ("`tsc` ok, the route leaks ..."),
# so it is kept.
TOOL_CLEAN = re.compile(r'^(?:clean|green|pass|passes|passed|ok|exit(?:s|ed)? 0)'
                        r'(?:\s*[,;]?\s*(?:zero|0|no) (?:errors|warnings)(?: on head)?)?\.?$', re.I)
TOOL_ABSENT = re.compile(r'^(?:empty|does not exist|not present)\b.*\bnothing to triage\.?$', re.I)

def is_scaffold(body, heading):
    """True when a headline is review scaffolding, not a finding. Fail-open:
    any doubt, and any exception, keeps the line."""
    try:
        if RULE.search(body) or FRAUD.search(body) or KEEP_BLOCK.search(body):
            return False
        bold = (body.startswith(('**', '__')) and body.rstrip(':').endswith(body[:2])
                and body.count(body[:2]) == 2)
        norm = body.replace('**', '').replace('__', '').strip().rstrip(':').strip()
        if SCAFFOLD_EXACT.match(norm):
            return True
        if (heading or bold) and SCAFFOLD_HEADING.match(norm):
            return True
        t = TOOL_LINE.match(norm)
        if t:
            rest = t.group(1).strip()
            if TOOL_CLEAN.match(rest):
                return True
            if TOOL_ABSENT.match(rest):
                return True
        return False
    except Exception:
        return False

rows, seen, done = [], set(), []
for pair in sys.argv[8:]:
    fname, lens = pair.split(':', 1)
    path = os.path.join(build, fname)
    try:
        with open(path, errors='replace') as fh:
            text = fh.read()
    except Exception:
        continue
    done.append(lens)
    # The LAST verdict is the verdict: a fix round appends its re-review to the
    # same file, and the re-review is the one the pipeline acted on.
    verdicts = LENS_VERDICT.get(lens, VERDICT).findall(text)
    verdict = verdicts[-1] if verdicts else '-'
    for line in text.splitlines():
        if len(rows) >= MAX_LINES:
            break
        m = MARKER.match(line)
        if not m:
            continue
        body = ' '.join(m.group(1).split())
        body = ''.join(c for c in body if c.isprintable())
        if len(body) < MIN_FINDING or body.startswith(('VERDICT:', 'TIER:', 'QA:')):
            continue
        if is_scaffold(body, line.lstrip().startswith('#')):
            continue
        body = body[:MAX_CHARS]
        rule = 'D' + RULE.search(body).group(1) if RULE.search(body) else '-'
        fm = FRAUD.search(body)
        # Emitted only when tagged, and always BEFORE family= so `family=<key>`
        # stays adjacent to the `::` separator on every row, tagged or not.
        fraud = 'fraud=%s ' % fm.group(1).lower() if fm else ''
        fam = family(body)
        dedup = (lens, fam, body)
        if dedup in seen:
            continue
        seen.add(dedup)
        rows.append('%s [%s] ticket=%s lens=%s verdict=%s rule=%s %s%s%sfamily=%s :: %s'
                    % (stamp, project, key, lens, verdict, rule, fraud, REPAIRS,
                       KIND, fam, body))
    if len(rows) >= MAX_LINES:
        break

if rows:
    sys.stdout.write('\n'.join(rows) + '\n')
# Marker per lens READ, not per lens that produced rows: a lens whose findings
# were all section labels is harvested, and re-reading it every call would be
# work with a guaranteed empty result.
for lens in done:
    try:
        open(os.path.join(build, '.findings-' + lens), 'w').close()
    except Exception:
        pass
PYF
exec 3>&-

if [ -n "$TMP" ] && [ -s "$TMP/rows.txt" ]; then
  cat "$TMP/rows.txt" >> "$FLOG"
  if [ -r "$HARNESS/bin/jobs-client.sh" ]; then
    # `line` is the file line MINUS its 20-char stamp and the one space after
    # it, because log_rehydrate re-emits each row as `stamp + " " + line`. A row
    # too short to carry a stamp, or one missing ticket=/lens=, is dropped from
    # the batch rather than failing it — the file line has already landed.
    jq -R -c 'select(length > 21) | {stamp: .[0:20],
        ticket: ((capture("ticket=(?<t>[^ ]+)") | .t) // ""),
        lens:   ((capture("lens=(?<l>[^ ]+)")   | .l) // ""),
        line:   .[21:]}' "$TMP/rows.txt" 2>/dev/null | jq -s . > "$TMP/rows.json" 2>/dev/null
    # shellcheck source=/dev/null
    . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
    findings_put "$P" "$TMP/rows.json" >/dev/null 2>&1 || true
  fi
fi
exit 0
