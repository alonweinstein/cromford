#!/bin/bash
# tests/mrb-act.bh-3685-test.sh — BH-3697 (BH-3685.4): main-red-bisect acts on a
# bisected episode. bin/lib/mrb-act.sh reverts the culprit merge through a PR
# and files a re-land ticket, or, with no culprit merge, quarantines the red
# suites and files a fix ticket.
#
# DRIVEN, NOT GREPPED: every case calls the real mrb_act_culprit /
# mrb_act_notmerge, with the real bin/jobs-client.sh (and so the real
# metric_flake_quarantine_put), gh-rest.sh, gh-rest-list.sh and
# main-red-label.sh, over a real scratch git repo whose main has three
# `git merge --no-ff` merges (#102 breaks tests/x-test.sh) and a bare remote
# whose pre-receive hook records every push. The recorders:
#   gh        on PATH; logs `<METHOD> <path>` to calls.gh, keeps every --input
#             body as payload.<n> (calls.pay: `<n> <METHOD> <path>`)
#   curl      on PATH; a STATEFUL ledger (GET answers the stored row or 404,
#             PUT stores it) and the quarantine PUT, logged to calls.qput
#   lane-alert, lead-verdict   scratch $H/bin stubs, argv to calls.alert / calls.verdict
#
#   A1  culprit #102 -> one revert PR, pushed tip reverts #102 and x-test passes,
#       label, verdict request, re-land ticket, warn digest, opening before push
#   A1x the pulls POST answers 422 -> rc 1, the row stays opening, nothing after
#   A2  notmerge clock-test -> one quarantine PUT, one fix ticket, no PR/push
#   A2b the quarantine PUT answers 500 -> rc != 0, the ticket still filed once
#   A3a A1 twice -> still one PR, one ticket, one push
#   A1y A1x then the same episode again with the POST answering 201 -> the
#       pushed branch is opened once (no second push), rc 0, ledger done
#   A3b an `opening` row adopts the PR through pulls?head=, no POST, no push
#   A3b' an `opening` row with no PR and no branch on the remote (the push or
#       the token mint failed) -> the revert is cut again: one push, one PR
#   A3g an `opening` row whose branch is pushed but whose PR open is refused
#       again -> no push, one critical orphan alert, rc 1
#   A9  MRB_REPO_DIR unset -> rc 75, one critical norepo alert, no POST
#   A2c the same suite set red again in a LATER episode -> a new fix ticket;
#       the same episode twice -> still one
#   A3c pr_branch=main-red-revert/... -> no PR, one critical alert
#   A3d already reverted on main -> no PR, ledger already-reverted
#   A3e a revert of #10 on main does not count for #102 -> PR opened
#   A3f no ledger rows, the marker in an open issue -> no issue POST
#   A5  a protected suite -> no PUT, one critical, the ticket filed
#   A5b 4 suites over the default cap 3 -> no PUT, one critical, the ticket
#   A5c QUARANTINE_MAX=0 -> no PUT, one critical
#   A8a a conflicting later merge -> no PR, no push, critical naming the file,
#       ticket "did not apply cleanly", ledger conflict
#   A8b MAIN_RED_BISECT_REVERT=0 -> no PR, no push, ticket "revert disabled by knob"
#   T3x the ledger answers 500 -> rc 75, no gh POST
#   W1  metric_flake_quarantine_put: exact body; active=2 -> rc 1, no request
#   C1  mc_is_harness_pr accepts main-red-revert/*, nothing else changes
#   M1  mutation: the lib without its main_red_revert ledger read -> A3a red
#   M2  mutation: _mrb_protected always 1 -> A5 red
#
# No network, one clock read (NOW). Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/mrb-act.bh-3685-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "mrb-act.bh-3685-test: SKIPPED — jq missing"; exit 0; }

NOW=$(date -u +%s)
LIB="$DIR/bin/lib/mrb-act.sh"
H="$T/h"
SB="$T/sb"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T" GH_ETAG=0

# ── the stubs (written once; they read $T at run time) ───────────────────────
mkdir -p "$SB" "$H/bin" "$H/catalog" "$H/env" "$H/logs" "$H/state"
: > "$H/env/global.env"
cp "$DIR/catalog/test-impact-always.txt" "$H/catalog/"
cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.alert"
SH
cat > "$H/bin/lead-verdict.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.verdict"
SH
cat > "$SB/gh" <<SH
#!/bin/bash
m=GET p="" n=\$(ls "$T" | grep -c '^payload\.')
shift # api
while [ \$# -gt 0 ]; do
  case "\$1" in
    -i) ;;
    -X) m="\$2"; shift ;;
    --input) n=\$((n+1)); cp "\$2" "$T/payload.\$n"; echo "\$n" > "$T/pay.last"; shift ;;
    -F|-f|-H) shift ;;
    *) [ -z "\$p" ] && p="\$1" ;;
  esac; shift
done
printf '%s %s\n' "\$m" "\$p" >> "$T/calls.gh"
[ -f "$T/pay.last" ] && { printf '%s %s %s\n' "\$(cat "$T/pay.last")" "\$m" "\$p" >> "$T/calls.pay"; rm -f "$T/pay.last"; }
case "\$m \$p" in
  "POST repos/o/r/pulls")
    if [ -n "\${STUB_PR_STATUS:-}" ]; then printf 'HTTP/2 %s\n\n{"message":"no"}\n' "\$STUB_PR_STATUS"
    else printf 'HTTP/2 201\n\n{"number":500,"html_url":"https://github.com/o/r/pull/500"}\n'; fi ;;
  "GET repos/o/r/pulls?"*)
    printf 'HTTP/2 200\n\n%s\n' "\${STUB_PULLS:-[]}" ;;
  "POST repos/o/r/issues/"*/labels)
    printf 'HTTP/2 200\n\n[{"name":"x"}]\n' ;;
  "GET repos/o/r/issues")
    printf 'HTTP/2 200\n\n'; if [ -n "\${STUB_LIST:-}" ]; then cat "\$STUB_LIST"; else printf '[]\n'; fi ;;
  "POST repos/o/r/issues")
    c=\$(grep -c '^POST repos/o/r/issues\$' "$T/calls.gh")
    printf 'HTTP/2 201\n\n{"number":60%s,"html_url":"https://github.com/o/r/issues/60%s"}\n' "\$c" "\$c" ;;
  *) printf 'HTTP/2 500\n\n{}\n' ;;
esac
SH
cat > "$SB/curl" <<SH
#!/bin/bash
m=GET d="" url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) m="\$2"; shift ;;
    --data-binary) d="\$2"; shift ;;
    -m|--connect-timeout|-w|-H) shift ;;
    -*) ;;
    *) url="\$1" ;;
  esac; shift
done
p="\${url#http://stub}"
mkdir -p "$T/ledger"
answer() { printf '%s\n%s' "\$1" "\$2"; exit 0; }
case "\$m \$p" in
  "GET /api/ledger?"*)
    [ -n "\${STUB_LEDGER_GET:-}" ] && answer '{}' "\$STUB_LEDGER_GET"
    f="$T/ledger/\$(printf '%s' "\${p#*\\?}" | sha1sum | cut -c1-16)"
    [ -f "\$f" ] && answer "{\"ledger\":\$(cat "\$f")}" 200
    answer '{"error":"not found"}' 404 ;;
  "PUT /api/ledger")
    q=\$(printf '%s' "\$d" | jq -r '"kind="+(.kind|@uri)+"&key="+(.key|@uri)')
    printf '%s' "\$d" | jq -c '{status, detail: (.detail // "")}' > "$T/ledger/\$(printf '%s' "\$q" | sha1sum | cut -c1-16)"
    printf '%s' "\$d" | jq -r '"\(.kind) \(.key) \(.status) \(.detail // "")"' >> "$T/calls.ledger"
    printf '%s' "\$d" | jq -r '"ledger \(.status)"' >> "$T/events"
    answer '{"ok":true}' 200 ;;
  "PUT /api/metrics/flakes/quarantine")
    printf '%s\n' "\$d" >> "$T/calls.qput"
    answer '{"ok":true}' "\${STUB_QPUT_STATUS:-200}" ;;
  *) answer '{}' 404 ;;
esac
SH
chmod +x "$SB/gh" "$SB/curl" "$H/bin/"*.sh
export PATH="$SB:$PATH" HARNESS="$H" JOBS_URL=http://stub HARNESS_SECRET=x JOBS_RETRIES=0 TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"

. "$DIR/bin/jobs-client.sh" || { echo "FAIL: jobs-client.sh did not load"; exit 1; }
. "$DIR/bin/lib/mc/classify.sh" || { echo "FAIL: classify.sh did not load"; exit 1; }
. "$LIB" || { echo "FAIL: $LIB did not load"; exit 1; }
gh_default_auth_for_slug() { :; }

# ── the scratch repo ─────────────────────────────────────────────────────────
# fresh [variant] — new remote, clone, ledger and recorders. Variants:
#   reverted   main also carries git's revert of #102
#   revert10   main also carries a `Revert "Merge pull request #10 ..."` commit
#   conflict   a later merge #103 edits the line #102 changed
fresh() {
  local v="${1:-}" S="$T/src"
  scratch_rm "$T/src"; scratch_rm "$T/remote.git"; scratch_rm "$T/clone"; scratch_rm "$T/ledger"
  rm -f "$T"/calls.* "$T"/payload.* "$T/pushes" "$T/events" "$T/pay.last"
  git init -q -b main "$S"
  mkdir -p "$S/tests"
  printf '#!/bin/bash\nexit 0\n' > "$S/tests/x-test.sh"
  printf '#!/bin/bash\nexit 0\n' > "$S/tests/clock-test.sh"
  git -C "$S" add -A && git -C "$S" commit -qm base
  git -C "$S" checkout -qb pr-101 && echo a > "$S/a.txt" && git -C "$S" add -A && git -C "$S" commit -qm a
  git -C "$S" checkout -q main && git -C "$S" merge -q --no-ff -m "Merge pull request #101 from o/a" pr-101
  git -C "$S" checkout -qb pr-102 && printf '#!/bin/bash\nexit 1\n' > "$S/tests/x-test.sh" && git -C "$S" commit -qam b
  git -C "$S" checkout -q main && git -C "$S" merge -q --no-ff -m "Merge pull request #102 from o/b" pr-102
  M=$(git -C "$S" rev-parse HEAD)
  case "$v" in
    reverted) git -C "$S" revert -m 1 --no-edit "$M" >/dev/null ;;
    revert10) git -C "$S" commit -q --allow-empty -m 'Revert "Merge pull request #10 from o/z"' ;;
    conflict) git -C "$S" checkout -qb pr-103 && printf '#!/bin/bash\nexit 2\n' > "$S/tests/x-test.sh" \
                && git -C "$S" commit -qam c && git -C "$S" checkout -q main \
                && git -C "$S" merge -q --no-ff -m "Merge pull request #103 from o/c" pr-103 ;;
  esac
  git init -q --bare -b main "$T/remote.git"
  git -C "$S" push -q "$T/remote.git" main
  cat > "$T/remote.git/hooks/pre-receive" <<SH
#!/bin/bash
while read -r o n r; do echo "\$r" >> "$T/pushes"; echo "push \$r" >> "$T/events"; done
SH
  chmod +x "$T/remote.git/hooks/pre-receive"
  git clone -q "$T/remote.git" "$T/clone"
  export MRB_REPO_DIR="$T/clone"
  printf '| sha | answer |\n| %s | red |\n' "$M" > "$T/bisect.md"
  EP="$T/ep"
  printf 'source=flag\nslug=o/r\nred=%s\ngreen=%s\nrun=4242\nsuites=tests/x-test.sh\noutcome=\n' \
    "$M" "$(git -C "$S" rev-parse HEAD~1)" > "$EP"
  printf 'culprit=%s\npr=102\npr_title=Break x "quoted" $HOME\npr_branch=b\nsteps=2\nbisect=%s\noutcome=culprit\n' \
    "$M" "$T/bisect.md" >> "$EP"
  M12=${M:0:12}
}
nm_ep() { # nm_ep <suites> -> $NEP, a notmerge episode
  NEP="$T/nep"
  printf 'source=nightly\nslug=o/r\nred=%s\ngreen=%s\nrun=4343\nsuites=%s\noutcome=\noutcome=notmerge\n' \
    "$(printf 'b%.0s' {1..40})" "$(printf 'a%.0s' {1..40})" "$1" > "$NEP"
}
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1" || true; else echo 0; fi; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
payload() { # payload <METHOD path regex> -> the last matching payload file
  local n; n=$(grep -E "^[0-9]+ $1\$" "$T/calls.pay" 2>/dev/null | tail -1 | cut -d' ' -f1)
  [ -n "$n" ] && printf '%s' "$T/payload.$n"
}
leftover() { find "$TMPDIR" -maxdepth 1 -name 'mrb-*' | wc -l | tr -d ' '; }
act() { ( "$@" ) > "$T/out" 2> "$T/err"; RC=$?; }

# ── A1: culprit #102 ─────────────────────────────────────────────────────────
fresh
act mrb_act_culprit "$EP"
eq "A1 rc" "$RC" 0
eq "A1 stdout" "$(cat "$T/out")" ""
eq "A1 one pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 1
P=$(payload 'POST repos/o/r/pulls')
BR=$(jq -r '.head' "$P" 2>/dev/null)
eq "A1 head" "$BR" "main-red-revert/pr-102-$M12"
eq "A1 base" "$(jq -r '.base' "$P" 2>/dev/null)" main
has "A1 title" "$(jq -r '.title' "$P" 2>/dev/null)" 'revert: #102 — Break x "quoted" $HOME'
has "A1 body marker" "$(jq -r '.body' "$P" 2>/dev/null)" "harness build: main-red-bisect revert of #102"
has "A1 body run" "$(jq -r '.body' "$P" 2>/dev/null)" "https://github.com/o/r/actions/runs/4242"
has "A1 body bisect" "$(jq -r '.body' "$P" 2>/dev/null)" "| $M | red |"
eq "A1 one push" "$(lines "$T/pushes")" 1
eq "A1 pushed ref" "$(cat "$T/pushes" 2>/dev/null)" "refs/heads/main-red-revert/pr-102-$M12"
case "$(git --git-dir="$T/remote.git" log -1 --format=%s "$BR" 2>/dev/null)" in
  'Revert "Merge pull request #102'*) ok ;; *) bad "A1 pushed tip subject is not git's revert of #102" ;;
esac
git --git-dir="$T/remote.git" show "$BR:tests/x-test.sh" > "$T/x.sh" 2>/dev/null
bash "$T/x.sh"; eq "A1 reverted tree makes x-test pass" "$?" 0
eq "A1 one labels POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues/500/labels$')" 1
# TEST-CHANGE (BH-4981): the revert now also carries hotfix_label's `hotfix`, so
# the merge conductor heads its order with it (the ticket's "through the hotfix lane").
eq "A1 label" "$(jq -c '.labels' "$(payload 'POST repos/o/r/issues/500/labels')" 2>/dev/null)" '["fix-main-red","hotfix"]'
PUSHED=$(git --git-dir="$T/remote.git" rev-parse "$BR" 2>/dev/null)
eq "A1 verdict request" "$(cat "$T/calls.verdict" 2>/dev/null)" "request o/r 500 $PUSHED"
eq "A1 one issue POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
I=$(payload 'POST repos/o/r/issues')
eq "A1 issue labels" "$(jq -c '.labels' "$I" 2>/dev/null)" '["ai-build"]'
has "A1 issue title" "$(jq -r '.title' "$I" 2>/dev/null)" "Re-land #102 (Break x \"quoted\" \$HOME) — reverted: broke tests/x-test.sh"
IB=$(jq -r '.body' "$I" 2>/dev/null)
has "A1 issue marker" "$IB" "<!-- main-red-reland: o/r@$M -->"
has "A1 issue suite" "$IB" "tests/x-test.sh"
has "A1 issue revert PR" "$IB" "https://github.com/o/r/pull/500"
has "A1 issue original PR" "$IB" "https://github.com/o/r/pull/102"
eq "A1 one warn alert" "$(count "$T/calls.alert" '^--severity warn ')" 1
has "A1 warn names #102" "$(grep -- '--severity warn' "$T/calls.alert" 2>/dev/null)" "#102"
has "A1 warn id" "$(cat "$T/calls.alert" 2>/dev/null)" "--id main-red-revert:o/r:$M12 main-red-bisect"
eq "A1 no critical" "$(count "$T/calls.alert" 'critical')" 0
eq "A1 events order" "$(grep -E '^(ledger (opening|done)|push)' "$T/events" 2>/dev/null | tr '\n' ',')" \
  "ledger opening,push refs/heads/main-red-revert/pr-102-$M12,ledger done,"
has "A1 ledger done detail" "$(grep '^main_red_revert .* done ' "$T/calls.ledger")" '"pr":500'
eq "A1 reland filed" "$(count "$T/calls.ledger" "^main_red_reland o/r@$M filed ")" 1
eq "A1 no temp dirs left" "$(leftover)" 0
eq "A1 worktrees pruned" "$(git -C "$T/clone" worktree list | wc -l | tr -d ' ')" 1

# ── A3a: the same episode again ─────────────────────────────────────────────
act mrb_act_culprit "$EP"
eq "A3a rc" "$RC" 0
eq "A3a still one pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 1
eq "A3a still one issue POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
eq "A3a still one push" "$(lines "$T/pushes")" 1

# ── M1: without the main_red_revert ledger read, A3a goes red ───────────────
sed '/job_ledger_row main_red_revert/d' "$LIB" > "$T/m1.sh"
if grep -q 'job_ledger_row main_red_revert' "$LIB"; then ok; else bad "M1: the lib has no main_red_revert ledger read to remove"; fi
fresh
( . "$T/m1.sh"; mrb_act_culprit "$EP"; mrb_act_culprit "$EP" ) >/dev/null 2>&1
M1=$(count "$T/calls.gh" '^POST repos/o/r/pulls$')
[ "$M1" -ge 2 ] && ok || bad "M1: without the ledger read the second call must POST again (got $M1 pulls POSTs) — A3a proves nothing"

# ── A1x: the pulls POST is refused -> rc 1, the row stays `opening` ────────
fresh
STUB_PR_STATUS=422 act mrb_act_culprit "$EP"
eq "A1x rc" "$RC" 1
eq "A1x ledger stays opening" "$(grep -c '^main_red_revert ' "$T/calls.ledger")$(grep -c '^main_red_revert .* opening' "$T/calls.ledger")" 11
eq "A1x no label, no ticket" "$(count "$T/calls.gh" '^POST repos/o/r/issues')" 0
eq "A1x no digest" "$(lines "$T/calls.alert")" 0
eq "A1x no temp dirs left" "$(leftover)" 0

# ── A1y: the next tick after A1x opens the pushed branch once ───────────────
act mrb_act_culprit "$EP"
eq "A1y rc" "$RC" 0
eq "A1y still one push" "$(lines "$T/pushes")" 1
eq "A1y two pulls POSTs in all" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 2
eq "A1y head" "$(jq -r '.head' "$(payload 'POST repos/o/r/pulls')" 2>/dev/null)" "main-red-revert/pr-102-$M12"
eq "A1y ledger done" "$(count "$T/calls.ledger" "^main_red_revert o/r@$M done ")" 1
eq "A1y verdict names the pushed tip" "$(cat "$T/calls.verdict" 2>/dev/null)" \
  "request o/r 500 $(git --git-dir="$T/remote.git" rev-parse "main-red-revert/pr-102-$M12" 2>/dev/null)"
eq "A1y no orphan alert" "$(count "$T/calls.alert" 'main-red-revert-orphan')" 0

# ── A3b: an `opening` row adopts, never POSTs ───────────────────────────────
fresh
job_ledger_put main_red_revert "o/r@$M" opening >/dev/null
: > "$T/calls.ledger"
HS=$(printf 'c%.0s' {1..40})
STUB_PULLS='[{"number":77,"html_url":"https://github.com/o/r/pull/77","head":{"sha":"'"$HS"'"}}]' act mrb_act_culprit "$EP"
eq "A3b rc" "$RC" 0
eq "A3b no pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 0
eq "A3b no push" "$(lines "$T/pushes")" 0
eq "A3b one adopt GET" "$(count "$T/calls.gh" "^GET repos/o/r/pulls?head=o:main-red-revert/pr-102-$M12&state=all\$")" 1
eq "A3b verdict names 77" "$(cat "$T/calls.verdict" 2>/dev/null)" "request o/r 77 $HS"
has "A3b ledger done" "$(cat "$T/calls.ledger")" '"pr":77'
eq "A3b no temp dirs left" "$(leftover)" 0

# ── A3b': `opening` with no PR and no branch -> the revert is cut again ─────
# TEST-CHANGE (2026-10-01, review BLOCK finding 1 on 67e60cf): this case used to
# pin an orphan page + rc 1 here. That was the wedge: a failed push or token
# mint left `opening` with nothing pushed, and every later tick paged the same
# deduped orphan and never reverted. The row being `opening` makes a retry safe,
# so it now pins the recovery: exactly one push, exactly one PR, no orphan page.
fresh
job_ledger_put main_red_revert "o/r@$M" opening >/dev/null
act mrb_act_culprit "$EP"
eq "A3b' rc" "$RC" 0
eq "A3b' one pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 1
eq "A3b' one push" "$(cat "$T/pushes" 2>/dev/null)" "refs/heads/main-red-revert/pr-102-$M12"
eq "A3b' no orphan alert" "$(count "$T/calls.alert" 'main-red-revert-orphan')" 0
eq "A3b' ledger done" "$(count "$T/calls.ledger" "^main_red_revert o/r@$M done ")" 1
eq "A3b' reland filed" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1

# ── A3g: `opening`, branch pushed, PR open refused again -> orphan page ──────
fresh
STUB_PR_STATUS=422 act mrb_act_culprit "$EP"
: > "$T/calls.alert"
STUB_PR_STATUS=422 act mrb_act_culprit "$EP"
eq "A3g rc" "$RC" 1
eq "A3g still one push" "$(lines "$T/pushes")" 1
eq "A3g two pulls POSTs" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 2
eq "A3g orphan alert" "$(count "$T/calls.alert" "^--severity critical --id main-red-revert-orphan:o/r:$M12 ")" 1
eq "A3g no ticket" "$(count "$T/calls.gh" '^POST repos/o/r/issues')" 0

# ── A9: no repo checkout -> rc 75 and a page, never a silent rc 1 ───────────
fresh
( unset MRB_REPO_DIR; mrb_act_culprit "$EP" ) > "$T/out" 2> "$T/err"; RC=$?
eq "A9 rc" "$RC" 75
eq "A9 norepo alert" "$(count "$T/calls.alert" '^--severity critical --id main-red-revert-norepo:o/r ')" 1
eq "A9 no gh POST" "$(count "$T/calls.gh" '^POST ')" 0
eq "A9 no push" "$(lines "$T/pushes")" 0

# ── A3c: the culprit is itself a revert ─────────────────────────────────────
fresh
printf 'pr_branch=main-red-revert/pr-90-aaaaaaaaaaaa\n' >> "$EP"
act mrb_act_culprit "$EP"
eq "A3c rc" "$RC" 0
eq "A3c no pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 0
eq "A3c no push" "$(lines "$T/pushes")" 0
eq "A3c one critical" "$(count "$T/calls.alert" '^--severity critical --id main-red-revert-loop:')" 1

# ── A3d: already reverted on main ───────────────────────────────────────────
fresh reverted
act mrb_act_culprit "$EP"
eq "A3d rc" "$RC" 0
eq "A3d no pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 0
eq "A3d no push" "$(lines "$T/pushes")" 0
eq "A3d ledger" "$(count "$T/calls.ledger" "^main_red_revert o/r@$M already-reverted")" 1

# ── A3e: a revert of #10 is not a revert of #102 ────────────────────────────
fresh revert10
act mrb_act_culprit "$EP"
eq "A3e rc" "$RC" 0
eq "A3e PR opened" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 1

# ── A3f: a lost reland row heals from the marker ────────────────────────────
fresh
printf '[{"number":41,"html_url":"https://github.com/o/r/issues/41","body":"x\\n<!-- main-red-reland: o/r@%s -->\\n"}]\n' "$M" > "$T/list.json"
STUB_LIST="$T/list.json" act mrb_act_culprit "$EP"
eq "A3f rc" "$RC" 0
eq "A3f no issue POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 0
has "A3f row written from the marker" "$(grep '^main_red_reland ' "$T/calls.ledger")" '"issue":41'
has "A3f digest names the found ticket" "$(cat "$T/calls.alert")" "https://github.com/o/r/issues/41"

# ── A8a: the revert conflicts ───────────────────────────────────────────────
fresh conflict
act mrb_act_culprit "$EP"
eq "A8a rc" "$RC" 0
eq "A8a no pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 0
eq "A8a no push" "$(lines "$T/pushes")" 0
eq "A8a one critical" "$(count "$T/calls.alert" '^--severity critical ')" 1
has "A8a critical names #102" "$(grep critical "$T/calls.alert")" "#102"
has "A8a critical names the file" "$(grep critical "$T/calls.alert")" "tests/x-test.sh"
eq "A8a one issue POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
has "A8a ticket flag" "$(jq -r '.body' "$(payload 'POST repos/o/r/issues')" 2>/dev/null)" "did not apply cleanly"
eq "A8a ledger conflict" "$(count "$T/calls.ledger" "^main_red_revert o/r@$M conflict")" 1
eq "A8a no temp dirs left" "$(leftover)" 0

# ── A8b: the revert knob is off ─────────────────────────────────────────────
fresh
MAIN_RED_BISECT_REVERT=0 act mrb_act_culprit "$EP"
eq "A8b rc" "$RC" 0
eq "A8b no pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 0
eq "A8b no push" "$(lines "$T/pushes")" 0
eq "A8b one issue POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
has "A8b ticket flag" "$(jq -r '.body' "$(payload 'POST repos/o/r/issues')" 2>/dev/null)" "revert disabled by knob; revert #102 by hand"

# ── T3x: the ledger is unreachable ──────────────────────────────────────────
fresh
STUB_LEDGER_GET=500 act mrb_act_culprit "$EP"
eq "T3x rc" "$RC" 75
eq "T3x no gh POST" "$(count "$T/calls.gh" '^POST ')" 0
eq "T3x no push" "$(lines "$T/pushes")" 0
nm_ep tests/clock-test.sh
STUB_LEDGER_GET=500 act mrb_act_notmerge "$NEP"
eq "T3x notmerge rc" "$RC" 75
eq "T3x notmerge no gh POST" "$(count "$T/calls.gh" '^POST ')" 0

# ── A2: not a merge ─────────────────────────────────────────────────────────
fresh
nm_ep tests/clock-test.sh
act mrb_act_notmerge "$NEP"
eq "A2 rc" "$RC" 0
eq "A2 stdout" "$(cat "$T/out")" ""
eq "A2 no pulls POST" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 0
eq "A2 no push" "$(lines "$T/pushes")" 0
eq "A2 one quarantine PUT" "$(lines "$T/calls.qput")" 1
eq "A2 PUT row" "$(jq -c '[.repo,.test,.active,.actor]' "$T/calls.qput" 2>/dev/null)" '["o/r","tests/clock-test.sh",1,"main-red-bisect"]'
eq "A2 PUT reason" "$(jq -r '.reason' "$T/calls.qput" 2>/dev/null)" "not-a-merge red since aaaaaaaaaaaa: https://github.com/o/r/actions/runs/4343"
eq "A2 one issue POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
I=$(payload 'POST repos/o/r/issues')
has "A2 title" "$(jq -r '.title' "$I" 2>/dev/null)" "Fix tests/clock-test.sh — red on main with no culprit merge (since aaaaaaaaaaaa)"
has "A2 marker" "$(jq -r '.body' "$I" 2>/dev/null)" "<!-- main-red-fix: o/r@"
has "A2 quarantine row in body" "$(jq -r '.body' "$I" 2>/dev/null)" "tests/clock-test.sh: quarantined"
eq "A2 one warn" "$(count "$T/calls.alert" '^--severity warn --id main-red-fix:o/r:')" 1
eq "A2 no critical" "$(count "$T/calls.alert" critical)" 0
eq "A2 no temp dirs left" "$(leftover)" 0

# ── A2c: a later episode of the same suite set gets its own fix ticket ─────
act mrb_act_notmerge "$NEP"
eq "A2c same episode twice: still one issue POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
printf 'source=nightly\nslug=o/r\nred=%s\ngreen=%s\nrun=4444\nsuites=tests/clock-test.sh\noutcome=notmerge\n' \
  "$(printf 'd%.0s' {1..40})" "$(printf 'c%.0s' {1..40})" > "$T/nep2"
act mrb_act_notmerge "$T/nep2"
eq "A2c later episode rc" "$RC" 0
eq "A2c later episode files a new ticket" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 2
has "A2c new title names the new green" "$(jq -r '.title' "$(payload 'POST repos/o/r/issues')" 2>/dev/null)" "since cccccccccccc"

# ── A2b: the quarantine write fails ─────────────────────────────────────────
fresh
STUB_QPUT_STATUS=500 act mrb_act_notmerge "$NEP"
[ "$RC" != 0 ] && ok || bad "A2b: a failed quarantine PUT must not be rc 0"
eq "A2b issue still POSTed once" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
has "A2b body says so" "$(jq -r '.body' "$(payload 'POST repos/o/r/issues')" 2>/dev/null)" "quarantine write FAILED"

# ── A5: a protected suite ───────────────────────────────────────────────────
fresh
nm_ep tests/merge-queue-ratchet-test.sh
act mrb_act_notmerge "$NEP"
eq "A5 rc" "$RC" 0
eq "A5 no quarantine PUT" "$(lines "$T/calls.qput")" 0
eq "A5 one critical" "$(count "$T/calls.alert" '^--severity critical --id main-red-protected:o/r:tests/merge-queue-ratchet-test.sh ')" 1
eq "A5 ticket filed" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1

# ── M2: with the protected check gone, A5 goes red ──────────────────────────
fresh
( _mrb_protected() { return 1; }; mrb_act_notmerge "$NEP" ) >/dev/null 2>&1
[ "$(lines "$T/calls.qput")" -ge 1 ] && ok || bad "M2: without _mrb_protected the protected suite must be PUT — A5 proves nothing"

# ── the protected matcher, both ways ────────────────────────────────────────
( h="$H"
  for s in tests/clock-test.sh tests/x-test.sh; do _mrb_protected "$s" && echo "protected $s"; done
  for s in tests/merge-queue-ratchet-test.sh tests/switch-ratchet.bh-2320-test.sh tests/gh-rest-no-subshell-lint.sh; do
    _mrb_protected "$s" || echo "unprotected $s"; done ) > "$T/prot"
eq "protected matcher" "$(cat "$T/prot")" ""

# ── A5b / A5c: over the cap, and the cap at 0 ───────────────────────────────
fresh
nm_ep "tests/a1.sh tests/a2.sh tests/a3.sh tests/a4.sh"
act mrb_act_notmerge "$NEP"
eq "A5b rc" "$RC" 0
eq "A5b no quarantine PUT" "$(lines "$T/calls.qput")" 0
eq "A5b one critical" "$(count "$T/calls.alert" '^--severity critical --id main-red-quarantine-cap:o/r:aaaaaaaaaaaa ')" 1
eq "A5b ticket filed" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
fresh
nm_ep tests/clock-test.sh
MAIN_RED_BISECT_QUARANTINE_MAX=0 act mrb_act_notmerge "$NEP"
eq "A5c no quarantine PUT" "$(lines "$T/calls.qput")" 0
eq "A5c one critical" "$(count "$T/calls.alert" '^--severity critical ')" 1

# ── W1: the quarantine writer ───────────────────────────────────────────────
rm -f "$T/calls.qput"
metric_flake_quarantine_put o/r tests/a.sh 1 why me; eq "W1 rc" "$?" 0
eq "W1 body" "$(cat "$T/calls.qput" 2>/dev/null)" '{"repo":"o/r","test":"tests/a.sh","active":1,"reason":"why","actor":"me"}'
rm -f "$T/calls.qput"
metric_flake_quarantine_put o/r tests/a.sh 2 why me; eq "W1 active=2 rc" "$?" 1
eq "W1 active=2 no request" "$(lines "$T/calls.qput")" 0

# ── C1: mc_is_harness_pr ────────────────────────────────────────────────────
for c in "main-red-revert/pr-102-abc 0" "ticket/bh-1 0" "feature/x 1" "feature/main-red-revert 1" "main-red-revertx/a 1"; do
  mc_is_harness_pr "${c% *}" ""; eq "C1 ${c% *}" "$?" "${c#* }"
done

# ── bad episodes abort before any write ─────────────────────────────────────
fresh
printf 'slug=o/r\nsuites=tests/x-test.sh\n' > "$T/bad"
act mrb_act_culprit "$T/bad"; eq "no culprit rc" "$RC" 1
( unset HARNESS H; mrb_act_notmerge "$NEP" ) >/dev/null 2>&1; eq "no root rc" "$?" 1
eq "bad episodes wrote nothing" "$(lines "$T/calls.gh")$(lines "$T/calls.ledger")" "00"

echo "mrb-act: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
