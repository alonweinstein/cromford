#!/bin/bash
# tests/selfhost-install-dryrun.bh-4081-test.sh — BH-4081 (the ticket's
# tests/selfhost-install-dryrun-test.sh, named per ticket): the self-host
# installer's dry-run lists every resource from the operator's settings, makes
# no live calls, writes nothing, refuses bad or secret-bearing settings, and
# keeps per-run dollar caps on unless they are explicitly turned off.
#
# Every case drives the real bin/selfhost-install.sh. The settings fixtures are
# the shipped env-templates/selfhost.conf.example with its blanks filled, so the
# input shape is the template's. wrangler, fly, flyctl, gh, curl, wget and npx
# are PATH stubs that log their argv to $T/calls.log; it must stay empty.
#
#   C1-C2  the catalog parses: 8 fields, unique ids, closed provider/when sets
#   C3     the template as shipped is refused, naming every required blank
#   C4     a full config plans every row, per-project rows once per project
#   C5     no stub was ever called          C6  a run writes nothing
#   C7     hub/pool matrix                  C8  gh/model/chat choices + SECRETs
#   C9     negatives (secret key, injection, unknown/duplicate key, bad slugs)
#   C10    the ledger marks `recorded`; two runs are byte-identical
#   C11    caps                             C12 none of our deployment literals
#   C13    --apply refuses, nothing created C14 a malformed catalog is rc 3
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/selfhost-install-dryrun.bh-4081-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SH="$DIR/bin/selfhost-install.sh"
CAT="$DIR/catalog/selfhost/resources.tsv"
TPL="$DIR/env-templates/selfhost.conf.example"
FAMS="$DIR/catalog/deployment-literals.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# PATH stubs for every tool that could reach a network.
mkdir -p "$T/stubs"
for t in wrangler fly flyctl gh curl wget npx; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$t" "$T" > "$T/stubs/$t"
  chmod +x "$T/stubs/$t"
done
: > "$T/calls.log"
export PATH="$T/stubs:$PATH"

# conf <file> [KEY=VAL ...] — the template with blanks filled by made-up values,
# then each KEY=VAL replacing that key's line (VAL may be empty).
conf() {
  local f="$1"; shift
  sed -e 's|^SELFHOST_CF_ACCOUNT_ID=$|SELFHOST_CF_ACCOUNT_ID=00000000000000000000000000000000|' \
      -e 's|^HARNESS_WORKERS_SUBDOMAIN=$|HARNESS_WORKERS_SUBDOMAIN=acme|' \
      -e 's|^CONSOLE_PAGES_PROJECT=$|CONSOLE_PAGES_PROJECT=acme-console|' \
      -e 's|^BACKUP_S3_BUCKET=$|BACKUP_S3_BUCKET=acme-backup|' \
      -e 's|^HARNESS_REPO=$|HARNESS_REPO=acme-org/acme-harness|' \
      -e 's|^HARNESS_OPERATOR_LOGIN=$|HARNESS_OPERATOR_LOGIN=acme-op|' \
      -e 's|^HARNESS_GIT_NAME=$|HARNESS_GIT_NAME=acme-op|' \
      -e 's|^HARNESS_GIT_EMAIL=$|HARNESS_GIT_EMAIL=op@acme.example|' \
      -e 's|^SELFHOST_GH_AUTH=$|SELFHOST_GH_AUTH=app|' \
      -e 's|^HARNESS_BOX_PREFIX=$|HARNESS_BOX_PREFIX=acme-|' \
      -e 's|^HARNESS_HUB_BOX=$|HARNESS_HUB_BOX=acme-hub|' \
      -e 's|^SELFHOST_HUB=$|SELFHOST_HUB=fly|' \
      -e 's|^FLY_ORG=$|FLY_ORG=acme-fly|' \
      -e 's|^SELFHOST_POOL=$|SELFHOST_POOL=fly|' \
      -e 's|^SELFHOST_PROJECTS=$|SELFHOST_PROJECTS=web=acme-org/web api=acme-org/api|' \
      -e 's|^SELFHOST_MODEL_AUTH=$|SELFHOST_MODEL_AUTH=oauth|' \
      "$TPL" > "$f"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k{print k "=" v; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}
run() { OUT=$(bash "$SH" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
has() { grep -qxF -- "$1" <<< "$OUT"; }
cnt() { printf '%s\n' "$OUT" | grep -c -- "$1"; }
calls_clean() { [ ! -s "$T/calls.log" ] && ok || bad "C5 $1: a live tool was called: $(cat "$T/calls.log")"; }

# ── C1/C2: the catalog parses ────────────────────────────────────────────────
rows=$(grep -v '^#' "$CAT" | grep -c .)
[ "$rows" -ge 19 ] && ok || bad "C1 catalog has $rows rows, want >= 19"
badnf=$(grep -v '^#' "$CAT" | awk -F'\t' 'NF && NF!=8' | wc -l)
[ "$badnf" = 0 ] && ok || bad "C1 $badnf rows without 8 TAB fields"
dups=$(grep -v '^#' "$CAT" | awk -F'\t' 'NF{print $1}' | sort | uniq -d)
[ -z "$dups" ] && ok || bad "C1 duplicate ids: $dups"
badp=$(grep -v '^#' "$CAT" | awk -F'\t' 'NF && $2 !~ /^(cloudflare|fly|vm|github|model|chat)$/{print $1}')
[ -z "$badp" ] && ok || bad "C2 provider outside the closed set: $badp"
badw=$(grep -v '^#' "$CAT" | awk -F'\t' 'NF{n=split($6,a,","); for(i=1;i<=n;i++) if (a[i] !~ /^(always|hub=fly|hub=vm|pool=fly|pool=local|gh=app|gh=pat|model=oauth|model=api-key|chat=telegram|chat=slack|per-project)$/) print $1": "a[i]}')
[ -z "$badw" ] && ok || bad "C2 when outside the closed set: $badw"

# ── C3: the template as shipped is refused, naming every required blank ──────
run --config "$TPL"
[ "$RC" = 1 ] && ok || bad "C3 template as shipped: rc=$RC, want 1"
for k in SELFHOST_CF_ACCOUNT_ID HARNESS_WORKERS_SUBDOMAIN CONSOLE_PAGES_PROJECT BACKUP_S3_BUCKET HARNESS_REPO HARNESS_OPERATOR_LOGIN HARNESS_GIT_NAME HARNESS_GIT_EMAIL SELFHOST_GH_AUTH HARNESS_BOX_PREFIX HARNESS_HUB_BOX SELFHOST_HUB SELFHOST_POOL SELFHOST_PROJECTS SELFHOST_MODEL_AUTH; do
  grep -qw -- "$k" <<< "$ERR" && ok || bad "C3 refusal does not name $k: $ERR"
done
[ -z "$OUT" ] && ok || bad "C3 a refused config still printed a plan: $OUT"
calls_clean C3

# ── C4: a full config plans every row ────────────────────────────────────────
conf "$T/full.conf"
run --config "$T/full.conf"
[ "$RC" = 0 ] && ok || bad "C4 full config: rc=$RC, want 0 ($ERR)"
nper=$(grep -v '^#' "$CAT" | awk -F'\t' 'NF && $6 ~ /per-project/' | wc -l)
nfix=$((rows - nper))
want=$((nfix + 2 * nper))
got=$(cnt '^RESOURCE ')
[ "$got" = "$want" ] && ok || bad "C4 RESOURCE lines: $got, want $want ($nfix rows + $nper per-project rows x 2 projects)"
has "RESOURCE cloudflare d1 harness-jobs create from=fixed" && ok || bad "C4 no D1 harness-jobs create row"
has "RESOURCE cloudflare worker harness-jobs create from=fixed" && ok || bad "C4 no jobs worker row"
has "RESOURCE cloudflare pages acme-console create from=CONSOLE_PAGES_PROJECT" && ok || bad "C4 Pages row does not carry the operator's project"
has "RESOURCE cloudflare r2 acme-backup create from=BACKUP_S3_BUCKET" && ok || bad "C4 R2 row does not carry the operator's bucket"
has "RESOURCE fly app builder-web create from=SELFHOST_PROJECTS" && ok || bad "C4 no builder-web row"
has "RESOURCE fly app builder-api create from=SELFHOST_PROJECTS" && ok || bad "C4 no builder-api row"
has "RESOURCE github app-installation acme-org create from=HARNESS_GH_OWNER" && ok || bad "C4 GH owner not derived from HARNESS_REPO"
for p in cloudflare fly vm github model chat; do
  [ "$(cnt "^RESOURCE $p ")" -ge 1 ] && ok || bad "C4 no RESOURCE line for provider $p"
done
nc=$(cnt '^RESOURCE .* create from='); nr=$(cnt '^RESOURCE .* recorded from='); ns=$(cnt '^RESOURCE .* skip(')
has "SUMMARY resources=$got create=$nc recorded=$nr skipped=$ns live_calls=0 writes=0" && ok || bad "C4 SUMMARY does not equal the counted lines ($got/$nc/$nr/$ns): $(printf '%s\n' "$OUT" | grep SUMMARY)"
[ $((nc + nr + ns)) = "$got" ] && ok || bad "C4 actions do not add up: $nc+$nr+$ns != $got"
has "ENV HARNESS_REPO=acme-org/acme-harness" && ok || bad "C4 no ENV HARNESS_REPO line"
has "ENV HARNESS_GH_OWNER=acme-org" && ok || bad "C4 no derived ENV HARNESS_GH_OWNER line"
has "ENV HARNESS_BOT_GIT_EMAIL=op@acme.example" && ok || bad "C4 bot email not set from the operator's (would inherit ours)"
calls_clean C4

# ── C6: a full run writes nothing ────────────────────────────────────────────
snap() { find "$T" -path "$T/calls.log" -prune -o -path "$T/err" -prune -o -printf '%p %s %T@\n' | sort; }
before=$(snap)
bash "$SH" --config "$T/full.conf" --state "$T/state-c6" >/dev/null 2>&1
after=$(snap)
[ "$before" = "$after" ] && ok || bad "C6 the dry-run wrote under \$T: $(diff <(echo "$before") <(echo "$after"))"
[ ! -e "$T/state-c6" ] && ok || bad "C6 --state dir was created"

# ── C7: hub/pool matrix ──────────────────────────────────────────────────────
for hp in fly/fly vm/local fly/local vm/fly; do
  h=${hp%/*}; p=${hp#*/}
  conf "$T/c7.conf" SELFHOST_HUB="$h" SELFHOST_POOL="$p" SELFHOST_HUB_HOST=hub.acme.example
  run --config "$T/c7.conf"
  [ "$RC" = 0 ] && ok || bad "C7 $hp: rc=$RC ($ERR)"
  if [ "$h" = fly ]; then
    has "RESOURCE fly app acme-hub create from=HARNESS_HUB_BOX" && ok || bad "C7 $hp: no fly hub app"
    has "RESOURCE vm host hub.acme.example skip(hub=vm) from=SELFHOST_HUB_HOST" && ok || bad "C7 $hp: vm row not skipped"
  else
    has "RESOURCE vm host hub.acme.example create from=SELFHOST_HUB_HOST" && ok || bad "C7 $hp: no vm hub row"
    has "RESOURCE fly app acme-hub skip(hub=fly) from=HARNESS_HUB_BOX" && ok || bad "C7 $hp: fly hub not skipped"
  fi
  for proj in web api; do
    if [ "$p" = fly ]; then
      has "RESOURCE fly app builder-$proj create from=SELFHOST_PROJECTS" && ok || bad "C7 $hp: no builder-$proj"
      has "RESOURCE fly volume builder-$proj/builder_data create from=SELFHOST_PROJECTS" && ok || bad "C7 $hp: no builder-$proj volume"
    else
      has "RESOURCE fly app builder-$proj skip(pool=fly) from=SELFHOST_PROJECTS" && ok || bad "C7 $hp: builder-$proj not skipped"
    fi
  done
  if [ "$hp" = vm/local ]; then
    [ "$(cnt '^RESOURCE fly .* create ')" = 0 ] && ok || bad "C7 vm/local still creates fly resources"
    grep -q '^SECRET FLY_API_TOKEN ' <<< "$OUT" && bad "C7 vm/local still asks for FLY_API_TOKEN" || ok
  fi
done
# FLY_ORG is only required when something is on Fly.
conf "$T/c7b.conf" SELFHOST_HUB=vm SELFHOST_POOL=local SELFHOST_HUB_HOST=hub.acme.example FLY_ORG=
run --config "$T/c7b.conf"
[ "$RC" = 0 ] && ok || bad "C7 vm/local without FLY_ORG: rc=$RC ($ERR)"
calls_clean C7

# ── C8: gh / model / chat ────────────────────────────────────────────────────
conf "$T/c8.conf" SELFHOST_GH_AUTH=app SELFHOST_MODEL_AUTH=oauth SELFHOST_CHAT=none
run --config "$T/c8.conf"
has "RESOURCE github pat acme-org skip(gh=pat) from=HARNESS_GH_OWNER" && ok || bad "C8 app: pat row not skipped"
has "SECRET GH_APP_PRIVATE_KEY_FILE needed-by=gh-app" && ok || bad "C8 app: no App key SECRET"
grep -q '^SECRET GH_TOKEN ' <<< "$OUT" && bad "C8 app: still asks for GH_TOKEN" || ok
has "SECRET CLAUDE_CODE_OAUTH_TOKEN needed-by=model-oauth" && ok || bad "C8 oauth: no CLAUDE_CODE_OAUTH_TOKEN"
grep -q '^SECRET ANTHROPIC_API_KEY ' <<< "$OUT" && bad "C8 oauth: still asks for ANTHROPIC_API_KEY" || ok
has "RESOURCE chat telegram-bot telegram skip(chat=telegram) from=fixed" && ok || bad "C8 chat=none: telegram row missing or not skipped"
has "RESOURCE chat slack-bot slack skip(chat=slack) from=fixed" && ok || bad "C8 chat=none: slack row missing or not skipped"
grep -qE '^SECRET (TELEGRAM|SLACK)_' <<< "$OUT" && bad "C8 chat=none: asks for a chat secret" || ok
[ "$(cnt '^SECRET CLOUDFLARE_API_TOKEN ')" = 1 ] && ok || bad "C8 SECRET lines are not deduped"
has "SECRET HARNESS_SECRET needed-by=cf-worker-jobs,cf-worker-watchdog" && ok || bad "C8 HARNESS_SECRET needed-by is not the joined id list"
has "SECRET FLY_API_TOKEN needed-by=fly-hub-app,fly-hub-volume,fly-pool-app,fly-pool-volume" && ok || bad "C8 per-project ids not deduped in needed-by"
conf "$T/c8b.conf" SELFHOST_GH_AUTH=pat SELFHOST_MODEL_AUTH=api-key SELFHOST_CHAT=telegram
run --config "$T/c8b.conf"
has "RESOURCE github pat acme-org create from=HARNESS_GH_OWNER" && ok || bad "C8 pat: no pat row"
has "SECRET GH_TOKEN needed-by=gh-pat" && ok || bad "C8 pat: no GH_TOKEN"
has "SECRET ANTHROPIC_API_KEY needed-by=model-api-key" && ok || bad "C8 api-key: no ANTHROPIC_API_KEY"
has "RESOURCE chat telegram-bot telegram create from=fixed" && ok || bad "C8 telegram: no create row"
has "SECRET TELEGRAM_BOT_TOKEN needed-by=chat-telegram" && ok || bad "C8 telegram: no bot token SECRET"
conf "$T/c8c.conf" SELFHOST_CHAT=slack
run --config "$T/c8c.conf"
has "RESOURCE chat slack-bot slack create from=fixed" && ok || bad "C8 slack: no create row"
has "SECRET SLACK_BOT_TOKEN needed-by=chat-slack" && ok || bad "C8 slack: no SLACK_BOT_TOKEN"
calls_clean C8

# ── C9: negatives ────────────────────────────────────────────────────────────
conf "$T/c9a.conf"; echo 'ANTHROPIC_API_KEY=sk-ant-xxx' >> "$T/c9a.conf"
run --config "$T/c9a.conf"
[ "$RC" = 1 ] && ok || bad "C9 secret key: rc=$RC, want 1"
grep -q 'ANTHROPIC_API_KEY' <<< "$ERR" && ok || bad "C9 secret refusal does not name the key: $ERR"
grep -q 'sk-ant-xxx' <<< "$OUT"$'\n'"$ERR" && bad "C9 the secret value was echoed" || ok
conf "$T/c9b.conf" "HARNESS_GIT_NAME=\$(touch $T/pwned)\`touch $T/pwned2\`;touch $T/pwned3"
run --config "$T/c9b.conf"
[ "$RC" = 0 ] && ok || bad "C9 injection value: rc=$RC ($ERR)"
[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] && [ ! -e "$T/pwned3" ] && ok || bad "C9 a settings value was executed"
has "ENV HARNESS_GIT_NAME=\$(touch $T/pwned)\`touch $T/pwned2\`;touch $T/pwned3" && ok || bad "C9 injection value not printed verbatim"
conf "$T/c9c.conf"; echo 'SELFHOST_HUB_HOTS=x' >> "$T/c9c.conf"
run --config "$T/c9c.conf"
[ "$RC" = 1 ] && grep -q SELFHOST_HUB_HOTS <<< "$ERR" && ok || bad "C9 unknown key: rc=$RC ($ERR)"
conf "$T/c9d.conf"; echo 'FLY_ORG=other' >> "$T/c9d.conf"
run --config "$T/c9d.conf"
[ "$RC" = 1 ] && grep -q 'FLY_ORG' <<< "$ERR" && ok || bad "C9 duplicate key: rc=$RC ($ERR)"
conf "$T/c9e.conf" SELFHOST_PROJECTS=app=notaslug
run --config "$T/c9e.conf"
[ "$RC" = 1 ] && ok || bad "C9 bad slug: rc=$RC"
conf "$T/c9f.conf" "SELFHOST_PROJECTS=web=acme-org/web web=acme-org/web2"
run --config "$T/c9f.conf"
[ "$RC" = 1 ] && grep -q web <<< "$ERR" && ok || bad "C9 duplicate project: rc=$RC ($ERR)"
conf "$T/c9g.conf" FLY_ORG=
run --config "$T/c9g.conf"
[ "$RC" = 1 ] && grep -q FLY_ORG <<< "$ERR" && ok || bad "C9 hub=fly without FLY_ORG: rc=$RC ($ERR)"
conf "$T/c9h.conf" SELFHOST_HUB=vm SELFHOST_HUB_HOST=
run --config "$T/c9h.conf"
[ "$RC" = 1 ] && grep -q SELFHOST_HUB_HOST <<< "$ERR" && ok || bad "C9 hub=vm without host: rc=$RC ($ERR)"
conf "$T/c9i.conf" HARNESS_REPO= HARNESS_GH_OWNER=
run --config "$T/c9i.conf"
[ "$RC" = 1 ] && grep -q HARNESS_REPO <<< "$ERR" && grep -q HARNESS_GH_OWNER <<< "$ERR" && ok || bad "C9 blank repo+owner not both named: rc=$RC ($ERR)"
conf "$T/c9j.conf" SELFHOST_HUB=cloud
run --config "$T/c9j.conf"
[ "$RC" = 1 ] && ok || bad "C9 enum outside its set: rc=$RC"
conf "$T/c9k.conf"; echo 'export FOO=1' >> "$T/c9k.conf"
run --config "$T/c9k.conf"
[ "$RC" = 1 ] && ok || bad "C9 a non KEY=value line: rc=$RC"
run --config "$T/does-not-exist.conf"
[ "$RC" = 1 ] && grep -q 'cannot read' <<< "$ERR" && ok || bad "C9 missing file: rc=$RC ($ERR)"
conf "$T/c9l.conf"; sed -i 's/$/\r/' "$T/c9l.conf"
run --config "$T/c9l.conf"
[ "$RC" = 0 ] && has "ENV HARNESS_HUB_BOX=acme-hub" && ok || bad "C9 CRLF config: rc=$RC ($ERR)"
conf "$T/c9m.conf" 'CONSOLE_PAGES_PROJECT="acme-console"'
run --config "$T/c9m.conf"
has "RESOURCE cloudflare pages acme-console create from=CONSOLE_PAGES_PROJECT" && ok || bad "C9 a quoted value kept its quotes"
calls_clean C9

# ── C10: ledger marks recorded; two runs are byte-identical ─────────────────
mkdir -p "$T/state"
printf 'cloudflare\td1\tharness-jobs\tabc-123\t2026-10-04T00:00:00Z\nfly\tapp\tnot-in-catalog\tx\t2026-10-04T00:00:00Z\n' > "$T/state/ledger.tsv"
run --config "$T/full.conf" --state "$T/state"
has "RESOURCE cloudflare d1 harness-jobs recorded from=fixed" && ok || bad "C10 ledger row not marked recorded"
has "RESOURCE cloudflare d1 harness-locks create from=fixed" && ok || bad "C10 a row not in the ledger is not create"
[ "$(cnt '^RESOURCE .* recorded ')" = 1 ] && ok || bad "C10 more than one recorded row"
first="$OUT"
run --config "$T/full.conf" --state "$T/state"
[ "$first" = "$OUT" ] && ok || bad "C10 two runs differ"
run --config "$T/full.conf" --state "$T/no-such-state"
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok || bad "C10 absent state dir: rc=$RC err=$ERR"
calls_clean C10

# ── C11: caps ────────────────────────────────────────────────────────────────
run --config "$T/full.conf"
has "CAP AGENT_CALL_BUDGET_USD=5" && ok || bad "C11 no per-call cap line"
has "CAP LLM_USD_CAP_DAY=20" && ok || bad "C11 no per-day cap line"
has "CAP calls/tokens: no enforcing knob in this harness yet; dollars are the cap" && ok || bad "C11 no calls/tokens honesty line"
for v in 0 0.00 -5 abc ''; do
  conf "$T/c11.conf" SELFHOST_CAP_USD_PER_CALL="$v"
  run --config "$T/c11.conf"
  [ "$RC" = 1 ] && grep -q SELFHOST_CAP_USD_PER_CALL <<< "$ERR" && ok || bad "C11 per-call cap '$v' accepted: rc=$RC"
  conf "$T/c11.conf" SELFHOST_CAP_USD_DAY="$v"
  run --config "$T/c11.conf"
  [ "$RC" = 1 ] && grep -q SELFHOST_CAP_USD_DAY <<< "$ERR" && ok || bad "C11 per-day cap '$v' accepted: rc=$RC"
done
conf "$T/c11.conf" SELFHOST_CAP_USD_PER_CALL=2.5
run --config "$T/c11.conf"
has "CAP AGENT_CALL_BUDGET_USD=2.5" && ok || bad "C11 a decimal cap is not accepted"
conf "$T/c11.conf" SELFHOST_CAPS_OFF=1 SELFHOST_CAP_USD_PER_CALL=0
run --config "$T/c11.conf"
[ "$RC" = 0 ] && has "CAP off (SELFHOST_CAPS_OFF=1)" && ok || bad "C11 SELFHOST_CAPS_OFF=1 does not print CAP off: rc=$RC ($ERR)"
grep -q '^CAP AGENT_CALL_BUDGET_USD' <<< "$OUT" && bad "C11 caps off still prints a cap" || ok
has "CAP calls/tokens: no enforcing knob in this harness yet; dollars are the cap" && ok || bad "C11 caps off drops the honesty line"
conf "$T/c11.conf" SELFHOST_CAPS_OFF=yes
run --config "$T/c11.conf"
[ "$RC" = 1 ] && ok || bad "C11 SELFHOST_CAPS_OFF=yes accepted: rc=$RC"
calls_clean C11

# ── C12: none of our deployment literals in someone else's plan ─────────────
run --config "$T/full.conf"
leaks=$(printf '%s\n' "$OUT" | python3 -c '
import re, sys
fams = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
for line in sys.stdin:
    for f in fams:
        if re.search(f[1], line):
            print(f[0] + ": " + line.rstrip())
' "$FAMS")
[ -z "$leaks" ] && ok || bad "C12 our deployment literals leaked into the plan: $leaks"

# ── C13: --apply refuses, nothing created ────────────────────────────────────
run --config "$T/full.conf" --apply
[ "$RC" = 2 ] && ok || bad "C13 --apply: rc=$RC, want 2"
grep -qF 'selfhost-install: --apply is not built yet (BH-4081 slice C0 ships the dry-run); nothing was created' <<< "$ERR" && ok || bad "C13 --apply line: $ERR"
[ -z "$OUT" ] && ok || bad "C13 --apply printed a plan"
calls_clean C13

# ── C14: a malformed catalog is rc 3 naming path:line ───────────────────────
{ grep '^#' "$CAT" | head -2; grep -v '^#' "$CAT" | head -3; printf 'broken\tcloudflare\td1\n'; } > "$T/bad.tsv"
OUT=$(SELFHOST_CATALOG="$T/bad.tsv" bash "$SH" --config "$T/full.conf" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
[ "$RC" = 3 ] && grep -qF "catalog $T/bad.tsv:6 malformed" <<< "$ERR" && ok || bad "C14 malformed catalog: rc=$RC ($ERR)"
printf 'x1\tcloudflare\td1\tn\tfixed\tsometimes\t-\tnote\n' > "$T/bad2.tsv"
OUT=$(SELFHOST_CATALOG="$T/bad2.tsv" bash "$SH" --config "$T/full.conf" 2>"$T/err"); RC=$?
[ "$RC" = 3 ] && ok || bad "C14 a when outside the closed set: rc=$RC"
printf 'x1\tcloudflare\td1\t${NOPE}\tNOPE\talways\t-\tnote\n' > "$T/bad3.tsv"
OUT=$(SELFHOST_CATALOG="$T/bad3.tsv" bash "$SH" --config "$T/full.conf" 2>"$T/err"); RC=$?
[ "$RC" = 3 ] && ok || bad "C14 a name naming an unknown setting: rc=$RC"
OUT=$(SELFHOST_CATALOG="$T/nope.tsv" bash "$SH" --config "$T/full.conf" 2>"$T/err"); RC=$?
[ "$RC" = 3 ] && ok || bad "C14 an unreadable catalog: rc=$RC"
calls_clean C14

# ── usage, verbatim from the script's own header (D7) ────────────────────────
run --help
[ "$RC" = 0 ] && grep -q 'selfhost-install.sh --config <file>' <<< "$OUT" && ok || bad "usage: --help rc=$RC"
run
[ "$RC" = 2 ] && ok || bad "usage: no --config rc=$RC, want 2"

echo "selfhost-install-dryrun.bh-4081: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
