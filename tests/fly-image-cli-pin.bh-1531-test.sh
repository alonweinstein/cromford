#!/bin/bash
# tests/fly-image-cli-pin.bh-1531-test.sh — BH-1531: the three BH-1517
# follow-ups (review notes N1/N2/N3 on #1520).
#
#   N3 (A-N3a/b/c): bin/fly-image-build.sh runs the cli.*.version DB row
#      through cli_version_parse. An unparseable row ("latest", a typo) is
#      ignored with a WARN and the existing host-CLI fallback is used; a row
#      carrying a version inside other text still pins the dotted number; a
#      bad row with no host CLI still FATALs. A bad row never reaches
#      --build-arg.
#   N2 (A-N2, A1-regress): state/fly/<p>.cli is written ONLY next to a parsed
#      image ref. When the pushed ref is not found, both .image and .cli are
#      left untouched and the WARN says so.
#   N1 (C-N1a/b/c): the baked-CLI bookkeeping + drift floor in
#      bin/fly-image-refresh.sh runs on EVERY per-project iteration, including
#      a FAILED rebuild — which, with N2 in place, is what makes it a real
#      stale-builder detector instead of a same-run self-compare.
#
# Run from anywhere: tests/fly-image-cli-pin.bh-1531-test.sh   (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- shared fakebin (same shape as the BH-1517 suite) ----------------------
FB="$T/fakebin"
mkdir -p "$FB"
cat > "$FB/fly" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo "[{\"Name\":\"${STUB_APP:-builder-demo}\"}]" ;;
  "apps create") exit 0 ;;
  deploy*)
    echo "$*" >> "${DEPLOY_ARGS_SINK:-/dev/null}"
    if [ "${STUB_NO_REF:-0}" = 1 ]; then echo "building image (no ref line)"
    else echo "image: registry.fly.io/${STUB_APP:-builder-demo}:deployment-01TEST"; fi ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$FB/gh"
printf '#!/bin/bash\nexit 0\n' > "$FB/npm"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$METHOD $URL" in
  *"GET "*"/api/settings/cli.claude_code.version")
    if [ -n "${SETTING_CLAUDE:-}" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$SETTING_CLAUDE"
    else printf '{}\n404\n'; fi ;;
  # BH-1528: every bake.<name>.version row the build now also pins; one
  # value serves them all (these suites are about the CLI rows).
  *"GET "*"/api/settings/bake."*) printf '{"setting":{"value":"1.0.0"}}\n200\n' ;;
  *"GET "*"/api/settings/cli.codex.version")
    if [ -n "${SETTING_CODEX:-}" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$SETTING_CODEX"
    else printf '{}\n404\n'; fi ;;
  *"PUT "*"/api/settings") printf '{"accepted":1}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
CURL
chmod +x "$FB"/*

stub_cli() { # stub_cli <name> <version-or-empty-to-remove>
  local name="$1" v="${2:-}"
  if [ -z "$v" ]; then rm -f "$FB/$name"; return; fi
  case "$name" in
    claude) printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s (Claude Code)"\n' "$v" > "$FB/$name" ;;
    codex)  printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli %s"\n' "$v" > "$FB/$name" ;;
  esac
  chmod +x "$FB/$name"
}

new_h() {
  local h; h=$(mktemp -d "$T/h-XXXXXX")
  mkdir -p "$h/bin/lib/jobs" "$h/state/fly" "$h/env" "$h/logs" "$h/flags"
  cp "$DIR/bin/jobs-client.sh" "$h/bin/jobs-client.sh"
  cp "$DIR"/bin/lib/jobs/*.sh "$h/bin/lib/jobs/"
  cp "$DIR/bin/lib/cli-version.sh" "$h/bin/lib/cli-version.sh"
  cp "$DIR/bin/alert-line.sh" "$h/bin/alert-line.sh"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$h/env/global.env"
  echo "$h"
}

build_run() { # build_run <project> [env...] — runs the REAL script; sets RC, OUT
  local proj="$1"; shift
  : > "$T/deploy-args"; : > "$T/req.log"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" HARNESS="$H" WARM_BAKE=0 FLY_ORG=stub-org \
        DEPLOY_ARGS_SINK="$T/deploy-args" REQ_SINK="$T/req.log" STUB_APP="builder-$proj" \
        "$@" bash "$DIR/bin/fly-image-build.sh" "$proj" 2>&1); RC=$?
}

# ===========================================================================
# N3 — the DB row is validated before it becomes a --build-arg
# ===========================================================================
# A-N3a: row "latest" is not a version -> WARN + host fallback, never shipped.
H=$(new_h); stub_cli claude 2.1.200; stub_cli codex 0.150.0
build_run demon3a SETTING_CLAUDE=latest SETTING_CODEX=0.153.4
[ "$RC" = 0 ] && ok || bad "A-N3a: rc=$RC: $OUT"
grep -q -- '--build-arg CLAUDE_CODE_VERSION=2.1.200' "$T/deploy-args" && ok \
  || bad "A-N3a: host fallback version did not reach fly deploy: $(cat "$T/deploy-args")"
grep -q -- 'CLAUDE_CODE_VERSION=latest' "$T/deploy-args" && bad "A-N3a: the unparseable row reached fly deploy: $(cat "$T/deploy-args")" || ok
grep -q 'is not a dotted version' <<<"$OUT" && ok || bad "A-N3a: no WARN about the bad row: $OUT"

# A-N3b: bad row AND no host claude -> the existing FATAL refusal still fires.
# A PATH with NO claude anywhere on it (not even this box's real one), so the
# fallback genuinely resolves nothing.
FB_NOCLAUDE="$T/fakebin-noclaude"; mkdir -p "$FB_NOCLAUDE"
cp "$FB"/fly "$FB"/gh "$FB"/npm "$FB"/curl "$FB_NOCLAUDE/"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.150.0"\n' > "$FB_NOCLAUDE/codex"
chmod +x "$FB_NOCLAUDE"/*
for b in jq sed grep awk cut tail head cat mktemp rm mkdir printf timeout date dirname basename realpath cd env bash; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$FB_NOCLAUDE/$b" 2>/dev/null
done
H=$(new_h)
: > "$T/deploy-args"; : > "$T/req.log"
OUT=$(env -i PATH="$FB_NOCLAUDE" HOME="$T" HARNESS="$H" WARM_BAKE=0 FLY_ORG=stub-org \
      DEPLOY_ARGS_SINK="$T/deploy-args" REQ_SINK="$T/req.log" STUB_APP=builder-demon3b \
      SETTING_CLAUDE=latest bash "$DIR/bin/fly-image-build.sh" demon3b 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "A-N3b: expected rc 1, got $RC: $OUT"
grep -q 'FATAL: no CLAUDE_CODE_VERSION' <<<"$OUT" && ok || bad "A-N3b: no FATAL line: $OUT"
[ -s "$T/deploy-args" ] && bad "A-N3b: fly deploy ran with nothing pinned: $(cat "$T/deploy-args")" || ok

# A-N3c: a row with the version inside other text still pins the dotted number.
H=$(new_h); stub_cli claude 2.1.200; stub_cli codex 0.150.0
build_run demon3c SETTING_CLAUDE="2.1.280 (Claude Code)" SETTING_CODEX=0.153.4
[ "$RC" = 0 ] && ok || bad "A-N3c: rc=$RC: $OUT"
grep -q -- '--build-arg CLAUDE_CODE_VERSION=2.1.280' "$T/deploy-args" && ok \
  || bad "A-N3c: dotted version not extracted from the row: $(cat "$T/deploy-args")"

# ===========================================================================
# N2 — .cli is written only next to a parsed image ref
# ===========================================================================
# A-N2: no ref in this run's output -> .image AND .cli both untouched.
H=$(new_h); stub_cli claude 2.1.200; stub_cli codex 0.150.0
printf 'claude=2.1.100\ncodex=0.100.0\n' > "$H/state/fly/demon2.cli"
echo 'registry.fly.io/builder-demon2:deployment-OLD' > "$H/state/fly/demon2.image"
build_run demon2 STUB_NO_REF=1 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
[ "$RC" = 0 ] && ok || bad "A-N2: rc=$RC: $OUT"
[ "$(cat "$H/state/fly/demon2.cli")" = "$(printf 'claude=2.1.100\ncodex=0.100.0')" ] && ok \
  || bad "A-N2: .cli overwritten although no image ref was parsed: $(cat "$H/state/fly/demon2.cli")"
[ "$(cat "$H/state/fly/demon2.image")" = 'registry.fly.io/builder-demon2:deployment-OLD' ] && ok \
  || bad "A-N2: .image overwritten although no ref was parsed: $(cat "$H/state/fly/demon2.image")"
grep -q 'WARN: pushed ref not found' <<<"$OUT" && grep -q '\.cli' <<<"$OUT" && ok \
  || bad "A-N2: the WARN line does not say .cli was left untouched: $OUT"

# A1-regress: a parsed ref still records both files (BH-1517 behavior kept).
H=$(new_h); stub_cli claude ""; stub_cli codex ""
build_run demon2b SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
[ "$RC" = 0 ] && ok || bad "A1-regress: rc=$RC: $OUT"
[ "$(cat "$H/state/fly/demon2b.cli" 2>/dev/null)" = "$(printf 'claude=2.1.280\ncodex=0.153.4')" ] && ok \
  || bad "A1-regress: .cli not recorded on a successful build: $(cat "$H/state/fly/demon2b.cli" 2>/dev/null)"
[ "$(cat "$H/state/fly/demon2b.image" 2>/dev/null)" = 'registry.fly.io/builder-demon2b:deployment-01TEST' ] && ok \
  || bad "A1-regress: .image not recorded: $(cat "$H/state/fly/demon2b.image" 2>/dev/null)"

# ===========================================================================
# N1 — the drift floor runs on a FAILED rebuild too
# ===========================================================================
stub_builder_fail() { # stub_builder_fail <h> — builder that never succeeds and writes nothing
  local h="$1"
  printf '#!/bin/bash\necho "FATAL: image build/push failed"\nexit 1\n' > "$h/bin/fly-image-build.sh"
  chmod +x "$h/bin/fly-image-build.sh"
}
refresh_run() { # refresh_run <h> [env...]
  local h="$1"; shift
  : > "$T/req.log"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" HARNESS="$h" REQ_SINK="$T/req.log" "$@" \
        bash "$DIR/bin/fly-image-refresh.sh" 2>&1); RC=$?
}

# C-N1a: failed rebuild + a stale on-disk .cli -> rebuild FAILED alert AND
# exactly one drift alert naming the stale baked version.
H=$(new_h); : > "$H/flags/fly-pool-demoN1a"
stub_builder_fail "$H"
printf 'claude=2.1.270\ncodex=0.153.4\n' > "$H/state/fly/demoN1a.cli"
refresh_run "$H" CLI_DRIFT_MAX_PATCH=3 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
[ "$RC" = 0 ] && ok || bad "C-N1a: rc=$RC: $OUT"
[ "$(grep -c 'rebuild FAILED' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "C-N1a: expected one rebuild FAILED alert: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(grep -c 'CLI drift' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "C-N1a: expected exactly one CLI drift alert on a failed rebuild: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep 'CLI drift' "$H/logs/ALERTS.log" 2>/dev/null | grep -q 'claude baked=2.1.270 hub=2.1.280' && ok \
  || bad "C-N1a: drift line missing the stale baked detail: $(grep 'CLI drift' "$H/logs/ALERTS.log" 2>/dev/null)"

# C-N1b: failed rebuild, .cli only 2 patches behind a floor of 3 -> no drift.
H=$(new_h); : > "$H/flags/fly-pool-demoN1b"
stub_builder_fail "$H"
printf 'claude=2.1.278\ncodex=0.153.4\n' > "$H/state/fly/demoN1b.cli"
refresh_run "$H" CLI_DRIFT_MAX_PATCH=3 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
grep -q 'CLI drift' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "C-N1b: a 2-patch drift under a floor of 3 must not alert: $(cat "$H/logs/ALERTS.log")" || ok

# C-N1c: failed rebuild and no .cli at all -> rc 0, no drift line.
H=$(new_h); : > "$H/flags/fly-pool-demoN1c"
stub_builder_fail "$H"
refresh_run "$H" CLI_DRIFT_MAX_PATCH=3 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
[ "$RC" = 0 ] && ok || bad "C-N1c: rc=$RC: $OUT"
grep -q 'CLI drift' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "C-N1c: no .cli file must mean no drift claim: $(cat "$H/logs/ALERTS.log")" || ok

echo "fly-image-cli-pin.bh-1531-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
