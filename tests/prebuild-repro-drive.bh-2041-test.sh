#!/bin/bash
# tests/prebuild-repro-drive.bh-2041-test.sh — the pre-build repro gate's drive
# stage (BH-2041, order 3 of #2004): preconditions, the dedup-before-spend
# repro_gate ledger, the capped read-only call, the strict final-block parse,
# the ledger put and $BUILD/prebuild-repro.md.
#
# WHAT THIS SUITE PINS: the SHIPPED bin/lib/prebuild-repro/drive.sh, sourced
# through the shipped bin/lib/prebuild-repro.sh in a scratch HARNESS with the
# real lane-gate and a registry composed from this tree. Stubbed around it:
#   bin/prod-url.sh      echoes $STUB_PROD (default https://os.example.test)
#   bin/agent-call.sh    records argv/prompt/env, counts calls, writes a canned
#                        transcript chosen by $STUB_CASE, exits $STUB_RC
#   bin/qa-unbanned.sh   leaves a marker
#   bin/jobs-client.sh   job_ledger_get/put + _jobs_req over a file store;
#                        get rc forced by $STUB_LEDGER_RC
#   bin/lib/lane-model.sh lane_role_model echoes stub-model
# B1 also runs the real bin/prebuild-repro.sh (D2).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-drive.bh-2041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

REG="$T/lanes.json"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 \
  || bad "setup: bin/lanes-build.sh --to could not compose the registry"
export LANE_REGISTRY="$REG" LANE_GATE_NOW=""
unset QA_CLERK_SECRET_KEY QA_TEST_USER_ID LLM_LANE_ENABLED REPRO_GATE_MAX_USD HARNESS_ENV_DIR AGENT_CALL_BUDGET_USD_REPRO 2>/dev/null

# mkh <name> — a scratch HARNESS with the shipped lib, stages and lane gate.
mkh() {
  local h="$T/$1"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/flags" "$h/env" "$h/ledger" "$h/calls"
  cp -p "$DIR/bin/prebuild-repro.sh" "$DIR/bin/kind-gate.sh" "$h/bin/"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$h/bin/"
  cp -p "$DIR/bin/lib/prebuild-repro.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$h/bin/lib/"
  cp -rp "$DIR/bin/lib/prebuild-repro" "$h/bin/lib/"
  # BH-4491: the drive fences body + thread
  scratch_install_closure bin/lib/untrusted-input.sh "$h" >/dev/null || { echo "closure install failed"; exit 1; }
  printf '#!/bin/bash\n[ "${STUB_PROD-https://os.example.test}" = FAIL ] && exit 1\necho "${STUB_PROD-https://os.example.test}"\n' > "$h/bin/prod-url.sh"
  printf '#!/bin/bash\ntouch "%s/qa-unbanned-called"\n' "$h" > "$h/bin/qa-unbanned.sh"
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_fake\n' > "$h/env/p.env"
  : > "$h/env/global.env"
  cat > "$h/bin/lib/lane-model.sh" <<'SH'
lane_role_model() { echo "$*" >> "$HARNESS/calls/model-role"; [ -n "${STUB_NO_MODEL:-}" ] && return 75; echo stub-model; }
SH
  cat > "$h/bin/jobs-client.sh" <<'SH'
_led() { printf '%s' "$1" | sha256sum | cut -c1-16; }
job_ledger_get() {
  echo "$1 $2" >> "$HARNESS/ledger/gets"
  [ -n "${STUB_LEDGER_RC:-}" ] && return "$STUB_LEDGER_RC"
  local f="$HARNESS/ledger/$(_led "$1/$2")"
  [ -f "$f.status" ] || return 2
  cat "$f.status"
}
job_ledger_put() {
  echo "$1 $2 $3" >> "$HARNESS/ledger/puts"
  local f="$HARNESS/ledger/$(_led "$1/$2")"
  printf '%s' "$3" > "$f.status"; printf '%s' "${4:-}" > "$f.detail"
  [ -z "${STUB_PUT_FAIL:-}" ]
}
_jobs_req() {
  local q="${2#*\?}" k v kind="" key=""
  for kv in ${q//&/ }; do k="${kv%%=*}"; v="${kv#*=}"; v=$(printf '%b' "${v//%/\\x}")
    case "$k" in kind) kind="$v" ;; key) key="$v" ;; esac; done
  local f="$HARNESS/ledger/$(_led "$kind/$key")"
  [ -f "$f.status" ] || return 2
  jq -nc --arg s "$(cat "$f.status")" --arg d "$(cat "$f.detail")" '{ledger:{status:$s,detail:$d}}'
}
SH
  cat > "$h/bin/agent-call.sh" <<'SH'
#!/bin/bash
H="$HARNESS"; n=$(( $(cat "$H/calls/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$H/calls/count"
printf '%s\n' "$@" > "$H/calls/$n.argv"; printf '%s' "$6" > "$H/calls/$n.prompt"
printf '%s' "${AGENT_CALL_BUDGET_USD_REPRO-UNSET}" > "$H/calls/$n.budget"
printf '%s|%s|%s' "${QA_TEST_USER_ID-}" "${QA_CLERK_SECRET_KEY:+set}" "${AGENT_CALL_LANE-}" > "$H/calls/$n.env"
OUT="$5"; P="${STUB_PROD_URL:-https://os.example.test}"
blk() { printf 'REPRO_VERDICT: %s\nREPRO_ROLE: %s\nREPRO_URL: %s\nREPRO_STEPS: open totals; add row\nREPRO_OBSERVED: %s\n' "$1" "$2" "$3" "$4"; }
case "${STUB_CASE:-repro}" in
  repro)    { echo "I drove it."; blk REPRODUCED qa-user "$P/totals" "total shows 0 after adding a row"; } > "$OUT" ;;
  notrep)   { echo "Looked."; blk NOT_REPRODUCED qa-user "${STUB_URL-$P/totals}" "total updates fine"; } > "$OUT" ;;
  fixed)    { echo "Looked."; blk ALREADY_FIXED qa-user "$P/totals" "fixed already"; } > "$OUT" ;;
  norole)   { blk NOT_REPRODUCED "" "$P/totals" "fine"; } > "$OUT" ;;
  prose)    { blk NOT_REPRODUCED qa-user "$P/totals" x | sed 's/^REPRO_VERDICT: NOT_REPRODUCED$/REPRO_VERDICT: NOT_REPRODUCED probably/'; } > "$OUT" ;;
  agentcd)  { blk CANNOT_DRIVE qa-user "$P" "the QA account is banned"; } > "$OUT" ;;
  mid)      { blk NOT_REPRODUCED qa-user "$P/totals" x; for i in 1 2 3 4 5 6 7 8 9; do echo "later prose $i"; done; } > "$OUT" ;;
  fence)    { echo '```'; blk NOT_REPRODUCED qa-user "$P/totals" x; for i in 1 2 3 4 5 6; do echo "inside $i"; done; blk NOT_REPRODUCED qa-user "$P/totals" x; } > "$OUT" ;;
  quote)    { echo x; blk NOT_REPRODUCED qa-user "$P/totals" x | sed 's/^REPRO_VERDICT/> REPRO_VERDICT/'; } > "$OUT" ;;
  fence2)   { echo '```'; echo 'REPRO_VERDICT: REPRODUCED'; echo '```'; blk NOT_REPRODUCED qa-user "$P/totals" x; } > "$OUT" ;;
  quote2)   { echo '> REPRO_VERDICT: REPRODUCED'; blk NOT_REPRODUCED qa-user "$P/totals" x; } > "$OUT" ;;
  two)      { blk REPRODUCED qa-user "$P/totals" x | head -1; blk NOT_REPRODUCED qa-user "$P/totals" x; } > "$OUT" ;;
  budget)   { echo "partial"; echo "BUDGET STOP: repro/p hit the cap"; } > "$OUT" ;;
  big)      { blk REPRODUCED qa-user "$P/totals" "$(head -c 5000 /dev/zero | tr '\0' o)"; } > "$OUT" ;;
esac
[ -n "${STUB_COST:-}" ] && printf '{"total_cost_usd":%s}' "$STUB_COST" > "$OUT.json"
exit "${STUB_RC:-0}"
SH
  chmod +x "$h/bin/"*.sh
  printf '%s' "$h"
}
TH='{"source":"app","truncated":false,"title":"x","body":"Totals are wrong after adding a row","body_principal":false,"comments":[{"id":"c1","createdAt":"2026-09-01T00:00:00Z","body":"still broken on mobile","principal":false},{"id":"c0","createdAt":"2026-08-30T00:00:00Z","body":"can you share steps?","principal":true}]}'
TH2=$(printf '%s' "$TH" | jq -c '.comments += [{"id":"c2","createdAt":"2026-09-03T00:00:00Z","body":"here are the steps","principal":false}]')
mkb() { local b="$T/$1"; mkdir -p "$b"; printf '{"title":"Totals are wrong","labels":[{"name":"bug"}],"body":""}\n' > "$b/ticket-meta.json"; printf '%s' "$b"; }
# drive <harness> <build> [thread] — the shipped pr_drive, as the runner sources it. Sets OUT, RC.
drive() {
  OUT=$( export HARNESS="$1"; . "$1/bin/lib/lane-gate.sh"; . "$1/bin/lib/prebuild-repro.sh"; pr_drive p BH-7 "$2" "${3:-$TH}" ); RC=$?
}
calls() { cat "$1/calls/count" 2>/dev/null || echo 0; }
# nput / lastput count the repro_gate VERDICT rows only. BH-2133 added a
# `repro_gate_claim` row (claim before spend, release after) around every paid
# call; those are pinned by tests/prebuild-repro-self-comment.bh-2133-test.sh,
# and every assertion here is still about the verdict ledger it always meant.
nput()  { awk '$1 == "repro_gate" {n++} END {print n + 0}' "$1/ledger/puts" 2>/dev/null || echo 0; }
nget()  { [ -f "$1/ledger/gets" ] && wc -l < "$1/ledger/gets" | tr -d ' ' || echo 0; }
lastput() { awk '$1 == "repro_gate" {s = $3} END {print s}' "$1/ledger/puts" 2>/dev/null; }
TAB=$'\t'

# ── B1 — REPRODUCED end to end, prompt contents, argv ────────────────────────
H=$(mkh b1); B=$(mkb b1b)
drive "$H" "$B"
[ "$RC" = 0 ] && [ "${OUT%%$TAB*}" = REPRODUCED ] && ok || bad "B1: rc $RC out '$OUT'"
[ "${OUT#*$TAB}" = "total shows 0 after adding a row" ] && ok || bad "B1: reason '${OUT#*$TAB}'"
[ "$(calls "$H")" = 1 ] && ok || bad "B1: $(calls "$H") calls"
A=$(cat "$H/calls/1.argv" 2>/dev/null)
[ "$(sed -n 1p <<<"$A")|$(sed -n 2p <<<"$A")|$(sed -n 3p <<<"$A")|$(sed -n 4p <<<"$A")|$(sed -n 5p <<<"$A")" = "repro|p|stub-model|900|$B/repro-run.txt" ] && ok || bad "B1: argv $(tr '\n' '|' <<<"$A")"
PR="$H/calls/1.prompt"
for s in 'qa-prod-drive/SKILL.md' 'bin/qa-drive.mjs' '1280' '375' '/root/repos/p/docs/verification-map' 'https://os.example.test' \
         'Totals are wrong' 'Totals are wrong after adding a row' 'still broken on mobile' 'can you share steps?' 'REPRO_VERDICT:' 'REPRO_OBSERVED:'; do
  grep -qF -- "$s" "$PR" 2>/dev/null && ok || bad "B1: prompt lacks '$s'"
done
# comments in createdAt order, principal flag carried
a=$(grep -nF 'can you share steps?' "$PR" | cut -d: -f1); b=$(grep -nF 'still broken on mobile' "$PR" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok || bad "B1: comments not in createdAt order ($a/$b)"
grep -q '^=== UNTRUSTED INPUT [0-9a-f]\{16\} (source: ticket-thread) ===$' "$PR" && ok || bad "B1: the thread must reach the prompt fenced (BH-4491)"
[ "$(grep -B1 -xF 'can you share steps?' "$PR" | head -1)" = '--- 2026-08-30T00:00:00Z principal=true' ] \
  && [ "$(grep -B1 -xF 'still broken on mobile' "$PR" | head -1)" = '--- 2026-09-01T00:00:00Z principal=false' ] && ok || bad "B1: principal flag not carried per comment"
! grep -qF 'sk_test_fake' "$PR" && ok || bad "B1: a secret value reached the prompt"
[ "$(cat "$H/calls/1.env")" = "user_fake|set|prebuild-repro" ] && ok || bad "B1: child env '$(cat "$H/calls/1.env")'"
[ "$(nput "$H")" = 1 ] && [ "$(lastput "$H")" = reproduced ] && ok || bad "B1: puts $(cat "$H/ledger/puts" 2>/dev/null)"
grep -qx 'REPRO_STEPS: open totals; add row' "$B/prebuild-repro.md" 2>/dev/null && ok || bad "B1: .md lacks REPRO_STEPS"
grep -qx "REPRO_URL: https://os.example.test/totals" "$B/prebuild-repro.md" 2>/dev/null && ok || bad "B1: .md lacks REPRO_URL"
[ ! -e "$B/prebuild-repro.txt" ] && ok || bad "B1: drive wrote the runner's record"
D=$(cat "$H/ledger/"*.detail 2>/dev/null)
[ "$(jq -r '[.role,.url,.steps,(.cost_usd|tostring),.build]|join("|")' <<<"$D" 2>/dev/null)" = "qa-user|https://os.example.test/totals|open totals; add row|null|b1b" ] && ok || bad "B1: detail '$D'"
# B1 via the real runner (D2)
H=$(mkh b1r); B=$(mkb b1rb)
printf 'pr_fetch_thread() { printf %%s %q; }\n' "$TH" > "$H/bin/lib/prebuild-repro/thread.sh"
HARNESS="$H" bash "$H/bin/prebuild-repro.sh" p 42 BH-7 "$B" > "$B/runner.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sed -n 's/^REPRO_GATE: //p' "$B/prebuild-repro.txt" 2>/dev/null)" = reproduced ] && ok \
  || bad "B1r: rc $rc record $(tr '\n' '|' < "$B/prebuild-repro.txt" 2>/dev/null) out $(tr '\n' '|' < "$B/runner.out")"
[ "$(calls "$H")" = 1 ] && [ "$(lastput "$H")" = reproduced ] && ok || bad "B1r: calls $(calls "$H") put '$(lastput "$H")'"

# ── B2 — read-only prompt; qa-unbanned never called ──────────────────────────
PR="$T/b1/calls/1.prompt"
grep -qF 'NEVER run bin/qa-unbanned.sh' "$PR" && ok || bad "B2: no qa-unbanned prohibition"
grep -qiE 'send, pay, delete, submit' "$PR" && ok || bad "B2: no send/pay/delete rule"
grep -qF 'QA_TEST_USER_ID' "$PR" && ok || bad "B2: low-privilege account not named"
[ ! -e "$T/b1/qa-unbanned-called" ] && [ ! -e "$T/b1r/qa-unbanned-called" ] && ok || bad "B2: qa-unbanned was called"

# ── B3/B4/B4b — preconditions: no call, no get, no put ───────────────────────
pre() { # pre <name> <want reason> [env...]
  local n="$1" want="$2"; shift 2
  H=$(mkh "$n"); B=$(mkb "${n}b"); [ "$n" = b3 ] && : > "$H/env/p.env"
  OUT=$( export "$@" HARNESS="$H"; . "$H/bin/lib/lane-gate.sh"; . "$H/bin/lib/prebuild-repro.sh"; pr_drive p BH-7 "$B" "$TH" ); RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = "CANNOT_DRIVE$TAB$want" ] && ok || bad "$n: rc $RC out '$OUT'"
  # no-model is resolved after the (free) ledger read; every other precondition reads nothing
  local g=0; [ "$n" = b4m ] && g=1
  [ "$(calls "$H")/$(nget "$H")/$(nput "$H")" = "0/$g/0" ] && ok || bad "$n: calls/gets/puts $(calls "$H")/$(nget "$H")/$(nput "$H")"
  [ -z "$(ls -A "$B" | grep -v ticket-meta.json)" ] && ok || bad "$n: wrote into \$BUILD: $(ls "$B")"
}
pre b3 no-qa-role X=1
pre b4 no-prod-url STUB_PROD=-
pre b4f no-prod-url STUB_PROD=FAIL
pre b4b llm-lane-disabled LLM_LANE_ENABLED=0
pre b4m no-model STUB_NO_MODEL=1
# process env creds win when the file has none
H=$(mkh b3e); B=$(mkb b3eb); : > "$H/env/p.env"
OUT=$( export HARNESS="$H" QA_CLERK_SECRET_KEY=k QA_TEST_USER_ID=u; . "$H/bin/lib/lane-gate.sh"; . "$H/bin/lib/prebuild-repro.sh"; pr_drive p BH-7 "$B" "$TH" )
[ "${OUT%%$TAB*}" = REPRODUCED ] && [ "$(cat "$H/calls/1.env" 2>/dev/null)" = "u|set|prebuild-repro" ] && ok || bad "B3e: process-env creds not used ('$OUT')"

# ── B5 — unparseable ────────────────────────────────────────────────────────
for c in mid fence fence2 quote quote2 two prose; do
  H=$(mkh "b5$c"); B=$(mkb "b5${c}b"); STUB_CASE=$c drive "$H" "$B"
  [ "$RC" = 0 ] && [ "$OUT" = "CANNOT_DRIVE${TAB}unparseable" ] && ok || bad "B5 $c: '$OUT'"
  [ "$(calls "$H")" = 1 ] && [ "$(nput "$H")" = 1 ] && [ "$(lastput "$H")" = cannot_drive ] && ok || bad "B5 $c: calls $(calls "$H") puts $(nput "$H") '$(lastput "$H")'"
done
# control: the fence case's second block alone (fence closed) parses
H=$(mkh b5ctl); B=$(mkb b5ctlb); STUB_CASE=notrep drive "$H" "$B"
[ "${OUT%%$TAB*}" = NOT_REPRODUCED ] && ok || bad "B5 control: '$OUT'"

# ── B6 — budget stop / nonzero rc is billed ─────────────────────────────────
H=$(mkh b6); B=$(mkb b6b); STUB_CASE=budget STUB_RC=1 STUB_COST=2.91 drive "$H" "$B"
[ "$OUT" = "CANNOT_DRIVE${TAB}cap-or-error" ] && ok || bad "B6: '$OUT'"
[ "$(nput "$H")" = 1 ] && [ "$(lastput "$H")" = cannot_drive ] && ok || bad "B6: puts $(cat "$H/ledger/puts" 2>/dev/null)"
[ "$(jq -r .cost_usd "$H/ledger/"*.detail 2>/dev/null)" = 2.91 ] && ok || bad "B6: cost_usd not carried"
grep -qx 'REPRO_ROLE: ' "$B/prebuild-repro.md" 2>/dev/null && ok || bad "B6: .md with empty fields missing"

# ── B7 — the knob binds the budget env ──────────────────────────────────────
H=$(mkh b7); B=$(mkb b7b)
printf '{"fetched_at":%s,"values":{"lane.prebuild-repro.p.repro_gate_max_usd":"1.75"},"seeded":{}}\n' "$(date -u +%s)" > "$H/state/settings-cache.json"
REPRO_GATE_MAX_USD=3 drive "$H" "$B"
[ "$(cat "$H/calls/1.budget" 2>/dev/null)" = 1.75 ] && ok || bad "B7: budget env '$(cat "$H/calls/1.budget" 2>/dev/null)'"
H=$(mkh b7d); B=$(mkb b7db); drive "$H" "$B"
[ "$(cat "$H/calls/1.budget" 2>/dev/null)" = 3 ] && ok || bad "B7: default budget '$(cat "$H/calls/1.budget" 2>/dev/null)'"

# ── B8 — NOT_REPRODUCED needs ROLE and the prod origin ──────────────────────
n=0  # per-iteration scratch names: a fresh HARNESS each pass, no rm
for u in '' 'https://x.vercel.app/totals' 'http://localhost:3000/totals' 'https://staging.os.example.test/totals' \
         'http://os.example.test/totals' 'https://os.example.test.evil.com/x' 'https://user@os.example.test/x'; do
  n=$((n+1)); H=$(mkh "b8-$n"); B=$(mkb "b8b-$n"); STUB_CASE=notrep STUB_URL="$u" drive "$H" "$B"
  [ "$OUT" = "CANNOT_DRIVE${TAB}unverifiable-url" ] && ok || bad "B8 '$u': '$OUT'"
  [ "$(nput "$H")" = 1 ] && [ "$(lastput "$H")" = cannot_drive ] && ok || bad "B8 '$u': put '$(lastput "$H")'"
done
H=$(mkh b8r); B=$(mkb b8rb); STUB_CASE=norole drive "$H" "$B"
[ "$OUT" = "CANNOT_DRIVE${TAB}unverifiable-url" ] && ok || bad "B8 empty role: '$OUT'"
for u in 'https://os.example.test/totals' 'HTTPS://OS.Example.test/' 'https://os.example.test'; do
  n=$((n+1)); H=$(mkh "b8ok-$n"); B=$(mkb "b8okb-$n"); STUB_CASE=notrep STUB_URL="$u" drive "$H" "$B"
  [ "$OUT" = "NOT_REPRODUCED${TAB}total updates fine" ] && ok || bad "B8 ok '$u': '$OUT'"
  [ "$(lastput "$H")" = not_reproduced_uncommented ] && ok || bad "B8 ok '$u': put '$(lastput "$H")'"
done
H=$(mkh b8f); B=$(mkb b8fb); STUB_CASE=fixed drive "$H" "$B"
[ "${OUT%%$TAB*}" = ALREADY_FIXED ] && [ "$(lastput "$H")" = already_fixed_uncommented ] && ok || bad "B8 fixed: '$OUT' '$(lastput "$H")'"
H=$(mkh b8a); B=$(mkb b8ab); STUB_CASE=agentcd drive "$H" "$B"
[ "$OUT" = "CANNOT_DRIVE${TAB}agent: the QA account is banned" ] && [ "$(lastput "$H")" = cannot_drive ] && ok || bad "B8 agent cd: '$OUT'"

# ── B9/B9b/B10 — dedup before spend ─────────────────────────────────────────
H=$(mkh b9); B=$(mkb b9b); drive "$H" "$B"; first="${OUT%%$TAB*}"
B2=$(mkb b9b2); drive "$H" "$B2"
[ "$(calls "$H")" = 1 ] && ok || bad "B9: $(calls "$H") calls for one fingerprint"
[ "$OUT" = "$first${TAB}ledger-reuse" ] && ok || bad "B9: second answer '$OUT' (first $first)"
grep -qx 'REPRO_STEPS: open totals; add row' "$B2/prebuild-repro.md" 2>/dev/null && ok || bad "B9: reuse did not rewrite .md from detail"
[ "$(nput "$H")" = 1 ] && ok || bad "B9: reuse wrote a row"
# B10 — a new comment moves the fingerprint: exactly one more call
B3=$(mkb b10b); drive "$H" "$B3" "$TH2"
[ "$(calls "$H")" = 2 ] && [ "$OUT" != "REPRODUCED${TAB}ledger-reuse" ] && ok || bad "B10: calls $(calls "$H") out '$OUT'"
# B9b — stored already_fixed_uncommented + detail
H=$(mkh b9b); B=$(mkb b9bb)
K=$( export HARNESS="$H"; . "$H/bin/lib/prebuild-repro.sh"; pr_ledger_key p BH-7 "$TH" )
( export HARNESS="$H"; . "$H/bin/jobs-client.sh"; job_ledger_put repro_gate "$K" already_fixed_uncommented '{"role":"qa-user","url":"https://os.example.test/fixed-here","steps":"s1; s2","observed":"works","cost_usd":1.2,"build":"old"}' )
: > "$H/ledger/puts"
drive "$H" "$B"
[ "$OUT" = "ALREADY_FIXED${TAB}ledger-reuse" ] && [ "$(calls "$H")" = 0 ] && ok || bad "B9b: '$OUT' calls $(calls "$H")"
grep -qx 'REPRO_URL: https://os.example.test/fixed-here' "$B/prebuild-repro.md" 2>/dev/null && ok || bad "B9b: .md not from detail"
for st in not_reproduced:NOT_REPRODUCED not_reproduced_uncommented:NOT_REPRODUCED already_fixed:ALREADY_FIXED reproduced:REPRODUCED cannot_drive:CANNOT_DRIVE weird:CANNOT_DRIVE; do
  n=$((n+1)); H=$(mkh "b9s-$n"); B=$(mkb "b9sb-$n")
  ( export HARNESS="$H"; . "$H/bin/jobs-client.sh"; job_ledger_put repro_gate "$K" "${st%%:*}" '{}' )
  drive "$H" "$B"; want="${st#*:}$TAB"; [ "${st%%:*}" = weird ] && want="${want}ledger-unknown-status" || want="${want}ledger-reuse"
  [ "$OUT" = "$want" ] && [ "$(calls "$H")" = 0 ] && ok || bad "B9 status ${st%%:*}: '$OUT'"
done

# ── B11 — ledger outage: no spend ───────────────────────────────────────────
H=$(mkh b11); B=$(mkb b11b); STUB_LEDGER_RC=1 drive "$H" "$B"
[ "$OUT" = "CANNOT_DRIVE${TAB}ledger-unreadable" ] && [ "$(calls "$H")" = 0 ] && [ "$(nput "$H")" = 0 ] && ok || bad "B11: '$OUT' calls $(calls "$H")"
H=$(mkh b11j); B=$(mkb b11jb); drive "$H" "$B" 'not json {'
[ "$OUT" = "CANNOT_DRIVE${TAB}ledger-unreadable" ] && [ "$(calls "$H")" = 0 ] && ok || bad "B11 bad thread: '$OUT'"
H=$(mkh b11m); B=$(mkb b11mb); rm -f "$H/bin/jobs-client.sh"; drive "$H" "$B"
[ "$OUT" = "CANNOT_DRIVE${TAB}ledger-unreadable" ] && [ "$(calls "$H")" = 0 ] && ok || bad "B11 no client: '$OUT'"

# ── B12 — not billed: no row ────────────────────────────────────────────────
for r in 74 76 79; do
  H=$(mkh "b12_$r"); B=$(mkb "b12b$r"); STUB_RC=$r drive "$H" "$B"
  [ "$OUT" = "CANNOT_DRIVE${TAB}not-billed-rc$r" ] && [ "$(nput "$H")" = 0 ] && [ ! -e "$B/prebuild-repro.md" ] && ok || bad "B12 rc $r: '$OUT' puts $(nput "$H")"
done
H=$(mkh b12p); B=$(mkb b12pb); STUB_PUT_FAIL=1 drive "$H" "$B"
[ "${OUT%%$TAB*}" = REPRODUCED ] && grep -q 'ledger put failed' "$B/pipeline.log" 2>/dev/null && ok || bad "B12: failed put not logged ('$OUT')"

# ── B13 — no model literal ──────────────────────────────────────────────────
[ "$(grep -c 'claude-' "$DIR/bin/lib/prebuild-repro/drive.sh")" = 0 ] && ok || bad "B13: a claude-* literal in drive.sh"

# ── B14 — .md capped ────────────────────────────────────────────────────────
H=$(mkh b14); B=$(mkb b14b); STUB_CASE=big drive "$H" "$B"
s=$(wc -c < "$B/prebuild-repro.md" 2>/dev/null || echo 0)
[ "$s" -gt 0 ] && [ "$s" -le 2000 ] && ok || bad "B14: .md is $s bytes"
[ "${#OUT}" -le 200 ] && ok || bad "B14: reason not capped (${#OUT})"

# ── B15 — the real _budget_for against the real catalog: no UNBUDGETED LANE ─
H=$(mkh b15)
awk '/^_budget_for\(\) \{/,/^\}$/' "$DIR/bin/agent-call.sh" > "$T/budget-for.sh"
grep -q '^_budget_for() {' "$T/budget-for.sh" || bad "B15: could not extract _budget_for"
v=$( HARNESS="$H" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" bash -c 'declare -A _JOB_CAP_MEMO; . "'"$T"'/budget-for.sh"; _budget_for repro p claude' )
[ -n "$v" ] && ok || bad "B15: _budget_for printed nothing"
! grep -q 'UNBUDGETED LANE' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "B15: $(cat "$H/logs/ALERTS.log")"
v=$( HARNESS="$H" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" bash -c 'declare -A _JOB_CAP_MEMO; . "'"$T"'/budget-for.sh"; _budget_for reprox p claude' )
grep -q 'UNBUDGETED LANE: reprox' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "B15 control: an unknown stage did not alert, so the check proves nothing"

echo "prebuild-repro-drive: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
