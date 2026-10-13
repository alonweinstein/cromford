#!/bin/bash
# tests/cromford-guide.bh-4084-test.sh — the install guide in docs/ (BH-4084).
#
# The guide is docs/guide.md plus every page it lists. bin/guide-check.py is
# its checker; every case below drives that CLI, over the real docs and over
# fixtures under tests/fixtures/guide-check.bh-4084/ that must go red.
#
#   AT1  real guide rc 0; a missing link target and a missing #anchor rc 1,
#        naming the file; GitHub slug rules (punctuation, backticks, -1 dups)
#   AT2  optional-services.md: 7 sections x 6 fields; a field or a section
#        removed goes red and says which
#   AT3  referral links go red (5 shapes); look-alikes do not
#   AT4  an unknown setting or a missing bin/ path goes red
#   AT5  bin/share/leakcheck.py is clean over the pages and catches an
#        injected mapping token; a #1234 ticket ref goes red
#   AT6  the diff touches no site/, LICENSE, NOTICE, SELF-HOST.md, cloud page
#   AT7  the quickstart's bin/ commands exist, and its dry-run line runs
#        verbatim on a filled template (rc 0, SUMMARY ... live_calls=0)
#   AT8  the five model vendors in "What you need"; "What still needs Claude
#        today"; the worked example's rung 0 is not claude
#   AT9  page order in guide.md; quickstart "What you need" links the
#        optional services page
#   AT10 no Programs line on Fly, MonkCI or Orgo; the "Programs change" note
#        on every service
#   AT11 the repo URL is named and no page says it is public or live
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/cromford-guide.bh-4084-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CHK="$DIR/bin/guide-check.py"
FX="$DIR/tests/fixtures/guide-check.bh-4084"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { OUT=$(python3 "$CHK" "$@" 2>&1); RC=$?; }

# guide_root <dest>: a root that looks like a checkout, with docs/ copied so a
# case can edit it and everything else linked.
guide_root() {
  mkdir -p "$1"
  cp -r "$DIR/docs" "$1/docs"
  for p in "$DIR"/* "$DIR"/.[!.]*; do
    case "${p##*/}" in docs|.git) ;; *) ln -s "$p" "$1/${p##*/}" ;; esac
  done
}
pages() { python3 - "$1" <<'PY'
import re, sys
t = open(sys.argv[1] + "/docs/guide.md").read()
for m in re.findall(r"\]\(([^)#\s]+\.md)", t):
    print(m)
PY
}
# inject <file> <text>: <text> as a paragraph just above "## At a glance", so
# the page still ends with its table and only the check under test can fire.
inject() { python3 - "$1" "$2" <<'PY'
import sys
p, s = sys.argv[1], sys.argv[2]
t = open(p).read()
assert "\n## At a glance" in t, "no At a glance section"
open(p, "w").write(t.replace("\n## At a glance", "\n" + s + "\n\n## At a glance", 1))
PY
}

# AT1
check
[ "$RC" = 0 ] && ok || bad "AT1 real guide rc=$RC: $OUT"
check --root "$FX/broken-link"
[ "$RC" = 1 ] && [[ "$OUT" == *"docs/guide.md: link missing.md"* ]] && ok || bad "AT1 broken link rc=$RC: $OUT"
check --root "$FX/broken-anchor"
[ "$RC" = 1 ] && [[ "$OUT" == *"docs/guide.md: link page.md#no-such-heading"* ]] && ok || bad "AT1 broken anchor rc=$RC: $OUT"
check --root "$FX/anchors"
[ "$RC" = 0 ] && ok || bad "AT1 GitHub slug rules rc=$RC: $OUT"

# AT2
R="$T/at2"; guide_root "$R"
check --root "$R"
[ "$RC" = 0 ] && ok || bad "AT2 scratch copy of the real guide rc=$RC: $OUT"
SVC="$R/docs/optional-services.md"
python3 - "$SVC" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
head, sep, rest = t.partition("## Mergify")
body, nxt, tail = rest.partition("\n## ")
assert "**Free tier.**" in body, "no Free tier field in the Mergify section"
open(p, "w").write(head + sep + body.replace("**Free tier.**", "Free tier:") + nxt + tail)
PY
check --root "$R"
[ "$RC" = 1 ] && [[ "$OUT" == *"section Mergify has no **Free tier.** field"* ]] && ok || bad "AT2 Free tier removed rc=$RC: $OUT"
cp "$DIR/docs/optional-services.md" "$SVC"
python3 - "$SVC" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
t2 = re.sub(r"\n## CodeRabbit\n.*?(?=\n## )", "\n", t, count=1, flags=re.S)
assert t2 != t, "no CodeRabbit section to delete"
open(p, "w").write(t2)
PY
check --root "$R"
[ "$RC" = 1 ] && [[ "$OUT" == *"6 service sections, expected 7"* ]] && ok || bad "AT2 section deleted rc=$RC: $OUT"
cp "$DIR/docs/optional-services.md" "$SVC"
sed -i "s/^| Service | What it's for | Required? | Setting |\$/| Service | Purpose | Required? | Setting |/" "$SVC"
check --root "$R"
[ "$RC" = 1 ] && [[ "$OUT" == *"does not end with the table"* ]] && ok || bad "AT2 table header changed rc=$RC: $OUT"
cp "$DIR/docs/optional-services.md" "$SVC"
printf '\nSee [the site](http://example.com).\n' >> "$R/docs/upgrading.md"
check --root "$R"
[ "$RC" = 1 ] && [[ "$OUT" == *"link http://example.com is not https://"* ]] && ok || bad "AT1 http:// link rc=$RC: $OUT"
cp "$DIR/docs/upgrading.md" "$R/docs/upgrading.md"

# AT3
check --root "$FX/referral"
n=$(grep -c ': referral link ' <<< "$OUT")
[ "$RC" = 1 ] && [ "$n" = 5 ] && ok || bad "AT3 referral fixture rc=$RC lines=$n: $OUT"
check --root "$FX/referral-negatives"
[ "$RC" = 0 ] && ok || bad "AT3 referral look-alikes rc=$RC: $OUT"
inject "$SVC" 'See [Mergify](https://mergify.com/pricing?ref=x).'
check --root "$R"
[ "$RC" = 1 ] && [[ "$OUT" == *"optional-services.md: referral link"* ]] && [[ "$OUT" == *", 1 failures"* ]] && ok || bad "AT3 ?ref= on a real page rc=$RC: $OUT"
cp "$DIR/docs/optional-services.md" "$SVC"

# AT4
inject "$SVC" 'Set `SELFHOST_NOT_A_SETTING` to 1.'
check --root "$R"
[ "$RC" = 1 ] && [[ "$OUT" == *"setting SELFHOST_NOT_A_SETTING"* ]] && [[ "$OUT" == *", 1 failures"* ]] && ok || bad "AT4 unknown setting rc=$RC: $OUT"
cp "$DIR/docs/optional-services.md" "$SVC"
printf '\nRun `bin/does-not-exist.sh`.\n' >> "$R/docs/upgrading.md"
check --root "$R"
[ "$RC" = 1 ] && [[ "$OUT" == *"path bin/does-not-exist.sh does not exist"* ]] && [[ "$OUT" == *", 1 failures"* ]] && ok || bad "AT4 missing path rc=$RC: $OUT"
cp "$DIR/docs/upgrading.md" "$R/docs/upgrading.md"

# AT5. The public copy drops bin/share/ (its own leak guard is
# tests/no-client-identifiers-test.sh), so there the leakcheck half is skipped.
if [ -f "$DIR/bin/share/leakcheck.py" ]; then
  L="$T/leak"; mkdir -p "$L"
  cp "$DIR/docs/guide.md" "$L/"
  while read -r p; do cp "$DIR/docs/$p" "$L/"; done < <(pages "$DIR")
  out=$(python3 "$DIR/bin/share/leakcheck.py" "$L" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok || bad "AT5 leakcheck over the guide pages rc=$rc: $out"
  tok=$(cd "$DIR/bin/share" && python3 -c 'import mapping; print(mapping.PROJECT_N["project-1"][0])')
  printf '\nBuilt for %s.\n' "$tok" >> "$L/quickstart.md"
  out=$(python3 "$DIR/bin/share/leakcheck.py" "$L" --quiet 2>&1); rc=$?
  [ "$rc" = 1 ] && ok || bad "AT5 injected mapping token not caught rc=$rc"
else
  echo "AT5 leakcheck skipped: no bin/share/ in this copy"
fi
check --root "$FX/ticket-ref"
[ "$RC" = 1 ] && [[ "$OUT" == *"internal ticket ref #4686"* ]] && ok || bad "AT5 ticket ref rc=$RC: $OUT"

# AT6 judges this ticket's OWN slice only: on another ticket's branch (which may
# edit SELF-HOST.md for its own reasons) or a merge-queue batch it is inert.
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-4084's own slice
  touched=$(git -C "$DIR" diff --name-only origin/main...HEAD 2>/dev/null)
  ref="${GITHUB_HEAD_REF:-$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
  case "$ref" in mergify/merge-queue/*) touched="" ;; esac
  if grep -qE '^\.harness/specs/BH-4084/' <<< "$touched" || [[ "$ref" == ticket/bh-4084* ]]; then
    hits=$(grep -E '^(site/|LICENSE|NOTICE|docs/SELF-HOST\.md$|docs/cloud[^/]*\.md$)|/(LICENSE|NOTICE)$' <<< "$touched" || true)
    [ -z "$hits" ] && ok || bad "AT6 the diff touches out-of-scope files: $hits"
  else
    echo "AT6 inert: this branch is not BH-4084's slice"
  fi
else
  echo "AT6 skipped: no origin/main in this checkout"
fi

# AT7
QS="$DIR/docs/quickstart.md"
mapfile -t cmds < <(awk '/^```(bash|sh)[[:space:]]*$/{f=1; next} /^```/{f=0; next} f' "$QS" | grep -vE '^[[:space:]]*(#|$)')
[ "${#cmds[@]}" -ge 3 ] && ok || bad "AT7 fewer than 3 commands in the quickstart (${#cmds[@]})"
dry=""
for line in "${cmds[@]}"; do
  read -r -a w <<< "$line"
  case "${w[0]}" in bin/*) [ -x "$DIR/${w[0]}" ] && ok || bad "AT7 ${w[0]} is not an executable script" ;; esac
  [[ "$line" == bin/selfhost-install.sh* ]] && dry="$line"
done
Q="$T/qs"; mkdir -p "$Q"
for p in bin catalog env-templates; do ln -s "$DIR/$p" "$Q/$p"; done
cp "$DIR/env-templates/selfhost.conf.example" "$Q/selfhost.conf"
sed -i -e 's|^SELFHOST_CF_ACCOUNT_ID=$|SELFHOST_CF_ACCOUNT_ID=00000000000000000000000000000000|' \
  -e 's|^HARNESS_WORKERS_SUBDOMAIN=$|HARNESS_WORKERS_SUBDOMAIN=example-sub|' \
  -e 's|^CONSOLE_PAGES_PROJECT=$|CONSOLE_PAGES_PROJECT=example-console|' \
  -e 's|^BACKUP_S3_BUCKET=$|BACKUP_S3_BUCKET=example-backup|' \
  -e 's|^HARNESS_REPO=$|HARNESS_REPO=example-owner/example-harness|' \
  -e 's|^HARNESS_OPERATOR_LOGIN=$|HARNESS_OPERATOR_LOGIN=example-owner|' \
  -e 's|^HARNESS_GIT_NAME=$|HARNESS_GIT_NAME=example-owner|' \
  -e 's|^HARNESS_GIT_EMAIL=$|HARNESS_GIT_EMAIL=owner@example.com|' \
  -e 's|^SELFHOST_GH_AUTH=$|SELFHOST_GH_AUTH=app|' \
  -e 's|^HARNESS_BOX_PREFIX=$|HARNESS_BOX_PREFIX=example-|' \
  -e 's|^HARNESS_HUB_BOX=$|HARNESS_HUB_BOX=example-hub|' \
  -e 's|^SELFHOST_HUB=$|SELFHOST_HUB=vm|' \
  -e 's|^SELFHOST_HUB_HOST=$|SELFHOST_HUB_HOST=hub.example.com|' \
  -e 's|^SELFHOST_POOL=$|SELFHOST_POOL=local|' \
  -e 's|^SELFHOST_PROJECTS=$|SELFHOST_PROJECTS=web=example-owner/web|' \
  -e 's|^SELFHOST_MODEL_AUTH=$|SELFHOST_MODEL_AUTH=api-key|' "$Q/selfhost.conf"
if [ -n "$dry" ]; then
  out=$(cd "$Q" && bash -c "$dry" 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q 'SUMMARY .*live_calls=0 writes=0' <<< "$out" && ok || bad "AT7 '$dry' on a filled template rc=$rc: $out"
else
  bad "AT7 the quickstart has no bin/selfhost-install.sh line"
fi

# AT8
grep -qF "a model key for at least one of: Claude, Codex, Grok, OpenRouter, Fireworks" "$QS" && ok || bad "AT8 quickstart does not name the five model vendors"
CM="$DIR/docs/choosing-models.md"
grep -qE '^## What still needs Claude today' "$CM" && ok || bad "AT8 no 'What still needs Claude today' heading"
r0=$(python3 - "$CM" <<'PY'
import json, re, sys
t = open(sys.argv[1]).read()
sec = t.split("## Worked example", 1)[1] if "## Worked example" in t else ""
m = re.search(r"```json\n(.*?)\n```", sec, re.S)
print(json.loads(m.group(1))["ladder"][0]["runner"] if m else "none")
PY
)
[ -n "$r0" ] && [ "$r0" != none ] && [ "$r0" != claude ] && ok || bad "AT8 worked example rung 0 runner is '$r0'"

# AT9
order=$(pages "$DIR" | tr '\n' ' ')
want="quickstart.md SELF-HOST.md connecting-a-board.md onboarding-a-repo.md choosing-models.md optional-services.md spending-caps.md upgrading.md "
[ "$order" = "$want" ] && ok || bad "AT9 page order is '$order', want '$want'"
awk '/^## What you need/{f=1; next} /^## /{f=0} f' "$QS" | grep -q '](optional-services.md)' && ok || bad "AT9 'What you need' does not link optional-services.md"

# AT10
python3 - "$DIR/docs/optional-services.md" <<'PY' && ok || bad "AT10 Programs lines"
import re, sys
t = open(sys.argv[1]).read()
secs = dict(re.findall(r"^## (.+?)\n(.*?)(?=^## |\Z)", t, re.S | re.M))
errs = [n for n in secs if re.match(r"(Fly|MonkCI|Orgo)", n) and "**Programs.**" in secs[n]]
errs += [n + " (no note)" for n in secs if n != "At a glance"
         and "Programs change; check the vendor's page." not in secs[n]]
print("\n".join(errs)); sys.exit(1 if errs or len(secs) != 8 else 0)
PY

# AT11
grep -q 'github.com/cromford-ai/cromford' "$QS" && ok || bad "AT11 the quickstart does not name github.com/cromford-ai/cromford"
live=$(cd "$DIR/docs" && grep -niE '\b(is|now) (public|live)\b' guide.md $(pages "$DIR") || true)
[ -z "$live" ] && ok || bad "AT11 a page says the repo is public or live: $live"

echo "cromford-guide: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
