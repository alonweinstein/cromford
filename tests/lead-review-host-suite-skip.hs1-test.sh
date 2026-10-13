#!/bin/bash
# tests/lead-review-host-suite-skip.hs1-test.sh — the lead review does not re-run
# the host verification suite when the PR's CI already passed on the head it
# reviews (LEAD_REVIEW_HOST_SUITE, catalog/lanes.d/lead-review.json).
#
# Drives the REAL bin/lead-review.sh tick against a scratch harness built the way
# tests/lead-review-rules-pack.bh-3546-test.sh builds one, with these stubbed:
#   * curl  — the jobs worker (list/claim/result, job rows, artifacts, routes)
#   * gh    — the REST reads: pulls/<n>, commits/<sha>/check-runs
#   * bin/agent-call.sh — answers a fixed verdict
#   * the host suite — the repo CLAUDE.md Verification Contract command, which
#     only touches $T/suite-ran, so each case can tell whether it ran
# The repo's .mergify.yml asks three checks of a PR (queue_conditions) plus the
# lead-verdict status, which this very review produces and so is never waited on.
#
#   H1  every required check green on the reviewed sha -> suite not run, the
#       report says `host suite: skipped (CI green on <sha12>: <n> checks)`
#   H2  one required check failed -> suite runs; H2b a non-required shard failed
#       -> suite runs; H2c a required check missing -> suite runs
#   H3  one check pending -> suite runs; H3c Mergify's own in_progress runs
#       (not CI results) do not block the skip
#   H4  the check-run read errors (HTTP 502) -> suite runs
#   H5  green, but the runs name a DIFFERENT sha -> suite runs
#   H6  knob `always` -> runs even when green
#   H7  knob `off` -> never runs (even when CI is red), no check-run read
#   H8  knob set by a settings row (env unset) takes effect: a row `off` with CI
#       red -> not run; H8b an unknown value -> treated as `always`, logged
#   H9  the replay parser still reads the skipped line back (paid-already path)
#   R1  for the harness repo, CI's lint job (it runs the rules pack) and the
#       determinism job green on the sha -> the lead's own rules pack is not run,
#       `- rules pack: skipped (CI green on <sha12>)`, the prompt calls it clean,
#       the verdict path is unchanged, ONE check-run read serves both skips;
#       R1b/c `off` stops the host suite only, the pack still follows CI
#   R2  lint failed / pending / missing, determinism failed, another sha, a read
#       error -> the pack runs; R2b a red pack is still a BLOCK, no agent call
#   R3  `always` runs both and reads no check runs
#   R4  a PR touching catalog/rules-pack.tsv, CI green -> the lead's trusted pack
#       runs (CI ran the PR's own, possibly weakened, pack); R5/R5b/R5c a
#       component script, a conf it reads, a suite a row runs -> runs
#   R6  a PR touching only unrelated files, CI green -> skipped; R6b the input
#       list cannot be built (no trusted catalog) -> runs
#   H10 the required checks come from the BASE branch's .mergify.yml: a PR that
#       drops a name from its own copy does not make its own skip fire
#   H11 a base .mergify.yml with a YAML anchor/alias (the line parser cannot
#       follow it) -> no required list, the suite runs
#   W1-W5 a PR that changes what CI runs (a workflow, .mergify.yml, a script a
#       workflow invokes, a file that script reads, the ci-*/test-impact* floor)
#       with CI green -> BOTH the host suite and the rules pack run (CI's green
#       is the PR's own CI); W6 the list cannot be built -> treated as touched
#   M1  a skipped suite tells the reviewer plainly no tests ran on this box
#   N1  `<n> checks` is the number of REQUIRED checks verified, not every
#       success run (Mergify's Summary, the CI plan job)
#   O1  `off` logs one line per review naming the repo; the prompt says no host
#       suite ran so the no-declared-suite cap applies
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-host-suite-skip.hs1-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
REG=$(rendered_registry)

H="$T/h"; mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
cp "$DIR/bin/lead-review.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
[ -r "$H/bin/lib/jobs/req.sh" ] || { echo "the closure did not install bin/lib/jobs/*.sh"; exit 1; }
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board offset box
demo-os example-org/demo https://demo.test /api/board 1 box-demo
cromford example-org/cromford https://bh.test /api/board 2 box-demo
EOF

CONTRACT=$'# demo\n\n## Verification Contract\n\n```bash\ntouch '"$T"$'/suite-ran\n```\n'
o="$T/origin/demo.git"; w="$T/work/demo"
git init -q --bare -b main "$o"; git init -q -b main "$w"
printf '%s\n' "$CONTRACT" > "$w/CLAUDE.md"; echo one > "$w/a.txt"
cat > "$w/.mergify.yml" <<'EOF'
queue_rules:
  - name: default
    queue_conditions:
      - base = main
      - "#changes-requested-reviews-by=0"
      - check-success = "Syntax + shellcheck + config integrity"
      - check-success = "Test determinism lint"
      - check-success = "Prompt replay evals (prompts/** only)"
      - check-success = "lead-verdict"
    merge_conditions:
      - check-success = "Pure-logic gate fixtures"
      - check-success = "Tests cannot touch a real harness"
EOF
# What decides CI: one workflow that invokes bin/run-checks.sh (which reads
# config/check-list.txt) and bin/ci-plan.sh. lr_ci_cfg_inputs derives these from the BASE.
mkdir -p "$w/.github/workflows" "$w/bin" "$w/config"
cat > "$w/.github/workflows/harness-ci.yml" <<'EOF'
name: CI
on: pull_request
jobs:
  lint:
    name: Syntax + shellcheck + config integrity
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash bin/run-checks.sh && bash bin/ci-plan.sh
EOF
printf '#!/bin/bash\n# reads the list from config/check-list.txt\nexit 0\n' > "$w/bin/run-checks.sh"
printf '#!/bin/bash\nexit 0\n' > "$w/bin/ci-plan.sh"
echo lint > "$w/config/check-list.txt"
git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm base
git -C "$w" push -q "$o" main
echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam "pr change"
git -C "$w" push -q "$o" "HEAD:refs/pull/41/head"
SHA=$(git -C "$w" rev-parse HEAD); SHA12=${SHA:0:12}
echo "$SHA" > "$T/head.41"
# More PR heads off main, one change each (mkpr <n> <path> [content]).
mkpr() {
  git -C "$w" checkout -q --detach main
  mkdir -p "$w/$(dirname "$2")"; printf '%s\n' "${3:-changed by pr $1}" >> "$w/$2"
  git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm "pr $1"
  git -C "$w" push -q "$o" "HEAD:refs/pull/$1/head"
  git -C "$w" rev-parse HEAD > "$T/head.$1"
}
mkpr 43 catalog/rules-pack.tsv                 # R4: the pack's catalog
mkpr 44 bin/y-lint.sh                          # R5: a component a catalog row runs
mkpr 45 catalog/y-lint.conf                    # R5b: a file that component reads
mkpr 46 tests/x-ratchet.sh                     # R5c: a suite a catalog row runs
mkpr 47 docs/notes/unrelated.md                # R6: nothing of the pack's
# H10: the PR drops "Test determinism lint" from its OWN .mergify.yml
git -C "$w" checkout -q --detach main
sed -i.bak '/check-success = "Test determinism lint"/d' "$w/.mergify.yml" && rm -f "$w/.mergify.yml.bak"
git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm "pr 48"
git -C "$w" push -q "$o" "HEAD:refs/pull/48/head"; git -C "$w" rev-parse HEAD > "$T/head.48"
mkpr 49 .github/workflows/harness-ci.yml '      - run: exit 0'   # W1: the workflow itself
mkpr 50 bin/run-checks.sh 'exit 0'             # W3: a script the workflow invokes
mkpr 51 config/check-list.txt                  # W4: a file that script reads
mkpr 52 catalog/ci-batch-escalate.tsv          # W5: the ci-* floor, named nowhere
mkpr 53 bin/test-impact-gate.sh                # W5b: the test-impact* floor
git clone -q "$o" "$T/repos/demo-os"
git clone -q "$o" "$T/repos/cromford"
# The box's TRUSTED rules pack install: its catalog names one suite and one
# command, and the command reads a conf. lr_rp_inputs derives the list from here.
mkdir -p "$H/tests" "$H/bin"
printf 'ratchet-x\ttree\tsuite\ttests/x-ratchet.sh\t-\tx\nlint-y\ttree\tcmd\tbin/y-lint.sh --tree .\t-\ty\n' > "$H/catalog/rules-pack.tsv"
printf '#!/bin/bash\nexit 0\n' > "$H/tests/x-ratchet.sh"
printf '#!/bin/bash\n# reads its rules from catalog/y-lint.conf\nexit 0\n' > "$H/bin/y-lint.sh"
echo 'rule' > "$H/catalog/y-lint.conf"
OTHER=0123456789abcdef0123456789abcdef01234567

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    st=\$(cat "$T/jobstate" 2>/dev/null)
    if [ "\$st" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/gh"
case "\$*" in
  *"-X GET repos/"*"/commits/"*"/check-runs"*)
    if [ -e "$T/checkfail" ]; then printf 'HTTP/2 502\r\n\r\n{"message":"bad gateway"}\n'; exit 1; fi
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/checks.json" ;;
  *"-X GET repos/"*"/pulls/"*)
    n=\$(printf '%s' "\$*" | sed -n 's#.*/pulls/\([0-9]*\).*#\1#p')
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/head.\$n")" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"no ticket"}' ;;
esac
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
case "\$6" in @/*) cat "\${6#@}" ;; *) printf '%s' "\$6" ;; esac > "$T/log/prompt"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
# The rules pack stub: logs each run, prints $T/pack.stdout, exits $T/pack.rc (0 if absent).
cat > "$T/rules-pack.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/pack"
cat "$T/pack.stdout" 2>/dev/null
exit "\$(cat "$T/pack.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh" "$T/rules-pack.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_THREAD_MAX_BYTES=60000
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_HOST_SUITE LANE_REGISTRY \
  VERDICT_WINDOW_LINES _VP_WINDOW

# run <name> <status> <conclusion> [sha]
run() { jq -nc --arg n "$1" --arg st "$2" --arg c "$3" --arg s "${4:-$SHA}" \
  '{name:$n,head_sha:$s,status:$st,conclusion:(if $c == "" then null else $c end)}'; }
setchecks() { printf '%s\n' "$@" | jq -sc '{total_count:length, check_runs:.}' > "$T/checks.json"; }
green() { # the PR head's CI as a PR sees it: three fast checks, the plan, corpus shards path-filtered
  setchecks "$(run 'Syntax + shellcheck + config integrity' completed success "${1:-}")" \
            "$(run 'Test determinism lint' completed success "${1:-}")" \
            "$(run 'Prompt replay evals (prompts/** only)' completed success "${1:-}")" \
            "$(run 'CI plan (what this run tests)' completed success "${1:-}")" \
            "$(run 'Tests, traced (shard 1/4)' completed skipped "${1:-}")"
}
reset() {
  rm -f "$T/log"/* "$T"/{jobstate,checkfail,suite-ran,pack.rc,pack.stdout} "$H/logs/lead-review.log" \
    "$H/state/settings-cache.json" "$H/bin/rules-pack.sh"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"
  unset LEAD_REVIEW_HOST_SUITE LANE_REGISTRY
  REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"
  jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/demo",pr:41,head_sha:$s,scope_notes:"",prior_verdict_ref:"",status:"requested"}],truncated:false}' \
    > "$T/requests.json"
  green
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"
ran() { [ -e "$T/suite-ran" ]; }
line() { sed -n 's/^- \(host suite: .*\)$/\1/p' "$REPORT" 2>/dev/null | head -n 1; }
done_ok() { grep -q '/result .*"outcome":"done"' "$T/log/worker" 2>/dev/null; }
# The rules pack only runs for the harness repo: point the request there.
harness_req() { # harness_req [pr] (default 41); CI is set green on that PR's head
  local n="${1:-41}" h
  h=$(cat "$T/head.$n")
  cp "$T/rules-pack.sh" "$H/bin/rules-pack.sh"
  jq -nc --arg s "$h" --argjson p "$n" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:$p,head_sha:$s,scope_notes:"",prior_verdict_ref:"",status:"requested"}],truncated:false}' \
    > "$T/requests.json"
  REPORT="$H/state/lead-reviews/lr-$n-${h:0:12}.md"
  [ "$n" = 41 ] || green "$h"
}
packed() { [ -s "$T/log/pack" ]; }
rpline() { sed -n 's/^- rules pack: //p' "$REPORT" 2>/dev/null | head -n 1; }

# ── H1: all required checks green on the reviewed sha -> skipped ──
reset; tick
[ "$RC" -eq 0 ] && ok || bad "H1 rc=$RC out=$(cat "$T/out")"
ran && bad "H1 the host suite ran with CI green on $SHA12" || ok
[ "$(line)" = "host suite: skipped (CI green on $SHA12: 3 checks)" ] && ok || bad "H1 report line '$(line)'"
# M1: the reviewer is told plainly that no tests ran on this box
grep -q 'The host suite was not run on this box' "$T/log/prompt" 2>/dev/null && ok || bad "M1 the prompt does not say the suite was not run here"
grep -q 'Do not claim local test evidence' "$T/log/prompt" 2>/dev/null && ok || bad "M1 the prompt does not forbid claiming local test evidence"
grep -q "repos/example-org/demo/commits/$SHA/check-runs" "$T/log/gh" 2>/dev/null && ok || bad "H1 check runs not read for $SHA: $(cat "$T/log/gh" 2>/dev/null)"
done_ok && ok || bad "H1 review did not finish"

# ── N1: Mergify's Summary and the CI plan job succeeding do not count as checks ──
reset; green
jq '.check_runs += [{name:"Summary",app:{slug:"mergify"},head_sha:"'"$SHA"'",status:"completed",conclusion:"success"}] | .total_count = (.check_runs|length)' \
  "$T/checks.json" > "$T/c2" && mv "$T/c2" "$T/checks.json"
tick
[ "$(line)" = "host suite: skipped (CI green on $SHA12: 3 checks)" ] && ok || bad "N1 report line '$(line)' (want the 3 required checks)"

# ── H2: one required check failed -> runs ──
reset
setchecks "$(run 'Syntax + shellcheck + config integrity' completed success)" \
          "$(run 'Test determinism lint' completed failure)" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success)"
tick
ran && ok || bad "H2 the suite did not run with a failed required check"
case "$(line)" in "host suite: touch $T/suite-ran rc=0") ok ;; *) bad "H2 report line '$(line)'" ;; esac
done_ok && ok || bad "H2 review did not finish"

# H2b: a non-required job (a corpus shard) failed -> runs
reset
setchecks "$(run 'Syntax + shellcheck + config integrity' completed success)" \
          "$(run 'Test determinism lint' completed success)" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success)" \
          "$(run 'Tests, traced (shard 2/4)' completed failure)"
tick
ran && ok || bad "H2b the suite did not run with a failed corpus shard"

# H2c: a required check missing entirely -> runs
reset
setchecks "$(run 'Syntax + shellcheck + config integrity' completed success)" \
          "$(run 'Test determinism lint' completed success)"
tick
ran && ok || bad "H2c the suite did not run with a required check missing"

# H2d: a REQUIRED check skipped is not green -> runs
reset
setchecks "$(run 'Syntax + shellcheck + config integrity' completed success)" \
          "$(run 'Test determinism lint' completed skipped)" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success)"
tick
ran && ok || bad "H2d the suite did not run with a required check skipped"

# ── H3: one pending -> runs ──
reset
setchecks "$(run 'Syntax + shellcheck + config integrity' completed success)" \
          "$(run 'Test determinism lint' in_progress '')" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success)"
tick
ran && ok || bad "H3 the suite did not run with a pending check"
# H3b: a non-required run still queued -> runs
reset; green
jq '.check_runs += [{name:"Tests, traced (shard 3/4)",head_sha:"'"$SHA"'",status:"queued",conclusion:null}] | .total_count = (.check_runs|length)' \
  "$T/checks.json" > "$T/c2" && mv "$T/c2" "$T/checks.json"
tick
ran && ok || bad "H3b the suite did not run with a queued shard"

# H3c: Mergify's own runs in progress are not CI results -> still skipped
reset; green
jq '.check_runs += [{name:"Mergify Merge Queue",app:{slug:"mergify"},head_sha:"'"$SHA"'",status:"in_progress",conclusion:null},
                    {name:"Summary",app:{slug:"mergify"},head_sha:"'"$SHA"'",status:"in_progress",conclusion:null}]
    | .total_count = (.check_runs|length)' "$T/checks.json" > "$T/c2" && mv "$T/c2" "$T/checks.json"
tick
ran && bad "H3c a pending Mergify run blocked the skip" || ok
# H3d: but a pending Actions run with no app field still counts as pending
reset; green
jq '.check_runs += [{name:"Tests, traced (shard 0/8)",head_sha:"'"$SHA"'",status:"in_progress",conclusion:null}] | .total_count = (.check_runs|length)' \
  "$T/checks.json" > "$T/c2" && mv "$T/c2" "$T/checks.json"
tick
ran && ok || bad "H3d the suite did not run with a pending shard (no app field)"

# ── H4: the check-run read errors -> runs ──
reset; : > "$T/checkfail"; tick
ran && ok || bad "H4 the suite did not run when the check-run read failed"
done_ok && ok || bad "H4 review did not finish"
# H4b: a 200 that is not a check-run list -> runs
reset; echo '{"message":"odd"}' > "$T/checks.json"; tick
ran && ok || bad "H4b the suite did not run on a malformed check-run answer"
# H4c: more runs than the page holds -> runs (unknown = run)
reset; green; jq '.total_count = 250' "$T/checks.json" > "$T/c2" && mv "$T/c2" "$T/checks.json"; tick
ran && ok || bad "H4c the suite did not run when the check-run list was cut"

# ── H5: green on a DIFFERENT sha -> runs ──
reset; green "$OTHER"; tick
ran && ok || bad "H5 the suite was skipped on CI that ran on another sha"
case "$(line)" in "host suite: skipped"*) bad "H5 report says skipped: $(line)" ;; *) ok ;; esac

# ── H6: knob always -> runs even when green ──
reset; export LEAD_REVIEW_HOST_SUITE=always; tick
ran && ok || bad "H6 always did not run the suite"
grep -q 'check-runs' "$T/log/gh" 2>/dev/null && bad "H6 always still read the check runs" || ok

# ── H7: knob off -> never runs, even with CI red ──
reset; export LEAD_REVIEW_HOST_SUITE=off
setchecks "$(run 'Test determinism lint' completed failure)"
tick
ran && bad "H7 off ran the suite" || ok
[ "$(line)" = "host suite: off (LEAD_REVIEW_HOST_SUITE)" ] && ok || bad "H7 report line '$(line)'"
grep -q 'check-runs' "$T/log/gh" 2>/dev/null && bad "H7 off read the check runs" || ok
done_ok && ok || bad "H7 review did not finish"
# O1: one log line per review names the repo and the fleet-wide knob
[ "$(grep -c 'example-org/demo: host suite not run (LEAD_REVIEW_HOST_SUITE=off, fleet-wide)' "$H/logs/lead-review.log" 2>/dev/null)" = 1 ] \
  && ok || bad "O1 no single per-review off line naming the repo: $(cat "$H/logs/lead-review.log" 2>/dev/null)"
grep -q 'No host suite ran on this head' "$T/log/prompt" 2>/dev/null && ok || bad "O1 the prompt does not say no host suite ran"

# ── H8: a settings row (no env) drives the knob ──
settings_row() { # settings_row <value>: a fresh box settings cache holding one operator row
  jq -nc --argjson fa "$(date -u +%s)" --arg v "$1" \
    '{fetched_at:$fa, values:{"lane.lead-review.lead_review_host_suite":$v}, seeded:{}}' > "$H/state/settings-cache.json"
}
reset; settings_row off; export LANE_REGISTRY="$REG"
setchecks "$(run 'Test determinism lint' completed failure)"
tick
ran && bad "H8 a settings row 'off' did not reach the lane (suite ran)" || ok
[ "$(line)" = "host suite: off (LEAD_REVIEW_HOST_SUITE)" ] && ok || bad "H8 report line '$(line)'"
# H8 control: the same red CI with no row runs the suite, so the row is what stopped it
reset; export LANE_REGISTRY="$REG"
setchecks "$(run 'Test determinism lint' completed failure)"
tick
ran && ok || bad "H8 control: red CI with no row did not run the suite"
# H8b: an unknown value is `always`, logged
reset; export LEAD_REVIEW_HOST_SUITE=sometimes; tick
ran && ok || bad "H8b an unknown value did not run the suite"
grep -q "LEAD_REVIEW_HOST_SUITE='sometimes' is not skip-if-ci-green|always|off; using always" "$H/logs/lead-review.log" 2>/dev/null \
  && ok || bad "H8b no log line: $(cat "$H/logs/lead-review.log" 2>/dev/null)"
[ "$(grep -c "LEAD_REVIEW_HOST_SUITE='sometimes'" "$H/logs/lead-review.log" 2>/dev/null)" = 1 ] && ok || bad "H8b logged more than once"

# ── H9: a replay of a skipped report keeps its host suite line ──
reset; tick; : > "$T/log/worker"; rm -f "$T/suite-ran"; echo queued_for_retry > "$T/jobstate"; tick
grep -q '/result .*"outcome":"done"' "$T/log/worker" 2>/dev/null && ok || bad "H9 replay did not post a result"
[ "$(wc -l < "$T/log/agent-count" | tr -d ' ')" = 1 ] && ok || bad "H9 the agent was called again on a replay"
ran && bad "H9 the suite ran on a replay" || ok

# ── R1: CI's lint + determinism jobs green on the sha -> the lead's rules pack is not run ──
reset; harness_req; tick
[ "$RC" -eq 0 ] && ok || bad "R1 rc=$RC out=$(cat "$T/out")"
packed && bad "R1 the rules pack ran with CI green on $SHA12" || ok
[ "$(rpline)" = "skipped (CI green on $SHA12)" ] && ok || bad "R1 report rules pack line '$(rpline)'"
grep -q '/result .*"outcome":"done".*"verdict":"MERGE"' "$T/log/worker" 2>/dev/null && ok || bad "R1 verdict path changed: $(grep result "$T/log/worker" 2>/dev/null)"
[ "$(wc -l < "$T/log/agent-count" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "R1 agent not called exactly once"
grep -q 'treat it as clean' "$T/log/prompt" 2>/dev/null && ok || bad "R1 the prompt does not say the skipped pack is clean"
grep -q 'stderr tail' "$T/log/prompt" 2>/dev/null && bad "R1 the prompt shows a stderr tail for a skipped pack" || ok
grep -qE '^- rules pack: (red|could not run)' "$REPORT" 2>/dev/null && bad "R1 a skip read as red or could-not-run" || ok
[ "$(grep -c 'check-runs' "$T/log/gh" 2>/dev/null)" = 1 ] && ok || bad "R1 check runs read $(grep -c 'check-runs' "$T/log/gh" 2>/dev/null) times (want 1 shared read)"
ran && bad "R1 the host suite ran with CI green" || ok
# R1b: `off` turns off the host suite only; the pack still follows CI
reset; harness_req; export LEAD_REVIEW_HOST_SUITE=off; tick
packed && bad "R1b off ran the rules pack with CI green" || ok
[ "$(rpline)" = "skipped (CI green on $SHA12)" ] && ok || bad "R1b report rules pack line '$(rpline)'"
[ "$(line)" = "host suite: off (LEAD_REVIEW_HOST_SUITE)" ] && ok || bad "R1b host suite line '$(line)'"
# R1c: `off` with the lint job red -> the pack runs, the suite does not
reset; harness_req; export LEAD_REVIEW_HOST_SUITE=off
setchecks "$(run 'Syntax + shellcheck + config integrity' completed failure)" "$(run 'Test determinism lint' completed success)"
tick
packed && ok || bad "R1c off did not run the pack with CI lint red"
ran && bad "R1c off ran the host suite" || ok

# ── R2: CI lint failed / pending / missing / another sha / unreadable -> the pack runs ──
r2() { # r2 <label>: tick the harness request and expect the pack to have run, clean
  tick
  packed && ok || bad "$1 the rules pack did not run"
  [ "$(rpline)" = clean ] && ok || bad "$1 report rules pack line '$(rpline)'"
}
reset; harness_req
setchecks "$(run 'Syntax + shellcheck + config integrity' completed failure)" "$(run 'Test determinism lint' completed success)" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success)"
r2 "R2 lint failed:"
reset; harness_req
setchecks "$(run 'Syntax + shellcheck + config integrity' in_progress '')" "$(run 'Test determinism lint' completed success)" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success)"
r2 "R2 lint pending:"
reset; harness_req
setchecks "$(run 'Syntax + shellcheck + config integrity' completed success)" "$(run 'Test determinism lint' completed failure)" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success)"
r2 "R2 determinism failed:"
reset; harness_req
setchecks "$(run 'Test determinism lint' completed success)" "$(run 'Prompt replay evals (prompts/** only)' completed success)"
r2 "R2 lint missing:"
reset; harness_req; green "$OTHER"
r2 "R2 another sha:"
reset; harness_req; : > "$T/checkfail"
r2 "R2 read error:"
# R2b: a red pack on a red CI is still a BLOCK with no agent call
reset; harness_req; echo 1 > "$T/pack.rc"; echo 'ratchet-x: bin/foo.sh:3 bad' > "$T/pack.stdout"
setchecks "$(run 'Syntax + shellcheck + config integrity' completed failure)"
tick
grep -q '/result .*"verdict":"BLOCK".*"reviewer_model":"rules-pack"' "$T/log/worker" 2>/dev/null && ok || bad "R2b red pack not a BLOCK"
[ -e "$T/log/agent-count" ] && bad "R2b agent called on a red pack" || ok

# ── R3: `always` runs both, even with CI green ──
reset; harness_req; export LEAD_REVIEW_HOST_SUITE=always; tick
packed && ok || bad "R3 always did not run the rules pack"
ran && ok || bad "R3 always did not run the host suite"
grep -q 'check-runs' "$T/log/gh" 2>/dev/null && bad "R3 always read the check runs" || ok

# ── R4-R6: the lead skips its pack only when the PR leaves the pack's own inputs alone ──
# CI runs the PR's own rules-pack.sh and catalog; the lead runs the box's trusted
# copy. A PR that edits the pack could pass CI on a weakened pack.
r_runs() { # r_runs <label> <pr>: CI green on that head, and the trusted pack still runs
  reset; harness_req "$2"; tick
  packed && ok || bad "$1 the trusted rules pack did not run (PR #$2)"
  [ "$(rpline)" = clean ] && ok || bad "$1 report rules pack line '$(rpline)'"
  grep -q "rules pack runs (trusted copy: the PR changes the rules pack's own input" "$H/logs/lead-review.log" 2>/dev/null \
    && ok || bad "$1 no trusted-copy log line: $(grep 'rules pack runs' "$H/logs/lead-review.log" 2>/dev/null)"
  ran && bad "$1 the host suite ran with CI green (its skip is unchanged)" || ok
}
r_runs "R4 catalog/rules-pack.tsv:" 43
r_runs "R5 a component script (bin/y-lint.sh):" 44
r_runs "R5b a file the component reads (catalog/y-lint.conf):" 45
r_runs "R5c a suite a row runs (tests/x-ratchet.sh):" 46
# R6: only unrelated files changed, CI green -> skipped
reset; harness_req 47; tick
packed && bad "R6 the pack ran for a PR that touches none of its inputs" || ok
[ "$(rpline)" = "skipped (CI green on $(cut -c1-12 "$T/head.47"))" ] && ok || bad "R6 report rules pack line '$(rpline)'"
grep -q "changes none of the pack's own files" "$T/log/prompt" 2>/dev/null && ok || bad "R6 prompt lacks the trusted-pack reason"
# R6b: the input list cannot be built (no trusted catalog) -> runs
mv "$H/catalog/rules-pack.tsv" "$T/rp.tsv"
reset; harness_req 47; tick
packed && ok || bad "R6b the pack did not run with no trusted catalog to list its inputs"
grep -q "could not be listed" "$H/logs/lead-review.log" 2>/dev/null && ok || bad "R6b no log line"
mv "$T/rp.tsv" "$H/catalog/rules-pack.tsv"

# ── H10: required checks come from the BASE .mergify.yml, not the PR's ──
# PR 48 drops "Test determinism lint" from its own list and CI has no such run.
reset; h48=$(cat "$T/head.48")
jq -nc --arg s "$h48" '{requests:[{id:"lr-1",repo:"example-org/demo",pr:48,head_sha:$s,scope_notes:"",prior_verdict_ref:"",status:"requested"}],truncated:false}' > "$T/requests.json"
REPORT="$H/state/lead-reviews/lr-48-${h48:0:12}.md"
setchecks "$(run 'Syntax + shellcheck + config integrity' completed success "$h48")" \
          "$(run 'Prompt replay evals (prompts/** only)' completed success "$h48")"
tick
ran && ok || bad "H10 the suite was skipped on the PR's own trimmed .mergify.yml"
grep -q 'required not green: Test determinism lint' "$H/logs/lead-review.log" 2>/dev/null && ok || bad "H10 log: $(grep 'host suite runs' "$H/logs/lead-review.log" 2>/dev/null)"

# ── W1-W5: a PR that changes what CI runs -> BOTH the suite and the pack run ──
w_runs() { # w_runs <label> <pr> <path>: CI green on that head; both run, logged
  reset; harness_req "$2"; tick
  packed && ok || bad "$1 the rules pack was skipped on a PR that changes CI (#$2)"
  ran && ok || bad "$1 the host suite was skipped on a PR that changes CI (#$2)"
  grep -q "host suite runs (the PR changes CI itself: $3)" "$H/logs/lead-review.log" 2>/dev/null \
    && ok || bad "$1 no host-suite log line: $(grep 'runs (' "$H/logs/lead-review.log" 2>/dev/null)"
  grep -q "rules pack runs (the PR changes CI itself: $3)" "$H/logs/lead-review.log" 2>/dev/null \
    && ok || bad "$1 no rules-pack log line: $(grep 'runs (' "$H/logs/lead-review.log" 2>/dev/null)"
}
w_runs "W1 .github/workflows/harness-ci.yml:" 49 .github/workflows/harness-ci.yml
w_runs "W2 .mergify.yml:" 48 .mergify.yml
w_runs "W3 a script the workflow invokes (bin/run-checks.sh):" 50 bin/run-checks.sh
w_runs "W4 a file that script reads (config/check-list.txt):" 51 config/check-list.txt
w_runs "W5 catalog/ci-* floor:" 52 catalog/ci-batch-escalate.tsv
w_runs "W5b bin/test-impact* floor:" 53 bin/test-impact-gate.sh
# W1b: the same workflow PR on a product repo (no rules pack) still runs the suite
reset; h49=$(cat "$T/head.49")
jq -nc --arg s "$h49" '{requests:[{id:"lr-1",repo:"example-org/demo",pr:49,head_sha:$s,scope_notes:"",prior_verdict_ref:"",status:"requested"}],truncated:false}' > "$T/requests.json"
REPORT="$H/state/lead-reviews/lr-49-${h49:0:12}.md"; green "$h49"; tick
ran && ok || bad "W1b the suite was skipped on a product-repo PR that changes its workflow"
# W6: the CI-input list cannot be built (base unreadable) -> treated as touched
lr_fns=$(awk '/^lr_ci_cfg_(inputs|touched)\(\) \{/,/^\}/' "$H/bin/lead-review.sh")
if [ -n "$lr_fns" ]; then
  eval "$lr_fns"
  lr_ci_cfg_inputs "$T/repos/demo-os" origin/no-such-branch >/dev/null 2>&1 && bad "W6 inputs listed from a missing base" || ok
  LR_CICFG_WHY=""; lr_ci_cfg_touched "$T/repos/demo-os" origin/no-such-branch "$(cat "$T/head.47")" \
    && ok || bad "W6 an unreadable base read as untouched"
  case "$LR_CICFG_WHY" in *"could not be listed"*) ok ;; *) bad "W6 why '$LR_CICFG_WHY'" ;; esac
  # W7 control: an unrelated PR reads as untouched, the base list holds the workflow-derived names
  LR_CICFG_SHA=""   # one answer per review: a new review starts fresh
  lr_ci_cfg_touched "$T/repos/demo-os" origin/main "$(cat "$T/head.47")" && bad "W7 an unrelated PR read as touching CI ($LR_CICFG_WHY)" || ok
  l=$(lr_ci_cfg_inputs "$T/repos/demo-os" origin/main)
  for want in .github/ .mergify.yml bin/run-checks.sh bin/ci-plan.sh config/check-list.txt; do
    grep -qxF "$want" <<<"$l" && ok || bad "W7 input list lacks $want: $(tr '\n' ' ' <<<"$l")"
  done
  grep -qx 'a.txt' <<<"$l" && bad "W7 input list holds an unrelated file" || ok
else bad "W6 lr_ci_cfg_inputs/lr_ci_cfg_touched not found in bin/lead-review.sh"; fi

# ── H11: a base .mergify.yml using a YAML anchor/alias -> no list, the suite runs ──
reset
git -C "$w" checkout -q main
cat >> "$w/.mergify.yml" <<'EOF'
defaults:
  ci: &ci
    - check-success = "Hidden required"
EOF
git -C "$w" -c user.email=t@t -c user.name=t commit -qam "anchor in base"
git -C "$w" push -q "$o" main
echo h11 >> "$w/a.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam "pr 54"
git -C "$w" push -q "$o" "HEAD:refs/pull/54/head"; h54=$(git -C "$w" rev-parse HEAD)
jq -nc --arg s "$h54" '{requests:[{id:"lr-1",repo:"example-org/demo",pr:54,head_sha:$s,scope_notes:"",prior_verdict_ref:"",status:"requested"}],truncated:false}' > "$T/requests.json"
echo "$h54" > "$T/head.54"; REPORT="$H/state/lead-reviews/lr-54-${h54:0:12}.md"
green "$h54"; tick
ran && ok || bad "H11 the suite was skipped with a YAML anchor in the base .mergify.yml"
grep -q 'no merge-queue check list' "$H/logs/lead-review.log" 2>/dev/null && ok || bad "H11 log: $(grep 'host suite runs' "$H/logs/lead-review.log" 2>/dev/null)"
git -C "$w" reset -q --hard HEAD~2 && git -C "$w" push -q -f "$o" main

echo "lead-review-host-suite-skip: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
