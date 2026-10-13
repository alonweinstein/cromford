#!/bin/bash
# tests/model-routes-bundle-deadline.bh-1928-test.sh — the dispatcher's route
# bundle has ONE total deadline, not only a per-question cap (BH-1928, item 3
# of the #1917 review follow-ups).
#
# WHY. model_routes_bundle (bin/lib/model-route.sh) asks the worker once per
# build role with a 4 s cap per ask. A worker that ANSWERS, slowly, never trips
# the "first failed ask -> cache only" rule, so seventeen slow answers add about
# 68 s to every pool tick. MODEL_ROUTES_BUNDLE_DEADLINE_S (a lib knob,
# catalog/lanes.d/_lib.model-route.json, default 15) bounds the whole build:
# no ask may run past what is left of it, and once it is spent the remaining
# roles come from this box's cache.
#
# HOW, with no sleep: the REAL lib and the REAL jobs client against the
# model-route stub worker, behind a fake curl that records its -m value and
# moves a fake clock file forward by $SLOW seconds per ask. The test overrides
# the lib's clock seam (_mr_now) in-shell to read that file.
#   D1 slow worker, deadline 10 -> 4 asks, every role still bundled (the rest
#      from cache), the spent deadline logged.
#   D2 no ask's -m is longer than what is left of the deadline.
#   D3 unset / non-numeric / 0 deadline -> the documented 15 s fallback, never
#      "cache only from the first role".
#   D4 a fast worker is asked for every role, with the per-ask cap, as before.
#
# Run from anywhere: tests/model-routes-bundle-deadline.bh-1928-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mrs_install "$T/fakebin"
mrs_table_1523 "$T/routes"
# The slow curl: log -m, advance the clock by $SLOW, then answer as the stub.
mkdir -p "$T/slowbin"
cat > "$T/slowbin/curl" <<EOF
#!/bin/bash
m=""; prev=""
for a in "\$@"; do [ "\$prev" = "-m" ] && m="\$a"; prev="\$a"; done
echo "\$m" >> "\$CURL_LOG"
c=\$(cat "\$CLOCK"); echo \$((c + \${SLOW:-0})) > "\$CLOCK"
exec "$T/fakebin/curl" "\$@"
EOF
chmod +x "$T/slowbin/curl"

mkbox() { # mkbox <dir> — resolver + client, no lane-gate (so no settings row can answer)
  scratch_rm "$1"; mkdir -p "$1/bin/lib/jobs" "$1/logs" "$1/state" "$1/flags" "$1/env"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  cp "$DIR/bin/lib/model-route.sh" "$DIR/bin/lib/env-path.sh" "$1/bin/lib/"
}
bundle() { # bundle <harness> <out> [ENV=VAL...] — one model_routes_bundle, on the fake clock
  local h="$1" out="$2"; shift 2
  echo 1000 > "$T/clock"; : > "$T/curl.log"
  env -u MODEL_ROUTES_BUNDLE_DEADLINE_S PATH="$T/slowbin:$T/fakebin:$PATH" HARNESS_SECRET=test-secret \
    JOBS_URL=https://jobs.invalid MRS_ROUTES="$T/routes" JOBS_RETRIES=0 CURL_LOG="$T/curl.log" CLOCK="$T/clock" \
    HARNESS="$h" "$@" bash -c '. "$1/bin/lib/model-route.sh"; _mr_now() { cat "$CLOCK"; }; model_routes_bundle testproj "$2"' _ "$h" "$out"
}
asks() { wc -l < "$T/curl.log" | tr -d ' '; }
ALL12=$(printf '%s\n' build.plan build.execute build.review build.review.t0 build.fix build.qa claude.ladder \
  codex.default grok.default fireworks.default fireworks.floor openrouter.floor | sort | paste -sd' ')
roles_of() { cut -f1 "$1" | sort -u | paste -sd' '; }

# A hub whose cache is warm for every build role (a fast worker, once).
HUB="$T/hub"; mkbox "$HUB"
bundle "$HUB" "$T/warm.tsv" SLOW=0 >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(roles_of "$T/warm.tsv")" = "$ALL12" ] && ok || bad "D0 warm-up bundle: rc=$RC '$(roles_of "$T/warm.tsv")'"
touch -t 202609010000 "$HUB/state/model-routes/"*.tsv
CACHE_T=$(stat -c %Y "$HUB/state/model-routes/build.plan@testproj.tsv" 2>/dev/null || stat -f %m "$HUB/state/model-routes/build.plan@testproj.tsv")

# --- D1. slow worker, deadline 10: 4 asks, the rest from cache, logged -------
: > "$HUB/logs/model-route.log"
bundle "$HUB" "$T/d1.tsv" SLOW=3 MODEL_ROUTES_BUNDLE_DEADLINE_S=10; RC=$?
N=$(asks)
[ "$N" = 4 ] && ok || bad "D1 a 10 s deadline over 3 s asks must stop asking after 4: $N asks"
[ "$RC" = 0 ] && [ "$(roles_of "$T/d1.tsv")" = "$ALL12" ] \
  && ok || bad "D1 every build role must still ship, the rest from cache: rc=$RC '$(roles_of "$T/d1.tsv")'"
# The first four roles were answered live (stamped now); the other eight carry the cache mtime.
[ "$(awk -F'\t' -v c="$CACHE_T" '$2==c{print $1}' "$T/d1.tsv" | sort -u | wc -l | tr -d ' ')" = 8 ] \
  && ok || bad "D1 the roles past the deadline must carry the cache's mtime: $(cut -f1,2 "$T/d1.tsv" | sort -u | paste -sd' ')"
grep -q 'bundle deadline 10s spent after 4 asks' "$HUB/logs/model-route.log" \
  && ok || bad "D1 a spent deadline must be logged, not silent: $(cat "$HUB/logs/model-route.log")"

# --- D2. no ask outlives what is left of the deadline ------------------------
# asks at elapsed 0, 3, 6, 9 -> left 10, 7, 4, 1 -> -m min(4, left)
[ "$(paste -sd, "$T/curl.log")" = "4,4,4,1" ] \
  && ok || bad "D2 each ask's -m must be min(per-ask cap, deadline left): $(paste -sd, "$T/curl.log")"
awk 'BEGIN{e=0} {left=10-e; if ($1 > left || $1 < 1) bad=1; e+=3} END{exit bad}' "$T/curl.log" \
  && ok || bad "D2 an ask ran past the deadline"

# --- D3. the fallback is 15 s, never 0 ---------------------------------------
# 15 s over 3 s asks: asks at 0,3,6,9,12 (the last with 3 s left), then spent.
for v in "" abc 0 -5; do
  if [ -z "$v" ]; then bundle "$HUB" "$T/d3.tsv" SLOW=3 >/dev/null
  else bundle "$HUB" "$T/d3.tsv" SLOW=3 MODEL_ROUTES_BUNDLE_DEADLINE_S="$v" >/dev/null; fi
  [ "$(paste -sd, "$T/curl.log")" = "4,4,4,4,3" ] && [ "$(roles_of "$T/d3.tsv")" = "$ALL12" ] \
    && ok || bad "D3 deadline '${v:-unset}' must fall back to 15 s: asks $(paste -sd, "$T/curl.log")"
done
# The resolver itself, in this shell (it sets a variable; never call it in $( )).
OUT=$(env -u MODEL_ROUTES_BUNDLE_DEADLINE_S HARNESS="$HUB" bash -c '. "$1/bin/lib/model-route.sh"
  for v in "" abc 0 7; do MODEL_ROUTES_BUNDLE_DEADLINE_S=$v; _MR_DEADLINE_APPLIED=0; _mr_bundle_deadline; printf "%s " "$_MR_BUNDLE_DEADLINE"; done' _ "$HUB")
[ "$OUT" = "15 15 15 7 " ] && ok || bad "D3 _mr_bundle_deadline: '$OUT'"
# D3b. with no env value the lib knob is asked for (lib_env_apply model-route —
# an operator's settings row), once per process, and a bad answer still falls back.
OUT=$(env -u MODEL_ROUTES_BUNDLE_DEADLINE_S HARNESS="$HUB" bash -c '. "$1/bin/lib/model-route.sh"
  lib_env_apply() { echo "asked:$1" >&2; export MODEL_ROUTES_BUNDLE_DEADLINE_S=9; }
  _mr_bundle_deadline; a=$_MR_BUNDLE_DEADLINE
  lib_env_apply() { echo "asked:$1" >&2; export MODEL_ROUTES_BUNDLE_DEADLINE_S=abc; }
  unset MODEL_ROUTES_BUNDLE_DEADLINE_S; _MR_DEADLINE_APPLIED=0; _mr_bundle_deadline; echo "$a $_MR_BUNDLE_DEADLINE"' _ "$HUB" 2>&1 | paste -sd' ')
[ "$OUT" = "asked:model-route asked:model-route 9 15" ] && ok || bad "D3b the lib knob must be read through lib_env_apply model-route: '$OUT'"

# --- D4. a fast worker is asked for every role, as before --------------------
: > "$HUB/logs/model-route.log"
bundle "$HUB" "$T/d4.tsv" SLOW=0 MODEL_ROUTES_BUNDLE_DEADLINE_S=10; RC=$?
[ "$(asks)" = 17 ] && [ "$(sort -u "$T/curl.log" | paste -sd,)" = 4 ] \
  && ok || bad "D4 a fast worker must be asked once per role at the per-ask cap: $(asks) asks, -m $(sort -u "$T/curl.log" | paste -sd,)"
[ "$RC" = 0 ] && [ "$(roles_of "$T/d4.tsv")" = "$ALL12" ] \
  && [ -z "$(awk -F'\t' -v c="$CACHE_T" '$2==c' "$T/d4.tsv")" ] \
  && ok || bad "D4 every role answered live, none from cache: rc=$RC"
! grep -q 'bundle deadline' "$HUB/logs/model-route.log" \
  && ok || bad "D4 an unspent deadline must log nothing"

# --- D5. the per-ask cap still wins when it is the smaller bound -------------
bundle "$HUB" "$T/d5.tsv" SLOW=0 MODEL_ROUTES_BUNDLE_DEADLINE_S=60 MODEL_ROUTES_BUNDLE_TIMEOUT_S=2 >/dev/null
[ "$(sort -u "$T/curl.log" | paste -sd,)" = 2 ] && ok || bad "D5 per-ask cap 2 must hold: $(sort -u "$T/curl.log" | paste -sd,)"

echo "model-routes-bundle-deadline.bh-1928: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
