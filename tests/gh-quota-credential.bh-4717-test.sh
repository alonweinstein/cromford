#!/bin/bash
# tests/gh-quota-credential.bh-4717-test.sh — the gh-quota alert pages once per
# CREDENTIAL, not once per repo, and its text says "N of M left" (BH-4717.2).
#
# THE INCIDENT. On 2026-10-05 the hub wrote 84 gh-quota lines: every repo cache
# file on one App installation is its own --status row, the dedupe flag was
# keyed on (repo, reset epoch), and the reset epoch moves every hour. The text
# `rest 750/5000 (15%)` was percent REMAINING and was read as percent used.
#
# What this pins, driving the REAL bin/lib/gh-quota.sh over the rows the REAL
# bin/gh-token.sh --status --json prints (curl stubbed per token value):
#   Q1/Q2  three repos on installation 42 -> ONE line, ONE beat, ONE flag, and
#          the worst row's numbers in "N of M left (P% left)" form
#   Q3-Q5  the dedupe: 2h window, re-fire on a fall of the band, re-fire after
#   Q6     two installations and a PAT -> three lines
#   Q7     both knobs DB-driven, a bad row logged once and falling back
#   Q8     --status --json gains `credential` LAST, text mode byte-identical
#   Q9     a legacy flag, or an empty one, never suppresses
#   M1/M2  mutants of the grouping and the band compare are caught (D1)
#
#   HARNESS_TEST_SANDBOX=1 bash tests/gh-quota-credential.bh-4717-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GH_ADMIN_TOKEN GH_LIMIT_IDENTITY GH_CALL_CALLER HARNESS H

NOW=$(date -u +%s)
iso_at() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; }
RESET_R=$(( NOW + 1800 )); RESET_G=$(( NOW + 2400 ))
ISO_R=$(iso_at "$RESET_R"); ISO_G=$(iso_at "$RESET_G")

# ── the scratch harness ──────────────────────────────────────────────────────
HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/state/gh-app-tokens" "$HH/env" "$HH/logs" "$HH/flags" \
         "$T/bodies" "$T/fakebin" "$T/settings"
scratch_install_closure bin/gh-token.sh "$HH" >/dev/null || { echo "FAIL: scratch_install_closure bin/gh-token.sh"; exit 1; }
chmod +x "$HH/bin/gh-token.sh"
LIB="$DIR/bin/lib/gh-quota.sh"
cat > "$HH/bin/beat.sh" <<SH
#!/bin/bash
printf '%s\n' "\$1" >> "$T/BEATS.jsonl"
SH
chmod +x "$HH/bin/beat.sh"
# GitHub, stubbed: one /rate_limit body per token value; the GraphQL POST
# answers nothing, so the helper falls back to /rate_limit's graphql bucket.
cat > "$T/fakebin/curl" <<SH
#!/bin/bash
AUTH=""; POST=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -H) case "\$2" in Authorization:*) AUTH="\${2#Authorization: }" ;; esac; shift 2 ;;
    -X) [ "\$2" = POST ] && POST=1; shift 2 ;;
    -m|-d|--data|-o|-D) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$POST" ] && exit 0
B="$T/bodies/\${AUTH#token }.json"
[ -f "\$B" ] && cat "\$B"
exit 0
SH
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

body() { # body <token> <rest_remaining> [graphql_remaining=4000]
  jq -nc --argjson rr "$2" --argjson gr "${3:-4000}" --argjson r "$RESET_R" --argjson g "$RESET_G" \
    '{resources:{core:{remaining:$rr,limit:5000,reset:$r},graphql:{remaining:$gr,limit:5000,reset:$g}}}' \
    > "$T/bodies/$1.json"
}
cache() { # cache <slug> <token> [installation_id] — the shape cache_write writes
  jq -nc --arg s "$1" --arg t "$2" --arg i "${3:-}" \
    '{repo:$s,token:$t,expires_at:"2099-01-01T00:00:00Z",minted_at:"2026-10-05T00:00:00Z"}
     + (if $i == "" then {} else {installation_id:$i} end)' \
    > "$HH/state/gh-app-tokens/$(printf '%s' "$1" | tr / -).json"
}
cache Org/a ghs_a 42; cache Org/b ghs_b 42; cache Org/c ghs_c 42
body ghs_a 750; body ghs_b 800; body ghs_c 900

# tick [lib] — one real alert tick: the real helper's rows into the real lib.
# A subshell, so _GHQ_LOADED and a mutant never leak into the next tick.
tick() {
  local lib="${1:-$LIB}"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HH" HARNESS_ENV_DIR="$HH/env" GH_APP_API_BASE="http://api.test"
    [ -n "${PATTOK:-}" ] && export GH_TOKEN="$PATTOK"
    setting_get() { [ -f "$T/settings/$1" ] || return 2; cat "$T/settings/$1"; }
    # shellcheck disable=SC1090
    . "$lib" || exit 1
    rows=$(gh_quota_rows) || exit 1
    gh_quota_alert "$rows" ) >/dev/null 2>&1
}
alerts() { local n; n=$(grep -c '\[gh-quota\] GitHub quota low' "$HH/logs/ALERTS.log" 2>/dev/null); printf '%s' "${n:-0}"; }
lastline() { grep '\[gh-quota\]' "$HH/logs/ALERTS.log" 2>/dev/null | tail -1; }
beats() { jq -r 'select(.kind == "fleet_alert") | .akey' "$T/BEATS.jsonl" 2>/dev/null; }
F42="$HH/flags/alerted-gh-quota-app-installation_42"
setflag() { printf '%s\n' "$1" > "$F42"; }
areset() { : > "$HH/logs/ALERTS.log"; rm -f "$T/BEATS.jsonl"; : > "$HH/logs/gh-quota.log"; }
freset() { areset; rm -f "$HH/flags/"alerted-gh-quota-*; }

Q1_LINE="[gh-quota] GitHub quota low for app-installation:42 (shared by 3 repos: Org/a, Org/b, Org/c): rest 750 of 5000 left (15% left), graphql 4000 of 5000 left (80% left), resets at $ISO_R — top callers last hour: none recorded"
# q1_holds — the Q1 contract as one predicate, so M1 can run it against a mutant.
q1_holds() {
  [ "$(alerts)" = 1 ] || return 1
  [ "$(lastline | sed 's/^[0-9-]* [0-9:]*Z //')" = "$Q1_LINE" ] || return 1
  [ "$(beats | grep -cE '^ghquota:app-installation:42:[0-9]+$')" = 1 ] || return 1
  [ "$(beats | grep -c .)" = 1 ]
}

# ── Q1: three repos, one installation, ONE line ─────────────────────────────
freset; tick
[ "$(alerts)" = 1 ] && ok || bad "Q1: three rows on installation 42 must write ONE line, got $(alerts): $(cat "$HH/logs/ALERTS.log")"
grep -qF 'GitHub quota low for app-installation:42 (shared by 3 repos: Org/a, Org/b, Org/c)' "$HH/logs/ALERTS.log" \
  && ok || bad "Q1: the line must name the credential and the three repos, got: '$(lastline)'"
[ "$(lastline | sed 's/^[0-9-]* [0-9:]*Z //')" = "$Q1_LINE" ] && ok \
  || bad "Q1: the whole line must be exactly '$Q1_LINE', got: '$(lastline)'"
[ "$(beats | grep -cE '^ghquota:app-installation:42:[0-9]+$')" = 1 ] && [ "$(beats | grep -c .)" = 1 ] \
  && ok || bad "Q1: exactly ONE fleet_alert beat keyed ghquota:app-installation:42:<epoch>, got: '$(beats)'"
grep -qE '^[0-9]+ 15$' "$F42" 2>/dev/null && ok \
  || bad "Q1: the flag must hold '<epoch> 15', got: '$(cat "$F42" 2>/dev/null)' in $(ls "$HH/flags" | tr '\n' ' ')"
[ "$(find "$HH/flags" -name 'alerted-gh-quota-*' | grep -c .)" = 1 ] && ok \
  || bad "Q1: one credential is one flag, got: $(ls "$HH/flags" | tr '\n' ' ')"

# ── Q2: the worst row's numbers, in "N of M left" form ──────────────────────
L=$(lastline)
grep -qF 'rest 750 of 5000 left (15% left)' <<<"$L" && ok || bad "Q2: rest must read '750 of 5000 left (15% left)', got: '$L'"
grep -qF 'graphql 4000 of 5000 left (80% left)' <<<"$L" && ok || bad "Q2: graphql must read '4000 of 5000 left (80% left)', got: '$L'"
grep -qF '750/5000' <<<"$L" && bad "Q2: the bare 'x/y' form must be gone, got: '$L'" || ok
grep -qF '800' <<<"$L" && bad "Q2: only the worst row's numbers may appear, got: '$L'" || ok

# Q2b: a bucket with no reset time still keeps every column in place.
freset
jq -nc '{resources:{core:{remaining:750,limit:5000},graphql:{remaining:4000,limit:5000}}}' > "$T/bodies/ghs_a.json"
tick
grep -qF 'rest 750 of 5000 left (15% left), graphql 4000 of 5000 left (80% left), resets at unknown — top callers' <<<"$(lastline)" \
  && ok || bad "Q2b: an unknown reset must read 'unknown' with the numbers intact, got: '$(lastline)'"
freset; body ghs_a 750; tick

# ── Q3: 30 minutes later at 14% — inside the window, not a band's fall ──────
areset; setflag "$(( NOW - 1800 )) 15"; body ghs_a 700; tick
[ "$(alerts)" = 0 ] && ok || bad "Q3: 14% 30 minutes after a 15% line must stay quiet, got: '$(cat "$HH/logs/ALERTS.log")'"

# ── Q4: 5% inside the window — it fell by the band, so it re-fires ──────────
areset; setflag "$(( NOW - 1800 )) 15"; body ghs_a 250; tick
[ "$(alerts)" = 1 ] && ok || bad "Q4: a fall from 15% to 5% inside 2h must write a line, got $(alerts)"
grep -qF 'rest 250 of 5000 left (5% left)' <<<"$(lastline)" && ok || bad "Q4: the re-fire must carry the new 5%, got: '$(lastline)'"
grep -qE '^[0-9]+ 5$' "$F42" && [ "$(cut -d' ' -f1 "$F42")" -ge "$NOW" ] && ok \
  || bad "Q4: a re-fire restarts the window from the new low, got flag '$(cat "$F42")'"
# Q4b: 12% is a fall of 3 points, not the band's 10.
areset; setflag "$(( NOW - 1800 )) 15"; body ghs_a 600; tick
[ "$(alerts)" = 0 ] && ok || bad "Q4b: 15% to 12% inside 2h must stay quiet, got: '$(cat "$HH/logs/ALERTS.log")'"

# ── Q5: the same 15% after 7201s is a new line ──────────────────────────────
areset; setflag "$(( NOW - 7201 )) 15"; body ghs_a 750; tick
[ "$(alerts)" = 1 ] && ok || bad "Q5: 15% again after 7201s must re-fire, got $(alerts)"
areset; setflag "$(( NOW - 7000 )) 15"; tick
[ "$(alerts)" = 0 ] && ok || bad "Q5: 15% again after 7000s is still inside the 2h window, got $(alerts)"

# ── Q6: two installations and a PAT — three lines ───────────────────────────
freset
cache Org/d ghs_d 43; body ghs_d 500; body pattok 250
PATTOK=pattok tick
[ "$(alerts)" = 3 ] && ok || bad "Q6: installations 42, 43 and pat:default must give 3 lines, got $(alerts): $(cat "$HH/logs/ALERTS.log")"
grep -qF 'GitHub quota low for app-installation:42 (shared by 3 repos: Org/a, Org/b, Org/c): rest 750 of 5000 left' "$HH/logs/ALERTS.log" \
  && ok || bad "Q6: installation 42's line is missing, got: $(cat "$HH/logs/ALERTS.log")"
grep -qF 'GitHub quota low for app-installation:43 (repo Org/d): rest 500 of 5000 left (10% left)' "$HH/logs/ALERTS.log" \
  && ok || bad "Q6: a one-repo installation must still name its repo, got: $(cat "$HH/logs/ALERTS.log")"
grep -qF 'GitHub quota low for pat:default: rest 250 of 5000 left (5% left)' "$HH/logs/ALERTS.log" \
  && ok || bad "Q6: the PAT line has no repo clause, got: $(cat "$HH/logs/ALERTS.log")"
[ "$(beats | grep -c .)" = 3 ] && ok || bad "Q6: one beat per credential, got: '$(beats)'"
rm -f "$HH/state/gh-app-tokens/Org-d.json"

# ── Q7: the knobs are DB-driven, and a bad row falls back loudly ────────────
printf '600' > "$T/settings/gh_quota_alert_dedupe_s"
areset; setflag "$(( NOW - 601 )) 15"; tick
[ "$(alerts)" = 1 ] && ok || bad "Q7: with gh_quota_alert_dedupe_s=600 a flag 601s old must re-fire, got $(alerts)"
areset; setflag "$(( NOW - 500 )) 15"; tick
[ "$(alerts)" = 0 ] && ok || bad "Q7: with gh_quota_alert_dedupe_s=600 a flag 500s old must hold, got $(alerts)"
printf 'abc' > "$T/settings/gh_quota_alert_dedupe_s"
areset; setflag "$(( NOW - 601 )) 15"; tick
[ "$(alerts)" = 0 ] && ok || bad "Q7: an unusable dedupe knob must fall back to 7200, so 601s holds, got $(alerts)"
[ "$(grep -c "gh_quota_alert_dedupe_s='abc'" "$HH/logs/gh-quota.log")" = 1 ] && ok \
  || bad "Q7: the bad dedupe value must be logged exactly once per tick, got: '$(cat "$HH/logs/gh-quota.log")'"
printf '100000' > "$T/settings/gh_quota_alert_dedupe_s"
areset; setflag "$(( NOW - 7201 )) 15"; tick
[ "$(alerts)" = 1 ] && ok || bad "Q7: an out-of-range dedupe knob falls back to 7200, never clamps to 86400, got $(alerts)"
grep -qF "out-of-range setting gh_quota_alert_dedupe_s='100000'" "$HH/logs/gh-quota.log" && ok \
  || bad "Q7: the out-of-range value must be logged, got: '$(cat "$HH/logs/gh-quota.log")'"
rm -f "$T/settings/gh_quota_alert_dedupe_s"
printf 'abc' > "$T/settings/gh_quota_alert_band_pct"
areset; setflag "$(( NOW - 1800 )) 15"; body ghs_a 250; tick
[ "$(alerts)" = 1 ] && ok || bad "Q7: an unusable band knob must fall back to 10, so 15% to 5% re-fires, got $(alerts)"
[ "$(grep -c "gh_quota_alert_band_pct='abc'" "$HH/logs/gh-quota.log")" = 1 ] && ok \
  || bad "Q7: the bad band value must be logged exactly once per tick, got: '$(cat "$HH/logs/gh-quota.log")'"
printf '5' > "$T/settings/gh_quota_alert_band_pct"
areset; setflag "$(( NOW - 1800 )) 15"; body ghs_a 500; tick
[ "$(alerts)" = 1 ] && ok || bad "Q7: with gh_quota_alert_band_pct=5 a fall from 15% to 10% must re-fire, got $(alerts)"
rm -f "$T/settings/gh_quota_alert_band_pct"
body ghs_a 750

# ── Q8: --status --json gains `credential`, last; text mode is unchanged ────
cache Org/e ghs_e; body ghs_e 4500
status() { env PATH="$T/fakebin:$PATH" HARNESS="$HH" HARNESS_ENV_DIR="$HH/env" \
             GH_APP_API_BASE="http://api.test" GH_TOKEN=pattok "$HH/bin/gh-token.sh" --status "$@" 2>/dev/null; }
J=$(status --json)
[ "$(jq -r '[.[] | "\(.identity)=\(.credential)"] | join(",")' <<<"$J" 2>/dev/null)" \
  = "Org/a=app-installation:42,Org/b=app-installation:42,Org/c=app-installation:42,Org/e=app:Org/e,pat:default=pat:default" ] \
  && ok || bad "Q8: credential must be app-installation:<id>, app:<slug> with no id, the identity for a PAT, got: $(jq -c 'map({identity,credential})' <<<"$J")"
[ "$(jq -r '[.[] | keys_unsorted | last] | unique | join(",")' <<<"$J" 2>/dev/null)" = credential ] && ok \
  || bad "Q8: credential must be the LAST key on every row, got: $(jq -c '[.[]|keys_unsorted]' <<<"$J")"
[ "$(jq -r '[.[] | del(.credential) | keys_unsorted | join(",")] | unique | join("|")' <<<"$J" 2>/dev/null)" \
  = "identity,kind,slug,rest_remaining,rest_limit,graphql_remaining,graphql_limit,graphql_used,graphql_source,resets_at,expires_at,unreadable,graphql_unreadable" ] \
  && ok || bad "Q8: every pre-existing key must keep its place, got: $(jq -c '[.[]|keys_unsorted]' <<<"$J")"
EXP="$T/status-expected.txt"
{ for p in "Org/a 750" "Org/b 800" "Org/c 900" "Org/e 4500"; do
    set -- $p
    printf '%s remaining=%s/5000 expires_at=2099-01-01T00:00:00Z graphql=4000/5000 rest_resets_at=%s graphql_resets_at=%s graphql_used=- graphql_source=rate_limit\n' "$1" "$2" "$ISO_R" "$ISO_G"
  done
  printf 'pat:default remaining=250/5000 expires_at=- graphql=4000/5000 rest_resets_at=%s graphql_resets_at=%s graphql_used=- graphql_source=rate_limit\n' "$ISO_R" "$ISO_G"
} > "$EXP"
status > "$T/status-actual.txt"
diff "$EXP" "$T/status-actual.txt" >/dev/null && ok \
  || bad "Q8: text mode must be byte-identical, diff: $(diff "$EXP" "$T/status-actual.txt")"
grep -qE 'credential|installation' "$T/status-actual.txt" && bad "Q8: text mode must not gain the new field" || ok
rm -f "$HH/state/gh-app-tokens/Org-e.json"

# ── Q9: a legacy reset-window flag never suppresses; nor does an empty one ──
freset
: > "$HH/flags/alerted-gh-quota-Org_a-$RESET_R"
: > "$HH/flags/alerted-gh-quota-app-installation_42-$RESET_R"
tick
[ "$(alerts)" = 1 ] && ok || bad "Q9: the first tick after deploy must fire once per credential despite old flags, got $(alerts)"
freset; : > "$F42"; tick
[ "$(alerts)" = 1 ] && ok || bad "Q9b: an empty flag at the new name reads as no flag, got $(alerts)"
grep -qE '^[0-9]+ 15$' "$F42" && ok || bad "Q9b: the empty flag must be rewritten to '<epoch> <pct>', got '$(cat "$F42")'"
freset; printf 'garbage here\n' > "$F42"; tick
[ "$(alerts)" = 1 ] && ok || bad "Q9b: a garbage flag reads as no flag, got $(alerts)"

# ── M1: group by repo instead of credential — Q1 must go red ────────────────
MUT="$T/gh-quota-m1.sh"
sed 's/group_by(\.cred)/group_by(.ident)/' "$LIB" > "$MUT"
cmp -s "$LIB" "$MUT" && bad "M1: the mutant is identical to the shipped lib — the mutation did not apply" || ok
freset; tick "$MUT"
q1_holds && bad "M1: with grouping by repo, Q1 still held — Q1 is vacuous: $(cat "$HH/logs/ALERTS.log")" || ok
freset; tick
q1_holds && ok || bad "M1: the shipped lib must satisfy Q1 again, got: $(cat "$HH/logs/ALERTS.log")"

# ── M2: the band compare never fires — Q4 must go red ───────────────────────
MUT="$T/gh-quota-m2.sh"
sed 's/-le \$(( fpct - band ))/-lt -1/' "$LIB" > "$MUT"
cmp -s "$LIB" "$MUT" && bad "M2: the mutant is identical to the shipped lib — the mutation did not apply" || ok
areset; setflag "$(( NOW - 1800 )) 15"; body ghs_a 250; tick "$MUT"
[ "$(alerts)" = 0 ] && ok || bad "M2: with the band compare neutralised the 15%->5% fall must not fire (so Q4 goes red), got $(alerts)"
body ghs_a 750

echo "gh-quota-credential.bh-4717-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
