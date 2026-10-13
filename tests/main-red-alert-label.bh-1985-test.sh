#!/bin/bash
# tests/main-red-alert-label.bh-1985-test.sh — the two main-red alerts name the
# label the merge lanes actually exempt (BH-1985 item 2, a BH-1770 follow-up).
#
# THE DEFECT. BH-1770 made the main-red label one knob, resolved by
# bin/lib/main-red-label.sh. The two alerts that tell an operator how to get
# out of a freeze still said "land the fix as a PR labelled fix-main-red" as a
# literal. On a box that renamed the label, the one instruction in the page was
# wrong: a PR labelled as told stayed frozen.
#
# THE CONTRACT pinned here, through the REAL scripts and a recording
# lane-alert.sh (the fixture of tests/main-red-pair-suspected.bh-1451-test.sh):
#   A1 detector, first red, nothing set  -> "labelled fix-main-red";
#   A2 detector, MC_MAIN_RED_LABEL=unbreak-main in env/global.env
#                                        -> "labelled unbreak-main", no fix-main-red;
#   A3 pr-pair suspected freeze, only the alias MAIN_RED_LABEL=alias-red
#                                        -> "labelled alias-red";
#   A4 pr-pair, MC_MAIN_RED_LABEL=unbreak-main -> "labelled unbreak-main", no fix-main-red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-alert-label.bh-1985-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-alert-label: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
cp "$DIR/bin/main-red-pr-pair.sh" "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/main-red-gate.sh" \
   "$DIR/bin/lib/main-red-label.sh" "$T/bin/lib/"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { return 0; }
SHIM

# gh shim, as in tests/main-red-pair-suspected.bh-1451-test.sh.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
PROJ='[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]'
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 echo "[]" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           case "$A" in
                                *"branch=main"*)
                                  [ -s "$T/mainruns.json" ] || exit 1
                                  pp=${A##*per_page=}; pp=${pp%% *}
                                  case "$pp" in ''|*[!0-9]*) pp=100 ;; esac
                                  jq -c --argjson pp "$pp" "$PROJ | .[0:\$pp]" "$T/mainruns.json" ;;
                                *)
                                  sha=${A##*head_sha=}; sha=${sha%% *}
                                  [ -s "$T/runs-$sha.json" ] || exit 1
                                  jq -c "$PROJ" "$T/runs-$sha.json" ;;
                              esac ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
ALERTS="$T/alerts.txt"
pulls() { # pulls <number:head-sha:updatedAt>...
  local out='[' first=1 spec num sha upd
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)),
        title:"t", body:"", head:{sha:$sha, ref:("b"+($n|tostring))},
        base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null,
        labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}
head_runs() { # head_runs <head-sha> <name|path|conclusion|created_at|run-id>
  local sha="$1" n p c t id; IFS='|' read -r n p c t id <<<"$2"
  jq -nc --arg n "$n" --arg p "$p" --arg t "$t" --argjson id "$id" --arg c "$c" --arg sha "$sha" \
    '{workflow_runs:[{name:$n, path:$p, status:"completed", head_sha:$sha, conclusion:$c,
      created_at:$t, html_url:("https://github.com/o/r/actions/runs/"+($id|tostring)), id:$id}]}' \
    > "$T/runs-$sha.json"
}
reset_case() { # reset_case <global.env line or empty>
  : > "$ALERTS"; rm -rf "$T/state/main-red"; rm -f "$T"/flags/main-red-* "$T"/runs-*.json \
    "$T"/jobs-*.txt "$T"/joblog-*.txt "$T/mainruns.json"
  printf '%s\n' "$1" > "$T/env/global.env"
}
drive() { # drive <script> [args...] — one tick of a real lane
  local s="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" ALERT_SINK="$ALERTS"
    unset GH_TOKEN MC_MAIN_RED_LABEL MAIN_RED_LABEL
    bash "$T/bin/$s" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
detector_red() { # the tip shape: one failed required run, 40 minutes old
  local t; t=$(date -u -d "@$(( $(date +%s) - 2400 ))" +%FT%TZ)
  jq -nc --arg t "$t" --arg p "$CI" '{workflow_runs:[{name:"Harness CI", path:$p, status:"completed",
    conclusion:"failure", created_at:$t, head_sha:"f1f1f1f1", html_url:"https://github.com/o/r/actions/runs/1", id:1}]}' \
    > "$T/mainruns.json"
}
pair_suspected() { # a firing pair against a detector that has not decided
  mkdir -p "$T/state/main-red"
  printf 'decision=none\nreason=no-required\nsha=\nat=2026-09-22 12:40:00Z\n' > "$T/state/main-red/o-r.verdict"
  local E="FAIL: clock-rolling-window worker/jobs/test/burn.test.js"
  pulls "1:aaaa111:2026-09-22T12:35:00Z" "2:bbbb222:2026-09-22T12:36:00Z"
  head_runs aaaa111 "Harness CI|$CI|failure|2026-09-22T12:30:00Z|9001"
  head_runs bbbb222 "Harness CI|$CI|failure|2026-09-22T12:30:35Z|9002"
  printf 'Test determinism lint\t8001\n' > "$T/jobs-9001.txt"; printf '2026-09-22T12:31:02Z %s\n' "$E" > "$T/joblog-8001.txt"
  printf 'Test determinism lint\t8002\n' > "$T/jobs-9002.txt"; printf '2026-09-22T12:31:40Z %s\n' "$E" > "$T/joblog-8002.txt"
}
says() { # says <case> <want-substring> [must-not-substring]
  grep -qF -- "$2" "$ALERTS" && ok || bad "$1: the alert must say '$2': $(cat "$ALERTS")"
  [ -z "${3:-}" ] || { grep -qF -- "$3" "$ALERTS" && bad "$1: the alert must not say '$3': $(cat "$ALERTS")" || ok; }
}

# ---------- A1 detector, nothing set: the default -----------------------------
reset_case ""; detector_red; drive main-red-detector.sh o/r
grep -q '^--critical ' "$ALERTS" && ok || bad "A1: the fixture must reach the first-red critical alert: $(cat "$ALERTS") $(cat "$T/err.txt")"
says A1 "labelled fix-main-red"

# ---------- A2 detector, the canonical knob renamed ---------------------------
reset_case "MC_MAIN_RED_LABEL=unbreak-main"; detector_red; drive main-red-detector.sh o/r
says A2 "labelled unbreak-main" "fix-main-red"

# ---------- A3 pr-pair, only the deprecated alias -----------------------------
reset_case "MAIN_RED_LABEL=alias-red"; pair_suspected; drive main-red-pr-pair.sh o/r
[ -f "$T/flags/main-red-o-r" ] && ok || bad "A3: the fixture must raise the suspected freeze: $(cat "$T/logs/main-red-pr-pair.log" 2>/dev/null)"
says A3 "labelled alias-red" "fix-main-red"

# ---------- A4 pr-pair, the canonical knob renamed ----------------------------
reset_case "MC_MAIN_RED_LABEL=unbreak-main"; pair_suspected; drive main-red-pr-pair.sh o/r
says A4 "labelled unbreak-main" "fix-main-red"

echo "main-red-alert-label.bh-1985: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
