#!/bin/bash
# tests/flyctl-issue-guard.bh-5210-test.sh — no recipe in this repo tells a
# session to run `flyctl ssh issue … --overwrite`, and only bin/remote-gate.sh
# runs `flyctl ssh issue` at all (BH-5210).
#
# WHY. On 2026-10-05 a hand issue with --overwrite into a scratch path looped
# for 44 hours and wrote 596 GB into a redirect. The bounded path already
# existed inside bin/remote-gate.sh; bin/issue-testhost-cert.sh is now its one
# hand entry point, and this suite keeps the docs pointing there.
#
#   G0 the scan finds a planted recipe: one line, backslash-continued, `fly`
#      spelled short, and it honours the allowlist (non-vacuity)
#   G1 the checkout has no such recipe in bin docs skills orchestrator prompts
#      rules CLAUDE.md
#   G2 in bin/, only remote-gate.sh runs `flyctl ssh issue` (non-comment lines)
#   G3 docs/REMOTE-GATE.md, skills/harness/SKILL.md and CLAUDE.md name the
#      wrapper and say never to run `flyctl ssh issue` directly
#   G4 the wrapper is executable, mode 100755 in git
#
# tests/ is not scanned: stubs there spell the command on purpose.
#
# Run from anywhere: tests/flyctl-issue-guard.bh-5210-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The one allowed hit: the BH-1836 note is the history of the defect that
# bounded path fixed (what the gate used to run), not a recipe anyone follows.
ALLOW=(docs/notes/2026-09-24-BH-1836-remote-gate-cert-reissue.md)
SCAN_PATHS=(bin docs skills orchestrator prompts rules CLAUDE.md)
ISSUE_RE='(^|[^[:alnum:]_-])fly(ctl)?[[:space:]]+ssh[[:space:]]+issue'

allowed() { local a; for a in "${ALLOW[@]}"; do [ "$1" = "$a" ] && return 0; done; return 1; }

# joined <file> — the file with backslash-continued lines joined, each output
# line prefixed with the line number the command started on.
joined() {
  awk '{ if (buf == "") start = NR
         line = $0
         if (line ~ /\\$/) { buf = buf substr(line, 1, length(line) - 1) " "; next }
         print start ":" buf line; buf = "" }
       END { if (buf != "") print start ":" buf }' "$1"
}

# scan <root> — prints <file>:<line> for every `fly(ctl) ssh issue` carrying
# --overwrite under the scanned paths of <root>, outside the allowlist.
scan() {
  local root=$1 p f rel
  for p in "${SCAN_PATHS[@]}"; do
    [ -e "$root/$p" ] || continue
    while IFS= read -r f; do
      rel=${f#"$root"/}
      allowed "$rel" && continue
      joined "$f" | grep -E -- "$ISSUE_RE" | grep -- '--overwrite' | cut -d: -f1 | sed "s|^|$rel:|"
    done < <(find "$root/$p" -type f ! -path '*/node_modules/*' 2>/dev/null; true)
  done
}

# issuers <root> — <file>:<line> for every non-comment line in bin/ that runs
# `flyctl ssh issue`, outside bin/remote-gate.sh.
issuers() {
  local root=$1 f rel
  while IFS= read -r f; do
    rel=${f#"$root"/}
    [ "$rel" = bin/remote-gate.sh ] && continue
    joined "$f" | grep -E -- "$ISSUE_RE" | awk -F: -v r="$rel" '{ l = substr($0, length($1) + 2); sub(/^[[:space:]]+/, "", l); if (l !~ /^#/) print r ":" $1 }'
  done < <(find "$root/bin" -type f -name '*.sh' 2>/dev/null; true)
}

# ── G0. the scan can fail ───────────────────────────────────────────────────
FX="$T/fx"; mkdir -p "$FX/bin" "$FX/docs/notes" "$FX/skills/s"
echo 'flyctl ssh issue o k --hours 1 --overwrite > /tmp/fi.txt' > "$FX/bin/x.sh"
printf 'intro\nflyctl ssh issue o k \\\n  --overwrite\n' > "$FX/docs/y.md"
echo 'run `fly ssh issue board-builders ~/k --overwrite`' > "$FX/skills/s/SKILL.md"
echo 'flyctl ssh issue o k --overwrite' > "$FX/${ALLOW[0]}"
echo 'flyctl ssh issue o k --hours 1' > "$FX/docs/clean.md"
echo 'myfly ssh issue o k --overwrite' >> "$FX/docs/clean.md"
out=$(scan "$FX")
case "$out" in *"bin/x.sh:1"*) ok ;; *) bad "G0a a one-line recipe in bin/ was not found: $out" ;; esac
case "$out" in *"docs/y.md:2"*) ok ;; *) bad "G0b a backslash-continued recipe in docs/ was not found: $out" ;; esac
case "$out" in *"skills/s/SKILL.md:1"*) ok ;; *) bad "G0c 'fly ssh issue … --overwrite' in a skill was not found: $out" ;; esac
case "$out" in *"${ALLOW[0]}"*) bad "G0d the allowlisted note was reported: $out" ;; *) ok ;; esac
case "$out" in *clean.md*) bad "G0e a line without --overwrite, or another tool's name, was reported: $out" ;; *) ok ;; esac
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] && ok || bad "G0f want exactly 3 hits in the fixture, got: $out"

# ── G1. the checkout is clean ───────────────────────────────────────────────
out=$(scan "$DIR")
[ -z "$out" ] && ok || bad "G1 a 'flyctl ssh issue … --overwrite' recipe outside bin/issue-testhost-cert.sh (use the wrapper instead): $out"

# ── G2. one issuer in bin/ ──────────────────────────────────────────────────
printf '#!/bin/bash\n# flyctl ssh issue is only a comment here\n  flyctl ssh issue "$ORG" "$K" --hours 1\n' > "$FX/bin/z.sh"
out=$(issuers "$FX")
case "$out" in *"bin/z.sh:3"*) ok ;; *) bad "G2a a second issuer in the fixture's bin/ was not found: $out" ;; esac
case "$out" in *"bin/z.sh:2"*) bad "G2b a comment was read as an issuer: $out" ;; *) ok ;; esac
out=$(issuers "$DIR")
[ -z "$out" ] && ok || bad "G2 a script in bin/ other than remote-gate.sh runs flyctl ssh issue: $out"
grep -Eq "^[^#]*$ISSUE_RE" "$DIR/bin/remote-gate.sh" && ok || bad "G2c bin/remote-gate.sh no longer runs the issue (the scan would be vacuous)"

# ── G3. the docs point at the wrapper ───────────────────────────────────────
for d in docs/REMOTE-GATE.md skills/harness/SKILL.md CLAUDE.md; do
  grep -q 'bin/issue-testhost-cert.sh' "$DIR/$d" 2>/dev/null && ok || bad "G3 $d does not name bin/issue-testhost-cert.sh"
  grep -qi 'never.*flyctl ssh issue' "$DIR/$d" 2>/dev/null && ok || bad "G3 $d does not say never to run flyctl ssh issue directly"
done

# ── G4. the wrapper is wired ────────────────────────────────────────────────
[ -x "$DIR/bin/issue-testhost-cert.sh" ] && ok || bad "G4 bin/issue-testhost-cert.sh is not executable"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  m=$(git -C "$DIR" ls-files -s bin/issue-testhost-cert.sh | awk '{print $1}')
  [ "$m" = 100755 ] && ok || bad "G4b bin/issue-testhost-cert.sh is '${m:-untracked}' in git, want 100755"
fi

echo "flyctl-issue-guard (BH-5210): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
