#!/bin/bash
# tests/pr-trailers-sites.bh-4015-test.sh — EVERY PR THE HARNESS OPENS SAYS WHO
# OPENED IT, NOT ONLY THE BUILD PR (BH-4015, slice 2 of BH-3987).
#
# The tracer (#4014) trailered bin/lib/rb/pr.sh. Every other create site now
# carries its own `# >>> pr trailers (BH-3987)` block: the restack in
# bin/pr-url-reconcile.sh, the rescue in bin/review-rescue.sh, the merge train in
# bin/batch-resolve.sh, the main-red-bisect revert in bin/lib/mrb-act.sh, and
# the lane PRs (deploy-train, rule-miner x2, guardrail-promote, flaky-quarantine,
# mergify-sync, feature-map-draft, qa-personas).
#
#   T5  restack: the REAL block, extracted from bin/pr-url-reconcile.sh, over a
#       pr-body.md that already carries an old block -> exactly one block, after
#       the restack note, the build's own job (never an exported lane JOB_ID),
#       pr-body.md byte-unchanged, the scratch body removed
#   T5b restack with no trailer in pr-body.md -> the job comes from job.json,
#       still not the lane's exported JOB_ID
#   T6  train: the REAL block from bin/batch-resolve.sh, stub gh copies
#       --body-file -> last three lines Job/Ticket/Train, member list intact
#   T7  mrb: the REAL _mrb_open_pr -> pr.json .body carries lane:main-red-bisect
#       and the culprit's ticket key, or `none` for a title with no key
#   T8  census over the real bin/: zero unguarded creates; planted creates are
#       red and named, hint strings / comments / a reviews POST stay green, a
#       same-line `# pr-trailers:` allow is green, a dropped marker pair is red
#   T9  rescue: the REAL block from bin/review-rescue.sh -> rescue text, then
#       the block, Ticket last; T9b with no writable TMPDIR the PR still opens
#       (untrailered) and one log line says so
#   T10 lanes: the REAL blocks from bin/flaky-quarantine.sh and
#       bin/feature-map-draft.sh -> body ends lane:<id> / none
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-trailers-sites.bh-4015-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset JOB_ID BUILDER_EXEC

# extract <file> [n] — the n-th `# >>> pr trailers` block of a shipped script,
# verbatim, markers excluded.
extract() {
  awk -v n="${2:-1}" '/^[[:space:]]*# >>> pr trailers/ { c++; if (c == n) f = 1; next }
                      f && /^[[:space:]]*# <<< pr trailers/ { exit }
                      f' "$1"
}
# need <name> <file> — a block that is not there is a red, not a silent pass.
need() { [ -s "$2" ] && ok || bad "$1: no # >>> pr trailers block was extracted"; }

# A gh on PATH: every call appends its argv to $T/gh.args, the --body-file it
# was given (or stdin for `-`) is copied to $T/gh.body, and it prints a url.
SB="$T/sb"; mkdir -p "$SB"
cat > "$SB/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.args"
: > "$T/gh.body"
while [ \$# -gt 0 ]; do
  case "\$1" in
    --body-file) if [ "\$2" = - ]; then cat > "$T/gh.body"; else cp "\$2" "$T/gh.body"; fi; shift ;;
    --body|-b) printf '%s\n' "\$2" > "$T/gh.body"; shift ;;
  esac
  shift
done
echo "https://github.com/o/r/pull/5"
SH
chmod +x "$SB/gh"
export PATH="$SB:$PATH"
reset_gh() { rm -f "$T/gh.args" "$T/gh.body"; }

# ══ T5: the restack (bin/pr-url-reconcile.sh) ═════════════════════════════════
extract "$DIR/bin/pr-url-reconcile.sh" > "$T/restack.sh"; need T5 "$T/restack.sh"
d="$T/build-5"; mkdir -p "$d"
printf 'the build body\n\nHarness-Job: job-own-7\nHarness-Ticket: BH-1\n' > "$d/pr-body.md"
printf '{"job_id":"job-from-json"}\n' > "$d/job.json"
BEFORE=$(md5sum < "$d/pr-body.md")
OUT=$(
  HARNESS="$DIR"; export JOB_ID=lane-claim
  key=BH-55 purl=https://github.com/o/r/pull/4 pbr=ticket/bh-54 base=main phead=0123456789abcdef
  slug=o/r br=ticket/bh-55 title=t bd=build-5
  say() { printf '%s\n' "$*" >> "$T/restack.log"; }
  _gpc_rung_create() { cp "$6" "$T/restack.body"; echo "https://github.com/o/r/pull/6"; }
  . "$T/restack.sh"
  printf '%s|%s\n' "$url" "$bf"
)
B=$(cat "$T/restack.body" 2>/dev/null)
eq "T5: one Harness-Job line" "$(grep -c '^Harness-Job:' <<<"$B")" 1
eq "T5: the job is the build's own, not the exported lane JOB_ID" "$(grep '^Harness-Job:' <<<"$B")" "Harness-Job: job-own-7"
eq "T5: the ticket is the restacked key, last" "$(tail -n 1 <<<"$B")" "Harness-Ticket: BH-55"
NL=$(grep -n '^Restacked by pr-url-reconcile' <<<"$B" | cut -d: -f1)
JL=$(grep -n '^Harness-Job:' <<<"$B" | cut -d: -f1)
[ -n "$NL" ] && [ -n "$JL" ] && [ "$JL" -gt "$NL" ] && ok \
  || bad "T5: the block must land after the restack note (note line ${NL:-none}, job line ${JL:-none})"
eq "T5: pr-body.md is byte-unchanged" "$(md5sum < "$d/pr-body.md")" "$BEFORE"
eq "T5: the create's url comes back" "${OUT%%|*}" "https://github.com/o/r/pull/6"
[ -n "${OUT#*|}" ] && [ ! -e "${OUT#*|}" ] && ok || bad "T5: the scratch body ${OUT#*|} must be removed after the create"

# ══ T5b: no trailer in pr-body.md -> job.json, never the lane's JOB_ID ════════
printf 'the build body\n' > "$d/pr-body.md"
(
  HARNESS="$DIR"; export JOB_ID=lane-claim
  key=BH-55 purl=u pbr=p base=main phead=0123456789abcdef slug=o/r br=b title=t bd=build-5
  say() { :; }
  _gpc_rung_create() { cp "$6" "$T/restack.body"; echo u; }
  . "$T/restack.sh"
)
eq "T5b: the job is job.json's, not the lane claim" "$(grep '^Harness-Job:' "$T/restack.body")" "Harness-Job: job-from-json"

# ══ T6: the merge train (bin/batch-resolve.sh) ════════════════════════════════
extract "$DIR/bin/batch-resolve.sh" > "$T/train.sh"; need T6 "$T/train.sh"
reset_gh
printf 'Members:\n\n- #11 (`ticket/a`)\n- #12 (`ticket/b`)\n' > "$T/train.body"
OUT=$(
  H="$DIR" SLUG=o/r PBASE=main br=batch/p/20261003 PROJECT=p bf="$T/train.body"
  in=(11 12)
  say() { printf '%s\n' "$*" >> "$T/train.log"; }
  br_train_identity() { return 0; }
  br_train_release() { :; }
  . "$T/train.sh"
  printf '%s\n' "$turl"
)
eq "T6: the train url comes back" "$OUT" "https://github.com/o/r/pull/5"
eq "T6: the last three lines are the train block" "$(tail -n 3 "$T/gh.body" 2>/dev/null)" \
  $'Harness-Job: train:batch/p/20261003\nHarness-Ticket: none\nHarness-Train: batch/p/20261003 #11 #12'
has "T6: the member list above is intact" "$(cat "$T/gh.body" 2>/dev/null)" $'- #11 (`ticket/a`)\n- #12 (`ticket/b`)'

# ══ T7: the main-red-bisect revert (bin/lib/mrb-act.sh _mrb_open_pr) ══════════
mrb_run() { # <culprit title> -> the pr.json body
  (
    unset -f pr_trailers_apply 2>/dev/null
    . "$DIR/bin/lib/mrb-act.sh" || exit 9
    gh_rest() { GH_REST_STATUS=201; cp "$4" "$T/mrb.input"; printf '{"number":9,"html_url":"https://x/9"}\n'; }
    _mrb_table() { :; }
    _mrb_finish() { printf '%s %s\n' "$1" "$2" > "$T/mrb.finish"; }
    d="$T/mrb"; mkdir -p "$d"
    pr=102 runurl=https://ci/1 culprit=abc suites=x-test green=g red=r br=main-red-revert/102 slug=o/r
    pr_title="$1" bisect=""
    _mrb_open_pr deadbeef
  )
  jq -r .body "$T/mrb.input" 2>/dev/null
}
rm -f "$T/mrb.input" "$T/mrb.finish"
B=$(mrb_run 'BH-77: x')
eq "T7: the job is the lane" "$(grep '^Harness-Job:' <<<"$B")" "Harness-Job: lane:main-red-bisect"
eq "T7: the ticket is the culprit's key, last" "$(tail -n 1 <<<"$B")" "Harness-Ticket: BH-77"
has "T7: the revert text is kept" "$B" "The bisect pinned it on merge abc (#102)"
eq "T7: the PR still finishes" "$(cat "$T/mrb.finish" 2>/dev/null)" "9 https://x/9"
rm -f "$T/mrb.input"
B=$(mrb_run 'a title with no key')
eq "T7: no key in the culprit title -> none" "$(tail -n 1 <<<"$B")" "Harness-Ticket: none"

# ══ T8: the census ════════════════════════════════════════════════════════════
# A create is `gh pr create` at a line start, after `$(` or `&&`; a POST to
# repos/<x>/pulls ending there; or a `$(_gpc_rung_create ` call. Continuation
# lines are joined and reported at their first line; a `# pr-trailers: <why>`
# allow is read from the last one. A create is guarded inside a
# `# >>> pr trailers` / `# <<< pr trailers` pair, by a same-line allow, or when
# the code line before it calls pr_trailers_apply or a _pr_trailers_* function
# (bin/lib/rb/pr.sh's `_pr_trailers_s1` sits on the line above its create).
# bin/lib/gh-shim/ is skipped: BH-4015 says no change there, it forwards
# whatever body its caller hands it and is not on any box's PATH.
cat > "$T/census.awk" <<'AWK'
function check(lg, last, start) {
  if (lg ~ /^[[:space:]]*$/) return
  if (lg ~ /^[[:space:]]*# >>> pr trailers/) { inb = 1; return }
  if (lg ~ /^[[:space:]]*# <<< pr trailers/) { inb = 0; return }
  if (lg ~ /^[[:space:]]*#/) return
  if (lg ~ /(^|\$\(|&&)[[:space:]]*gh pr create/ \
      || lg ~ /POST[[:space:]]+["']?repos\/[^[:space:]"']*\/pulls(["'[:space:]]|$)/ \
      || lg ~ /\$\(_gpc_rung_create[[:space:]]/) {
    if (!(inb || prev || last ~ /# pr-trailers:[[:space:]]*[^[:space:]]/)) { print F ":" start; bad = 1 }
  }
  prev = (lg ~ /(^|[^A-Za-z0-9_])(pr_trailers_apply|_pr_trailers_[A-Za-z0-9_]+)([^A-Za-z0-9_]|$)/)
}
FNR == 1 { inb = 0; prev = 0; cont = 0 }
{
  if (cont) lg = lg " " $0; else { lg = $0; start = FNR }
  last = $0
  if (!cont && $0 ~ /^[[:space:]]*#/) { check(lg, last, start); next }
  if ($0 ~ /\\$/) { cont = 1; sub(/\\$/, "", lg); next }
  cont = 0; check(lg, last, start)
}
END { exit bad }
AWK
census() { # <root> -> unguarded `<root-name>/<path>:<line>` lines, rc 1 if any
  local root="$1" f rc=0 name; name=$(basename "$root")
  while IFS= read -r f; do
    case "$f" in "$root"/lib/gh-shim/*) continue ;; esac
    case "$f" in *.sh) ;; *) head -n 1 "$f" 2>/dev/null | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)' || continue ;; esac
    awk -v F="$name/${f#"$root"/}" -f "$T/census.awk" "$f" || rc=1
  done < <(find "$root" -type f | sort)
  return "$rc"
}
OUT=$(census "$DIR/bin"); RC=$?
eq "T8: the real bin/ has no unguarded create (got: $OUT)" "$RC" 0
plant() { rm -rf "$T/c"; mkdir -p "$T/c"; cp -r "$DIR/bin" "$T/c/bin"; }
plant; printf '#!/bin/bash\nx=1\nx=$(gh pr create --head a --base main --body-file f)\n' > "$T/c/bin/plant.sh"
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(i): a bare create is red" "$RC" 1
eq "T8(i): and named by file:line" "$OUT" "bin/plant.sh:3"
plant; printf '#!/bin/bash\ny=$(cd w && gh pr create -B main \\\n  --body-file f)\n' > "$T/c/bin/plant.sh"
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(ii): a continued create is red at its first line" "$RC:$OUT" "1:bin/plant.sh:2"
plant
cat > "$T/c/bin/plant.sh" <<'SH'
#!/bin/bash
say "the parent merged, then gh pr create --head $br"
lint_fail "gh pr create" "finish with: gh pr create -R x"
alert "open it by hand with: gh pr create --head $br --base main"
gh_rest POST "repos/$r/pulls/$n/reviews" -f event=COMMENT
_gpc_rung_create() {
  :
}
# x=$(gh pr create --head a)
SH
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(iii): hint strings, a reviews POST, a definition and a comment stay green (got: $OUT)" "$RC" 0
plant; printf '#!/bin/bash\nx=$(gh pr create --head a --body-file f)   # pr-trailers: test\n' > "$T/c/bin/plant.sh"
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(iv): a same-line allow is green (got: $OUT)" "$RC" 0
plant; printf '#!/bin/bash\nx=$(gh pr create --head a --body-file f)   # pr-trailers:\n' > "$T/c/bin/plant.sh"
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(iv): an allow with no reason is red" "$RC:$OUT" "1:bin/plant.sh:2"
plant; sed -i '/# >>> pr trailers/d; /# <<< pr trailers/d' "$T/c/bin/flaky-quarantine.sh"
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(v): flaky-quarantine without its marker pair is red" "$RC" 1
has "T8(v): and it is named" "$OUT" "bin/flaky-quarantine.sh:"
plant; printf 'PR_URL=$(gh pr create --head x --body-file y)\n' >> "$T/c/bin/lib/rb/pr.sh"
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(vi): a second create in rb/pr.sh with no apply above it is red" "$RC" 1
has "T8(vi): and it is named" "$OUT" "bin/lib/rb/pr.sh:"
plant; printf '#!/bin/bash\nrest o POST "repos/$s/pulls" --input i\n' > "$T/c/bin/plant.sh"
OUT=$(census "$T/c/bin"); RC=$?
eq "T8(vii): a bare REST pulls POST is red" "$RC:$OUT" "1:bin/plant.sh:2"

# ══ T9: the rescue (bin/review-rescue.sh) ═════════════════════════════════════
extract "$DIR/bin/review-rescue.sh" > "$T/rescue.sh"; need T9 "$T/rescue.sh"
CAND="$T/cand-9"; mkdir -p "$CAND"
printf '{"job_id":"job-9"}\n' > "$CAND/job.json"
rescue_run() {
  (
    H="$DIR"; export JOB_ID=lane-claim
    SLUG=o/r BRANCH=ticket/bh-9 KEY=BH-9 TITLE=t CLOG="$T/rescue.clog" BN=cand-9
    BODY=$(printf 'Rescued by `bin/review-rescue.sh` on now.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n')
    say() { printf '%s\n' "$*" >> "$T/rescue.log"; }
    . "$T/rescue.sh"
    printf '%s\n' "$PRURL"
  )
}
reset_gh; rm -f "$T/rescue.log"
OUT=$(rescue_run)
eq "T9: the url comes back" "$OUT" "https://github.com/o/r/pull/5"
eq "T9: the rescue text comes first" "$(head -n 1 "$T/gh.body" 2>/dev/null)" 'Rescued by `bin/review-rescue.sh` on now.'
eq "T9: the job is job.json's, not the lane claim" "$(grep '^Harness-Job:' "$T/gh.body" 2>/dev/null)" "Harness-Job: job-9"
eq "T9: the ticket is last" "$(tail -n 1 "$T/gh.body" 2>/dev/null)" "Harness-Ticket: BH-9"
has "T9: the create reads a body file" "$(cat "$T/gh.args" 2>/dev/null)" "--body-file"
[ -z "$(find "$T" -maxdepth 1 -name 'rescue-body-*' 2>/dev/null)" ] && ok || bad "T9: the temp body must be removed"
# T9b: nowhere to write the body -> the PR still opens, untrailered, and says so.
reset_gh; rm -f "$T/rescue.log"
OUT=$(TMPDIR="$T/no-such-dir" rescue_run)
eq "T9b: the create still ran" "$(grep -c 'pr create' "$T/gh.args" 2>/dev/null)" 1
eq "T9b: and its url comes back" "$OUT" "https://github.com/o/r/pull/5"
has "T9b: the body is the rescue text" "$(cat "$T/gh.body" 2>/dev/null)" 'Rescued by `bin/review-rescue.sh`'
has "T9b: one log line says it opened without trailers" "$(cat "$T/rescue.log" 2>/dev/null)" "PR opened without trailers"

# ══ T10: lane PRs (flaky-quarantine, feature-map-draft) ═══════════════════════
extract "$DIR/bin/flaky-quarantine.sh" > "$T/fq.sh"; need T10 "$T/fq.sh"
reset_gh
(
  H="$DIR" SLUG=o/r BASE=main BR=chore/quarantine-flaky-1 NEW=$'a-test\nb-test'
  PRBODY=$'Adds 2 test(s) to `.flaky`.\n\n- a-test\n- b-test'
  . "$T/fq.sh"
  printf '%s\n' "$PRURL" > "$T/fq.url"
)
eq "T10: flaky-quarantine url" "$(cat "$T/fq.url")" "https://github.com/o/r/pull/5"
eq "T10: flaky-quarantine body ends in its block" "$(tail -n 2 "$T/gh.body" 2>/dev/null)" \
  $'Harness-Job: lane:flaky-detect\nHarness-Ticket: none'
has "T10: flaky-quarantine keeps its text" "$(cat "$T/gh.body" 2>/dev/null)" $'- a-test\n- b-test'
has "T10: flaky-quarantine reads a body file" "$(cat "$T/gh.args" 2>/dev/null)" "--body-file"

extract "$DIR/bin/feature-map-draft.sh" > "$T/fmd.sh"; need T10 "$T/fmd.sh"
reset_gh
WT="$T/fmd-wt"
printf 'A first verification map for p.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$WT.body"
(
  HARNESS="$DIR" slug=o/r BRANCH=docs/vmap p=p
  . "$T/fmd.sh"
  printf '%s %s\n' "$r" "$url" > "$T/fmd.out"
)
eq "T10: feature-map-draft rc and url" "$(cat "$T/fmd.out")" "0 https://github.com/o/r/pull/5"
eq "T10: feature-map-draft body ends in its block" "$(tail -n 2 "$T/gh.body" 2>/dev/null)" \
  $'Harness-Job: lane:feature-map-draft\nHarness-Ticket: none'
[ ! -e "$WT.body" ] && ok || bad "T10: feature-map-draft must still remove its body file"

echo "pr-trailers-sites.bh-4015: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
