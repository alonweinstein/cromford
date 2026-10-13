#!/bin/bash
# tests/guardrails-test.sh — the guardrail catalog's checks must actually FIRE.
#
# A guardrail nobody proved is a guardrail nobody can trust, and the failure is
# silent by construction: a rule that matches nothing looks exactly like a repo
# with nothing to find. So every check in guardrails/ is exercised against a
# seeded violation (must fail) AND a clean fixture (must pass), here, on every
# CI run.
#
# semgrep checks are skipped when semgrep is absent (dev laptops) — CI installs
# it, and SEMGREP_REQUIRED=1 turns the skip into a hard failure, the same shape
# the codegraph suite uses.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
G="$DIR/guardrails"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── every catalog entry ships a doc and at least one fixture ────────────────
for C in hardcoded-model-ids native-dialogs metered-vendor-choke \
         rls-on-create-table verification-map-freshness doc-monolith-edit rendered-file-freshness; do
  [ -f "$G/$C/README.md" ] && ok || bad "$C: missing README.md"
  [ -d "$G/$C/fixtures" ] && [ -n "$(ls -A "$G/$C/fixtures" 2>/dev/null)" ] \
    && ok || bad "$C: missing fixtures"
done
[ -f "$G/README.md" ] && ok || bad "guardrails/README.md missing"
[ -f "$G/PILOT-TICKET.md" ] && ok || bad "guardrails/PILOT-TICKET.md missing"

# every check's doc must name the escape hatch — a check without a documented
# way out gets deleted the first time it is wrong
for C in hardcoded-model-ids native-dialogs metered-vendor-choke \
         rls-on-create-table verification-map-freshness doc-monolith-edit rendered-file-freshness; do
  grep -q 'skip-guardrail' "$G/$C/README.md" && ok \
    || bad "$C: README does not document the skip-guardrail escape hatch"
done

# ── semgrep checks: fire on the violation, silent on the clean file ─────────
if command -v semgrep >/dev/null 2>&1; then
  sg() { # sg <check> <violation-file> <clean-file>
    local c="$1" v="$2" cl="$3"
    semgrep scan --config "$G/$c/rule.yml" --error --quiet "$G/$c/fixtures/$v" >/dev/null 2>&1 \
      && bad "$c: rule did NOT fire on its seeded violation" || ok
    semgrep scan --config "$G/$c/rule.yml" --error --quiet "$G/$c/fixtures/$cl" >/dev/null 2>&1 \
      && ok || bad "$c: rule fired on the clean fixture (false positive)"
  }
  sg hardcoded-model-ids  violation.ts   clean.ts
  sg native-dialogs       violation.tsx  clean.tsx
  sg metered-vendor-choke violation.ts   clean.ts
  # review round 2: a CSP connect-src allowlist naming a metered vendor is the
  # security control, not a rogue call site. Config files are excluded.
  semgrep scan --config "$G/metered-vendor-choke/rule.yml" --error --quiet \
    "$G/metered-vendor-choke/fixtures/clean.config.ts" >/dev/null 2>&1 \
    && ok || bad "metered-vendor-choke: fired on a CSP allowlist in a config file"
  # a semgrep message must not contain an unescaped $N — semgrep reads it as a
  # metavariable and silently rewrites the sentence (it ate "USD 1,678" once)
  grep -q . <<<"$(grep -hoE '\$[0-9]' "$G"/*/rule.yml)" \
    && bad "a rule.yml message contains \$N — semgrep will interpolate it" || ok
elif [ "${SEMGREP_REQUIRED:-0}" = "1" ]; then
  bad "semgrep required but not installed"
else
  echo "  (semgrep not installed — semgrep checks skipped; set SEMGREP_REQUIRED=1 to fail instead)"
fi

# ── rls-on-create-table ────────────────────────────────────────────────────
mkdir -p "$T/rls-bad" "$T/rls-good"
cp "$G/rls-on-create-table/fixtures/violation.sql" "$T/rls-bad/"
cp "$G/rls-on-create-table/fixtures/clean.sql" "$T/rls-good/"
"$G/rls-on-create-table/check.sh" "$T/rls-bad" >/dev/null 2>&1 \
  && bad "rls: did NOT fire on a CREATE TABLE with no RLS" || ok
"$G/rls-on-create-table/check.sh" "$T/rls-good" >/dev/null 2>&1 \
  && ok || bad "rls: fired on the clean migration"
# no migrations at all is 'nothing to check', not a failure
mkdir -p "$T/rls-empty"
"$G/rls-on-create-table/check.sh" "$T/rls-empty" >/dev/null 2>&1 \
  && ok || bad "rls: an empty dir must be rc 0"
# the escape hatch needs BOTH the label and a real justification
PR_LABELS="skip-guardrail" "$G/rls-on-create-table/check.sh" "$T/rls-bad" >/dev/null 2>&1 \
  && bad "rls: label alone must NOT skip the check" || ok
PR_LABELS="bug,skip-guardrail" \
GUARDRAIL_JUSTIFICATION="Guardrail-Justification: legacy migration reapplied verbatim from the vendor export" \
  "$G/rls-on-create-table/check.sh" "$T/rls-bad" >/dev/null 2>&1 \
  && ok || bad "rls: label + justification must skip the check"

# ── the escape hatch itself (review round 2) ───────────────────────────────
# It disables a security check, so what it accepts IS the security boundary.
HATCH() { # HATCH <justification-text> ; rc 0 = would skip the check
  PR_LABELS="skip-guardrail" GUARDRAIL_JUSTIFICATION="$1" \
    "$G/rls-on-create-table/check.sh" "$T/rls-bad" >/dev/null 2>&1
}
# whitespace is not a reason — 25 spaces passed a naive length check
HATCH "                         " && bad "hatch: whitespace-only justification accepted" || ok
HATCH "Guardrail-Justification:                          " \
  && bad "hatch: whitespace-only marker payload accepted" || ok
HATCH "" && bad "hatch: empty justification accepted" || ok
HATCH "short" && bad "hatch: too-short justification accepted" || ok
# a bare blob is not enough: the marker line has to be typed on purpose
HATCH "this is a perfectly long sentence but carries no marker line at all" \
  && bad "hatch: accepted a bare blob with no Guardrail-Justification marker" || ok
# the marker match is case-insensitive, so the STRIP must be too — a mangled-case
# marker that the grep finds but the sed misses leaves the 24-char marker text
# itself as the "reason", skipping with an empty actual payload (review round 3)
HATCH "GUARDRAIL-JUSTIFICATION:                          " \
  && bad "hatch: case-mangled marker with empty payload accepted" || ok
HATCH "GUARDRAIL-JUSTIFICATION: legacy migration reapplied verbatim from vendor" \
  || bad "hatch: case-mangled marker with a REAL reason must still work" && ok
# a real marker line inside a larger PR body is what a human actually writes
HATCH "$(printf 'Fixes the flaky test.\n\nGuardrail-Justification: pure rename refactor, no migration semantics changed\n\nCc @someone')" \
  && ok || bad "hatch: a real marker line inside a PR body must be accepted"
# only the marker payload is measured, not the surrounding body
HATCH "$(printf 'A very long PR body that goes on and on for many characters indeed.\nGuardrail-Justification: nope\n')" \
  && bad "hatch: measured the whole body instead of the marker payload" || ok

# the raw-PR-body wiring must not appear in any shipped ci-step sample —
# it is what drafted checks copy, and it makes any body a justification
# Matches a YAML-shaped ASSIGNMENT (line begins with the key), not prose that
# NAMES the anti-pattern. escape-hatch.sh and the catalog README both have to
# be able to say "never wire it to ${{ github.event.pull_request.body }}" in
# order to warn about it — quoting the bug is the fix, not an instance of it.
# A real sample, in a .yml or inside a markdown fence, still trips this.
grep -q . <<<"$(grep -rnE '^[[:space:]]*GUARDRAIL_JUSTIFICATION:[[:space:]]*\$\{\{[^}]*pull_request\.body' \
     "$G" 2>/dev/null)" \
  && bad "a shipped sample wires GUARDRAIL_JUSTIFICATION to the raw PR body" || ok

# ── verification-map-freshness ─────────────────────────────────────────────
VF="$G/verification-map-freshness/fixtures"
# adopted repo: routes changed, map untouched -> fail
mkdir -p "$T/repo/docs/verification-map"
( cd "$T/repo" && VMAP_FILES="$VF/changed-stale.txt" \
  "$G/verification-map-freshness/check.sh" >/dev/null 2>&1 ) \
  && bad "vmap: did NOT fire on routes-changed-map-unchanged" || ok
( cd "$T/repo" && VMAP_FILES="$VF/changed-fresh.txt" \
  "$G/verification-map-freshness/check.sh" >/dev/null 2>&1 ) \
  && ok || bad "vmap: fired when the map changed alongside the routes"
( cd "$T/repo" && VMAP_FILES="$VF/changed-no-routes.txt" \
  "$G/verification-map-freshness/check.sh" >/dev/null 2>&1 ) \
  && ok || bad "vmap: fired on a diff with no route files"
# NOT adopted: same stale diff must pass, and say so
mkdir -p "$T/plain"
OUT=$( cd "$T/plain" && VMAP_FILES="$VF/changed-stale.txt" \
  "$G/verification-map-freshness/check.sh" 2>&1 ); RC=$?
[ "$RC" = 0 ] && grep -q 'not adopted' <<<"$OUT" && ok \
  || bad "vmap: an unadopted repo must pass and say 'not adopted' (rc=$RC)"
# adoption is read off the CHECKOUT: a diff that DELETES the map still fails
printf 'src/app/clients/page.tsx\ndocs/verification-map/clients.md\n' > "$T/del.txt"
( cd "$T/repo" && VMAP_FILES="$T/del.txt" \
  "$G/verification-map-freshness/check.sh" >/dev/null 2>&1 ) \
  && ok || bad "vmap: a diff touching both routes and the map is fresh"
# escape hatch
( cd "$T/repo" && PR_LABELS="skip-guardrail" \
  GUARDRAIL_JUSTIFICATION="Guardrail-Justification: pure rename refactor, no user-visible behavior changed" \
  VMAP_FILES="$VF/changed-stale.txt" \
  "$G/verification-map-freshness/check.sh" >/dev/null 2>&1 ) \
  && ok || bad "vmap: label + justification must skip the check"
( cd "$T/repo" && PR_LABELS="skip-guardrail" GUARDRAIL_JUSTIFICATION="meh" \
  VMAP_FILES="$VF/changed-stale.txt" \
  "$G/verification-map-freshness/check.sh" >/dev/null 2>&1 ) \
  && bad "vmap: a too-short justification must NOT skip the check" || ok

# ── doc-monolith-edit ──────────────────────────────────────────────────────
# The catalog's claim is that every check FIRES on its seeded violation and is
# silent on its clean one, so the pack gets that pair here too. The full case
# list — title near-misses, deleted markers, marker-less docs — lives in
# tests/guardrail-doc-monolith-test.sh.
DF="$G/doc-monolith-edit/fixtures"
mkdir -p "$T/mono/docs"
printf '# EVENTS\n\n<!-- changes:begin -->\n> pointer line\n<!-- changes:end -->\n\nStable contract text.\nMore stable text.\n' \
  > "$T/mono/docs/EVENTS.md"
( cd "$T/mono" && PR_TITLE='feat: x' DOC_MONOLITH_DIFF="$DF/diff-body.txt" \
  "$G/doc-monolith-edit/check.sh" >/dev/null 2>&1 ) \
  && bad "doc-monolith: did NOT fire on a paragraph appended to a contract doc" || ok
( cd "$T/mono" && PR_TITLE='feat: x' DOC_MONOLITH_DIFF="$DF/diff-notes-only.txt" \
  "$G/doc-monolith-edit/check.sh" >/dev/null 2>&1 ) \
  && ok || bad "doc-monolith: fired on a diff that only adds a dated note"

# ── rendered-file-freshness ────────────────────────────────────────────────
# A rendered file hand-edited without its fragments is reverted by the next
# render, silently. Every case drives the REAL check.sh as a process, with the
# changed-file list handed in through RFF_FILES and adoption judged in a scratch
# RFF_ROOT — so nothing here depends on which sibling renderer has merged.
RF="$G/rendered-file-freshness"
RFX="$RF/fixtures"
[ -x "$RF/check.sh" ] && ok || bad "rff: check.sh is missing or not executable"
A="$T/rff-repo"      # fully adopted: every fragment dir present
mkdir -p "$A/cron/lanes" "$A/cron/boxes" "$A/env-templates/lanes" "$A/rules/topics"
E="$T/rff-plain"     # adopted by nothing — this repo today
mkdir -p "$E"
P="$T/rff-rules-only" # partially adopted: only the rules row
mkdir -p "$P/rules/topics"
RFF_RC=0
rff() { # rff <root> <changed-list-file>
  RFF_ROOT="$1" RFF_FILES="$2" "$RF/check.sh" >"$T/rff.out" 2>&1
  RFF_RC=$?
}
list() { printf '%s\n' "$@" > "$T/rff-list.txt"; echo "$T/rff-list.txt"; }
# rc is asserted exactly: a missing script exits 127, and "nonzero" would read
# that as "the check fired".
fires() { [ "$RFF_RC" = 1 ] && ok || bad "$1 (rc=$RFF_RC: $(head -2 "$T/rff.out" | tr '\n' ' '))"; }
clean() { [ "$RFF_RC" = 0 ] && ok || bad "$1 (rc=$RFF_RC: $(head -2 "$T/rff.out" | tr '\n' ' '))"; }
says()   { grep -qF -- "$1" "$T/rff.out" && ok || bad "$2"; }
denies() { grep -qF -- "$1" "$T/rff.out" && bad "$2" || ok; }

# G1-G4 must FIRE, and the message has to name the fragment dir and the command
rff "$A" "$RFX/changed-stale.txt"
fires "rff: a rendered cron file with no input change must fire"
says 'cron/lanes/' "rff: the violation must name the fragment dir"
says 'bin/render-crontab.sh --from-fragments --all --write' "rff: the violation must name the render command"
says 'cron/hub.cron' "rff: the violation must list the rendered file it saw"
rff "$A" "$(list env-templates/global.env.example)"
fires "rff: a hand-edited env example must fire"
says 'env-templates/lanes/' "rff: the env row must name env-templates/lanes/"
rff "$A" "$(list rules/CLAUDE.md)"
fires "rff: a hand-edited rules/CLAUDE.md must fire"
says 'rules/topics/' "rff: the rules row must name rules/topics/"
rff "$A" "$RFX/changed-deleted.txt"
fires "rff: DELETING a rendered file with no input change must fire"
says 'cron/lanes/' "rff: the deletion case must name the fragment dir"

# G5-G10 must NOT fire
rff "$A" "$(list fleet.conf cron/project-4.cron)"
clean "rff: fleet.conf is an input of the cron row"
rff "$A" "$RFX/changed-fresh.txt"
clean "rff: a fragment edited alongside its rendered file is fresh"
says 'Clean' "rff: the fresh case must say so"
rff "$A" "$RFX/changed-registry.txt"
clean "rff: bin/lib/cron-lines.sh is an input of the cron row"
rff "$A" "$(list bin/render-rules.sh rules/CLAUDE.md)"
clean "rff: the renderer script itself counts as an input of its row"
rff "$A" "$RFX/changed-no-rendered.txt"
clean "rff: a diff with no rendered file must pass"
says 'no rendered registry file' "rff: the no-rendered-file no-op must be printed"
for F in cron/README.md env-templates/project.env.example rules/RTK.md; do
  rff "$A" "$(list "$F")"
  clean "rff: $F is not a rendered registry file"
done

# G11-G13 adoption is a fact about the CHECKOUT, per row
rff "$E" "$RFX/changed-stale.txt"
clean "rff: an unadopted checkout must pass"
says 'not adopted' "rff: an unadopted checkout must say 'not adopted'"
rff "$P" "$(list rules/CLAUDE.md cron/hub.cron)"
fires "rff: the adopted rules row must still fire in a partly adopted checkout"
says 'rules/topics/' "rff: the adopted row is checked"
denies 'cron/lanes/' "rff: an unadopted row must not be checked (no cron/lanes/ in this root)"
( cd "$E" && RFF_ROOT="$A" RFF_FILES="$RFX/changed-stale.txt" "$RF/check.sh" >"$T/rff.out" 2>&1 )
RFF_RC=$?
fires "rff: adoption is judged under RFF_ROOT, not the current directory"

# G14-G15 the escape hatch, on the real script
PR_LABELS="skip-guardrail" RFF_ROOT="$A" RFF_FILES="$RFX/changed-stale.txt" \
  "$RF/check.sh" >"$T/rff.out" 2>&1; RFF_RC=$?
fires "rff: the label alone must NOT skip the check"
PR_LABELS="bug,skip-guardrail" \
GUARDRAIL_JUSTIFICATION="Guardrail-Justification: rendered by hand for the hotfix, fragments follow in #999" \
RFF_ROOT="$A" RFF_FILES="$RFX/changed-stale.txt" "$RF/check.sh" >"$T/rff.out" 2>&1; RFF_RC=$?
clean "rff: label + justification must skip the check"
says 'SKIPPED' "rff: a skip must say it skipped"

# G16 a target repo brings its own map, by file or by env
C1="$T/rff-cfg"; mkdir -p "$C1/config/parts"
RFF_MAP_FILE="$RFX/map.txt" RFF_ROOT="$C1" RFF_FILES="$(list config/generated.json)" \
  "$RF/check.sh" >"$T/rff.out" 2>&1; RFF_RC=$?
fires "rff: RFF_MAP_FILE rows are honoured"
says 'config/parts/' "rff: the custom row must name its own fragment dir"
RFF_MAP_FILE="$RFX/map.txt" RFF_ROOT="$C1" \
RFF_FILES="$(list config/parts/a.json config/generated.json)" \
  "$RF/check.sh" >"$T/rff.out" 2>&1; RFF_RC=$?
clean "rff: a custom row with its fragment edited is fresh"
RFF_MAP="$(printf 'config/generated.json|config/parts/|scripts/render-config.sh --write\n')" \
RFF_ROOT="$C1" RFF_FILES="$(list config/generated.json)" \
  "$RF/check.sh" >"$T/rff.out" 2>&1; RFF_RC=$?
fires "rff: RFF_MAP rows are honoured"

# G17 a list it cannot read is an honest no-op, never a pass claim
rff "$A" "$T/rff-does-not-exist.txt"
clean "rff: an unreadable RFF_FILES must not fail the PR"
says 'not readable' "rff: an unreadable RFF_FILES must say so rather than pass silently"

# G18 ONE spelling of the registry. The baked default is extracted from the
# shipped script by its markers and compared to the contract's rf_registry —
# retyping either one here would prove only that they were typed twice.
RFF_BLOCK=$(sed -n '/# >>> rff default map/,/# <<< rff default map/p' "$RF/check.sh" 2>/dev/null)
[ -n "$RFF_BLOCK" ] && ok || bad "rff: no '# >>> rff default map' block in check.sh to compare"
( eval "$RFF_BLOCK"; printf '%s\n' "${RFF_DEFAULT_MAP:-}" | tr '|' '\t' ) > "$T/rff-default.tsv" 2>/dev/null
( . "$DIR/bin/lib/render-fragments.sh" && rf_registry ) > "$T/rff-registry.tsv" 2>/dev/null
[ -s "$T/rff-default.tsv" ] && [ -s "$T/rff-registry.tsv" ] \
  && ok || bad "rff: could not read both spellings of the registry"
[ "$(wc -l < "$T/rff-registry.tsv")" = 4 ] && ok || bad "rff: rf_registry no longer prints 4 rows"
diff -q "$T/rff-default.tsv" "$T/rff-registry.tsv" >/dev/null \
  && ok || bad "rff: the baked default map has drifted from rf_registry: $(diff "$T/rff-default.tsv" "$T/rff-registry.tsv" | head -4 | tr '\n' ' ')"

# G19 the catalog names it, exactly once
[ "$(grep -c 'rendered-file-freshness/' "$G/README.md")" = 1 ] \
  && ok || bad "rff: the catalog table must carry exactly one row for the pack"

# G20 adoption survives the fragment dir being DELETED in the diff: a row whose
# first input exists at the base ref is still checked, so "delete cron/lanes/
# and hand-edit cron/hub.cron" cannot read as "not adopted" and pass.
D="$T/rff-deleted-dir"; mkdir -p "$D/cron/lanes"
if git -C "$D" init -q 2>/dev/null && : > "$D/cron/lanes/a.frag" \
   && git -C "$D" add -A && git -C "$D" -c user.name=t -c user.email=t@t commit -qm base 2>/dev/null; then
  scratch_rm "$D/cron/lanes"
  RFF_ROOT="$D" RFF_FILES="$RFX/changed-stale.txt" "$RF/check.sh" HEAD >"$T/rff.out" 2>&1; RFF_RC=$?
  fires "rff: a row adopted at the base ref must still fire when the diff deleted its fragment dir"
  says 'cron/lanes/' "rff: the deleted-dir case must still name the fragment dir"
else
  echo "  (git unavailable — the deleted-fragment-dir case is not exercised)"
fi
RFF_ROOT="$E" RFF_FILES="$RFX/changed-stale.txt" "$RF/check.sh" HEAD >"$T/rff.out" 2>&1; RFF_RC=$?
clean "rff: a plain dir with no git history and no fragment dir is still not adopted"

# G21 a map row whose input field opens with a space must not adopt itself
RFF_MAP="$(printf 'config/generated.json| config/parts/|scripts/render-config.sh --write\n')" \
RFF_ROOT="$T/rff-plain" RFF_FILES="$(list config/generated.json)" \
  "$RF/check.sh" >"$T/rff.out" 2>&1; RFF_RC=$?
clean "rff: a leading space in the input field must not adopt the row unconditionally"
RFF_MAP="$(printf 'config/generated.json| |scripts/render-config.sh --write\n')" \
RFF_ROOT="$T/rff-plain" RFF_FILES="$(list config/generated.json)" \
  "$RF/check.sh" >"$T/rff.out" 2>&1; RFF_RC=$?
clean "rff: an all-blank input field is a malformed row, not an adopted one"
says 'malformed row' "rff: the all-blank input field must be reported as malformed"

# G22 the same base-ref adoption, for a row whose first input is a FILE. `-d`
# on git ls-tree prints tree entries only, so a blob path read as "not adopted"
# and the row a custom map explicitly allows (a file input) kept the hole G20
# closed for directories.
FD="$T/rff-deleted-file"; mkdir -p "$FD/config"
FDMAP='config/generated.json|config/parts.json|scripts/render-config.sh --write'
if git -C "$FD" init -q 2>/dev/null && : > "$FD/config/parts.json" \
   && git -C "$FD" add -A && git -C "$FD" -c user.name=t -c user.email=t@t commit -qm base 2>/dev/null; then
  scratch_rm "$FD/config/parts.json"
  RFF_MAP="$FDMAP" RFF_ROOT="$FD" RFF_FILES="$(list config/generated.json)" \
    "$RF/check.sh" HEAD >"$T/rff.out" 2>&1; RFF_RC=$?
  fires "rff: a row whose first input is a FILE present at the base ref must still fire when the diff deleted it"
  says 'config/parts.json' "rff: the deleted-file case must still name the input"
else
  echo "  (git unavailable — the deleted-fragment-file case is not exercised)"
fi

# G23 a file that IS an input is never counted as a rendered file: 'cron/*.cron'
# matches cron/lanes/x.cron because '*' crosses '/', so a fragment-only diff used
# to report "1 rendered file(s) changed with their inputs" for a diff holding
# zero rendered files. rc was right; the count was not.
rff "$A" "$(list cron/lanes/x.cron)"
clean "rff: a fragment-only diff must pass"
says 'no rendered registry file' "rff: a fragment-only diff holds no rendered file and must say so"
denies 'rendered file(s) changed with their inputs' "rff: a fragment must not be counted as a rendered file"

# W1/W2 the CI wiring itself: one PR-only step in the lint job, full history,
# and the justification taken from the marker line rather than the raw body.
WF="$DIR/.github/workflows/harness-ci.yml"
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$WF" <<'PY' && ok || bad "rff: harness-ci.yml lint job must checkout with fetch-depth 0 and run the check once against origin/\${{ github.base_ref }}, on pull_request only"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
lint = d['jobs']['lint']['steps']
s = [x for x in lint if 'rendered-file-freshness/check.sh "origin/${{ github.base_ref }}"' in (x.get('run') or '')]
ok = (len(s) == 1
      and s[0].get('if') == "github.event_name == 'pull_request'"
      and lint[0].get('with', {}).get('fetch-depth') == 0
      and 'PR_LABELS' in (s[0].get('env') or {})
      and 'PR_BODY' in (s[0].get('env') or {}))
sys.exit(0 if ok else 1)
PY
else
  echo "  (PyYAML missing — the workflow wiring is checked by text instead)"
  grep -qF 'rendered-file-freshness/check.sh "origin/${{ github.base_ref }}"' "$WF" \
    && grep -q 'fetch-depth: 0' "$WF" \
    && ok || bad "rff: harness-ci.yml does not run the check or does not fetch full history"
fi
grep -qE '^[[:space:]]*GUARDRAIL_JUSTIFICATION:[[:space:]]*\$\{\{' "$WF" \
  && bad "rff: harness-ci.yml wires GUARDRAIL_JUSTIFICATION straight from a \${{ }} expression" || ok

# V1 the verification map carries the entry, and the index points at it
[ -f "$DIR/docs/verification-map/rendered-registries.md" ] \
  && ok || bad "rff: docs/verification-map/rendered-registries.md is missing"
# The index is GENERATED and not committed (BH-1175), so the assertion reads the
# committed SOURCE the index is built from — the entry files — rather than an
# artifact that may not exist in this checkout at all.
[ "$(cat "$DIR"/docs/verification-map/entries/*.md 2>/dev/null | grep -c 'rendered-registries.md')" = 1 ] \
  && ok || bad "rff: the verification-map entries must name rendered-registries.md exactly once"

echo "guardrails-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
