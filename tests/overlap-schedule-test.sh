#!/bin/bash
# tests/overlap-schedule-test.sh — bin/overlap-schedule.sh and the three places
# that consume it. Run from anywhere: tests/overlap-schedule-test.sh
# (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY (BH-475). 9 of 17 cromford builds in 24h ended
# BUILD_DEFERRED on a file overlap discovered at LAUNCH, after the plan session
# was already paid for. The schedule moves that question in front of the launch,
# and the expensive way for it to be wrong is not "it missed an overlap" — that
# costs one rebase, which is what today costs. It is "it invented one": a HELD
# verdict on two tickets that do not actually share a file delays a client's
# work for a reason nobody can see. So the adversarial negatives (a shared
# SOURCE: header, a dir its own list names a file under, code/a.ts vs
# code/a.tsx, a finished build's claim, a ticket's own claim) are cases here,
# and case 8 pins the overlap rule EQUAL to bin/lib/dep-verify-lib.sh's
# dep_overlap rather than merely similar — a fourth spelling of that rule is a
# wave that disagrees with the gate it feeds.
#
# No network, no gh, no LLM, no clock reads.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCHED="$DIR/bin/overlap-schedule.sh"

# ── the fixture harness ──────────────────────────────────────────────────────
# A scratch $HARNESS that owns state/, plans/, builds/ and flags/ but serves the
# REAL script under test, the same shape tests/preplan-speculative-test.sh uses.
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" \
         "$H/locks" "$H/state/claims/proj" "$H/state/preplan-candidates"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" \
   "$DIR/bin/lib/scheduler-conf.sh" "$H/bin/lib/" 2>/dev/null
[ -f "$SCHED" ] && cp "$SCHED" "$H/bin/overlap-schedule.sh"
cat > "$H/fleet.conf" <<'CONF'
proj  example-org/proj   -  -  0 local -
CONF

plan_files() { # plan_files <KEY> <path>...
  local k="$1"; shift
  mkdir -p "$H/plans/proj-$k"
  printf '%s\n' "$@" > "$H/plans/proj-$k/planned-files.txt"
}
snapshot() { # snapshot — write the candidate rows and make them FRESH
  cat > "$H/state/preplan-candidates/proj.tsv" <<'TSV'
AB-1	1	ahead
AB-2	2	ahead
AB-3	3	ahead
AB-4	4	ahead
AB-5	5	ahead
AB-6	6	ahead
AB-7	7	blocked
AB-8	8	ahead
TSV
}
reset() { # reset — back to the base fixture (no claims, no build dirs)
  scratch_rm "$H/state/claims/proj"; scratch_rm "$H/builds"; rm -f "$H/bin/jobs-client.sh"
  mkdir -p "$H/state/claims/proj" "$H/builds"
  snapshot
}
plan_files AB-1 code/a.ts code/shared.ts
plan_files AB-2 code/shared.ts
plan_files AB-3 code/c.ts notes/X.txt
plan_files AB-4 notes/X.txt
plan_files AB-5 code/e.ts
plan_files AB-6 code/shared.ts code/f.ts
plan_files AB-7 code/g.ts
# AB-8 deliberately has no plans/ dir at all.
reset

run() { HARNESS="$H" "$H/bin/overlap-schedule.sh" "$@" 2>/dev/null; }
run2() { HARNESS="$H" "$H/bin/overlap-schedule.sh" "$@" 2>"$T/err.txt"; }
wave_of() { # wave_of <output> <KEY> -> the wave number, or nothing
  awk -v k="$2" '/^WAVE /{n=$2; sub(":","",n); for(i=3;i<=NF;i++) if($i==k){print n; exit}}' <<<"$1"
}

# ---------- 0. the script exists and parses --------------------------------
[ -x "$SCHED" ] && ok || bad "bin/overlap-schedule.sh must exist and be executable"
bash -n "$SCHED" 2>/dev/null && ok || bad "bin/overlap-schedule.sh does not parse"

# ---------- 1. waves: independent sets first -------------------------------
OUT=$(run proj)
W1=$(awk '/^WAVE 1:/{ $1="";$2=""; print }' <<<"$OUT")
for K in AB-1 AB-3 AB-5; do
  grep -qw "$K" <<<"$W1" && ok || bad "WAVE 1 must contain $K (got: $OUT)"
done
for K in AB-2 AB-4 AB-6; do
  grep -qw "$K" <<<"$W1" && bad "WAVE 1 must NOT contain $K — it overlaps a wave-1 key (got: $OUT)" || ok
done
W2=$(awk '/^WAVE 2:/{ $1="";$2=""; print }' <<<"$OUT")
grep -qw AB-2 <<<"$W2" && ok || bad "AB-2 must land in WAVE 2 (got: $OUT)"
grep -qw AB-4 <<<"$W2" && ok || bad "AB-4 must land in WAVE 2 (got: $OUT)"
WN=$(wave_of "$OUT" AB-6)
[ -n "$WN" ] && [ "$WN" -ge 2 ] && ok \
  || bad "AB-6 overlaps AB-1 and AB-2, so it must be in wave 2 or later (got: $OUT)"
# a `blocked` candidate is planned-but-not-ready: it counts for HOT-FILES and is
# never scheduled, or the wave would launch a ticket whose blocker is still open.
[ -z "$(wave_of "$OUT" AB-7)" ] && ok || bad "a 'blocked' candidate must appear in NO wave (got: $OUT)"
[ -z "$(wave_of "$OUT" AB-8)" ] && ok || bad "a candidate with no pre-plan must appear in NO wave (got: $OUT)"
grep -qE '^UNPLANNED:.*\bAB-8\b' <<<"$OUT" && ok || bad "AB-8 must be listed UNPLANNED (got: $OUT)"

# 1b. the threshold is a knob, and at 2 the two-ticket file shows up with both
OUT2=$(OVERLAP_HOT_MIN=2 run proj)
grep -qF 'notes/X.txt :: AB-3 AB-4' <<<"$OUT2" && ok \
  || bad "OVERLAP_HOT_MIN=2 must list notes/X.txt with BOTH tickets (got: $OUT2)"

# ---------- 2. an in-flight claim HOLDS a candidate ------------------------
echo 'code/e.ts' > "$H/state/claims/proj/AB-9"
OUT=$(run proj)
[ -z "$(wave_of "$OUT" AB-5)" ] && ok || bad "AB-5 overlaps in-flight AB-9 — it must be in no wave (got: $OUT)"
grep -qF 'HELD: AB-5 overlaps in-flight AB-9 on code/e.ts' <<<"$OUT" && ok \
  || bad "the HELD line must name the sibling and the file (got: $OUT)"
# an EMPTY claim file is not a claim: a build that published nothing holds nothing
: > "$H/state/claims/proj/AB-9"
[ -n "$(wave_of "$(run proj)" AB-5)" ] && ok || bad "an empty claim file must not hold anything"
echo 'code/e.ts' > "$H/state/claims/proj/AB-9"

# ---------- 3. a live build dir holds; a finished one does not -------------
B="$H/builds/proj-AB-10-1"; mkdir -p "$B"; echo 'code/c.ts' > "$B/planned-files.txt"
OUT=$(run proj)
[ -z "$(wave_of "$OUT" AB-3)" ] && ok || bad "a live build dir on code/c.ts must hold AB-3 (got: $OUT)"
echo 'PR https://example/1' > "$B/RESULT"
OUT=$(run proj)
[ "$(wave_of "$OUT" AB-3)" = 1 ] && ok || bad "a FINISHED build must release AB-3 back to wave 1 (got: $OUT)"
scratch_rm "$B"

# ---------- 4. --key: the one-line verdict the shard prompt carries ---------
V=$(run proj --key AB-2)
[ "$(grep -c . <<<"$V")" = 1 ] && ok || bad "--key must print exactly one line (got: $V)"
grep -qE '^AB-2 WAVE 2 \(overlaps AB-1 on code/shared\.ts\)$' <<<"$V" && ok \
  || bad "--key AB-2 must name its wave, the key it collides with and the file (got: $V)"
V=$(run proj --key AB-5)
grep -qF 'HELD: AB-5 overlaps in-flight AB-9 on code/e.ts' <<<"$V" && ok \
  || bad "--key on a HELD ticket must print the HELD line (got: $V)"
V=$(run proj --key AB-8)
grep -qE '^AB-8 UNPLANNED' <<<"$V" && ok || bad "--key on a ticket with no pre-plan must say UNPLANNED (got: $V)"
V=$(run proj --key AB-1)
grep -qE '^AB-1 WAVE 1' <<<"$V" && ok || bad "--key on a wave-1 ticket must say WAVE 1 (got: $V)"
[ -z "$(run proj --key AB-999)" ] && ok || bad "--key on a key the schedule never saw must print nothing"
rm -f "$H/state/claims/proj/AB-9"

# ---------- 5. HOT-FILES at the default threshold of 3 ---------------------
OUT=$(run proj)
grep -qF 'code/shared.ts :: AB-1 AB-2 AB-6' <<<"$OUT" && ok \
  || bad "HOT-FILES must list code/shared.ts with its three tickets (got: $OUT)"
grep -qF 'notes/X.txt' <<<"$OUT" && bad "a file shared by 2 tickets is below the default threshold of 3 (got: $OUT)" || ok

# ---------- 6. the kill switch ---------------------------------------------
OUT=$(OVERLAP_SCHEDULE=0 run proj); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "OVERLAP_SCHEDULE=0 must print nothing and exit 0 (rc=$RC out=$OUT)"
printf 'OVERLAP_SCHEDULE=0\n' > "$H/env/global.env"
[ -z "$(run proj)" ] && ok || bad "OVERLAP_SCHEDULE=0 in env/global.env must turn it off"
: > "$H/env/global.env"
touch "$H/flags/overlap-schedule-off"
OUT=$(run proj); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "flags/overlap-schedule-off must turn it off (rc=$RC out=$OUT)"
rm -f "$H/flags/overlap-schedule-off"
[ -n "$(run proj)" ] && ok || bad "removing the flag must turn it back on"

# ---------- 7. the SOURCE: header is not a file ----------------------------
# bin/planned-files-cheap.sh writes which tier produced a list as its first
# line. Counted as a path it makes EVERY cheap list overlap every other one.
printf 'SOURCE: ticket-body\ncode/only-mine.ts\n' > "$H/plans/proj-AB-5/planned-files.txt"
printf 'SOURCE: ticket-body\ncode/only-yours.ts\n' > "$H/plans/proj-AB-4/planned-files.txt"
OUT=$(run proj)
[ "$(wave_of "$OUT" AB-4)" = 1 ] && [ "$(wave_of "$OUT" AB-5)" = 1 ] && ok \
  || bad "two lists sharing only the SOURCE: header must be disjoint (got: $OUT)"
grep -q 'SOURCE' <<<"$OUT" && bad "the SOURCE: header must never appear as a hot file (got: $OUT)" || ok
plan_files AB-4 notes/X.txt
plan_files AB-5 code/e.ts

# ---------- 8. the overlap rule EQUALS dep_overlap's -----------------------
# Four shapes, each a real one: the TK-667 dir+file list, a bare dir scope, and
# the two suffix near-misses. The scheduler's verdict must match the library's
# for every one, or the wave disagrees with the gate that backstops it.
. "$DIR/bin/lib/dep-verify-lib.sh"
agree() { # agree <name> <listA...> -- <listB...>
  local name="$1"; shift
  local -a A=() B=(); local side=A
  for a in "$@"; do
    if [ "$a" = "--" ]; then side=B; continue; fi
    if [ "$side" = A ]; then A+=("$a"); else B+=("$a"); fi
  done
  plan_files AB-4 "${A[@]}"
  plan_files AB-5 "${B[@]}"
  printf '%s\n' "${A[@]}" > "$T/la"; printf '%s\n' "${B[@]}" > "$T/lb"
  local libsays schedsays
  [ -n "$(dep_overlap "$T/la" "$T/lb")" ] && libsays=overlap || libsays=disjoint
  local o; o=$(run proj)
  if [ "$(wave_of "$o" AB-4)" = "$(wave_of "$o" AB-5)" ] && [ -n "$(wave_of "$o" AB-4)" ]; then
    schedsays=disjoint
  else
    schedsays=overlap
  fi
  [ "$libsays" = "$schedsays" ] && ok \
    || bad "overlap rule disagrees with dep_overlap on '$name': lib=$libsays scheduler=$schedsays"
}
agree "dir+file vs another file under the dir" zz/x zz/x/a.ts -- zz/x/b.ts
agree "bare dir vs a file under it"            zz/x           -- zz/x/b.ts
agree "zz/a.ts vs zz/a.tsx"                    zz/a.ts        -- zz/a.tsx
agree "zz/a.ts vs zz/a.ts.bak"                 zz/a.ts        -- zz/a.ts.bak
agree "the same file"                          zz/same.ts     -- zz/same.ts
plan_files AB-4 notes/X.txt
plan_files AB-5 code/e.ts

# ---------- 8b. ONE deferral rule, shared with bin/overlap-guard.sh --------
# THE FLEET ALREADY HAS A FILE-OVERLAP RULE AT LAUNCH TIME (#366, 2026-09-15):
# bin/overlap-guard.sh exempts `package.json package-lock.json *.md` and honours
# a Jaccard threshold, both resolved through bin/lib/scheduler-conf.sh, because
# the merge conductor union-resolves those classes deterministically
# (docs/SCHEDULER.md). A schedule that defers on exactly the paths the guard
# waves through puts two contradictory rules in one tick prompt — on the very
# files this ticket's own evidence is made of. So both read the same knobs from
# the same place, and these cases drive that rather than assume it.
plan_files AB-4 docs/SHARED.md
plan_files AB-5 docs/SHARED.md code/e.ts
OUT=$(run proj)
W4=$(wave_of "$OUT" AB-4); W5=$(wave_of "$OUT" AB-5)
[ -n "$W4" ] && [ "$W4" = "$W5" ] && ok \
  || bad "two tickets sharing only a *.md must ride one wave — the guard exempts that class (got: $OUT)"
# ...and it is still REPORTED. The exemption is about DEFERRING, not about the
# hot-file line that asks whether the change belongs in a per-ticket file.
grep -qF 'docs/SHARED.md :: AB-4 AB-5' <<<"$(OVERLAP_HOT_MIN=2 run proj)" && ok \
  || bad "an exempt path must still be reported as a hot file (got: $(OVERLAP_HOT_MIN=2 run proj))"
# an in-flight claim on an exempt path holds nobody either
echo 'docs/SHARED.md' > "$H/state/claims/proj/AB-9"
OUT=$(run proj)
grep -qE '^HELD: AB-[45] ' <<<"$OUT" && bad "an exempt path must never HELD a candidate (got: $OUT)" || ok
rm -f "$H/state/claims/proj/AB-9"
# the list is a knob, and it is the guard's knob: environment...
OUT=$(OVERLAP_IGNORE='package-lock.json' run proj)
W4=$(wave_of "$OUT" AB-4); W5=$(wave_of "$OUT" AB-5)
[ -n "$W4" ] && [ "$W4" != "$W5" ] && ok \
  || bad "an OVERLAP_IGNORE without *.md must put the collision back (got: $OUT)"
# ...and flags/scheduler.conf, the file an operator edits from the console.
printf 'OVERLAP_IGNORE=package-lock.json\n' > "$H/flags/scheduler.conf"
OUT=$(run proj)
W4=$(wave_of "$OUT" AB-4); W5=$(wave_of "$OUT" AB-5)
[ -n "$W4" ] && [ "$W4" != "$W5" ] && ok \
  || bad "flags/scheduler.conf must reach the scheduler as it reaches the guard (got: $OUT)"
rm -f "$H/flags/scheduler.conf"
# the Jaccard threshold is the guard's too: one shared file out of four is 0.14,
# below a 0.9 setting, and is not a collision at that setting.
plan_files AB-4 code/p.ts code/q.ts code/r.ts code/pair2.ts
plan_files AB-5 code/s.ts code/t.ts code/u.ts code/pair2.ts
OUT=$(OVERLAP_THRESHOLD=0.9 run proj)
W4=$(wave_of "$OUT" AB-4); W5=$(wave_of "$OUT" AB-5)
[ -n "$W4" ] && [ "$W4" = "$W5" ] && ok \
  || bad "OVERLAP_THRESHOLD=0.9 must let one shared file past, as the guard does (got: $OUT)"
OUT=$(run proj)
W4=$(wave_of "$OUT" AB-4); W5=$(wave_of "$OUT" AB-5)
[ -n "$W4" ] && [ "$W4" != "$W5" ] && ok \
  || bad "the default threshold 0 must still treat one shared file as a collision (got: $OUT)"
plan_files AB-4 notes/X.txt
plan_files AB-5 code/e.ts

# ---------- 9. the snapshot, and the live fallback -------------------------
cat > "$H/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
echo "live-call" >> "$HARNESS/live-called.txt"
printf 'AB-1\t1\tahead\nAB-2\t2\tahead\n'
SH
chmod +x "$H/bin/preplan-candidates.sh"
: > "$H/live-called.txt"
OUT=$(run proj)
[ ! -s "$H/live-called.txt" ] && ok || bad "a FRESH snapshot must not trigger a live preplan-candidates call"
mv "$H/state/preplan-candidates/proj.tsv" "$T/snap.keep"
OUT=$(run proj)
[ -s "$H/live-called.txt" ] && ok || bad "an ABSENT snapshot must fall back to the live classifier"
grep -qE '^WAVE 1:.*\bAB-1\b' <<<"$OUT" && ok || bad "the live fallback's rows must be used (got: $OUT)"
# ...and the live fallback PUBLISHES what it got, so the shard calls that follow
# it in the same tick read the file instead of buying two more GitHub requests
# each (a 10-shard tick would otherwise ask 11 times).
[ -s "$H/state/preplan-candidates/proj.tsv" ] && ok \
  || bad "a live fallback must publish its rows as the snapshot for the rest of the tick"
: > "$H/live-called.txt"
OUT=$(run proj)
[ ! -s "$H/live-called.txt" ] && ok || bad "the published snapshot must stop the next call asking live again"
rm -f "$H/state/preplan-candidates/proj.tsv"
# ...but an EMPTY live answer is an outage, not an empty backlog: publishing it
# would freeze a dead token into a fresh-looking snapshot for the whole window.
cat > "$H/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
echo "live-call" >> "$HARNESS/live-called.txt"
SH
chmod +x "$H/bin/preplan-candidates.sh"
run proj >/dev/null
[ ! -e "$H/state/preplan-candidates/proj.tsv" ] && ok \
  || bad "an empty live answer must NOT be published as a snapshot"
cat > "$H/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
echo "live-call" >> "$HARNESS/live-called.txt"
printf 'AB-1\t1\tahead\nAB-2\t2\tahead\n'
SH
chmod +x "$H/bin/preplan-candidates.sh"
# a STALE snapshot is not "no candidates" — it triggers the same live fallback
cp "$T/snap.keep" "$H/state/preplan-candidates/proj.tsv"
touch -d '@86400' "$H/state/preplan-candidates/proj.tsv"   # determinism: ok a fixed epoch, not the wall clock
: > "$H/live-called.txt"
OUT=$(run proj)
[ -s "$H/live-called.txt" ] && ok || bad "a STALE snapshot must fall back to the live classifier"
# ...and a dead classifier with no snapshot is silence, never a held ticket
rm -f "$H/state/preplan-candidates/proj.tsv"
cat > "$H/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$H/bin/preplan-candidates.sh"
OUT=$(run proj); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "no candidates must print nothing and exit 0 (rc=$RC out=$OUT)"
rm -f "$H/bin/preplan-candidates.sh"
cp "$T/snap.keep" "$H/state/preplan-candidates/proj.tsv"

# ---------- 10. a candidate that is ITSELF in flight ----------------------
echo 'code/a.ts
code/shared.ts' > "$H/state/claims/proj/AB-1"
OUT=$(run proj)
[ -z "$(wave_of "$OUT" AB-1)" ] && ok || bad "a candidate whose own claim is live is building — no wave (got: $OUT)"
grep -qF 'HELD: AB-2 overlaps in-flight AB-1 on code/shared.ts' <<<"$OUT" && ok \
  || bad "AB-2 must be HELD by the in-flight AB-1 (got: $OUT)"
grep -qE '^HELD: AB-1 ' <<<"$OUT" && bad "a ticket must never be HELD by its own claim (got: $OUT)" || ok
reset

# 10c. child-building IS A CANDIDATE CLASS TOO. bin/preplan-candidates.sh
# releases a child whose parent's build is running right now as
# `child-building`; that is the ticket most likely to plan the very files the
# parent holds, so the filter must judge it. A class the case list does not
# know is `continue`d out silently: no wave, no HELD, no coverage.
echo 'code/a.ts
code/shared.ts' > "$H/state/claims/proj/AB-1"
# Written the way bin/preplan-candidates.sh would actually print it: its own
# ORDER puts `child-building` ABOVE `ahead`, and case 15 pins that this script
# follows the classifier's row order instead of re-deriving a rank of its own.
{ printf 'AB-2\t2\tchild-building\n'
  grep -v '^AB-2	' "$H/state/preplan-candidates/proj.tsv"; } > "$T/snap.cb"
mv -f "$T/snap.cb" "$H/state/preplan-candidates/proj.tsv"
grep -qP '^AB-2\t2\tchild-building$' "$H/state/preplan-candidates/proj.tsv" || bad "fixture: AB-2 must be re-classed child-building"
OUT=$(run proj)
grep -qF 'HELD: AB-2 overlaps in-flight AB-1 on code/shared.ts' <<<"$OUT" && ok \
  || bad "a child-building candidate must be judged like child (got: $OUT)"
rm -f "$H/state/claims/proj/AB-1"
OUT=$(run proj)
[ "$(wave_of "$OUT" AB-2)" = 1 ] && ok \
  || bad "a child-building candidate with no live overlap must ride wave 1 (got: $OUT)"
reset

# 10b. THE CLAIM IS WHAT THE BUILD ACTUALLY OWNS, and a pre-plan the build has
# since re-planned past is not. AB-3's claim says code/zzz.ts; its (now stale)
# pre-plan still says notes/X.txt. AB-4 plans notes/X.txt and must be FREE —
# reading the two lists as one set would hold a ticket on a file nobody holds.
echo 'code/zzz.ts' > "$H/state/claims/proj/AB-3"
OUT=$(run proj)
[ "$(wave_of "$OUT" AB-4)" = 1 ] && ok \
  || bad "a candidate must not be held by a superseded pre-plan of an in-flight key (got: $OUT)"
grep -qE '^HELD: AB-4 ' <<<"$OUT" && bad "AB-4 shares no file with AB-3's live claim (got: $OUT)" || ok
grep -qF 'notes/X.txt' <<<"$OUT" && bad "an in-flight key's stale pre-plan must not count toward HOT-FILES (got: $OUT)" || ok
reset

# ---------- 11. the tick feed, extracted from bin/lib/rt/scope.sh ---------
# The production entry point: the block rt_scope() actually runs (bin/lib/rt/
# scope.sh, the scope stage bin/run-triage.sh sources — BH-567), lifted
# by its markers and driven against a stub scheduler.
cut_block() { # cut_block <file> <marker-word...> <outfile>
  # Leading indentation is stripped before the marker is matched (the shard
  # block below lives inside a loop), but the extracted lines keep theirs.
  awk -v n="$2" '{l=$0; sub(/^[ \t]+/,"",l)}
                 index(l,"# >>> " n)==1{f=1;next}
                 index(l,"# <<< " n)==1{exit} f' "$1" > "$3"
}
cut_block "$DIR/bin/lib/rt/scope.sh" "overlap schedule feed" "$T/feed.sh"
[ -s "$T/feed.sh" ] && ok || bad "could not extract '# >>> overlap schedule feed' from bin/lib/rt/scope.sh"
bash -n "$T/feed.sh" 2>/dev/null && ok || bad "the extracted tick-feed block does not parse on its own"

FH="$T/fh"; mkdir -p "$FH/bin" "$FH/logs"
cat > "$FH/bin/overlap-schedule.sh" <<'SH'
#!/bin/bash
[ -s "$HARNESS/stub-out.txt" ] || exit 0
cat "$HARNESS/stub-out.txt"
SH
chmod +x "$FH/bin/overlap-schedule.sh"
cat > "$FH/stub-out.txt" <<'OUTEOF'
WAVE 1: AB-1 AB-3 AB-5
WAVE 2: AB-2 AB-4
HELD: AB-5 overlaps in-flight AB-9 on code/e.ts
HOT-FILES:
code/shared.ts :: AB-1 AB-2 AB-6
OUTEOF
DRIVE_FEED() { # DRIVE_FEED -> prints OVERLAP_SEC
  ( set -uo pipefail
    export HARNESS="$FH"; PROJECT=proj; LOG="$FH/logs/proj.log"; STAMP=x
    # shellcheck disable=SC1090
    . "$T/feed.sh"
    printf '%s' "${OVERLAP_SEC:-}" )
}
: > "$FH/logs/proj.log"
SEC=$(DRIVE_FEED)
grep -qF 'WAVE 1: AB-1 AB-3 AB-5' <<<"$SEC" && ok || bad "OVERLAP_SEC must carry the schedule (got: $SEC)"
grep -qi 'launch rule' <<<"$SEC" && ok || bad "OVERLAP_SEC must carry the launch rule sentence (got: $SEC)"
grep -q 'HELD' <<<"$SEC" && ok || bad "OVERLAP_SEC must carry the HELD lines (got: $SEC)"
# WAVE 2+ IS ORDER, NOT A VETO, AND IT HAS AN ESCAPE. HELD is bounded by the
# build it names (a RESULT, a finished claim, the 4h age-out). A wave is not:
# the wave-1 key it yields to may be un-launchable for reasons this schedule
# cannot see (a blocking PR still open, no slot, another shard's ticket), and a
# rule that says "not this tick" on every tick holds a client's ticket forever.
# So the prompt says the earlier key goes first AND names the condition that
# frees this one, with bin/overlap-guard.sh as the gate at launch.
grep -qi 'not a veto' <<<"$SEC" && ok \
  || bad "the launch rule must say a WAVE verdict is ordering, not a prohibition (got: $SEC)"
grep -qi 'does not launch this tick' <<<"$SEC" && ok \
  || bad "the launch rule must name the wave escape: launch it anyway when the earlier key does not (got: $SEC)"
grep -qi 'overlap-guard' <<<"$SEC" && ok \
  || bad "the launch rule must name the launch-time guard as the gate that settles it (got: $SEC)"
grep -qF 'HOT-FILES: code/shared.ts shared by AB-1 AB-2 AB-6' "$FH/logs/proj.log" && ok \
  || bad "the tick log must gain one HOT-FILES line per hot file (got: $(cat "$FH/logs/proj.log"))"
# ...and a scheduler that prints nothing leaves the tick byte-for-byte as it was
: > "$FH/stub-out.txt"; : > "$FH/logs/proj.log"
SEC=$(DRIVE_FEED)
[ -z "$SEC" ] && ok || bad "a silent scheduler must leave OVERLAP_SEC empty (got: $SEC)"
[ ! -s "$FH/logs/proj.log" ] && ok || bad "a silent scheduler must write no log line (got: $(cat "$FH/logs/proj.log"))"
# no script on the box at all: same answer, no error
rm -f "$FH/bin/overlap-schedule.sh"
SEC=$(DRIVE_FEED); RC=$?
[ "$RC" = 0 ] && [ -z "$SEC" ] && ok || bad "an absent scheduler must be a silent no-op (rc=$RC sec=$SEC)"

# 11b. the scheduler's stderr reaches the project log STAMPED. Every line in
# logs/<project>.log carries `<stamp> [<project>] ` and the pipeline-health
# greps read that shape, so an OVERLAP_UNJUDGED line appended raw is a line
# nobody can find. Driven: the stub writes to stderr, the real block routes it.
cat > "$FH/bin/overlap-schedule.sh" <<'SH'
#!/bin/bash
echo "OVERLAP_UNJUDGED AB-7 — claimed on another box" >&2
[ -s "$HARNESS/stub-out.txt" ] || exit 0
cat "$HARNESS/stub-out.txt"
SH
chmod +x "$FH/bin/overlap-schedule.sh"
: > "$FH/logs/proj.log"
SEC=$(DRIVE_FEED)
grep -qF 'x [proj] OVERLAP_UNJUDGED AB-7 — claimed on another box' "$FH/logs/proj.log" && ok \
  || bad "the scheduler's stderr must reach the log stamped (got: $(cat "$FH/logs/proj.log"))"
grep -q '^OVERLAP_UNJUDGED' "$FH/logs/proj.log" && bad "no unstamped line may reach the log" || ok

# ---------- 11c. the shard prompt's per-ticket verdict, DRIVEN -------------
# Not a source grep: the real `# >>> shard overlap verdict` block and the real
# prompt line are lifted from bin/lib/rt/shards.sh (the shard stage
# bin/run-triage.sh sources — BH-567) and evaluated against a stub
# scheduler, so the quoting, the fail-open and the sentence itself are proven
# by what a shard would actually be handed.
cut_block "$DIR/bin/lib/rt/shards.sh" "shard overlap verdict" "$T/shardov.sh"
[ -s "$T/shardov.sh" ] && ok || bad "could not extract '# >>> shard overlap verdict' from bin/lib/rt/shards.sh"
grep -qF -- '--key "$K"' "$T/shardov.sh" && ok || bad "the shard block must ask for its own key's verdict (--key)"
OVLINE=$(grep -F 'OVERLAP SCHEDULE (deterministic, bin/overlap-schedule.sh)' "$DIR/bin/lib/rt/shards.sh")
[ -n "$OVLINE" ] && ok || bad "bin/lib/rt/shards.sh must carry the shard prompt's OVERLAP SCHEDULE line"

SH2="$T/sh2"; mkdir -p "$SH2/bin"
cat > "$SH2/bin/overlap-schedule.sh" <<'SH'
#!/bin/bash
[ "$2" = --key ] || exit 0
printf 'HELD: %s overlaps in-flight AB-9 on code/e.ts\n' "$3"
SH
chmod +x "$SH2/bin/overlap-schedule.sh"
DRIVE_SHARD() { # DRIVE_SHARD <key> -> the prompt tail that shard is handed
  ( set -uo pipefail
    HARNESS="$SH2"; PROJECT=proj; K="$1"
    # shellcheck disable=SC1090
    . "$T/shardov.sh"
    eval "SHARD_TAIL=\"$OVLINE\""
    printf '%s' "$SHARD_TAIL" )
}
TAIL=$(DRIVE_SHARD AB-5)
grep -qF 'HELD: AB-5 overlaps in-flight AB-9 on code/e.ts' <<<"$TAIL" && ok \
  || bad "the shard prompt must carry its own key's verdict (got: $TAIL)"
grep -qF 'do NOT launch AB-5 this tick' <<<"$TAIL" && ok \
  || bad "the shard prompt must name the key in the launch instruction (got: $TAIL)"
grep -qF "skip :: overlaps <KEY> on <file>" <<<"$TAIL" && ok \
  || bad "the shard prompt must carry the skip wording (got: $TAIL)"
# the \n in the printf are REAL newlines, not the two literal characters
[ "$(printf '%s\n' "$TAIL" | wc -l)" -ge 3 ] && ok \
  || bad "the appended verdict must be newline-separated, not one run-on line (got: $TAIL)"
grep -q 'OVERLAP SCHEDULE' <<<"$(printf '%s' "$TAIL" | tail -n +2)" && ok \
  || bad "the verdict must land on its own line after the do-not-widen sentence (got: $TAIL)"
# ...and a WAVE verdict is ordering with an escape, not a second "do not launch".
# A shard told "not this tick" every tick is a ticket nobody ever builds, and
# the key it yields to may never launch at all.
cat > "$SH2/bin/overlap-schedule.sh" <<'SH'
#!/bin/bash
[ "$2" = --key ] || exit 0
printf '%s WAVE 2 (overlaps AB-1 on code/shared.ts)\n' "$3"
SH
chmod +x "$SH2/bin/overlap-schedule.sh"
TAIL=$(DRIVE_SHARD AB-5)
grep -qF 'AB-5 WAVE 2 (overlaps AB-1 on code/shared.ts)' <<<"$TAIL" && ok \
  || bad "the shard prompt must carry a WAVE verdict too (got: $TAIL)"
grep -qi 'not a veto' <<<"$TAIL" && ok \
  || bad "a WAVE verdict must be stated as ordering, not a prohibition (got: $TAIL)"
grep -qi 'does not launch this tick' <<<"$TAIL" && ok \
  || bad "the shard prompt must name the escape for a WAVE 2+ key (got: $TAIL)"
grep -qi 'overlap-guard' <<<"$TAIL" && ok \
  || bad "the shard prompt must name the launch-time guard as the gate (got: $TAIL)"
# fail-open: no scheduler on the box -> the shard prompt gains NO sentence
rm -f "$SH2/bin/overlap-schedule.sh"
TAIL=$(DRIVE_SHARD AB-5); RC=$?
[ "$RC" = 0 ] && ok || bad "an absent scheduler must not fail the shard prompt (rc=$RC)"
grep -q 'OVERLAP SCHEDULE' <<<"$TAIL" && bad "an absent scheduler must add no verdict sentence (got: $TAIL)" || ok

# ---------- 12. the snapshot writer, driven through bin/preplan-tick.sh ----
# Production entry point again: the real tick, stubbed externals, asserting the
# snapshot file AND that the PREPLAN_PARALLEL cap still bounds the launches.
PT="$T/pt"
mkdir -p "$PT/bin/lib" "$PT/env" "$PT/flags" "$PT/logs" "$PT/locks" "$PT/plans" \
         "$PT/state" "$PT/prompts" "$PT/repos/proj"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$PT/bin/lib/"
for f in preplan-tick.sh fleet-conf.sh project-of.sh fleet-projects-or-alert.sh; do
  cp "$DIR/bin/$f" "$PT/bin/"
done
cat > "$PT/fleet.conf" <<'CONF'
proj  example-org/proj  -  -  0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$PT/prompts/proj.md"
printf '#!/bin/bash\necho local\n' > "$PT/bin/box-name.sh"
printf '#!/bin/bash\necho "$1 $2 $3" >> "$HARNESS/launched.txt"\n' > "$PT/bin/run-preplan.sh"
cat > "$PT/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tahead\nAB-2\t2\tahead\nAB-3\t3\tahead\nAB-4\t4\tahead\nAB-5\t5\tahead\n'
SH
chmod +x "$PT/bin/box-name.sh" "$PT/bin/run-preplan.sh" "$PT/bin/preplan-candidates.sh"
: > "$PT/launched.txt"
( export HARNESS="$PT" FLEET_CONF="$PT/fleet.conf" REPOS_ROOT="$PT/repos" PREPLAN_PARALLEL=3
  "$PT/bin/preplan-tick.sh" ) >/dev/null 2>&1
sleep 0.5
SNAPF="$PT/state/preplan-candidates/proj.tsv"
[ -s "$SNAPF" ] && ok || bad "the tick must write state/preplan-candidates/<project>.tsv"
diff <("$PT/bin/preplan-candidates.sh" proj) "$SNAPF" >/dev/null 2>&1 && ok \
  || bad "the snapshot must equal the classifier's own output (got: $(cat "$SNAPF" 2>/dev/null))"
[ "$(grep -c . "$PT/launched.txt")" = 3 ] && ok \
  || bad "PREPLAN_PARALLEL=3 must still bound the launches (got: $(cat "$PT/launched.txt"))"

# ---------- 13. the reviewer's hot-file context, from bin/run-build.sh -----
cut_block "$RB_ALL" "hot files" "$T/hot.sh"
[ -s "$T/hot.sh" ] && ok || bad "could not extract '# >>> hot files' from bin/run-build.sh"
bash -n "$T/hot.sh" 2>/dev/null && ok || bad "the extracted hot-files block does not parse on its own"
HB="$H/builds/proj-AB-1-1"; mkdir -p "$HB"
printf 'code/a.ts\ncode/shared.ts\n' > "$HB/planned-files.txt"
DRIVE_HOT() {
  ( set -uo pipefail
    export HARNESS="$H"; PROJECT=proj; KEY=AB-1; BUILD="$HB"
    # shellcheck disable=SC1090
    . "$T/hot.sh" )
}
DRIVE_HOT
HF=$(cat "$HB/hot-files.txt" 2>/dev/null)
grep -qF 'code/shared.ts' <<<"$HF" && ok || bad "hot-files.txt must name the shared file (got: $HF)"
grep -qw 'AB-2' <<<"$HF" && grep -qw 'AB-6' <<<"$HF" && ok \
  || bad "hot-files.txt must name the sibling tickets that share it (got: $HF)"
grep -qw 'AB-1' <<<"$HF" && bad "hot-files.txt must not list the ticket itself as a sharer (got: $HF)" || ok
grep -qF 'code/a.ts' <<<"$HF" && bad "a file nobody else plans to touch is not hot (got: $HF)" || ok
# ...and a file shared with exactly ONE other ticket is reported. That is the
# most common and most actionable case — the ticket's own wording is "shared
# with #a #b" — and OVERLAP_HOT_MIN is the threshold for the whole-backlog
# report, not for this build's own list. At the default of 3 the two-ticket
# collision was invisible to the reviewer.
printf 'code/a.ts\ncode/pair.ts\n' > "$HB/planned-files.txt"
plan_files AB-2 code/shared.ts code/pair.ts
DRIVE_HOT
HF=$(cat "$HB/hot-files.txt" 2>/dev/null)
grep -qF 'code/pair.ts' <<<"$HF" && ok \
  || bad "--hot-for must report a file shared with exactly one other ticket (got: $HF)"
grep -qw 'AB-2' <<<"$HF" && ok || bad "--hot-for must name that one other ticket (got: $HF)"
plan_files AB-2 code/shared.ts
printf 'code/a.ts\ncode/shared.ts\n' > "$HB/planned-files.txt"
( export OVERLAP_SCHEDULE=0; DRIVE_HOT )
[ ! -s "$HB/hot-files.txt" ] && ok || bad "with the scheduler off, hot-files.txt must be empty (got: $(cat "$HB/hot-files.txt"))"
scratch_rm "$HB"
reset

# ---------- 14. a ledger row claimed on another box -----------------------
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
queue_list() { printf 'proj\tAB-11\t11\tclaimed\tbox\t0\tb\t-\t-\t-\n'
               printf 'proj\tAB-12\t12\tclaimed\tbox\t0\tb\t-\t-\t-\n'; }
SH
plan_files AB-11 code/a.ts
OUT=$(run2 proj)
grep -qF 'HELD: AB-1 overlaps in-flight AB-11 on code/a.ts' <<<"$OUT" && ok \
  || bad "a ledger-claimed key with a local plan list must hold its overlaps (got: $OUT)"
grep -qF 'UNJUDGED AB-12' "$T/err.txt" && ok \
  || bad "a claimed key with NO local list must be reported UNJUDGED on stderr (got: $(cat "$T/err.txt"))"
grep -q 'AB-12' <<<"$OUT" && bad "an UNJUDGED key must never produce a HELD (got: $OUT)" || ok
scratch_rm "$H/plans/proj-AB-11"
reset

# ---------- 14b. a DEAD claim file holds nobody ---------------------------
# bin/plan-overlap.sh:live() — a claim file is only in flight while the jobs
# ledger still lists that key as claimed, WHEN THE LEDGER ANSWERED AT ALL. A
# build killed without its EXIT trap (kill -9, OOM, reboot) leaves its claim on
# disk until some later run-build.sh prunes it >240 min later, and for that
# whole window HELD is the one hard stop in the tick prompt. One liveness rule,
# the same one the launch-time backstop uses.
echo 'code/e.ts' > "$H/state/claims/proj/AB-9"
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
queue_list() { printf 'proj\tAB-11\t11\tclaimed\tbox\t0\tb\t-\t-\t-\n'; }
SH
OUT=$(run proj)
[ -n "$(wave_of "$OUT" AB-5)" ] && ok \
  || bad "a claim the ledger no longer calls claimed must not HELD AB-5 (got: $OUT)"
grep -qE '^HELD: AB-5 ' <<<"$OUT" && bad "a dead claim file must produce no HELD (got: $OUT)" || ok
# ...INCLUDING the artifact a kill actually leaves. A build killed without its
# EXIT trap leaves BOTH a claim file and its build directory — no RESULT,
# touched inside the 4h window — so a liveness rule that only filters the claim
# file lets source 2 re-add the very same key and the HELD comes back.
# bin/plan-overlap.sh avoids that by seeding its SEEN set with the claim key
# BEFORE the liveness check: a key whose claim the ledger has settled is not
# re-judged from its leftovers. Without this the "cannot hold its siblings for
# the next four hours" guarantee is false for every real kill (#1014 review).
B9="$H/builds/proj-AB-9-202609191200"; mkdir -p "$B9"
echo 'code/e.ts' > "$B9/planned-files.txt"
OUT=$(run proj)
[ -n "$(wave_of "$OUT" AB-5)" ] && ok \
  || bad "a stranded build dir of a dead claim must not hold AB-5 (got: $OUT)"
grep -qE '^HELD: AB-5 ' <<<"$OUT" && bad "the dead key's leftovers must produce no HELD (got: $OUT)" || ok
# ...and the ledger saying the key IS claimed keeps it held, as before
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
queue_list() { printf 'proj\tAB-9\t9\tclaimed\tbox\t0\tb\t-\t-\t-\n'; }
SH
OUT=$(run proj)
grep -qF 'HELD: AB-5 overlaps in-flight AB-9 on code/e.ts' <<<"$OUT" && ok \
  || bad "a claim the ledger confirms must still hold, build dir and all (got: $OUT)"
# A BUILD THAT IS ACTUALLY RUNNING AND HAS NO QUEUE ROW IS STILL HELD (#1014
# review 2). Not every build has a ledger row: every direct `setsid
# run-build.sh` launch — a triage session, orphan-reconcile, blocked-resolver,
# a medic relaunch — runs without one, and for those keys the ledger answers
# "not claimed" for the same reason it answers that about a corpse. The signal
# that tells the two apart is the one that DIES WITH THE PROCESS: run-build.sh
# holds locks/build-key-<project>-<KEY>.lock for the build's whole life, so a
# live build still holds it and a killed one does not. Same lock
# bin/preplan-tick.sh already reads through preplan_held.
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
queue_list() { printf 'proj\tAB-11\t11\tclaimed\tbox\t0\tb\t-\t-\t-\n'; }
SH
: > "$H/locks/build-key-proj-AB-9.lock"
flock "$H/locks/build-key-proj-AB-9.lock" sleep 5 & HOLDER=$!
wait_holder "$HOLDER"
OUT=$(run proj)
grep -qF 'HELD: AB-5 overlaps in-flight AB-9 on code/e.ts' <<<"$OUT" && ok \
  || bad "a running build with no queue row must still hold its overlaps (got: $OUT)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -f "$H/locks/build-key-proj-AB-9.lock"
# ...and with the lock released — which is what a kill -9 leaves behind — the
# same fixture holds nobody.
OUT=$(run proj)
grep -qE '^HELD: AB-5 ' <<<"$OUT" && bad "a released build-key lock means the build is gone (got: $OUT)" || ok
# a build dir with NO claim file is still judged on its own — the skip is about
# a key the ledger has settled, never about build dirs in general.
scratch_rm "$B9"
B10="$H/builds/proj-AB-10-202609191200"; mkdir -p "$B10"
echo 'code/c.ts' > "$B10/planned-files.txt"
OUT=$(run proj)
grep -qF 'HELD: AB-3 overlaps in-flight AB-10 on code/c.ts' <<<"$OUT" && ok \
  || bad "a live build dir with no claim file must still hold its overlaps (got: $OUT)"
scratch_rm "$B10"
mkdir -p "$B9"; echo 'code/e.ts' > "$B9/planned-files.txt"
# ...and an OUTAGE is not an answer: with no ledger at all the claim file is
# trusted exactly as it is today, or a worker blip would switch the gate off.
rm -f "$H/bin/jobs-client.sh"
OUT=$(run proj)
grep -qF 'HELD: AB-5 overlaps in-flight AB-9 on code/e.ts' <<<"$OUT" && ok \
  || bad "with no ledger answer the claim file must still hold (got: $OUT)"
scratch_rm "$B9"
reset

# ---------- 15. the classifier's ROW ORDER is the priority order ----------
# bin/preplan-candidates.sh says "this is the emergency ticket" ONLY by emitting
# its row first (#368: hot queue lines, then hotfix rows, then the plain queue,
# then the rest); the class field of a hotfix stays `ahead`. A scheduler that
# re-sorts by (class, ticket number) throws that away and can hand a hotfix
# WAVE 2 behind an ordinary ticket — which is exactly the guarantee #368 exists
# to make ("a hotfix is never dropped by the speculation machinery"). One
# ordering mechanism, and it is the classifier's.
cat > "$H/state/preplan-candidates/proj.tsv" <<'TSV'
AB-99	99	ahead
AB-10	10	ahead
TSV
plan_files AB-99 code/hot.ts
plan_files AB-10 code/hot.ts
OUT=$(run proj)
[ "$(wave_of "$OUT" AB-99)" = 1 ] && ok \
  || bad "the row the classifier emitted FIRST (the hotfix) must take wave 1 (got: $OUT)"
[ "$(wave_of "$OUT" AB-10)" = 2 ] && ok \
  || bad "the lower-numbered ordinary ticket must yield to it, not outrank it (got: $OUT)"
V=$(run proj --key AB-99)
grep -qE '^AB-99 WAVE 1' <<<"$V" && ok || bad "--key must agree with the wave it printed (got: $V)"
scratch_rm "$H/plans/proj-AB-99"; scratch_rm "$H/plans/proj-AB-10"
reset

echo "overlap-schedule: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
