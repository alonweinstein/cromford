#!/bin/bash
# tests/review-rescue.bh-118-test.sh — a rescued review is harvested into
# logs/findings.log exactly once (BH-118).
#
# WHY. bin/findings-log.sh records each lens it has read with a
# `.findings-<lens>` marker in the build dir and skips a marked lens on every
# later call. A build that died mid-review was already harvested from its DRAFT
# review.md at the end of the review stage, so `.findings-general` was set. Then
# bin/review-rescue.sh had the agent REWRITE review.md as the complete review
# and left the marker alone, so the next harvest (bin/rule-miner.sh walks every
# build dir) skipped it and the rescued review's findings never reached the log.
#
# The fix clears `.findings-general` when the rescue's review call actually
# changed review.md's content. This suite drives the real bin/review-rescue.sh
# and the real bin/findings-log.sh, called the way rule-miner.sh calls it
# (`findings-log.sh <dir> <project> <key>`). Fixture shape is the one
# tests/review-rescue.bh-1301-test.sh uses: a real bare origin and clone, a fake
# gh and a stub review agent whose behavior $T/agent-mode picks.
#
# Run from anywhere: tests/review-rescue.bh-118-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PRURL="https://github.com/example-org/project-5/pull/777"

# ── the fixture harness tree ─────────────────────────────────────────────────
export HARNESS="$T/h"; H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$T/fakebin" "$T/repos"
cp "$DIR/bin/review-rescue.sh" "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/fleet-projects-or-alert.sh" "$DIR/bin/test-tamper-scan.sh" "$H/bin/"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
export REPOS_ROOT="$T/repos"
mkdir -p "$H/bin/lib"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" project-5

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -k) shift 2 ;;
    -*) shift ;;
    [0-9]*) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF
chmod +x "$T/fakebin/flock" "$T/fakebin/timeout"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr create"*)        echo "$PRURL"; exit 0 ;;
  *"pr list"*"--head"*) : ;;
  *"issue view"*)       echo OPEN ;;
  *"pr list"*)          : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# The stub reviewer. $T/agent-mode picks what it does:
#   rewrite — writes a complete review with a finding the draft never had
#   none    — dies without touching review.md
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1 \$2" >> "$T/review-calls.txt"
RM=\$(printf '%s' "\${6:-}" | grep -oE '/[^ ]*/review\.md' | head -1)
case "\$(cat "$T/agent-mode" 2>/dev/null)" in
  rewrite)
    [ -n "\$RM" ] && printf '## Findings\n- rescued finding: the retry loop never bounds its attempts (D21)\nTIER: 1\nVERDICT: APPROVE\n' > "\$RM" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"

# ── a real bare origin + clone ───────────────────────────────────────────────
ORIGIN="$T/origin.git"
git init -q --bare "$ORIGIN"
W="$T/work"; mkdir -p "$W/tests"
(
  cd "$W" || exit 1
  git -c init.defaultBranch=main init -q .
  git config user.email t@t; git config user.name t
  cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds', () => { expect(add(1,2)).toBe(3) })
})
EOF
  echo "src" > app.js
  git add -A; git commit -qm "init"
  git branch -M main
  git remote add origin "$ORIGIN"; git push -q -u origin main
  git checkout -q -b ticket/TK-551
  echo "feature" >> app.js
  cat >> tests/thing.test.js <<'EOF'
it('multiplies', () => { expect(mul(2,3)).toBe(6) })
EOF
  git add -A; git commit -qm "TK-551: add multiply and its test"
  git push -q -u origin ticket/TK-551
  git checkout -q main
  echo "later" > mainfile.txt
  git add -A; git commit -qm "main: moves on"
  git push -q origin main
) >/dev/null 2>&1
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$T/repos/project-5"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

# ── helpers ──────────────────────────────────────────────────────────────────
FLOG="$H/logs/findings.log"
ago() { date -d "-$1 minutes" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"$1"M +%Y%m%d%H%M.%S; }
reset_h() { scratch_rm "$H/builds"; scratch_rm "$H/logs"; scratch_rm "$H/flags"
            mkdir -p "$H/builds" "$H/logs" "$H/flags"
            : > "$T/review-calls.txt"; : > "$FLOG"; echo "$1" > "$T/agent-mode"; }
# mkbuild <dir-name> — RESULT's first line as $2, aged past the 90-minute floor.
mkbuild() {
  local D="$H/builds/$1"
  mkdir -p "$D"
  printf '%s\n' "$2" > "$D/RESULT"
  printf '# %s — the ticket title\n\n## Tasks\n' "$1" > "$D/plan.md"
  touch -t "$(ago 200)" "$D/RESULT"
  echo "$D"
}
run()     { bash "$H/bin/review-rescue.sh" >>"$T/run.log" 2>&1; }
# The harvest, exactly as bin/rule-miner.sh makes it.
harvest() { "$DIR/bin/findings-log.sh" "$1" project-5 TK-551; }
lines()   { wc -l < "$FLOG" | tr -d ' '; }
cnt()     { local n; n=$(grep -c -- "$1" "$FLOG" 2>/dev/null); echo "${n:-0}"; }

DRAFT='## Findings (draft)
- draft finding: the session died before the edge cases were checked (D7)'
DIED="REVIEW_BLOCKED review lane died mid-run"
TAMPER="REVIEW_BLOCKED test-tamper: TAMPER_COUNT: 1 (deleted_files=0 deleted_cases=1 added_skips=0) — no TEST-CHANGE justification; see /root/harness/builds/x/test-tamper.txt"

# ══ 1. harvest draft → rescue rewrite → harvest picks it up exactly once ═════
reset_h rewrite
D=$(mkbuild project-5-TK-551-202609231001 "$DIED")
printf '%s\n' "$DRAFT" > "$D/review.md"
harvest "$D"
[ -f "$D/.findings-general" ] && ok || bad "1: the draft harvest must set .findings-general"
eq "1: draft row harvested" "$(cnt 'draft finding')" "1"
run
[ -s "$T/review-calls.txt" ] && ok || bad "1: the rescue never called the reviewer ($(cat "$T/run.log"))"
grep -q 'rescued finding' "$D/review.md" && ok || bad "1: the stub did not rewrite review.md"
[ -f "$D/.findings-general" ] && bad "1: .findings-general still present after rewrite" || ok
harvest "$D"
eq "1: rescued finding harvested" "$(cnt 'rescued finding')" "1"
[ "$(cnt 'rescued finding')" = 0 ] && bad "1: rescued finding not harvested (0 rows)"
grep -q 'lens=general verdict=APPROVE .*rescued finding' "$FLOG" && ok \
  || bad "1: the rescued row carries the rescued verdict ($(cat "$FLOG"))"
[ -f "$D/.findings-general" ] && ok || bad "1: the second harvest must set the marker again"
N=$(lines); harvest "$D"
eq "1: a third harvest adds nothing" "$(lines)" "$N"

# ══ 2. a reused APPROVE (test-tamper, REUSED=1) keeps the marker ═════════════
reset_h rewrite
D=$(mkbuild project-5-TK-551-202609231002 "$TAMPER")
printf '%s\n- standing finding: the original round approved this diff as written\nTIER: 1\nVERDICT: APPROVE\n' '## Findings' > "$D/review.md"
harvest "$D"
SUM=$(cksum < "$D/review.md"); N=$(lines)
run
[ -s "$T/review-calls.txt" ] && bad "2: a standing APPROVE must not be re-reviewed" || ok
grep -q '^PR_CREATED ' "$D/RESULT" && ok || bad "2: the rescue did not reach the reuse branch ($(cat "$D/RESULT"))"
eq "2: review.md unchanged" "$(cksum < "$D/review.md")" "$SUM"
[ -f "$D/.findings-general" ] && ok || bad "2: .findings-general must survive a rescue that rewrote nothing"
harvest "$D"
eq "2: no duplicate rows" "$(lines)" "$N"

# ══ 3. the reviewer dies without writing: marker kept, no duplicates ══════════
reset_h none
D=$(mkbuild project-5-TK-551-202609231003 "$DIED")
printf '%s\n' "$DRAFT" > "$D/review.md"
harvest "$D"
N=$(lines)
run
[ -s "$T/review-calls.txt" ] && ok || bad "3: the rescue never called the reviewer"
[ -f "$D/.findings-general" ] && ok || bad "3: .findings-general must survive a review that wrote nothing"
harvest "$D"
eq "3: no duplicate rows" "$(lines)" "$N"
eq "3: the draft row is still logged once" "$(cnt 'draft finding')" "1"

# ══ 4. only the general lens is cleared ═══════════════════════════════════════
reset_h rewrite
D=$(mkbuild project-5-TK-551-202609231004 "$DIED")
printf '%s\n' "$DRAFT" > "$D/review.md"
printf -- '- security finding: the webhook route never checks the signature header\nVERDICT: BLOCK\n' > "$D/security-review.md"
printf -- '1. refuter finding: I tried to break the retry cap and could not do it\nVERDICT: APPROVE\n' > "$D/refute-review.md"
harvest "$D"
eq "4: security row harvested once" "$(cnt 'lens=security')" "1"
eq "4: refuter row harvested once"  "$(cnt 'lens=refuter')" "1"
run
[ -f "$D/.findings-general" ]  && bad "4: .findings-general still present after rewrite" || ok
[ -f "$D/.findings-security" ] && ok || bad "4: .findings-security must not be cleared"
[ -f "$D/.findings-refuter" ]  && ok || bad "4: .findings-refuter must not be cleared"
harvest "$D"
eq "4: rescued finding harvested once" "$(cnt 'rescued finding')" "1"
eq "4: no second security row" "$(cnt 'lens=security')" "1"
eq "4: no second refuter row"  "$(cnt 'lens=refuter')" "1"

echo "review-rescue.bh-118: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
