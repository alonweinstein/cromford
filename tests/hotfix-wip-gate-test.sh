#!/bin/bash
# tests/hotfix-wip-gate-test.sh — the build side of the hotfix lane inside
# bin/run-build.sh (#368, lane 1/3): the ticket is recognised ONCE, the answer
# rides the queued job, and the per-project WIP cap is exceeded by exactly one
# row for it.
#
# WHY EACH HALF IS DRIVEN RATHER THAN GREPPED. "Cap-exempt" fails silently in
# both directions — too little and the emergency waits for a slot like anything
# else, too much and a cap nobody meant to lift stops binding — so the plain
# path is asserted beside the hotfix one every time. And the DETECTION is the
# half that can quietly poison the whole fleet: a dead gh token that answers
# "not urgent" for every ticket looks exactly like a week with no emergencies,
# which is why §2 drives a FAILING gh and asserts the retry and the log line
# rather than the happy path.
#
# Every region below is lifted out of bin/run-build.sh by its own
# `# >>> name` / `# <<< name` markers and executed, the same way
# tests/run-build-gates-test.sh and tests/pr-body-closes-test.sh drive theirs.
# Run from anywhere: tests/hotfix-wip-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset HOTFIX HOTFIX_LANE HOTFIX_LABEL GH_ISSUES_REPO 2>/dev/null || true

# ══ 1. THE WIP GATE: a hotfix exceeds flags/wip-limit-<p> by one ════════════
mkdir -p "$T/h/bin" "$T/h/flags" "$T/h/logs" "$T/b"
awk '/^# >>> wip gate/{f=1;next} /^# <<< wip gate/{exit} f' "$RB_ALL" > "$T/wip.sh"
[ -s "$T/wip.sh" ] && grep -q 'wip-limit' "$T/wip.sh" && ok \
  || bad "could not extract the WIP gate — # >>> wip gate markers missing?"
printf '#!/bin/bash\necho "${FAKE_BUILDS:-0}"\n' > "$T/h/bin/count-builds.sh"
chmod +x "$T/h/bin/count-builds.sh"

wipgate() { # wipgate [env...] -> rc; RESULT in $T/b/RESULT, log in $T/b/pipeline.log
  rm -f "$T/b/RESULT"; : > "$T/b/pipeline.log"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=tproj KEY=TK-9 "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "$*" > "$BUILD/RESULT"; }
             . "$0"' "$T/wip.sh" >/dev/null 2>&1 )
}

# no flag at all: nothing changes for anybody
rm -f "$T/h/flags/wip-limit-tproj"
wipgate; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/b/RESULT" ] && ok || bad "with no wip-limit flag the gate must pass (rc=$RC)"
wipgate HOTFIX=1; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/b/RESULT" ] && ok || bad "with no wip-limit flag a hotfix must pass too (rc=$RC)"

echo 0 > "$T/h/flags/wip-limit-tproj"
wipgate HOTFIX=""; RC=$?
[ "$RC" = 3 ] && ok || bad "a plain build at the WIP cap must exit 3 (rc=$RC)"
head -1 "$T/b/RESULT" 2>/dev/null | grep -q '^BUILD_DEFERRED wip-limit 0 reached' \
  && ok || bad "the plain terminal must stay BUILD_DEFERRED wip-limit 0 reached (got: $(cat "$T/b/RESULT" 2>/dev/null))"

wipgate HOTFIX=1; RC=$?
[ "$RC" = 0 ] && ok || bad "a hotfix at the WIP cap must NOT be deferred (rc=$RC)"
[ ! -f "$T/b/RESULT" ] && ok || bad "a hotfix must write no RESULT here: $(cat "$T/b/RESULT" 2>/dev/null)"
grep -q 'exceeding it by one' "$T/b/pipeline.log" \
  && ok || bad "exceeding a cap must say so in the build log: $(cat "$T/b/pipeline.log")"
grep -q 'wip-limit 0' "$T/b/pipeline.log" \
  && ok || bad "the log line must name the cap it exceeded: $(cat "$T/b/pipeline.log")"
# the plain build logs nothing at all — the exemption line is the hotfix's alone
wipgate HOTFIX=""
grep -q 'exceeding it by one' "$T/b/pipeline.log" \
  && bad "a plain deferral must not claim an exemption: $(cat "$T/b/pipeline.log")" || ok

# the cap still binds for everything else while one hotfix is over it
wipgate HOTFIX="" FAKE_BUILDS=3; RC=$?
[ "$RC" = 3 ] && ok || bad "a plain build must still defer while the cap is exceeded (rc=$RC)"

# ══ the detection fixture ═══════════════════════════════════════════════════
# A real hotfix-lib, a fleet-conf that says "GitHub issues, repo o/r", and a gh
# that RECORDS every call so the retry is countable rather than assumed.
mkdir -p "$T/d/bin/lib" "$T/d/logs" "$T/d/flags" "$T/d/env" "$T/d/state" "$T/db" "$T/fakebin"
awk '/^# >>> hotfix detect/{f=1;next} /^# <<< hotfix detect/{exit} f' "$RB_ALL" > "$T/detect.sh"
[ -s "$T/detect.sh" ] && grep -q 'hotfix_key_is' "$T/detect.sh" && ok \
  || bad "could not extract the detection block — # >>> hotfix detect markers missing?"
cp "$DIR/bin/lib/hotfix-lib.sh" "$T/d/bin/lib/" 2>/dev/null || bad "bin/lib/hotfix-lib.sh does not exist"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/d/bin/lib/" 2>/dev/null || bad "bin/lib/gh-rest.sh does not exist"
cat > "$T/d/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in board_prefix) echo "-" ;; repo) echo "o/r" ;; esac
exit 0
SH
cat > "$T/d/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEAT_SINK"
exit 0
SH
# (BH-781) hotfix_issue_is reads the labels collection through
# bin/lib/gh-rest.sh, so the stub answers in that library's wire shape: a
# status line, a blank line, the body. GH_RC=1 is the 403 a dead or
# rate-limited token really returns, which the library maps to 75 and the lib
# maps to rc 2 — UNKNOWN, the answer this section is about.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
if [ "${GH_RC:-0}" = 0 ]; then
  printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[]\n'; exit 0
fi
printf 'HTTP/2.0 403 Forbidden\nx-stub: 1\n\n{"message":"API rate limit exceeded"}\n'
exit "${GH_RC:-0}"
SH
chmod +x "$T/d/bin/fleet-conf.sh" "$T/d/bin/beat.sh" "$T/fakebin/gh"

detect() { # detect [env...] -> rc; HOTFIX value in $T/hotfix.txt
  : > "$T/gh.txt"; : > "$T/beat.txt"; : > "$T/d/logs/ALERTS.log"
  : > "$T/db/pipeline.log"; : > "$T/hotfix.txt"; rm -rf "$T/d/state/hotfix-announced"
  ( env PATH="$T/fakebin:$PATH" HARNESS="$T/d" BUILD="$T/db" PROJECT=tproj KEY=TK-9 \
        GH_SINK="$T/gh.txt" BEAT_SINK="$T/beat.txt" GH_TOKEN=live-token "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             . "$0"
             printf "%s" "${HOTFIX:-}" > "$1"' "$T/detect.sh" "$T/hotfix.txt" >/dev/null 2>"$T/derr.txt" )
}

# ══ 2. gh IS DOWN: retried once, logged, and the build goes on as plain ═════
# rc 2 out of the lib means "the read failed", not "ordinary ticket". It buys
# exactly one retry with the token unset and then gets out of the way.
detect GH_RC=1; RC=$?
[ "$RC" = 0 ] && ok || bad "a failed hotfix check must never stop the build (rc=$RC, err=$(cat "$T/derr.txt"))"
[ -z "$(cat "$T/hotfix.txt")" ] && ok || bad "a failed check must leave HOTFIX empty (got '$(cat "$T/hotfix.txt")')"
grep -q 'HOTFIX check could not be made (gh failed) - retrying once without GH_TOKEN' "$T/db/pipeline.log" \
  && ok || bad "an unknown answer must say so in the build log: $(cat "$T/db/pipeline.log")"
[ "$(wc -l < "$T/gh.txt")" = 2 ] && ok \
  || bad "rc 2 must be retried exactly once — 2 gh calls, got $(wc -l < "$T/gh.txt"): $(cat "$T/gh.txt")"
grep -q 'hotfix check unavailable, building as plain' "$T/db/pipeline.log" \
  && ok || bad "a second failure must be logged as building plain: $(cat "$T/db/pipeline.log")"
[ ! -s "$T/beat.txt" ] && ok || bad "a build that is not a hotfix must not announce: $(cat "$T/beat.txt")"

# a definite NO (rc 1: gh answers, no label) is silent and costs one call
detect; RC=$?
[ "$RC" = 0 ] && [ -z "$(cat "$T/hotfix.txt")" ] && ok \
  || bad "an unlabelled ticket must be plain (rc=$RC hotfix='$(cat "$T/hotfix.txt")')"
[ "$(wc -l < "$T/gh.txt")" = 1 ] && ok \
  || bad "a definite answer must not be retried: $(cat "$T/gh.txt")"
grep -q 'could not be made' "$T/db/pipeline.log" \
  && bad "a definite no must log nothing: $(cat "$T/db/pipeline.log")" || ok

# ══ 3. A PRESET HOTFIX WINS, AND ANNOUNCES ITSELF ONCE ══════════════════════
# fly/builder-runner.sh exports HOTFIX=1 from the job file. Asking GitHub again
# from a pool machine is a second chance to get a different answer.
detect HOTFIX=1; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/hotfix.txt")" = 1 ] && ok \
  || bad "a preset HOTFIX must survive (rc=$RC hotfix='$(cat "$T/hotfix.txt")')"
[ ! -s "$T/gh.txt" ] && ok || bad "a preset HOTFIX must cost no GitHub call: $(cat "$T/gh.txt")"
[ -f "$T/d/state/hotfix-announced/tproj/TK-9.seen" ] && ok \
  || bad "the backstop announcement must write its dedupe marker"
grep -q 'HOTFIX seen: TK-9 queued for build' "$T/d/logs/ALERTS.log" && ok \
  || bad "the backstop must state the rung it has — queued, not built: $(cat "$T/d/logs/ALERTS.log")"
grep -q 'is being built now' "$T/d/logs/ALERTS.log" \
  && bad "the backstop must not claim a build that has not started: $(cat "$T/d/logs/ALERTS.log")" || ok
# BH-2337: `seen` is a notice — its ALERTS line (above) is the record, no beat.
[ "$(grep -c 'hotfix:tproj:TK-9:seen' "$T/beat.txt")" = 0 ] && ok \
  || bad "HOTFIX seen must not beat: $(cat "$T/beat.txt")"

# the kill flag beats a preset flag, an env var and the issue alike
detect HOTFIX=1 HOTFIX_LANE=0; RC=$?
[ "$RC" = 0 ] && [ -z "$(cat "$T/hotfix.txt")" ] && ok \
  || bad "HOTFIX_LANE=0 must clear a preset HOTFIX (rc=$RC hotfix='$(cat "$T/hotfix.txt")')"
[ ! -s "$T/beat.txt" ] && ok || bad "HOTFIX_LANE=0 must silence the backstop: $(cat "$T/beat.txt")"
touch "$T/d/flags/hotfix-lane-off"
detect HOTFIX=1
[ -z "$(cat "$T/hotfix.txt")" ] && ok || bad "flags/hotfix-lane-off must clear a preset HOTFIX"
rm -f "$T/d/flags/hotfix-lane-off"

# ══ 4. THE ANSWER RIDES THE JOB ═════════════════════════════════════════════
# The pool machine is two hops from the issue. A cap exemption that does not
# survive the trip is an emergency that queues behind ordinary work over there.
awk '/^  # >>> queue job json/{f=1;next} /^  # <<< queue job json/{exit} f' "$RB_ALL" > "$T/qjson.sh"
[ -s "$T/qjson.sh" ] && grep -q 'JOB_JSON=' "$T/qjson.sh" && ok \
  || bad "could not extract the queue job JSON — # >>> queue job json markers missing?"

qjob() { # qjob [env...] -> JOB_JSON in $T/job.json, QMETA in $T/qmeta.txt
  ( env TICKET=42 KEY=TK-9 ATTEMPT=0 "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             . "$0"
             printf "%s" "$JOB_JSON" > "$1"
             printf "%s" "$QMETA"    > "$2"' "$T/qjson.sh" "$T/job.json" "$T/qmeta.txt" >/dev/null 2>&1 )
}

qjob HOTFIX=1 STACK_BASE=""
jq -e '.hotfix == true' "$T/job.json" >/dev/null 2>&1 && ok \
  || bad "the queued job must carry the flag: $(cat "$T/job.json")"
[ "$(cat "$T/qmeta.txt")" = '{"hotfix":true}' ] && ok \
  || bad "the queue ROW meta must carry the flag: $(cat "$T/qmeta.txt")"

qjob HOTFIX="" STACK_BASE=""
jq -e 'has("hotfix") | not' "$T/job.json" >/dev/null 2>&1 && ok \
  || bad "a plain job must carry no hotfix key at all: $(cat "$T/job.json")"
[ -z "$(cat "$T/qmeta.txt")" ] && ok \
  || bad "a plain row must carry no meta, byte for byte as before #368: $(cat "$T/qmeta.txt")"

qjob HOTFIX=1 STACK_BASE=x
[ "$(cat "$T/qmeta.txt")" = '{"stack_base":"x","hotfix":true}' ] && ok \
  || bad "the flag must ride BESIDE stack_base, not instead of it: $(cat "$T/qmeta.txt")"
jq -e '.stack_base == "x" and .hotfix == true' "$T/job.json" >/dev/null 2>&1 && ok \
  || bad "the job file must carry both: $(cat "$T/job.json")"

qjob HOTFIX="" STACK_BASE=x
[ "$(cat "$T/qmeta.txt")" = '{"stack_base":"x"}' ] && ok \
  || bad "a plain stacked row must be unchanged: $(cat "$T/qmeta.txt")"

# The string "true" is a different value than the boolean, written by a
# different code path; bin/lib/hotfix-lib.sh's hotfix_job_is accepts only the
# boolean, so writing the string here would be a flag nothing downstream reads.
qjob HOTFIX=1 STACK_BASE=""
[ "$(jq -r '.hotfix | type' "$T/job.json" 2>/dev/null)" = boolean ] && ok \
  || bad "the flag must be a JSON boolean, not a string: $(cat "$T/job.json")"

echo "hotfix-wip-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
