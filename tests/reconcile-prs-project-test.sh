#!/bin/bash
# tests/reconcile-prs-project-test.sh — bin/reconcile-prs.sh must resolve a
# build key's project through the REGISTRY, not through a string operation.
#
# THE DEFECT THIS PINS. The script derived the project as
# `PROJ="${BKEY%%-os-*}-os"` and the slug as `example-org/$PROJ`. That is a
# hard-coded assumption that every fleet project's name ends in "-os", written
# when the fleet was four OS projects. For `pool-project-5-TK-419-2026…` the
# expansion finds no `-os-` at all, so PROJ came out as the WHOLE key with "-os"
# stapled on and the slug as `example-org/pool-project-5-TK-419-…-os`. A repo that
# does not exist: no ship beat ever named project-5, and no project-5 PR has
# ever been reconciled. project-6, project-7 and project-8 are the same
# class. This is the 2026-09-10 shape — a lane silently blind to every project
# enrolled after the original four (see tests/project-of-test.sh).
#
# Run from anywhere: tests/reconcile-prs-project-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$H/bin/"
# BH-994/BH-1295: reconcile-prs.sh reads PR state through mc_pr_view now, so
# this fixture needs the same lib set tests/reconcile-prs-closed-unmerged-test.sh
# carries (the shim, its bin/lib/mc/ modules, and gh-rest.sh + its ETag cache).
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# BH-1583: the lane runs only on the reconcile owner and reads its knobs with no
# literal; this fixture box is armed as the owner (tests/lib/reconcile-fixture.sh).
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$H" "$DIR" || exit 1
# The registry the fix must read. Deliberately contains the two shapes the old
# string trick could not handle: a project with no "-os" suffix, and one whose
# GitHub slug is NOT "example-org/<project>" (the project-2 typo).
cat > "$H/fleet.conf" <<'EOF'
project-1   Example/project-1       https://project-1.example  /api/board 2 box-a
project-2 Example/project-2    https://project-2.example       /api/board 4 box-b
project-5     Example/project-5         https://project-5.example -          9 box-c
EOF
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\n' > "$H/env/global.env"
# Every project owns its deploys here, so the deploy gate runs and we can read
# the slug it was handed.
for P in project-1 project-2 project-5; do printf 'DEPLOY_HOOK_URL=https://hook.example/%s\n' "$P" > "$H/env/$P.env"; done

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\t%%s\\t%%s\\n" "$1" "$2" "$3" >> "%s/deploys.txt"\nexit 0\n' "$T" > "$H/bin/deploy-request.sh"; chmod +x "$H/bin/deploy-request.sh"

# The console says three builds are unmerged; GitHub says all three merged.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  *"/api/builds/unmerged") cat <<'J'
{"builds":[{"bkey":"pool-project-5-TK-419-202609101200","pr_url":"https://github.com/Example/project-5/pull/419"},
           {"bkey":"project-1-TK-88-202609101201","pr_url":"https://github.com/Example/project-1/pull/88"},
           {"bkey":"project-2-TK-7-202609101202","pr_url":"https://github.com/Example/project-2/pull/7"}]}
J
    ;;
  *"/api/builds/reconcile") printf '{"ok":true}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
# BH-994/BH-1295: reconcile-prs.sh reads PR state through mc_pr_view -> gh_rest
# now, never `gh pr view` — this answers the REST shape gh_rest sends
# (`gh api -i -X GET repos/<slug>/pulls/<num>`) with all three PRs MERGED, the
# same fact the old stub gave every one of them.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf 'HTTP/2.0 200 Status\r\n\r\n{"state":"closed","closed_at":"2026-09-10T12:00:00Z","merged_at":"2026-09-10T12:00:00Z","merge_commit_sha":"deadbeefcafe"}'
exit 0
EOF
chmod +x "$T/fakebin/gh"

: > "$T/beats.txt"; : > "$T/deploys.txt"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
    bash "$H/bin/reconcile-prs.sh" >/dev/null 2>"$T/run.err" ) || { echo "run rc=$? stderr:"; cat "$T/run.err"; }
# the deploy gate is launched in the background; give it a moment to land
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ "$(wc -l < "$T/deploys.txt")" -ge 3 ] && break; sleep 0.2
done

beat_field() { # beat_field <bkey> <field>
  local line; line=$(grep -F "shipped:$1" "$T/beats.txt" | head -1)
  [ -n "$line" ] && jq -r ".$2 // \"\"" <<<"$line" 2>/dev/null
}

# ---- the project on the ship beat ------------------------------------------
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
eq "a pool-project-5 key must resolve to the project-5 project" \
   "$(beat_field pool-project-5-TK-419-202609101200 project)" "project-5"
eq "a project-1 key still resolves exactly as before" \
   "$(beat_field project-1-TK-88-202609101201 project)" "project-1"
eq "a project-2 key still resolves exactly as before" \
   "$(beat_field project-2-TK-7-202609101202 project)" "project-2"
# The ticket KEY in the beat line is what the board reader sees; the pool prefix
# and the project must both be stripped off it.
L=$(grep -F "shipped:pool-project-5-TK-419-202609101200" "$T/beats.txt" | head -1)
grep -q '"line":"TK-419 merged' <<<"$L" && ok || bad "the beat line must name the ticket key TK-419, got: $L"

# ---- the slug the deploy gate is handed, from fleet.conf --------------------
slug_of() { awk -F'\t' -v p="$1" '$1==p {print $2}' "$T/deploys.txt" | head -1; }
eq "the project-5 slug comes from fleet.conf" "$(slug_of project-5)" "Example/project-5"
eq "the project-1 slug comes from fleet.conf" "$(slug_of project-1)" "Example/project-1"
# The registry, not a hand-written case arm, is what knows about the typo.
eq "the project-2 slug is the registry's (typo and all), not Example/project-2" \
   "$(slug_of project-2)" "Example/project-2"
grep -q "example-org/" "$T/deploys.txt" && bad "the owner must come from fleet.conf, never be hard-coded" || ok

# ---- all three rows still get reconciled -----------------------------------
grep -q "reconciled 3 externally-merged" "$H/logs/reconcile.log" \
  && ok || bad "all three merged rows must be reconciled: $(cat "$H/logs/reconcile.log" 2>/dev/null)"

# ---- a key that names no fleet project is logged, not silently mangled -----
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  *"/api/builds/unmerged") printf '{"builds":[{"bkey":"stranger-XX-1-202609101203","pr_url":"https://github.com/Example/stranger/pull/1"}]}\n' ;;
  *) printf '{"ok":true}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
: > "$T/beats.txt"; : > "$T/deploys.txt"; : > "$H/logs/reconcile.log"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
    bash "$H/bin/reconcile-prs.sh" >/dev/null 2>&1 )
[ -s "$T/beats.txt" ] && bad "a key naming no fleet project must not emit a ship beat for an invented project" || ok
grep -qi "no fleet" "$H/logs/reconcile.log" && ok || bad "an unresolvable build key must be logged, not silent: $(cat "$H/logs/reconcile.log")"
grep -q "reconciled 1 externally-merged" "$H/logs/reconcile.log" \
  && ok || bad "the console row must still be cleared even when the project is unknown"

echo "reconcile-prs-project-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
