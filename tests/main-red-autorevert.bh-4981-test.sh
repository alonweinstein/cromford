#!/bin/bash
# tests/main-red-autorevert.bh-4981-test.sh — BH-4981 (BH-4974.3): the
# main-red safety net. A red daily full run on main (a workflow_dispatch run of
# harness-ci.yml) is a third red source for main-red-bisect; the revert of the
# culprit merge goes through the hotfix lane; and one map-gap ticket is filed
# per culprit when the queue gave it a scoped lane that missed a red suite.
#
# DRIVEN, NOT GREPPED. The detect and act libs are the real ones, with the real
# gh_rest, bin/jobs-client.sh, queue-partition.sh and hotfix-lib.sh. E1/E2 run
# the real bin/main-red-bisect.sh in a scratch harness whose bin closure comes
# from scratch_install_closure. Only these are stubs:
#   gh        on PATH; REST (`api -i -X M path`) logs `M path` to calls.gh and
#             keeps every --input body as payload.<n> (calls.pay); bytes
#             (`api path`) answer $T/bytes/<key>. GETs answer $T/rest/<key>,
#             a status in $T/st-<key>, else 404.
#   curl      on PATH; a stateful jobs-worker ledger (calls.ledger)
#   $H/bin/test-impact.sh   prints $T/impact-rows: the map qp_impact reads
#   lane-alert, lead-verdict   argv to calls.alert / calls.verdict
#   E1/E2's MAIN_RED_BISECT_FIXTURE replaces mrb_probe and mrb_bisect (the
#   bisect answers M) and the token mint, nothing else.
#
# The scratch origin: C0, then merges #101 (a.txt), #102 = M (bin/y.sh, which
# tests/x-test.sh sources, now fails), #103 (c.txt), and for E2 #104.
#
#   F1  a red dispatch run at M3 -> one full-<run>.ep, source=full, green=C0
#   F2  the newest dispatch run succeeded -> no file
#   F3  the runs GET answers 404 -> rc 0, no file; 500 -> rc 75
#   F4  only a push-event green exists -> outcome=noanchor (the event filter)
#   F5  still_red: rc 0 on the F1 episode, rc 1 after a newer dispatch success
#   E1  bin/main-red-bisect.sh end to end: one revert PR, one labels POST,
#       one map-gap issue, main_red_attrib row `gap`
#   E2  a second red full run on the same M opens nothing new
#   R1  the labels payload is ["fix-main-red","hotfix"]; HOTFIX_LABEL=urgent
#   G1  the gap ticket body; G2 serial lane; G3 always-suite; G4 mapped suite
#       and the prefix case; G5 the attrib detail; G6 a refused issue POST
#   M1  no hotfix label -> R1 red; M2 no attrib ledger read -> E2 red;
#   M3  no event filter -> F4 red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-autorevert.bh-4981-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in: $2" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "main-red-autorevert: SKIPPED — jq missing"; exit 0; }

DETECT="$DIR/bin/lib/mrb-detect.sh"
PROBE="$DIR/bin/lib/mrb-probe.sh"
ACT="$DIR/bin/lib/mrb-act.sh"
H="$T/h"; SB="$T/sb"; S=o/r
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-10-01T00:00:00Z' GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
export GIT_CONFIG_NOSYSTEM=1 HOME="$T" GH_ETAG=0 MRBT="$T"

# ── stubs ────────────────────────────────────────────────────────────────────
mkdir -p "$SB" "$H/bin" "$H/catalog" "$H/env" "$H/logs" "$H/state" "$H/flags" "$T/tmp"
: > "$H/env/global.env"
echo local > "$H/state/box-name"
printf 'tests/always-test.sh\n' > "$H/catalog/test-impact-always.txt"
cp "$DIR/tests/lib/rest-emit.sh" "$SB/restpr"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.alert"\n' "$T" > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.verdict"\n' "$T" > "$H/bin/lead-verdict.sh"
printf '#!/bin/bash\necho "$*" >> "%s/calls.impact"\ncat "%s/impact-rows"\n' "$T" "$T" > "$H/bin/test-impact.sh"
cat > "$SB/gh" <<'SH'
#!/bin/bash
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
[ "${1:-}" = api ] || exit 1
shift
if [ "${1:-}" != -i ]; then          # gh api <path>: log bytes
  printf 'BYTES %s\n' "$1" >> "$MRBT/calls.gh"
  k=$(key "$1")
  [ -f "$MRBT/bytes/$k" ] && { cat "$MRBT/bytes/$k"; exit 0; }
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
m=GET p="" in=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) ;;
    -X) m="$2"; shift ;;
    --input) in="$2"; shift ;;
    -F|-f|-H) shift ;;
    *) [ -z "$p" ] && p="$1" ;;
  esac; shift
done
printf '%s %s\n' "$m" "$p" >> "$MRBT/calls.gh"
if [ -n "$in" ]; then
  n=$(( $(cat "$MRBT/pay.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MRBT/pay.n"
  cp "$in" "$MRBT/payload.$n"; printf '%s %s %s\n' "$n" "$m" "$p" >> "$MRBT/calls.pay"
fi
k=$(key "$p")
if [ "$m" = GET ] && [ -f "$MRBT/st-$k" ]; then restpr --raw "$(cat "$MRBT/st-$k")" '{"message":"x"}'; exit 1; fi
if [ "$m" = GET ] && [ -f "$MRBT/rest/$k" ]; then restpr --raw 200 "$(cat "$MRBT/rest/$k")"; exit 0; fi
case "$m $p" in
  "POST repos/o/r/pulls") restpr --raw 201 '{"number":500,"html_url":"https://github.com/o/r/pull/500"}' ;;
  "GET repos/o/r/pulls?"*) restpr --raw 200 '[]' ;;
  "POST repos/o/r/issues/"*/labels) restpr --raw 200 '[{"name":"x"}]' ;;
  "GET repos/o/r/issues") restpr --raw 200 '[]' ;;
  "POST repos/o/r/issues")
    if [ -f "$MRBT/gap-500" ] && grep -q 'main-red-mapgap' "$in"; then restpr --raw 500 '{"message":"no"}'; exit 1; fi
    c=$(grep -c '^POST repos/o/r/issues$' "$MRBT/calls.gh")
    restpr --raw 201 "{\"number\":60$c,\"html_url\":\"https://github.com/o/r/issues/60$c\"}" ;;
  *) restpr --raw 404 '{"message":"Not Found"}'; exit 1 ;;
esac
exit 0
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
    f="$T/ledger/\$(printf '%s' "\${p#*\\?}" | sha1sum | cut -c1-16)"
    [ -f "\$f" ] && answer "{\"ledger\":\$(cat "\$f")}" 200
    answer '{"error":"not found"}' 404 ;;
  "PUT /api/ledger")
    q=\$(printf '%s' "\$d" | jq -r '"kind="+(.kind|@uri)+"&key="+(.key|@uri)')
    printf '%s' "\$d" | jq -c '{status, detail: (.detail // "")}' > "$T/ledger/\$(printf '%s' "\$q" | sha1sum | cut -c1-16)"
    printf '%s' "\$d" | jq -r '"\(.kind) \(.key) \(.status) \(.detail // "")"' >> "$T/calls.ledger"
    answer '{"ok":true}' 200 ;;
  *) answer '{}' 404 ;;
esac
SH
chmod +x "$SB"/* "$H/bin/"*.sh
export PATH="$SB:$PATH" HARNESS="$H" JOBS_URL=http://stub HARNESS_SECRET=x JOBS_RETRIES=0 TMPDIR="$T/tmp"
key()   { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
rest()  { mkdir -p "$T/rest"; printf '%s' "$2" > "$T/rest/$(key "$1")"; }
st()    { printf '%s' "$2" > "$T/st-$(key "$1")"; }
bytes() { mkdir -p "$T/bytes"; cat > "$T/bytes/$(key "$1")"; }
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1" || true; else echo 0; fi; }
payload() { # payload <METHOD path ERE> -> the last matching payload file
  local n; n=$(grep -E "^[0-9]+ $1\$" "$T/calls.pay" 2>/dev/null | tail -1 | cut -d' ' -f1)
  [ -n "$n" ] && printf '%s' "$T/payload.$n"
}
attrib() { grep "^main_red_attrib $S@$M " "$T/calls.ledger" 2>/dev/null | tail -1; }
attrib_detail() { attrib | cut -d' ' -f4-; }

# ── the scratch origin ──────────────────────────────────────────────────────
G() { git -C "$T/w" "$@" >/dev/null 2>&1 || { echo "setup: git $* failed"; exit 1; }; }
merge() { # merge <n> <branch> <file> <content> <title>
  G checkout -q -b "$2" main
  mkdir -p "$T/w/$(dirname "$3")"; printf '%s\n' "$4" > "$T/w/$3"; G add -A; G commit -qm "work $1"
  G checkout -q main; G merge -q --no-ff "$2" -m "Merge pull request #$1 from o/$2" -m "$5"
}
git init -q --bare -b main "$T/origin.git" || exit 1
git init -q -b main "$T/w" || exit 1
mkdir -p "$T/w/tests" "$T/w/bin"
printf '#!/bin/bash\n. "$(dirname "$0")/../bin/y.sh"\ny\n' > "$T/w/tests/x-test.sh"
printf 'y() { return 0; }\n' > "$T/w/bin/y.sh"
G add -A; G commit -qm C0
C0=$(git -C "$T/w" rev-parse HEAD)
merge 101 a a.txt a "Add a"
M1=$(git -C "$T/w" rev-parse HEAD)
merge 102 b bin/y.sh 'y() { return 1; }' "Change y"
M=$(git -C "$T/w" rev-parse HEAD); M12=${M:0:12}
merge 103 c c.txt c "Add c"
M3=$(git -C "$T/w" rev-parse HEAD)
G remote add origin "$T/origin.git"; G push -q origin main
cat > "$T/origin.git/hooks/pre-receive" <<SH
#!/bin/bash
while read -r o n r; do echo "\$r" >> "$T/pushes"; done
SH
chmod +x "$T/origin.git/hooks/pre-receive"
git clone -q "$T/origin.git" "$T/repos/r" || exit 1
REPO="$T/repos/r"

FULL="repos/$S/actions/workflows/harness-ci.yml/runs?branch=main&event=workflow_dispatch&status=completed&per_page=1"
FGREEN="repos/$S/actions/workflows/harness-ci.yml/runs?status=success&branch=main&event=workflow_dispatch&per_page=100"
PGREEN="repos/$S/actions/workflows/harness-ci.yml/runs?status=success&branch=main&per_page=100"
runjson() { # runjson <id> <sha> <conclusion> [event]
  jq -nc --argjson id "$1" --arg h "$2" --arg c "$3" --arg e "${4:-workflow_dispatch}" \
    '{id:$id,head_sha:$h,head_branch:"main",event:$e,workflow_id:7,name:"Harness CI",
      path:".github/workflows/harness-ci.yml",status:"completed",conclusion:$c}'
}
runs() { local r a=(); for r in "$@"; do a+=("$r"); done; printf '%s\n' ${a[@]+"${a[@]}"} | jq -sc '{total_count:length, workflow_runs:.}'; }
JOBS='{"total_count":3,"jobs":[
 {"id":554,"name":"decisions","conclusion":"failure"},
 {"id":555,"name":"Tests, traced (shard 1/4)","conclusion":"failure"},
 {"id":556,"name":"Tests, traced (shard 2/4)","conclusion":"success"}]}'
full_fixture() { # full_fixture <run> <red-sha>
  rest "$FULL" "$(runs "$(runjson "$1" "$2" failure)")"
  rest "repos/$S/actions/runs/$1/jobs?filter=latest&per_page=100" "$JOBS"
  printf '2026-10-07T03:00:01.1Z --- tests/a-test.sh rc=0 2s\n2026-10-07T03:00:02.1Z --- tests/x-test.sh rc=1 3s\n' \
    | bytes "repos/$S/actions/jobs/555/logs"
  rest "$FGREEN" "$(runs "$(runjson 8000 "$C0" success)")"
}
reset() { # a clean world: no fixtures, no ledger, no calls
  scratch_rm "$T/rest"; scratch_rm "$T/bytes"; scratch_rm "$T/out"; scratch_rm "$T/ledger"
  rm -f "$T"/st-* "$T"/calls.* "$T"/payload.* "$T/pay.n" "$T/pushes" "$T/gap-500"
  mkdir -p "$T/out"
  printf 'tests/other-test.sh\tsource\tbin/y.sh\n' > "$T/impact-rows"
  : > "$H/env/global.env"
}
detect() { # detect [lib] — one detect tick on the clone, rc to $T/rc
  ( . "$PROBE"; . "${1:-$DETECT}"; mrb_detect_episodes "$S" "$REPO" "$T/out" ) 2> "$T/err"
  echo $? > "$T/rc"
}
still() { ( . "$PROBE"; . "$DETECT"; mrb_episode_still_red "$1" ) 2>> "$T/err"; echo $?; }
val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
files() { find "$T/out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }

# ── F1 ───────────────────────────────────────────────────────────────────────
reset; full_fixture 9001 "$M3"; detect
EP="$T/out/full-9001.ep"
eq "F1 rc" "$(cat "$T/rc")" 0
eq "F1 files" "$(files)" "full-9001.ep "
eq "F1 source" "$(val "$EP" source)" full
eq "F1 red" "$(val "$EP" red)" "$M3"
eq "F1 green" "$(val "$EP" green)" "$C0"
eq "F1 suites" "$(val "$EP" suites)" tests/x-test.sh
eq "F1 wf" "$(val "$EP" wf)" harness-ci.yml
eq "F1 run" "$(val "$EP" run)" 9001
eq "F1 job" "$(val "$EP" job)" 555
eq "F1 outcome empty" "$(grep -c '^outcome=$' "$EP" 2>/dev/null)" 1
eq "F1 passing shard log unread" "$(count "$T/calls.gh" 'actions/jobs/556/logs')" 0
cp "$EP" "$T/f1.ep" 2>/dev/null

# ── F2 ───────────────────────────────────────────────────────────────────────
reset; full_fixture 9001 "$M3"; rest "$FULL" "$(runs "$(runjson 9002 "$M3" success)")"; detect
eq "F2 rc" "$(cat "$T/rc")" 0
eq "F2 no file" "$(files)" ""

# ── F3 ───────────────────────────────────────────────────────────────────────
reset; detect
eq "F3 404 rc" "$(cat "$T/rc")" 0
eq "F3 404 no file" "$(files)" ""
eq "F3 the dispatch runs were asked for" "$(count "$T/calls.gh" "^GET $FULL\$")" 1
reset; st "$FULL" 500; detect
eq "F3 500 rc" "$(cat "$T/rc")" 75
eq "F3 500 no file" "$(files)" ""

# ── F4: only a push-event green ─────────────────────────────────────────────
f4() {
  reset; full_fixture 9001 "$M3"
  rest "$FGREEN" '{"total_count":0,"workflow_runs":[]}'
  rest "$PGREEN" "$(runs "$(runjson 7000 "$C0" success push)")"
  detect "${1:-$DETECT}"
}
f4
eq "F4 rc" "$(cat "$T/rc")" 0
eq "F4 noanchor" "$(val "$T/out/full-9001.ep" outcome)" noanchor
eq "F4 green empty" "$(val "$T/out/full-9001.ep" green)" ""

# ── M3: without the event filter the push green anchors, F4 goes red ──────
sed 's/&event=\$6//' "$DETECT" > "$T/m3.sh"
if cmp -s "$DETECT" "$T/m3.sh"; then bad "M3: the lib has no event filter to remove"; fi
f4 "$T/m3.sh"
[ "$(val "$T/out/full-9001.ep" outcome)" != noanchor ] && ok || bad "M3: without the event filter F4 must anchor on the push green — F4 proves nothing"

# ── F5: still_red ───────────────────────────────────────────────────────────
reset; full_fixture 9001 "$M3"
eq "F5 still red" "$(still "$T/f1.ep")" 0
rest "$FULL" "$(runs "$(runjson 9003 "$M3" success)")"
eq "F5 green again is stale" "$(still "$T/f1.ep")" 1
st "$FULL" 500
eq "F5 failed read is stale" "$(still "$T/f1.ep")" 1

# ── the act cases, direct (R1, G1-G6) ───────────────────────────────────────
act_ep() { # act_ep [pr_branch] -> $AEP, a bisected full episode for M
  AEP="$T/aep"
  printf 'source=full\nslug=%s\nred=%s\ngreen=%s\nrun=9001\nwf=harness-ci.yml\njob=555\nsuites=%s\noutcome=\n' \
    "$S" "$M3" "$C0" "${SUITES:-tests/x-test.sh}" > "$AEP"
  printf 'culprit=%s\npr=102\npr_title=Change y\npr_branch=%s\nsteps=3\noutcome=culprit\n' "$M" "${1:-b}" >> "$AEP"
}
act() { # act [lib] — one mrb_act_culprit in a subshell; rc to RC
  ( . "$DIR/bin/jobs-client.sh"; . "${LIBX:-$ACT}"; gh_default_auth_for_slug() { :; }
    eval "${PRE:-:}"
    MRB_REPO_DIR="$REPO" mrb_act_culprit "$AEP" ) > "$T/out.txt" 2> "$T/err"
  RC=$?
}
fresh_remote() { # the clone's origin back to M3, no revert branches
  git -C "$T/origin.git" for-each-ref --format='%(refname)' refs/heads/main-red-revert | while read -r r; do
    git -C "$T/origin.git" update-ref -d "$r"; done
  git -C "$REPO" fetch -q --prune origin
}

# R1
reset; fresh_remote; act_ep; act
eq "R1 rc" "$RC" 0
eq "R1 one labels POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues/500/labels$')" 1
eq "R1 labels" "$(jq -c '.labels' "$(payload 'POST repos/o/r/issues/500/labels')" 2>/dev/null)" '["fix-main-red","hotfix"]'
reset; fresh_remote; echo 'HOTFIX_LABEL=urgent' > "$H/env/global.env"; act
eq "R1 HOTFIX_LABEL=urgent" "$(jq -c '.labels' "$(payload 'POST repos/o/r/issues/500/labels')" 2>/dev/null)" '["fix-main-red","urgent"]'

# M1: the lib without the hotfix label
sed 's/else \[\$l, \$x\] end/else [$l] end/' "$ACT" > "$T/m1.sh"
if cmp -s "$ACT" "$T/m1.sh"; then bad "M1: the lib has no hotfix label to remove"; fi
reset; fresh_remote; LIBX="$T/m1.sh" act
[ "$(jq -c '.labels' "$(payload 'POST repos/o/r/issues/500/labels')" 2>/dev/null)" != '["fix-main-red","hotfix"]' ] && ok \
  || bad "M1: without the hotfix label R1 must go red — R1 proves nothing"

# G1 + G5: the gap ticket and the attrib row
reset; fresh_remote; act
eq "G1 rc" "$RC" 0
eq "G1 two issue POSTs (re-land, map gap)" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 2
GP=$(payload 'POST repos/o/r/issues')
GB=$(jq -r '.body' "$GP" 2>/dev/null)
has "G1 marker" "$GB" "<!-- main-red-mapgap: $S@$M -->"
has "G1 title" "$(jq -r '.title' "$GP" 2>/dev/null)" "Impact map gap: #102 reached tests/x-test.sh"
has "G1 names the changed file" "$GB" "bin/y.sh"
has "G1 names the missed suite" "$GB" "tests/x-test.sh"
has "G1 names the lane" "$GB" "scoped"
has "G1 names the scope" "$GB" "tests/other-test.sh"
has "G1 PR link" "$GB" "https://github.com/o/r/pull/102"
has "G1 run link" "$GB" "https://github.com/o/r/actions/runs/9001"
has "G1 the rule line" "$GB" "Fix the impact map (bin/test-impact.sh) so these files reach these suites; the selection rule is not the bug."
eq "G1 issue labels" "$(jq -c '.labels' "$GP" 2>/dev/null)" '["ai-build"]'
eq "G1 mapgap row filed" "$(count "$T/calls.ledger" "^main_red_mapgap $S@$M filed ")" 1
eq "G5 attrib status" "$(attrib | cut -d' ' -f3)" gap
D=$(attrib_detail)
eq "G5 pr" "$(jq -r '.pr' <<<"$D" 2>/dev/null)" 102
eq "G5 lane" "$(jq -r '.lane' <<<"$D" 2>/dev/null)" scoped
eq "G5 risk_tier" "$(jq -r '.risk_tier' <<<"$D" 2>/dev/null)" unknown
eq "G5 scopes" "$(jq -c '.scopes' <<<"$D" 2>/dev/null)" '["tests/other-test.sh"]'
eq "G5 missed" "$(jq -c '.missed' <<<"$D" 2>/dev/null)" '["tests/x-test.sh"]'
eq "G5 revert_url" "$(jq -r '.revert_url' <<<"$D" 2>/dev/null)" https://github.com/o/r/pull/500
eq "G5 gap_url" "$(jq -r '.gap_url' <<<"$D" 2>/dev/null)" https://github.com/o/r/issues/602
eq "G5 run" "$(jq -r '.run' <<<"$D" 2>/dev/null)" 9001
eq "G5 red" "$(jq -r '.red' <<<"$D" 2>/dev/null)" "$M3"
eq "G5 the qp map saw M's files" "$(grep -c . "$T/calls.impact" 2>/dev/null)" 1
# the same culprit again: nothing new, and the step is not recomputed
act
eq "G1 again rc" "$RC" 0
eq "G1 again no new issue" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 2
eq "G1 again one attrib row write" "$(count "$T/calls.ledger" "^main_red_attrib ")" 1

# G2: a serial lane is no gap
reset; fresh_remote; PRE='qp_impact() { echo "lane=serial reason=too-many-files (30 > 25)"; }' act
eq "G2 rc" "$RC" 0
eq "G2 only the re-land issue" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
eq "G2 attrib serial" "$(attrib | cut -d' ' -f3)" serial
eq "G2 reason" "$(jq -r '.reason' <<<"$(attrib_detail)" 2>/dev/null)" "too-many-files (30 > 25)"

# G3: a red always-suite is no gap
reset; fresh_remote; SUITES=tests/always-test.sh act_ep; act
eq "G3 only the re-land issue" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
eq "G3 attrib no-gap" "$(attrib | cut -d' ' -f3)" no-gap

# G4: the map reached the suite; a prefix-only scope did not
reset; fresh_remote; act_ep
printf 'tests/x-test.sh\tsource\tbin/y.sh\n' > "$T/impact-rows"; act
eq "G4 mapped: only the re-land issue" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
eq "G4 mapped: attrib no-gap" "$(attrib | cut -d' ' -f3)" no-gap
reset; fresh_remote
printf 'tests/x-test.sh.bak\tsource\tbin/y.sh\n' > "$T/impact-rows"; act
eq "G4 prefix scope: a gap" "$(attrib | cut -d' ' -f3)" gap
eq "G4 prefix scope: the gap issue" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 2

# G4b: the qp lib unavailable -> unknown, a warn, no ticket
reset; fresh_remote; PRE='unset -f qp_impact; _QP_LOADED=1' act
eq "G4b only the re-land issue" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 1
eq "G4b attrib unknown" "$(attrib | cut -d' ' -f3)" unknown
eq "G4b warn" "$(count "$T/calls.alert" "^--severity warn --id main-red-mapgap-unknown:$S:$M12 ")" 1

# G4c: the culprit is a revert -> no map-gap step at all
reset; fresh_remote; act_ep main-red-revert/pr-90-aaaaaaaaaaaa; act
eq "G4c no attrib row" "$(count "$T/calls.ledger" '^main_red_attrib ')" 0
eq "G4c no issue" "$(count "$T/calls.gh" '^POST repos/o/r/issues$')" 0
act_ep

# G6: the gap issue POST is refused -> rc 1, no attrib row; the retry files once
reset; fresh_remote; : > "$T/gap-500"; act
eq "G6 rc" "$RC" 1
eq "G6 no attrib row" "$(count "$T/calls.ledger" '^main_red_attrib ')" 0
rm -f "$T/gap-500"; act
eq "G6 retry rc" "$RC" 0
eq "G6 retry attrib gap" "$(attrib | cut -d' ' -f3)" gap
eq "G6 one gap issue created" "$(grep -l 'main-red-mapgap' "$T"/payload.* 2>/dev/null | wc -l | tr -d ' ')" 2
eq "G6 one revert PR" "$(count "$T/calls.gh" '^POST repos/o/r/pulls$')" 1

# ── E1/E2: the real lane ────────────────────────────────────────────────────
scratch_install_closure bin/main-red-bisect.sh "$H" >/dev/null || bad "E: closure install failed"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "E: jobs-client closure install failed"
LANE="$H/bin/main-red-bisect.sh"
cat > "$T/fixture.sh" <<SH
mrb_probe() { case "\$2" in $C0) echo green ;; *) echo red ;; esac; }
mrb_bisect() { echo "found $M 1"; }
gh_default_auth_for_slug() { :; }
# M2 only: the mutated act lib, loaded over the installed one
[ -z "\${MRB_LIB_OVERRIDE:-}" ] || . "\$MRB_LIB_OVERRIDE"
SH
lane() {
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 MAIN_RED_BISECT_FIXTURE="$T/fixture.sh" \
    REPOS_ROOT="$T/repos" HARNESS_REPO="$S" MAIN_RED_BISECT_REPOS="$S" JOBS_URL=http://stub HARNESS_SECRET=x \
    JOBS_RETRIES=0 GH_ETAG=0 MRBT="$T" TMPDIR="$T/tmp" MRB_LIB_OVERRIDE="${MRB_LIB_OVERRIDE:-}" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1 \
    bash "$LANE" > "$T/lane.out" 2>&1
}
e_run() { # e_run — E1 then E2 against the lane in $H; sets E1_* / E2_*
  reset; fresh_remote; full_fixture 9001 "$M3"
  lane
  E1_PULLS=$(count "$T/calls.gh" '^POST repos/o/r/pulls$')
  E1_ISSUES=$(count "$T/calls.gh" '^POST repos/o/r/issues$')
  E1_ATTRIB=$(count "$T/calls.ledger" '^main_red_attrib ')
  # E2: a later merge, a new red full run on it, the same suite, the bisect again answers M
  git -C "$T/w" checkout -q main
  if [ -z "${M4:-}" ]; then merge 104 d d.txt d "Add d"; M4=$(git -C "$T/w" rev-parse HEAD); G push -q origin main; fi
  git -C "$REPO" fetch -q origin
  full_fixture 9100 "$M4"
  lane
  E2_PULLS=$(count "$T/calls.gh" '^POST repos/o/r/pulls$')
  E2_ISSUES=$(count "$T/calls.gh" '^POST repos/o/r/issues$')
  E2_ATTRIB=$(count "$T/calls.ledger" '^main_red_attrib ')
}
e_run
eq "E1 one revert PR" "$E1_PULLS" 1
eq "E1 revert head" "$(jq -r '.head' "$(payload 'POST repos/o/r/pulls')" 2>/dev/null)" "main-red-revert/pr-102-$M12"
eq "E1 pushed the revert branch" "$(head -1 "$T/pushes" 2>/dev/null)" "refs/heads/main-red-revert/pr-102-$M12"
eq "E1 one labels POST" "$(count "$T/calls.gh" '^POST repos/o/r/issues/500/labels$')" 1
eq "E1 labelled hotfix" "$(jq -c '.labels' "$(payload 'POST repos/o/r/issues/500/labels')" 2>/dev/null)" '["fix-main-red","hotfix"]'
eq "E1 two issues (re-land, map gap)" "$E1_ISSUES" 2
eq "E1 one map-gap issue" "$(grep -l "<!-- main-red-mapgap: $S@$M -->" "$T"/payload.* 2>/dev/null | wc -l | tr -d ' ')" 1
eq "E1 attrib gap" "$(grep "^main_red_attrib $S@$M " "$T/calls.ledger" | head -1 | cut -d' ' -f3)" gap
eq "E1 one attrib row write" "$E1_ATTRIB" 1
eq "E1 episode acted" "$(count "$T/calls.ledger" "^main_red_bisect $S@$M3@[0-9a-f]* culprit ")" 1
eq "E2 no new revert PR" "$E2_PULLS" 1
eq "E2 no new issue" "$E2_ISSUES" 2
eq "E2 no second attrib row" "$E2_ATTRIB" 1
eq "E2 the second episode was acted" "$(count "$T/calls.ledger" "^main_red_bisect $S@$M4@[0-9a-f]* culprit ")" 1
[ "$FAIL" = 0 ] || { echo "--- lane log"; cat "$H/logs/main-red-bisect.log" 2>/dev/null; cat "$T/lane.out"; }

# M2: the lib without the main_red_attrib read -> E2 recomputes and rewrites
sed 's/job_ledger_row main_red_attrib "\$lkey"/(exit 2)/' "$H/bin/lib/mrb-act.sh" > "$H/bin/lib/m2-mrb-act.sh"
if cmp -s "$H/bin/lib/mrb-act.sh" "$H/bin/lib/m2-mrb-act.sh"; then bad "M2: the lib has no main_red_attrib read to remove"; fi
scratch_rm "$T/repos/r"; git clone -q "$T/origin.git" "$T/repos/r"
git -C "$REPO" reset -q --hard "$M3"
M4=$(git -C "$T/w" rev-parse HEAD)
MRB_LIB_OVERRIDE="$H/bin/lib/m2-mrb-act.sh" e_run
[ "$E2_ATTRIB" -ge 2 ] && ok || bad "M2: without the attrib read E2 must write a second attrib row (got $E2_ATTRIB) — E2 proves nothing"

echo "main-red-autorevert: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
