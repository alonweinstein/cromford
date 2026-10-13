#!/bin/bash
# tests/mergify-drift-project-5.bh-3439-test.sh — the drift check
# (bin/mergify-sync.sh check, BH-1699) on the project-5 case BH-3439 names.
#
# The REAL bin/mergify-sync.sh runs with the REAL bin/mergify-template.sh as its
# comparator (no MERGIFY_TEMPLATE_BIN stub) against a HARNESS=$T/h sandbox that
# holds one conf, config/mergify/repos/project-5.conf. `gh` is a stub first on
# PATH, the same shape as tests/mergify-sync.bh-1699-test.sh: it answers the
# gh_repo_use_token probe, logs every `METHOD path` (and any --input body) to
# $T/gh.log, and replies from $T/fx/<METHOD>_<path> fixtures (no fixture = 404).
#
# "Today's live file" is not hand-written: it is the render of today's conf
# (project-5.conf without its tuning keys) plus max_checks_retries=1, which is
# what the ticket says example-org/project-5 carries on main.
#
#   D1 today's conf  vs today's file   -> DRIFT rc 1, ALERTS names max_checks_retries
#   D2 the new conf  vs today's file   -> DRIFT rc 1, the diff names max_parallel_checks
#   D3 the new conf  vs its own render -> IN_SYNC rc 0, no ALERTS (after the sync)
#   D4 override=                       -> OVERRIDE rc 0, no ALERTS, no contents read
#   D5 apply                           -> PUTs parallel 6 / retries 1 on harness/mergify-sync-*
#   N1 retry-only drift, N2 no PyYAML  -> never IN_SYNC
#
# Without PyYAML the comparator cannot compare, so every case but N2 prints
# `SKIP (no PyYAML): <case>`; CI installs PyYAML (tests/ci-pyyaml.bh-1741-test.sh).
#
# D1 MUTATIONS (run by the builder, not by CI): MERGIFY_SYNC_BIN at a copy of
# bin/mergify-sync.sh in a scratch repo tree (with bin/lib,
# bin/mergify-template.sh and config/mergify/) whose classify maps compare rc 1
# to IN_SYNC turns D1/D2/D5/N1 red; PROJECT_5_CONF at origin/main's
# project-5.conf turns D2/D3/D5/N1 red.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SUT="${MERGIFY_SYNC_BIN:-$DIR/bin/mergify-sync.sh}"
TPL="$(dirname "$SUT")/mergify-template.sh"
CONF="${PROJECT_5_CONF:-$DIR/config/mergify/repos/project-5.conf}"
SLUG=example-org/project-5
DEFB=main
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
skip() { echo "SKIP (no PyYAML): $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
FX="$STUB_FX"
if [ "${1:-}" = api ] && [ "${2:-}" != -i ]; then   # gh_repo_use_token's probe
  grep -qxF "${2#repos/}" "$FX/visible" 2>/dev/null && { echo 1; exit 0; }
  exit 1
fi
m="$4"; p="$5"; shift 5
inp=""
while [ $# -gt 0 ]; do [ "$1" = --input ] && inp="$2"; shift; done
echo "$m $p" >> "$STUB_LOG"
[ -n "$inp" ] && { printf 'INPUT '; tr -d '\n' < "$inp"; echo; } >> "$STUB_LOG"
k="$FX/${m}_$(printf '%s' "$p" | tr -c 'A-Za-z0-9' '_')"
if [ -f "$k.body" ]; then
  printf 'HTTP/2.0 %s X\r\n\r\n' "$(cat "$k.code")"; cat "$k.body"; echo
else
  printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}\n'
fi
exit 0
EOF
chmod +x "$T/bin/gh"

key() { printf '%s/%s_%s' "$T/fx" "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"; }
fx()  { local k; k=$(key "$1" "$2"); printf '%s' "$3" > "$k.code"; printf '%s' "$4" > "$k.body"; }
live() { # live <yaml-file> — the committed .mergify.yml on the default branch
  fx GET "repos/$SLUG/contents/.mergify.yml?ref=$DEFB" 200 \
    "$(jq -nc --arg c "$(base64 -w0 < "$1")" '{sha:"blobmain",content:$c}')"
}
reset() { # reset <conf-file> — a fresh sandbox whose only conf is <conf-file>
  rm -rf "$T/h" "$T/fx"; mkdir -p "$T/h/config/mergify/repos" "$T/fx"
  cp "$1" "$T/h/config/mergify/repos/project-5.conf"
  echo "$SLUG" > "$T/fx/visible"
  fx GET "repos/$SLUG" 200 "{\"default_branch\":\"$DEFB\"}"
}
run() {
  : > "$T/gh.log"
  OUT=$(env -u MERGIFY_TEMPLATE_BIN HARNESS="$T/h" PATH="$T/bin:$PATH" GH_ETAG=0 \
        STUB_FX="$T/fx" STUB_LOG="$T/gh.log" ${PYPATH:+PYTHONPATH="$PYPATH"} bash "$SUT" "$@" 2>"$T/err"); RC=$?
  cat "$T/gh.log" >> "$T/gh.all"
}
alerts() { if [ -f "$T/h/logs/ALERTS.log" ]; then grep -c . "$T/h/logs/ALERTS.log"; else echo 0; fi; }
tojson() { python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'; }

# Today's conf (what main carried before BH-3439), today's live file, and the new render.
grep -Ev '^(max_parallel_checks|batch_size|max_checks_retries)=' "$CONF" > "$T/today.conf"
{ cat "$T/today.conf"; echo 'max_checks_retries=1'; } > "$T/today-live.conf"
"$TPL" render "$T/today-live.conf" > "$T/today-live.yml" && [ -s "$T/today-live.yml" ] && ok || bad "setup: render of today's live conf failed"
"$TPL" render "$CONF" > "$T/new.yml" && [ -s "$T/new.yml" ] && ok || bad "setup: render of project-5.conf failed"
cmp -s "$T/today-live.yml" "$T/new.yml" && bad "setup: the new render equals today's live file, nothing to sync" || ok

# --- N2 no PyYAML: cannot compare is never IN_SYNC (runs with or without PyYAML)
mkdir -p "$T/noyaml"; echo 'raise ImportError("stubbed out by the test")' > "$T/noyaml/yaml.py"
reset "$CONF"; live "$T/new.yml"; PYPATH="$T/noyaml" run check example-org/project-5
[ "$OUT" = "$SLUG UNREADABLE cannot-compare" ] && [ "$RC" = 1 ] && ok || bad "N2 no PyYAML: '$OUT' rc $RC ($(head -c 300 "$T/err"))"

if ! python3 -c 'import yaml' 2>/dev/null; then
  for s in D1 D2 D3 D4 D5 N1; do skip "$s"; done
  echo "mergify-drift-project-5.bh-3439: $PASS passed, $FAIL failed"
  [ "$FAIL" = 0 ]; exit
fi

# --- D1 today's mismatch: the conf says 0 retries, the repo runs 1 ------------
reset "$T/today.conf"; live "$T/today-live.yml"; run check example-org/project-5
[ "$OUT" = "$SLUG DRIFT" ] && ok || bad "D1 stdout: '$OUT' ($(head -c 300 "$T/err"))"
[ "$RC" = 1 ] && ok || bad "D1 rc $RC"
[ "$(alerts)" = 1 ] && ok || bad "D1 alerts $(alerts)"
grep -F "[mergify-sync] $SLUG DRIFT:" "$T/h/logs/ALERTS.log" 2>/dev/null | grep -q max_checks_retries \
  && ok || bad "D1 the ALERTS line does not name max_checks_retries: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q "bin/mergify-sync.sh apply $SLUG" "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "D1 the ALERTS line has no fix command"

# --- D2 the new conf against today's file: DRIFT until the sync PR lands ------
reset "$CONF"; live "$T/today-live.yml"; run check example-org/project-5
[ "$OUT" = "$SLUG DRIFT" ] && [ "$RC" = 1 ] && ok || bad "D2: '$OUT' rc $RC ($(head -c 300 "$T/err"))"
grep -F "[mergify-sync] $SLUG DRIFT:" "$T/h/logs/ALERTS.log" 2>/dev/null | grep -q max_parallel_checks \
  && ok || bad "D2 the drift does not name max_parallel_checks: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# --- D3 after the sync: the repo carries the render of the new conf ------------
reset "$CONF"; live "$T/new.yml"; run check example-org/project-5
[ "$OUT" = "$SLUG IN_SYNC" ] && [ "$RC" = 0 ] && ok || bad "D3: '$OUT' rc $RC ($(head -c 300 "$T/err"))"
[ "$(alerts)" = 0 ] && ok || bad "D3 alerted: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
tojson < "$T/new.yml" | jq -e '.merge_queue.max_parallel_checks == 6
    and (.queue_rules[]|select(.name=="default") | .batch_size == 4 and .max_checks_retries == 1)
    and (.queue_rules[]|select(.name=="hotfix")  | .batch_size == 1 and .max_checks_retries == 0)' >/dev/null \
  && ok || bad "D3 the synced file is not 6 parallel / batch 4 / 1 retry (hotfix 1 / 0)"

# --- D4 override= exempts the repo, without reading its file ------------------
{ cat "$CONF"; echo 'override=hand-tuned for D4'; } > "$T/override.conf"
reset "$T/override.conf"; live "$T/today-live.yml"; run check example-org/project-5
[ "$OUT" = "$SLUG OVERRIDE hand-tuned for D4" ] && [ "$RC" = 0 ] && ok || bad "D4: '$OUT' rc $RC"
[ "$(alerts)" = 0 ] && ok || bad "D4 alerted"
grep -q contents "$T/gh.log" && bad "D4 read the live file" || ok

# --- D5 apply opens the sync PR carrying the new values ------------------------
BR="harness/mergify-sync-$(sha256sum < "$T/new.yml" | cut -c1-8)"
reset "$CONF"; live "$T/today-live.yml"
fx GET "repos/$SLUG/pulls?state=open&head=example-org:$BR" 200 '[]'
fx GET "repos/$SLUG/git/ref/heads/$DEFB" 200 '{"object":{"sha":"headsha"}}'
fx POST "repos/$SLUG/git/refs" 201 "{\"ref\":\"refs/heads/$BR\"}"
fx GET "repos/$SLUG/contents/.mergify.yml?ref=$BR" 200 '{"sha":"blobbr","content":""}'
fx PUT "repos/$SLUG/contents/.mergify.yml" 200 '{"content":{}}'
fx POST "repos/$SLUG/pulls" 201 '{"number":9,"html_url":"https://github.com/example-org/project-5/pull/9"}'
run apply example-org/project-5
[ "$OUT" = "$SLUG PR_CREATED https://github.com/example-org/project-5/pull/9" ] && [ "$RC" = 0 ] && ok || bad "D5: '$OUT' rc $RC ($(head -c 300 "$T/err"))"
PUTIN=$(grep -A1 -xF "PUT repos/$SLUG/contents/.mergify.yml" "$T/gh.log" | tail -n 1)
printf '%s' "${PUTIN#INPUT }" | jq -r .branch 2>/dev/null | grep -qx 'harness/mergify-sync-[0-9a-f]\{8\}' \
  && ok || bad "D5 PUT is not on a harness/mergify-sync-* branch: $PUTIN"
printf '%s' "${PUTIN#INPUT }" | jq -r .content 2>/dev/null | base64 -d > "$T/put.yml" 2>/dev/null
tojson < "$T/put.yml" > "$T/put.json" 2>/dev/null \
  && jq -e '.merge_queue.max_parallel_checks == 6 and (.queue_rules[]|select(.name=="default").max_checks_retries) == 1
            and (.queue_rules[]|select(.name=="hotfix").max_checks_retries) == 0' "$T/put.json" >/dev/null \
  && ok || bad "D5 the PUT file is not parallel 6 / default retries 1: $(jq -c '{mq:.merge_queue, q:[.queue_rules[]?|{name,max_checks_retries}]}' "$T/put.json" 2>/dev/null)"
grep -qF "\"ref\":\"refs/heads/$DEFB\"" "$T/gh.log" && bad "D5 a ref write to the default branch" || ok
grep -qF "\"branch\":\"$DEFB\"" <<<"$(grep -A1 '^PUT ' "$T/gh.log")" && bad "D5 a PUT on the default branch" || ok
grep -q '/merge' "$T/gh.log" && bad "D5 a merge call" || ok

# --- N1 a file with only the retry flipped back to 0 is not in sync ------------
python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
[r for r in d["queue_rules"] if r["name"]=="default"][0]["max_checks_retries"]=0
print(yaml.safe_dump(d, sort_keys=False), end="")' "$T/new.yml" > "$T/n1.yml"
reset "$CONF"; live "$T/n1.yml"; run check example-org/project-5
[ "$OUT" = "$SLUG DRIFT" ] && [ "$RC" = 1 ] && ok || bad "N1 retry-only drift: '$OUT' rc $RC"

echo "mergify-drift-project-5.bh-3439: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
