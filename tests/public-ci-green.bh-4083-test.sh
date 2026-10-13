#!/bin/bash
# tests/public-ci-green.bh-4083-test.sh — the public copy carries its licence,
# its contributor files and a CI that is green on it (BH-4083).
#
# The public repo, cromford-ai/cromford, is whatever bin/publish-share.sh
# builds. Its first push happens only once an operator arms the deploy key, and
# its CI has to be green on that first push. This suite is the local half of
# that claim: it builds the public tree with the real publisher
# (--dry-run --out, aimed at the public target), checks the files a public
# Apache-2.0 repo needs are in it, and then RUNS every step of the CI it ships,
# inside that tree.
#
# Steps that install a tool are not run (they download); the gitleaks one is
# checked for the repo's pin instead. A step whose tool is absent here is a
# SKIP, never a pass, and CI's GITLEAKS_REQUIRED turns a missing gitleaks into a
# FAIL.
#
# Run from anywhere: tests/public-ci-green.bh-4083-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4080: scratch.sh points deployment-defaults consumers at THIS checkout's
# bin/lib/deployment.sh. The mirror's scripts must read the mirror's own,
# sanitized copy, or its crontab regeneration looks for unsanitized box names.
unset HARNESS_DEPLOYMENT_FILE
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "public-ci-green.bh-4083-test: $PASS pass, $FAIL fail, $SKIP skip"; [ "$FAIL" -eq 0 ]; exit; }

if [ ! -f "$DIR/bin/publish-share.sh" ]; then
  echo "SKIP public-ci-green: no bin/publish-share.sh in this copy (the mirror does not ship it)"
  exit 0
fi
if ! command -v gitleaks >/dev/null 2>&1; then
  if [ -n "${GITLEAKS_REQUIRED:-}" ]; then
    bad "GITLEAKS_REQUIRED is set but gitleaks is not on PATH — the publisher cannot build without it (BH-2059)"
  else
    SKIP=$((SKIP+1))
    echo "SKIP public-ci-green: gitleaks not on PATH, and bin/publish-share.sh refuses to build without it (CI sets GITLEAKS_REQUIRED)"
  fi
  done_
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  bad "python3 yaml is required to read the shipped workflow and issue forms"; done_
fi

# ── 1. build the public tree with the real publisher ────────────────────────
# --ref HEAD: the commit under test. GH_TOKEN is a dummy so the publisher does
# not go looking for a real credential; its read of the published head may
# fail, which it treats as "unpublished" — and --dry-run pushes nothing.
M="$T/mirror"
( unset SHARE_MIRROR_REPO; GH_TOKEN=dummy-not-used \
  bash "$DIR/bin/publish-share.sh" --dry-run --repo cromford-ai/cromford --ref HEAD --out "$M" ) > "$T/publish.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'guard clean' "$T/publish.out" \
   && grep -q 'would push .* to cromford-ai/cromford main\|already identical' "$T/publish.out"; then ok
else
  bad "1 publish-share.sh --dry-run --repo cromford-ai/cromford exited $rc:"; tail -30 "$T/publish.out"; done_
fi

# ── 2. licence and contributor files ────────────────────────────────────────
head -3 "$M/LICENSE" 2>/dev/null | grep -q 'Apache License' && grep -q 'Version 2.0, January 2004' "$M/LICENSE" \
  && grep -q 'END OF TERMS AND CONDITIONS' "$M/LICENSE" && ok || bad "2 LICENSE must be the Apache License 2.0 text"
grep -q 'Cromford' "$M/NOTICE" 2>/dev/null && ! grep -qi 'private' "$M/NOTICE" && ok \
  || bad "2 NOTICE must name Cromford and must not call anything private"
grep -q 'Apache' "$M/CONTRIBUTING.md" 2>/dev/null && grep -q 'docs/ABOUT.md\|https://cromford.dev' "$M/CONTRIBUTING.md" && ok \
  || bad "2 CONTRIBUTING.md must state the Apache inbound=outbound terms and link the guide"
for f in bug.yml feature.yml config.yml; do
  [ -f "$M/.github/ISSUE_TEMPLATE/$f" ] && ok || bad "2 .github/ISSUE_TEMPLATE/$f is missing"
done
python3 - "$M/.github/ISSUE_TEMPLATE" > "$T/forms.out" 2>&1 <<'PY'
import os, sys, yaml
d = sys.argv[1]
cfg = yaml.safe_load(open(os.path.join(d, "config.yml")))
assert cfg.get("blank_issues_enabled") is False, "config.yml must disable blank issues"
for f in ("bug.yml", "feature.yml"):
    form = yaml.safe_load(open(os.path.join(d, f)))
    for k in ("name", "description", "body"):
        assert form.get(k), "%s needs %s" % (f, k)
    text = open(os.path.join(d, f)).read().lower()
    assert "key" in text and "private" in text, "%s must warn against pasting keys or private content" % f
print("forms ok")
PY
[ $? -eq 0 ] && ok || { bad "2 the issue forms are malformed:"; cat "$T/forms.out"; }

# ── 3. the only workflow is the public CI ───────────────────────────────────
WFS=$(cd "$M/.github/workflows" 2>/dev/null && ls -1)
[ "$WFS" = "ci.yml" ] && ok || bad "3 .github/workflows in the public tree must hold only ci.yml (got: $(tr '\n' ' ' <<<"$WFS"))"

# ── 4. the shipped CI, step by step, inside the public tree ─────────────────
python3 - "$M/.github/workflows/ci.yml" "$T/ci" > "$T/ci-parse.out" 2>&1 <<'PY'
import os, sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); out = sys.argv[2]
os.makedirs(out, exist_ok=True)
on = wf.get(True, wf.get("on")) or {}
assert "push" in on and "pull_request" in on, "triggers must be push and pull_request"
import re
raw = open(sys.argv[1]).read()
assert not re.search(r"\$\{\{[^}]*\b(secrets|vars)\.", raw), "the public CI must need no secrets and no repo variables"
n = 0
for job in wf["jobs"].values():
    assert job.get("runs-on") == "ubuntu-latest", "runs-on must be ubuntu-latest"
    for s in job["steps"]:
        if "run" not in s:
            continue
        n += 1
        name = s.get("name", "step %d" % n)
        open(os.path.join(out, "%02d.sh" % n), "w").write(s["run"])
        open(os.path.join(out, "%02d.name" % n), "w").write(name)
assert n >= 4, "expected at least four run steps, found %d" % n
print("steps=%d" % n)
PY
if [ $? -ne 0 ]; then bad "4 ci.yml does not have the required shape:"; cat "$T/ci-parse.out"; done_; fi
ok
SEEN_SC=0 SEEN_GL=0 SEEN_GUARD=0 SEEN_SYNTAX=0
for s in "$T"/ci/*.sh; do
  name=$(cat "${s%.sh}.name"); lname=$(tr '[:upper:]' '[:lower:]' <<<"$name")
  case "$lname" in
    install*gitleaks*)
      PIN=$(bash -c '. "$1" && echo "$GITLEAKS_PIN_VERSION $GITLEAKS_PIN_SHA256"' _ "$DIR/bin/lib/gitleaks-pin.sh" 2>/dev/null)
      WPIN="$(sed -n 's/^V=\([0-9][0-9.]*\).*/\1/p' "$s" | head -1) $(sed -n 's/^SHA=\([0-9a-f]\{64\}\)$/\1/p' "$s" | head -1)"
      [ -n "$PIN" ] && [ "$PIN" = "$WPIN" ] && ok || bad "4 '$name' pins gitleaks '$WPIN', bin/lib/gitleaks-pin.sh says '$PIN'"
      grep -q 'sha256sum -c' "$s" && ok || bad "4 '$name' must verify the download's sha256"
      continue ;;
    *shellcheck*)
      SEEN_SC=1
      if ! command -v shellcheck >/dev/null 2>&1; then
        SKIP=$((SKIP+1)); echo "SKIP 4 '$name': shellcheck not on PATH"; continue
      fi ;;
    *gitleaks*) SEEN_GL=1 ;;
    *identifier*|*leak\ guard*) SEEN_GUARD=1 ;;
    *syntax*|*bash\ -n*) SEEN_SYNTAX=1 ;;
  esac
  mkdir -p "$T/rt"
  ( cd "$M" && RUNNER_TEMP="$T/rt" bash --noprofile --norc -eo pipefail "$s" ) > "$T/step.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then ok
  else bad "4 ci.yml step '$name' exited $rc in the public tree:"; tail -25 "$T/step.out"; fi
done
[ "$SEEN_SYNTAX" = 1 ] && ok || bad "4 ci.yml has no bash -n syntax step"
[ "$SEEN_SC" = 1 ] && ok || bad "4 ci.yml has no shellcheck step"
[ "$SEEN_GUARD" = 1 ] && ok || bad "4 ci.yml does not run tests/no-client-identifiers-test.sh"
[ "$SEEN_GL" = 1 ] && ok || bad "4 ci.yml has no gitleaks scan step"
grep -q 'tests/no-client-identifiers-test.sh' "$M/.github/workflows/ci.yml" && ok \
  || bad "4 ci.yml must run tests/no-client-identifiers-test.sh"

if command -v actionlint >/dev/null 2>&1; then
  actionlint "$M/.github/workflows/ci.yml" > "$T/actionlint.out" 2>&1 && ok \
    || { bad "4 actionlint rejected ci.yml:"; cat "$T/actionlint.out"; }
else
  SKIP=$((SKIP+1)); echo "SKIP actionlint: not on PATH"
fi

done_
