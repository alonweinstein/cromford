#!/bin/bash
# tests/flaky-tier-release-wiring.bh-4321-test.sh — BH-4321: the real lane,
# bin/flaky-tier.sh, releases a quarantine row after K clean nightlies.
#
# The defect: the lane never sourced bin/lib/gh-ci-read.sh, so ft_release found
# gh_ci_api undefined on every tick and released nothing. Its reason went to
# stderr, which the lane dropped, so no log said why. The two share suites
# quarantined on 2026-10-04 stayed active through every clean nightly.
#
# This suite installs the lane's REAL bin closure (scratch_install_closure),
# gh-ci-read.sh and flaky-tier-release.sh included, and does
# NOT define gh_ci_api itself (tests/flaky-tier-release.bh-3686-test.sh stubs
# it, which is how the gap went unseen). The seams, as in
# tests/flaky-tier.bh-3686-test.sh:
#   bin/jobs-client.sh  the REAL bin/lib/jobs/cost.sh over a stateful _jobs_req
#   gh (on PATH)        `gh api <path>` (gh_ci_api) answers the nightly run
#                       listing; `gh api -i -X …` (gh-rest) answers the
#                       CI_QUARANTINE variable
#   bin/lane-alert.sh   records its argv
# The nightly verdicts are pre-seeded cache files, so no artifact zip is read.
#
# Cases: W0 the closure carries gh-ci-read.sh; W1 release; W2 dry run; W3 unparseable listing reason in the lane log;
# W4 a console row is never released; W5 a red nightly breaks the streak;
# W6 a missing gh-ci-read.sh stops the lane.
#
# Run from anywhere: tests/flaky-tier-release-wiring.bh-4321-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LANE="$DIR/bin/flaky-tier.sh"
FAKE_NOW=1791547200            # 2026-10-09 12:00:00Z
SLUG=example-org/cromford
TOKEN=ghp_FIXTURE_ADMIN_TOKEN
SUITE=tests/x-test.sh
H="$T/h"; FX="$T/fx"; CALLS="$T/calls.log"
mkdir -p "$H/bin/lib" "$H/env" "$H/tests" "$H/catalog" "$T/stubbin"
printf '#!/bin/bash\n' > "$H/$SUITE"
: > "$H/catalog/test-quarantine-protected.txt"
printf 'GH_ADMIN_TOKEN=%s\n' "$TOKEN" > "$H/env/github-admin.env"

cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "ALERT \$*" >> "$CALLS"
EOF

cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
# shellcheck source=/dev/null
. "$DIR/bin/lib/jobs/cost.sh"
_jobs_req() {
  echo "JOBS \$1 \$2 \${3:-}" >> "$CALLS"
  case "\$1 \$2" in
    "GET /api/metrics/flakes/quarantine?"*) cat "$FX/rows.json" ;;
    "GET /api/metrics/flakes?"*) echo '{"flakes":[]}' ;;
    "PUT /api/metrics/flakes/quarantine")
      jq -c --argjson b "\$3" '.rows = ([.rows[] | select(.test != \$b.test)] + [\$b + {updated_at: "2026-10-09 12:00:00"}])' \
        "$FX/rows.json" > "$FX/rows.tmp" && mv "$FX/rows.tmp" "$FX/rows.json"
      echo '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
EOF

cat > "$T/stubbin/gh" <<EOF
#!/bin/bash
# gh api [-i] [-X <M>] <path> [args...]
shift; M=; P=; RAW=1
while [ \$# -gt 0 ]; do case "\$1" in -i) RAW=0; shift ;; -X) M="\$2"; shift 2 ;; *) P="\$1"; shift; break ;; esac; done
echo "GH \${M:-GET} \$P" >> "$CALLS"
if [ "\$RAW" = 1 ]; then
  case "\$P" in
    "repos/$SLUG/actions/workflows/harness-nightly.yml/runs?"*) cat "$FX/runs.body"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
val=
for a in "\$@"; do case "\$a" in value=*) val="\${a#value=}" ;; esac; done
reply() { printf 'HTTP/2 %s X\r\n\r\n%s\n' "\$1" "\${2:-}"; }
case "\$M \$P" in
  "GET repos/$SLUG/actions/variables/CI_QUARANTINE")
    if [ -f "$FX/var" ]; then reply 200 "{\"name\":\"CI_QUARANTINE\",\"value\":\"\$(cat "$FX/var")\"}"; else reply 404 '{"message":"Not Found"}'; fi ;;
  "POST repos/$SLUG/actions/variables") printf '%s' "\$val" > "$FX/var"; reply 201 '{}' ;;
  "PATCH repos/$SLUG/actions/variables/CI_QUARANTINE") printf '%s' "\$val" > "$FX/var"; reply 204 '' ;;
  *) reply 500 '{}' ;;
esac
EOF
chmod +x "$H/bin/lane-alert.sh" "$T/stubbin/gh"
# The lane's whole bin closure, the real gh-ci-read.sh included, after the
# stubs (no-clobber keeps them). A hand lib list is how BH-4321 went unseen.
scratch_install_closure bin/flaky-tier.sh "$H" > /dev/null || { echo "FAIL: closure install"; exit 1; }
# W0: the lane names gh-ci-read.sh, so its closure carries it.
[ -f "$H/bin/lib/gh-ci-read.sh" ] && ok || bad "W0: the lane's closure has no bin/lib/gh-ci-read.sh"

# world <actor> <rc newest-first…> — one active row quarantined on 2026-10-04,
# one scheduled nightly per rc (newest 2026-10-09, one day apart), each cached
# with that rc for $SUITE, and CI_QUARANTINE carrying the suite.
world() {
  local actor="$1" d i=0 id at; shift
  for d in "$FX" "$H/state" "$H/logs" "$H/locks"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FX" "$H/state/flaky-tier/nightly"; : > "$CALLS"
  jq -nc --arg t "$SUITE" --arg c "$actor" \
    '{rows: [{test: $t, active: 1, actor: $c, updated_at: "2026-10-04 05:01:16", reason: "main-red-bisect: red on main"}]}' > "$FX/rows.json"
  printf '%s' "$SUITE" > "$FX/var"
  echo '{"workflow_runs":[]}' > "$FX/runs.body"
  for rc in "$@"; do
    id=$((9000 - i)); at=$(date -u -d "2026-10-09 09:00:00 UTC - $i days" +%FT%TZ)
    printf '# created_at=%s sha=%040d\n%s\t%s\n' "$at" "$id" "$SUITE" "$rc" > "$H/state/flaky-tier/nightly/$id.tsv"
    jq -c --argjson id "$id" --arg at "$at" '.workflow_runs += [{id: $id, created_at: $at, head_sha: "abc"}]' \
      "$FX/runs.body" > "$FX/r" && mv "$FX/r" "$FX/runs.body"
    i=$((i + 1))
  done
}
run() { env HARNESS="$H" PATH="$T/stubbin:$PATH" FLAKY_TIER_NOW="$FAKE_NOW" "$@" > "$T/out" 2>&1; }
cnt() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
tick() { grep "flaky-tier $SLUG: candidates=" "$H/logs/flaky-tier.log" 2>/dev/null | tail -1; }

# ── W1: a clean main-red-bisect row, 5 clean nightlies => released ──────────
world main-red-bisect 0 0 0 0 0
run bash "$LANE" cromford; RC=$?
[ "$RC" = 0 ] && ok || bad "W1 rc=$RC: $(cat "$T/out")"
case "$(tick)" in *' released=1 '*) ok ;; *) bad "W1 tick: '$(tick)' out: $(cat "$T/out")" ;; esac
PUTL=$(grep '^JOBS PUT /api/metrics/flakes/quarantine' "$CALLS")
[ "$(printf '%s\n' "$PUTL" | grep -c .)" = 1 ] && ok || bad "W1: PUTs '$PUTL'"
case "$PUTL" in *'"active":0'*'"actor":"flaky-tier"'*) ok ;; *) bad "W1: PUT body '$PUTL'" ;; esac
grep -q 'is not defined' "$T/out" && bad "W1: a helper is undefined: $(grep 'is not defined' "$T/out")" || ok
[ "$(cat "$FX/var")" = - ] && ok || bad "W1: CI_QUARANTINE='$(cat "$FX/var")', the release was not projected"

# ── W2: the same world, --dry-run => would release, no PUT ──────────────────
world main-red-bisect 0 0 0 0 0
run bash "$LANE" cromford --dry-run
[ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "W2: dry run PUT: $(grep '^JOBS PUT' "$CALLS")"
grep -q "would release $SUITE" "$H/logs/flaky-tier.log" && ok || bad "W2: no 'would release' in the log: $(cat "$H/logs/flaky-tier.log")"
grep -q "would release $SUITE" "$T/out" && ok || bad "W2: no 'would release' in the output"

# ── W3: the run listing is not JSON => released=0, the reason is in the log ─
world main-red-bisect 0 0 0 0 0
echo 'upstream connect error' > "$FX/runs.body"
run bash "$LANE" cromford
case "$(tick)" in *' released=0 '*) ok ;; *) bad "W3 tick: '$(tick)'" ;; esac
[ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "W3: PUT on an unparseable listing"
grep -q 'ft_release: nightly run listing unparseable' "$H/logs/flaky-tier.log" && ok \
  || bad "W3: the ft_release reason is not in logs/flaky-tier.log: $(cat "$H/logs/flaky-tier.log")"
# the reason line precedes the tick line
RL=$(grep -n 'ft_release: nightly run listing unparseable' "$H/logs/flaky-tier.log" | head -1 | cut -d: -f1)
TL=$(grep -n "flaky-tier $SLUG: candidates=" "$H/logs/flaky-tier.log" | tail -1 | cut -d: -f1)
[ -n "$RL" ] && [ -n "$TL" ] && [ "$RL" -lt "$TL" ] && ok || bad "W3: reason line $RL not before tick line $TL"

# ── W4: a console row is never released ─────────────────────────────────────
world console 0 0 0 0 0
run bash "$LANE" cromford
[ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "W4: released an operator row: $(grep '^JOBS PUT' "$CALLS")"
case "$(tick)" in *' released=0 '*) ok ;; *) bad "W4 tick: '$(tick)'" ;; esac

# ── W5: a red nightly inside the 5 breaks the streak ────────────────────────
world main-red-bisect 0 0 1 0 0
run bash "$LANE" cromford
[ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "W5: released across a red nightly: $(grep '^JOBS PUT' "$CALLS")"
case "$(tick)" in *' released=0 '*) ok ;; *) bad "W5 tick: '$(tick)'" ;; esac

# ── W6: gh-ci-read.sh absent => the lane stops, rc 1 ────────────────────────
world main-red-bisect 0 0 0 0 0
mv "$H/bin/lib/gh-ci-read.sh" "$T/gh-ci-read.sh.held" 2>/dev/null
run bash "$LANE" cromford; RC=$?
[ "$RC" = 1 ] && ok || bad "W6 rc=$RC: $(cat "$T/out")"
grep -q 'cannot load bin/lib/gh-ci-read.sh' "$T/out" && ok || bad "W6: no 'cannot load' line: $(cat "$T/out")"
[ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "W6: PUT with no gh-ci-read.sh"
[ -f "$T/gh-ci-read.sh.held" ] && mv "$T/gh-ci-read.sh.held" "$H/bin/lib/gh-ci-read.sh"

echo "flaky-tier-release-wiring: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
