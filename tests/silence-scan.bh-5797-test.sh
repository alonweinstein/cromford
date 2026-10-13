#!/bin/bash
# tests/silence-scan.bh-5797-test.sh — BH-5797 scope 3: the silence check. A
# diff that widens a public-leak allow-list (a KNOWN_FAKE_* entry in bin/share,
# a gitleaks marker) gets the needs-human label and one comment, and no lead
# review is asked. Any other allow-list line or marker goes into the lead
# review request notes for the Opus lead to judge, and a marker with no reason
# on its line fails the builder verify step (bin/marker-reason-lint.sh).
#
#   S1  an added scratch-closure marker line is a hit
#   S2  an added KNOWN_FAKE_IDENTIFIERS entry (bin/share, hunk inside the set)
#       is a hit (ticket acceptance test 2)
#   S2c the real bin/share/mapping.py with a -U3 patch: an entry just under
#       the KNOWN_FAKE_SECRETS or KNOWN_FAKE_CREDENTIALS opener is a human hit
#       although the @@ header names an earlier definition; a string inside a
#       def is no hit (lead review lr-5811)
#   S3  an added line in an allow-list or baseline file is a hit, and a file
#       GitHub shows no patch for is a hit too
#   S4  the negative list: a removed marker line, a context line, a path with
#       "allow" inside a word, a suite named *-allowlist-test.sh, and the
#       pattern file itself are no hit; an unparseable compare is rc 2, and
#       one with no files list is rc 1 (GitHub showed no file)
#   S1-S4 also check each hit's route (human or lead): a KNOWN_FAKE_* entry,
#       a gitleaks marker, a leak or identifier allow-list and the gitleaks
#       ignore file are human; other ratchet baselines and markers are lead
#   S5  the enqueue tick on a human hit: needs-human label, one comment naming the
#       reason, no POST /api/lead-reviews, skipped_silence=1; a second tick
#       posts nothing again
#   S6  a human removed the label: the next tick requests the review, and a
#       later tick with the same lines does not label again
#   S7  LEAD_REVIEW_SILENCE_CHECK=0: requested as before, no label
#   S8  the label POST fails: nothing requested, no comment, no state row,
#       counted unreadable
#   S9  no hit: requested as before, no label read or write
#   S10 no rules file on the box: no check, requested as before
#   S11 a lead hit: requested, no label, the request notes carry the marker
#       line; the re-confirm on the next tick sends the same notes
#   R1  bin/marker-reason-lint.sh: a bare added determinism marker is rc 1 and
#       named; one with a reason, one in a .md file and a removed one are rc 0
#   R2  the rules pack carries the marker-reason component
# Marker text is built from pieces so this suite's own lines are no hit.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/silence-scan.bh-5797-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "silence-scan: jq is required"; exit 2; }

LIB="$DIR/bin/lib/silence-scan.sh"
CAT="$DIR/catalog/silence-markers.tsv"
SCA="scratch-closure-""allow"; DOK="determinism: ""ok"; KFI="KNOWN_FAKE_""IDENTIFIERS"

# cmp <out> <files-json> — a compare answer with one commit and these files
cmp() { jq -nc --argjson f "$2" '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat"}}], files:$f}' > "$1"; }
# file <path> <patch> — one compare file entry
file() { jq -nc --arg p "$1" --arg d "$2" '{filename:$p, status:"modified", patch:$d}'; }
scan() { ( . "$LIB" && ss_scan "$1" "$CAT" ); }

[ -r "$LIB" ] && bash -n "$LIB" && ok || bad "bin/lib/silence-scan.sh is missing or does not parse"
[ -r "$CAT" ] && ok || bad "catalog/silence-markers.tsv is missing"

# ── S1 ──────────────────────────────────────────────────────────────────────
cmp "$T/s1.json" "[$(file tests/x-test.sh $'@@ -1,2 +1,3 @@\n #!/bin/bash\n+cp a b  # '"$SCA"$': one lib\n echo')]"
out=$(scan "$T/s1.json"); rc=$?
[ "$rc" = 0 ] && grep -q $'^lead\ttests/x-test.sh' <<<"$out" && ok || bad "S1 a scratch-closure marker is no hit (rc $rc): $out"
cmp "$T/s1b.json" "[$(file tests/y-test.sh $'@@ -1,2 +1,3 @@\n x\n+sleep 0.2 # '"$DOK"$' bounded wait\n y')]"
out=$(scan "$T/s1b.json"); rc=$?
[ "$rc" = 0 ] && ok || bad "S1 a determinism marker is no hit (rc $rc): $out"

# ── S2 (acceptance test 2) ──────────────────────────────────────────────────
cmp "$T/s2.json" "[$(file bin/share/mapping.py $'@@ -540,6 +540,7 @@ '"$KFI"$' = {\n     "acme-demo",\n+    "demo-client-x",\n     "zz-fixture",')]"
out=$(scan "$T/s2.json"); rc=$?
[ "$rc" = 0 ] && grep -q $'^human\tbin/share/mapping.py: .*demo-client-x' <<<"$out" && ok || bad "S2 a $KFI entry is no hit (rc $rc): $out"
cmp "$T/s2b.json" "[$(file bin/share/mapping.py $'@@ -10,6 +10,7 @@ def map_paths():\n     a = 1\n+    "just-a-string",\n     b = 2')]"
out=$(scan "$T/s2b.json"); rc=$?
[ "$rc" = 1 ] && ok || bad "S2 a string line outside the known-fakes set is a hit (rc $rc): $out"

# S2c (lead review lr-5811): the real bin/share/mapping.py, an entry added just
# under a set opener. GitHub's -U3 patch puts an EARLIER definition in the @@
# header there (FIXTURE_MARKERS, def project_for_env_prefix), so the set name
# must come from the context line that opens it.
realpatch() { # realpatch <after-line-regex> <entry> <out> — a compare from git diff -U3
  local m="$T/mapping.mod.py"
  awk -v re="$1" -v e="$2" '{ print } !d && $0 ~ re { print e; d = 1 }' "$DIR/bin/share/mapping.py" > "$m"
  git diff --no-index -U3 "$DIR/bin/share/mapping.py" "$m" | awk '/^@@/{f=1} f' > "$T/real.patch"
  cmp "$3" "[$(jq -nc --rawfile d "$T/real.patch" '{filename:"bin/share/mapping.py", status:"modified", patch:($d | rtrimstr("\n"))}')]"
}
realpatch '^KNOWN_FAKE_SECRETS = [{]' '    "demo-secret-fixture-1",' "$T/s2c.json"
grep -q '^@@ .*FIXTURE_MARKERS' "$T/real.patch" && ok || bad "S2c precondition: the -U3 header is not the earlier FIXTURE_MARKERS line: $(head -1 "$T/real.patch")"
grep -q $'^human\tbin/share/mapping.py: .*demo-secret-fixture-1' <<<"$(scan "$T/s2c.json")" \
  && ok || bad "S2c an entry under KNOWN_FAKE_SECRETS is no human hit: $(scan "$T/s2c.json")"
realpatch '^KNOWN_FAKE_CREDENTIALS = [{]' '    "demo-cred-fixture-2",' "$T/s2d.json"
grep -q '^@@ .*def project_for_env_prefix' "$T/real.patch" && ok || bad "S2c precondition: the -U3 header is not def project_for_env_prefix: $(head -1 "$T/real.patch")"
grep -q $'^human\tbin/share/mapping.py: .*demo-cred-fixture-2' <<<"$(scan "$T/s2d.json")" \
  && ok || bad "S2c an entry under KNOWN_FAKE_CREDENTIALS is no human hit: $(scan "$T/s2d.json")"
realpatch '^def project_for_env_prefix' '    "just-a-string-in-a-def",' "$T/s2e.json"
[ "$(scan "$T/s2e.json" >/dev/null; echo $?)" = 1 ] && ok || bad "S2c a string line inside a def is a hit: $(scan "$T/s2e.json")"

# ── S3 ──────────────────────────────────────────────────────────────────────
cmp "$T/s3.json" "[$(file tests/raw-claude-allowlist.txt $'@@ -3,2 +3,3 @@\n bin/a.sh\n+bin/new.sh\n bin/b.sh')]"
out=$(scan "$T/s3.json"); rc=$?
[ "$rc" = 0 ] && grep -q $'^lead\ttests/raw-claude-allowlist.txt' <<<"$out" && ok || bad "S3 an allow-list line is no hit (rc $rc): $out"
cmp "$T/s3b.json" "[$(file tests/gh-app-ratchet-baseline/new.sh.txt $'@@ -0,0 +1 @@\n+3')]"
[ "$(scan "$T/s3b.json" >/dev/null; echo $?)" = 0 ] && ok || bad "S3 a ratchet baseline line is no hit"
jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat"}}], files:[{filename:"tests/llm-call-ratchet-allowlist.txt", status:"modified"}]}' > "$T/s3c.json"
out=$(scan "$T/s3c.json"); rc=$?
[ "$rc" = 0 ] && grep -q 'patch not shown' <<<"$out" && ok || bad "S3 an allow-list file with no patch is no hit (rc $rc): $out"

# S3 by route: a leak or identifier list and the gitleaks ignore file are
# human; a ratchet baseline that only names a gitleaks file is lead.
cmp "$T/s3d.json" "[$(file tests/leak-allowlist.txt $'@@ -1 +1,2 @@\n a\n+b')]"
grep -q $'^human\ttests/leak-allowlist.txt' <<<"$(scan "$T/s3d.json")" && ok || bad "S3 a leak allow-list line is not a human hit: $(scan "$T/s3d.json")"
cmp "$T/s3e.json" "[$(file .gitleaksignore $'@@ -1 +1,2 @@\n a\n+abc:1')]"
grep -q $'^human\t.gitleaksignore' <<<"$(scan "$T/s3e.json")" && ok || bad "S3 a .gitleaksignore line is not a human hit: $(scan "$T/s3e.json")"
cmp "$T/s3f.json" "[$(file tests/fixtures/root-fallback-baseline/bin__lib__gitleaks-pin.sh.count.txt $'@@ -1 +1 @@\n-1\n+2')]"
grep -q $'^lead\ttests/fixtures/root-fallback-baseline/' <<<"$(scan "$T/s3f.json")" && ok || bad "S3 a ratchet baseline is not a lead hit: $(scan "$T/s3f.json")"

# ── S4: the negative list ───────────────────────────────────────────────────
cmp "$T/s4.json" "[$(file tests/x-test.sh $'@@ -1,3 +1,2 @@\n x\n-cp a b # '"$SCA"$': gone\n  # '"$DOK"$' context only'),
  $(file bin/allowance.sh $'@@ -1 +1,2 @@\n x\n+y=1'),
  $(file tests/egress-allowlist-test.sh $'@@ -1 +1,2 @@\n x\n+bad "nope"'),
  $(file catalog/silence-markers.tsv "$(sed 's/^/+/' "$CAT" | sed '1s/^/@@ -0,0 +1,99 @@\n/')")]"
out=$(scan "$T/s4.json"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "S4 the negative list hit (rc $rc): $out"
echo 'not json' > "$T/s4b.json"
[ "$(scan "$T/s4b.json" >/dev/null 2>&1; echo $?)" = 2 ] && ok || bad "S4 an unparseable compare is not rc 2"
echo '{"total_commits":1,"commits":[]}' > "$T/s4c.json"
[ "$(scan "$T/s4c.json" >/dev/null 2>&1; echo $?)" = 1 ] && ok || bad "S4 a compare with no files list is not rc 1 (nothing shown, nothing to scan)"

# ============================================================================
# S5-S9: the real tick, bin/lead-review-enqueue.sh, on a scratch harness.
# ============================================================================
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || bad "could not install the enqueue closure"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "could not install the jobs client closure"
mkdir -p "$H/catalog" && cp "$CAT" "$H/catalog/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"
SHA=$(printf 'a%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s\n' "\$m" "\$p" >> "$T/log/worker"
[ "\$m" = POST ] && printf '%s\n' "\$body" >> "$T/log/bodies"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    out=\$(jq -nc --arg s "$SHA" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:\$s,
      artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:\$s, settled:true}|tojson)}]}') ;;
  "GET /api/verdicts?"*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "POST /api/lead-reviews") code=201; out='{"request":{"id":"lr-1","status":"requested"}}' ;;
  *) code=404; out='{"error":"unknown endpoint"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/demo-os/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$SHA" --argjson l "\$(cat "$T/labels.json")" '{head:{sha:\$s},base:{ref:"main"},labels:\$l,user:{login:"operator"}}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp.json" ;;
  *"-X POST repos/example-org/demo-os/issues/41/labels"*)
    if [ -e "$T/label500" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n[{"name":"needs-human"}]\n'; echo '[{"name":"needs-human"}]' > "$T/labels.json"; fi ;;
  *"-X POST repos/example-org/demo-os/issues/41/comments"*)
    printf 'HTTP/2 201\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
for f in lane-alert.sh agent-call.sh; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log/alerts"\nexit 0\n' "$T" > "$H/bin/$f"; done
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 LEAD_REVIEW_SILENCE_CHECK=1
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

reset() {
  rm -f "$T/log"/* "$T/label500" "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"; echo box-hub > "$H/state/box-name"
  jq -nc --arg h "$SHA" '[{number:41, html_url:"https://github.com/example-org/demo-os/pull/41", title:"t", draft:false, state:"open",
    user:{login:"operator",type:"User"}, head:{sha:$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' > "$T/prs.json"
  echo '[]' > "$T/labels.json"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; }
# TEST-CHANGE (BH-5779 merged with main): a request is POST /api/lead-reviews
# exactly. The enqueue now also POSTs /api/lead-reviews/reclaim-stale once a
# tick (BH-5779), which is not a review request.
posts() { grep -c '^POST /api/lead-reviews\( \|$\)' "$T/log/worker" 2>/dev/null; }
labels() { grep -c 'X POST repos/example-org/demo-os/issues/41/labels' "$T/log/gh" 2>/dev/null; }
comments() { grep -c 'X POST repos/example-org/demo-os/issues/41/comments' "$T/log/gh" 2>/dev/null; }
summ() { grep ' tick repos=' "$H/logs/lead-review-enqueue.log" 2>/dev/null | tail -1; }
HIT="[$(file bin/share/mapping.py $'@@ -540,6 +540,7 @@ '"$KFI"$' = {\n     "acme-demo",\n+    "demo-client-x",\n     "zz-fixture",')]"
LEADHIT="[$(file tests/x-test.sh $'@@ -1,2 +1,3 @@\n x\n+cp a b # '"$SCA"$': one lib\n y')]"
CLEAN="[$(file bin/x.sh $'@@ -1,2 +1,3 @@\n x\n+echo hi\n y')]"

# ── S5 ──────────────────────────────────────────────────────────────────────
reset; cmp "$T/cmp.json" "$HIT"; tick
[ "$(posts)" = 0 ] && ok || bad "S5 a silencing diff was requested for a lead review: $(cat "$T/log/worker") $(tail -5 "$T/out")"
[ "$(labels)" = 1 ] && awk '/issues\/41\/labels/ && /labels\[\]=needs-human/ {f = 1} END {exit !f}' "$T/log/gh" && ok || bad "S5 no needs-human label POST: $(cat "$T/log/gh" 2>/dev/null)"
[ "$(comments)" = 1 ] && ok || bad "S5 comments=$(comments), want 1"
summ | grep -qw 'skipped_silence=1' && ok || bad "S5 the summary has no skipped_silence=1: $(summ)"
grep -q "bin/share/mapping.py" "$H/logs/lead-review-enqueue.log" && ok || bad "S5 the log does not name the file"
tick
[ "$(posts)" = 0 ] && [ "$(labels)" = 1 ] && [ "$(comments)" = 1 ] && ok || bad "S5 a second tick acted again: posts=$(posts) labels=$(labels) comments=$(comments)"

# ── S6: the human removed the label ─────────────────────────────────────────
echo '[]' > "$T/labels.json"; tick
[ "$(posts)" = 1 ] && ok || bad "S6 a human-cleared PR was not requested: posts=$(posts) $(summ)"
[ "$(labels)" = 1 ] && ok || bad "S6 the cleared PR was labelled again: labels=$(labels)"
grep -q 'cleared by a human' "$H/logs/lead-review-enqueue.log" && ok || bad "S6 the log does not say a human cleared it"

# ── S7: knob 0 ──────────────────────────────────────────────────────────────
reset; cmp "$T/cmp.json" "$HIT"; LEAD_REVIEW_SILENCE_CHECK=0 tick
[ "$(posts)" = 1 ] && [ "$(labels)" = 0 ] && ok || bad "S7 knob 0: posts=$(posts) labels=$(labels)"

# ── S8: the label POST fails ────────────────────────────────────────────────
reset; cmp "$T/cmp.json" "$HIT"; touch "$T/label500"; tick
[ "$(posts)" = 0 ] && [ "$(comments)" = 0 ] && ok || bad "S8 a failed label: posts=$(posts) comments=$(comments)"
[ -z "$(ls -A "$H/state/lead-review-enqueue/silence" 2>/dev/null)" ] && ok || bad "S8 a state row was written for a failed label"
summ | grep -qw 'unreadable=1' && ok || bad "S8 not counted unreadable: $(summ)"

# ── S9: no hit ──────────────────────────────────────────────────────────────
reset; cmp "$T/cmp.json" "$CLEAN"; tick
[ "$(posts)" = 1 ] && [ "$(labels)" = 0 ] && [ "$(comments)" = 0 ] && ok || bad "S9 a clean diff: posts=$(posts) labels=$(labels) comments=$(comments)"

# ── S10: no rules file on the box = no check ────────────────────────────────
reset; cmp "$T/cmp.json" "$HIT"; mv "$H/catalog/silence-markers.tsv" "$T/rules.away"; tick
[ "$(posts)" = 1 ] && [ "$(labels)" = 0 ] && ok || bad "S10 no rules file: posts=$(posts) labels=$(labels)"
mv "$T/rules.away" "$H/catalog/silence-markers.tsv"

# ── S11: a lead hit goes to the lead, with the marker in the notes ──────────
reset; cmp "$T/cmp.json" "$LEADHIT"; tick
[ "$(posts)" = 1 ] && [ "$(labels)" = 0 ] && [ "$(comments)" = 0 ] && ok || bad "S11 a lead hit: posts=$(posts) labels=$(labels) comments=$(comments)"
N1=$(jq -r '.scope_notes // empty' "$T/log/bodies" 2>/dev/null | head -1)
case "$N1" in *"silence markers for the lead to judge"*"tests/x-test.sh"*"one lib"*) ok ;; *) bad "S11 the request notes do not carry the marker: '$N1'" ;; esac
tick
N2=$(jq -r '.scope_notes // empty' "$T/log/bodies" 2>/dev/null | sed -n 2p)
[ "$(posts)" = 2 ] && [ "$N2" = "$N1" ] && ok || bad "S11 the re-confirm notes differ: posts=$(posts) '$N2' vs '$N1'"

# ── R1/R2: bin/marker-reason-lint.sh ────────────────────────────────────────
R="$T/r"; mkdir -p "$R/catalog" "$R/tests" "$R/docs"; cp "$CAT" "$R/catalog/"
( cd "$R" && git init -q -b main && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false
  printf '#!/bin/bash\nsleep 1 # %s gone later\n' "$DOK" > tests/old-test.sh
  git add -A && git commit -qm base && git checkout -qb ticket/x ) >/dev/null 2>&1
lint() { "$DIR/bin/marker-reason-lint.sh" --base main "$R" > "$T/lint.out" 2>"$T/lint.err"; echo $?; }
( cd "$R" && printf '#!/bin/bash\nsleep 0.2 # %s\n' "$DOK" > tests/bare-test.sh && git add -A && git commit -qm bare ) >/dev/null 2>&1
[ "$(lint)" = 1 ] && grep -q 'tests/bare-test.sh: a determinism lint marker with no reason' "$T/lint.out" && ok \
  || bad "R1 a bare marker is not a finding: $(cat "$T/lint.out" "$T/lint.err")"
( cd "$R" && printf '#!/bin/bash\nsleep 0.2 # %s — a bounded wait for the child\n' "$DOK" > tests/bare-test.sh \
  && printf 'Write `# %s` with a reason.\n' "$DOK" > docs/x.md && : > tests/old-test.sh && git add -A && git commit -qm reason ) >/dev/null 2>&1
[ "$(lint)" = 0 ] && ok || bad "R1 a marker with a reason, one in a .md file or a removed one is a finding: $(cat "$T/lint.out")"
awk -F'\t' '$1 == "marker-reason" && $2 == "delta" && $4 == "bin/marker-reason-lint.sh --base <fork> ." {f = 1} END {exit !f}' "$DIR/catalog/rules-pack.tsv" \
  && ok || bad "R2 the rules pack has no marker-reason component"

echo "silence-scan.bh-5797: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
