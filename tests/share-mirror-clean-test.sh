#!/bin/bash
# tests/share-mirror-clean-test.sh — the public mirror this checkout would
# build must be clean BEFORE the branch merges, not after.
#
# THE SILENCE THIS KILLS (2026-09-18). "Publish share mirror" is a required
# workflow on main and it had been red on every push for three shas. Every hit
# was a fixture: a new test invented an OAuth token, a new spec quoted a Slack
# token, a new fleet fixture used a CGNAT address — and bin/share/mapping.py's
# allowlists are EXACT LITERALS by design, so each new fixture token refuses the
# publish until somebody adds it. Nothing on main ran the guard before a merge,
# so the only way to learn was to break main and read the run log.
#
# Two claims, and the second is the one that matters:
#
#   1. POSITIVE. bin/share/sanitize.py + bin/share/leakcheck.py on THIS
#      checkout exit 0, and the guard the mirror ships to contributors
#      (tests/no-client-identifiers-test.sh, run by bin/publish-share.sh one
#      step after leakcheck) agrees with it.
#   2. NEGATIVE. A credential-shaped string that is on no allowlist still
#      refuses, and names the file it is in. Without this the test would pass
#      just as well against a guard that had been gutted, which is exactly the
#      failure mode an allowlist invites.
#
# The planted string is assembled at run time. Written as a literal it would be
# a hit in this very file and case 1 would fail on the test that proves case 2.
#
# Run from anywhere: tests/share-mirror-clean-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/share-mirror.sh" || exit 1
# BH-4080: scratch.sh points every deployment-defaults consumer at THIS
# checkout's bin/lib/deployment.sh. The mirror's scripts must read the mirror's
# own, sanitized copy (box-, box-hub), as they do on a box where it is unset.
unset HARNESS_DEPLOYMENT_FILE
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "share-mirror-clean-test: SKIPPED — python3 is not installed"; exit 0; }

# ── 0. build the publisher's OWN source tree, in scratch ────────────────────
# bin/publish-share.sh copies the repo into $WORK/src, renders the twelve BH-1247
# artifacts THERE, and sanitizes that. Two things follow, and this case needs
# both:
#
#   * the mirror must be graded AFTER the renders. They are generated and not
#     committed, and a mirror without them cannot answer "what does the fleet
#     actually run" — so the tree the publisher sanitizes always has them.
#     sanitize.py copies by WALKING the tree and leakcheck.py refuses any
#     un-auditable extension, so anything a renderer drops beside its output
#     stops the publish, on every push, silently. catalog/.lanes.json.stamp was
#     exactly that file (BH-1247 review r1, B1; the 2026-09-13 freeze shape).
#     Grading $DIR as it happens to sit could not see it: a fresh checkout has
#     not rendered and a developer's has.
#   * the renders must NOT land in the checkout this suite was handed. cron/
#     README.md (BH-1247) tells operators never to run `--all` in a box
#     checkout, and a suite that does it to the tree it is testing is the same
#     mistake with a test runner in front of it — the Fly host's checkout and
#     every developer's carried the twelve ignored files after one run.
#
# So: a scratch copy, rendered there, graded there. Exactly $WORK/src.
# What the HANDED checkout already carries, before this suite does anything.
dir_renders() {
  git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0
  ( cd "$DIR" && git status --porcelain --ignored 2>/dev/null | awk '{print $2}' \
    | grep -E '^(catalog/lanes\.json|env-templates/global\.env\.example|cron/[a-z0-9-]+\.cron)$' | LC_ALL=C sort )
}
DIR_RENDERS_BEFORE=$(dir_renders)

# tests/lib/share-mirror.sh builds exactly that tree (and sanitizes it) once
# per tree, in its own cache rather than in $DIR, and the other share suites
# read the same build (BH-5543). No git (a bare export): it copies the working
# tree and drops the artifacts, so the fixture is never handed a render it did
# not produce itself.
share_mirror_get "$DIR" --or-copy
SRC="$SM_SRC"
[ -d "$SRC/catalog/lanes.d" ] && ok || bad "could not build the publisher's source tree from $DIR — nothing below grades the mirror this branch would publish"

# The file list BEFORE the renders (SM_SRC_BEFORE) and after them
# (SM_SRC_AFTER). The delta below is the claim; an absolute set would be a
# statement about the whole checkout rather than about the renderers.
RENDER_RC=$SM_RENDER_RC
[ "$RENDER_RC" = 0 ] && ok \
  || bad "the three BH-1247 renderers did not all run — bin/publish-share.sh runs exactly these before sanitizing, so the mirror below is not the one that would be published"

# ...and they added NOTHING but their twelve outputs. This is the assertion that
# cannot be argued with later.
EXTRA=$(comm -13 "$SM_SRC_BEFORE" "$SM_SRC_AFTER" \
        | sed 's|^\./||' \
        | grep -vE '^(catalog/lanes\.json|env-templates/global\.env\.example|cron/[a-z0-9-]+\.cron)$' \
        | tr '\n' ' ')
[ -z "${EXTRA// /}" ] && ok \
  || bad "a renderer dropped a file beside its output:$EXTRA — sanitize.py walks the tree and leakcheck.py refuses an un-auditable extension, so this freezes the public mirror (BH-1247 B1). Keep scratch state OUT of the repo."

# ...and THIS SUITE left the checkout it was handed exactly as it found it.
#
# A DELTA, not an absolute set. A shard job runs every suite in one checkout, and
# any earlier suite that reached bin/lib/lanes-registry.sh with the checkout as
# its root has legitimately rendered catalog/lanes.json there — that is the
# loader working, not this suite misbehaving. The absolute form blamed this suite
# for it (CI shard 2: "this suite rendered into the checkout it was handed:
# catalog/lanes.json"). What this suite is responsible for is its OWN render step,
# so the window is the one either side of it.
LEFT=$(comm -13 <(printf '%s\n' "$DIR_RENDERS_BEFORE") <(dir_renders) | grep -v '^$' | tr '\n' ' ')
[ -z "${LEFT// /}" ] && ok \
  || bad "this suite rendered into the checkout it was handed:$LEFT — cron/README.md says never to run --all in a checkout, and a test must not do what it forbids. Render into \$T."

# ── 1. the mirror the PUBLISHER builds ──────────────────────────────────────
M="$SM_MIRROR"
SAN_RC=${SM_SANITIZE_RC:-3}
[ "$SAN_RC" = 0 ] && ok || bad "sanitize.py failed (rc=$SAN_RC): $(tail -5 "${SM_SANITIZE_OUT:-/dev/null}")"

if [ "$SAN_RC" = 0 ]; then
  python3 "$DIR/bin/share/leakcheck.py" --quiet "$M" > "$T/leak.txt" 2>&1
  LEAK_RC=$?
  [ "$LEAK_RC" = 0 ] && ok || bad "the mirror this branch would publish carries identifiers (leakcheck rc=$LEAK_RC). Every line below is either a real leak or a fixture bin/share/mapping.py has not been taught — add the EXACT string leakcheck printed to the right allowlist there and to bin/share/overlay/tests/no-client-identifiers-test.sh:
$(head -50 "$T/leak.txt")"

  # The publisher runs the SHIPPED copy of the guard against the built mirror
  # immediately after leakcheck (bin/publish-share.sh, step 3). A copy that
  # allowlists less refuses the publish one step later, which is a redder day
  # than this one.
  bash "$M/tests/no-client-identifiers-test.sh" > "$T/overlay.txt" 2>&1
  OVERLAY_RC=$?
  [ "$OVERLAY_RC" = 0 ] && ok || bad "the mirror's own tests/no-client-identifiers-test.sh refuses this tree (rc=$OVERLAY_RC):
$(head -30 "$T/overlay.txt")"
fi

# ── 2. the guard still fires on something nobody allowlisted ────────────────
mkdir -p "$T/neg"
printf 'OAUTH_TOKEN=sk-%s\n' "notonanyallowlist0001" > "$T/neg/planted-secret.txt"
python3 "$DIR/bin/share/leakcheck.py" "$T/neg" > "$T/neg.txt" 2>&1
NEG_RC=$?
[ "$NEG_RC" = 1 ] && ok || bad "leakcheck accepted a credential-shaped string that is on no allowlist (rc=$NEG_RC): $(cat "$T/neg.txt")"
grep -q 'planted-secret.txt' "$T/neg.txt" && ok || bad "leakcheck refused but never named the file: $(cat "$T/neg.txt")"

echo "share-mirror-clean: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
