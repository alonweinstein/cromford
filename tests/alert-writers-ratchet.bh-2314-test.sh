#!/bin/bash
# tests/alert-writers-ratchet.bh-2314-test.sh — freeze the raw ALERTS.log
# writers in bin/ while the BH-2314 waves move them onto bin/alert-line.sh.
#
# THE POINT. A bare `echo … >> ALERTS.log` reaches the alerts table only when
# poll-commands.sh's re-beat tails the file, a minute later, and only if that
# cron is alive. bin/alert-line.sh notes the row at emit time. This suite stops
# new bare writers landing while the waves convert the old ones.
#
# THE REGISTRY IS ONE FILE PER WRITER (the gh-app-ratchet shape, BH-1177):
# tests/alert-writers-ratchet-baseline/<path under bin/>.txt holds that file's
# raw-site count. A wave that converts a file deletes (or lowers) its own
# baseline file, so waves in flight touch disjoint paths and never conflict.
#
# WHAT THE RATCHET ASSERTS, per file under bin/ (*.sh, or any shell shebang):
#   red   sites > 0 and no baseline file;
#   red   sites > the baseline's count;
#   note  a baseline whose file is gone or is now at 0 sites (not red: the wave
#         that converted it deletes the baseline in the same PR, and a red here
#         would force waves to land in order);
#   skip  a file whose HEADER BLOCK (shebang to first line of code) carries
#         `# alert-writer: by-design — <why>`. The list is printed every run.
#
# WHAT COUNTS AS A SITE. After `#` comments are stripped (quote-aware), a `>>`
# or `tee -a` that sits OUTSIDE quotes, whose target word
#   (1) ends in ALERTS.log (`$H/logs/ALERTS.log`, "$HARNESS/logs/ALERTS.log"), or
#   (2) is $VAR / ${VAR} / "$VAR" where the same file assigns VAR a value ending
#       in ALERTS.log, or expands `${VAR:-…ALERTS.log}` anywhere (that default
#       is the file saying what VAR is — bin/lib/rb/gates.sh reads $ALERTS that
#       run-build.sh assigns, and spells the default out on some of its lines).
# NOT a site: grep/tail/cat/wc/`<` reads, comments, quoted prose that mentions
# `>> ALERTS.log`, ALERTS.log.1, and `>> "$VAR"` where VAR is some other log.
# Every one of those is pinned in block 2.
#
# WHAT IT DOES NOT CATCH, said plainly: a write built at runtime (`eval`, a
# `bash -c` string), a quote that opens on one line and closes on another
# (the per-line quote state is then wrong for that line), a VAR assigned in
# another file, and anything outside bin/.
#
# TWO MODES (tests/lib/ratchet-delta.sh). The absolute check above is STRICT
# mode (RATCHET_MODE=strict or --strict), for a scheduled or post-merge run.
# The default, DELTA, is what every PR and merge-queue run uses: count each
# file's raw sites at the base (the newest main this HEAD contains) and at HEAD,
# by-design files excluded on both sides, and go red only when THIS diff raised
# a file's count or added a file with sites. Delta mode never reads the
# baseline files: a raw writer main landed elsewhere (a batch that did not
# select this suite, a baseline two waves deleted at once) sits on both sides
# and cancels, which is what kept PR #2818's batches red in 10 of 35 runs. A
# base that does not resolve is red, never a skip. A PR adding a raw writer
# has two ways out, the same two as before: bin/alert-line.sh, or the
# by-design header. Block 4 drives both modes through hermetic git repos.
#
# Run from anywhere: tests/alert-writers-ratchet.bh-2314-test.sh [--strict] (exit 0 = pass)
# No network, no clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BASE="$DIR/tests/alert-writers-ratchet-baseline"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/scan.py" <<'PY'
import os, re, sys

MARK = re.compile(r"^#\s*alert-writer:\s*by-design\s+—\s+\S")
SHEBANG = re.compile(r"^#!.*\b(ba|da|k|z)?sh\b")
ASSIGN = re.compile(r"(?:^|[\s;(])(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)*)?([A-Za-z_]\w*)=(\S+)")
VARREF = re.compile(r"^\$\{?([A-Za-z_]\w*)\}?$")
DEFAULT = re.compile(r"\$\{([A-Za-z_]\w*):?[-=][^}]*ALERTS\.log\}")


def strip_comment(line):
    out, sq, dq, esc, prev = [], False, False, False, ""
    for ch in line:
        if esc:
            esc = False
        elif ch == "\\" and not sq:
            esc = True
        elif ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif ch == "#" and not sq and not dq and (prev == "" or prev.isspace() or prev in ";&|("):
            break
        out.append(ch)
        prev = ch
    return "".join(out)


def unquote(w):
    return w.replace('"', "").replace("'", "")


def word_at(s, i):
    """The shell word starting at s[i] (quotes kept), after leading blanks."""
    while i < len(s) and s[i] in " \t":
        i += 1
    out, sq, dq = [], False, False
    while i < len(s):
        ch = s[i]
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif not sq and not dq and (ch.isspace() or ch in ";|&)<>"):
            break
        out.append(ch)
        i += 1
    return "".join(out)


def redirect_targets(code):
    """Targets of every `>>` / `tee -a` outside quotes on one stripped line."""
    out, sq, dq, esc, i = [], False, False, False, 0
    while i < len(code):
        ch = code[i]
        if esc:
            esc = False
        elif ch == "\\" and not sq:
            esc = True
        elif ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif not sq and not dq:
            if code.startswith(">>", i):
                out.append(word_at(code, i + 2))
                i += 2
                continue
            m = re.match(r"tee\s+(?:-\w+\s+)*-a\s+", code[i:])
            if m and (i == 0 or not (code[i - 1].isalnum() or code[i - 1] in "_-")):
                out.append(word_at(code, i + m.end()))
                i += m.end()
                continue
        i += 1
    return out


def is_alerts(value):
    v = unquote(value).rstrip("};)")
    return v.endswith("ALERTS.log")


def header_marked(lines):
    for line in lines:
        t = line.strip()
        if t and not t.startswith("#"):
            return False
        if MARK.match(t):
            return True
    return False


def scan(path):
    with open(path, errors="ignore") as fh:
        lines = fh.read().split("\n")
    code = [strip_comment(l).strip() for l in lines]
    avars = set()
    for c in code:
        for m in ASSIGN.finditer(c):
            if is_alerts(m.group(2)):
                avars.add(m.group(1))
        avars.update(DEFAULT.findall(c))
    n = 0
    for c in code:
        if not c:
            continue
        for t in redirect_targets(c):
            u = unquote(t)
            if is_alerts(u):
                n += 1
            else:
                m = VARREF.match(u)
                if m and m.group(1) in avars:
                    n += 1
    return n, header_marked(lines)


def is_shell(path):
    if path.endswith(".sh"):
        return True
    try:
        with open(path, errors="ignore") as fh:
            return bool(SHEBANG.match(fh.readline()))
    except OSError:
        return False


root = sys.argv[1]
for d, _, files in os.walk(root):
    if "__pycache__" in d or "/node_modules" in d:
        continue
    for f in sorted(files):
        p = os.path.join(d, f)
        if os.path.isfile(p) and is_shell(p):
            n, ex = scan(p)
            print("%s\t%d\t%d" % (os.path.relpath(p, root), n, int(ex)))
PY

# check <bin-dir> <baseline-dir> — the ratchet. Prints findings, rc 1 on red.
check() {
  local bin="$1" base="$2" rc=0 rel n ex want f
  python3 "$T/scan.py" "$bin" | sort > "$T/rows.tsv" || { echo "RED: scanner failed"; return 1; }
  while IFS=$'\t' read -r rel n ex; do
    [ "$ex" = 1 ] && continue
    [ "$n" -gt 0 ] || continue
    f="$base/$rel.txt"
    if [ ! -f "$f" ]; then
      echo "RED: bin/$rel has $n raw ALERTS.log write(s) and no baseline — use bin/alert-line.sh, or add '# alert-writer: by-design — <why>' to its header"
      rc=1; continue
    fi
    want=$(tr -dc '0-9' < "$f")
    if [ -z "$want" ] || [ "$n" -gt "$want" ]; then
      echo "RED: bin/$rel has $n raw ALERTS.log write(s), baseline ${want:-unreadable} — new writers go through bin/alert-line.sh"
      rc=1
    fi
  done < "$T/rows.tsv"
  if [ -d "$base" ]; then
    while IFS= read -r f; do
      rel=${f#"$base"/}; rel=${rel%.txt}
      n=$(awk -F'\t' -v r="$rel" '$1==r && $3==0 {print $2}' "$T/rows.tsv")
      [ "${n:-0}" -gt 0 ] || echo "NOTE: baseline $rel.txt names a file with no raw writes now — delete it"
    done < <(find "$base" -name '*.txt' | sort)
  fi
  return $rc
}
count_of() { python3 "$T/scan.py" "$1" | awk -F'\t' -v f="$2" '$1==f{print $2}'; }

# sites <bin-dir> — "<path under bin/>\t<n>" for every non-by-design file with
# raw sites: the per-file counts delta mode compares.
sites() { python3 "$T/scan.py" "$1" | awk -F'\t' '$3 == 0 && $2 > 0 { print $1 "\t" $2 }' | sort; }

# delta_check <repo> <base-commit> — red when THIS diff adds a raw writer.
delta_check() {
  local repo="$1" ref="$2" w rel n b rc=0
  w=$(mktemp -d "$T/delta-base.XXXXXX") || return 1
  rd_tree "$repo" "$ref" "$w" bin || { echo "RED: cannot read bin/ at base $ref"; return 1; }
  mkdir -p "$w/bin"
  sites "$w/bin" > "$w.base" || { echo "RED: scanner failed on base $ref"; return 1; }
  sites "$repo/bin" > "$w.head" || { echo "RED: scanner failed"; return 1; }
  while IFS=$'\t' read -r rel n b; do
    echo "RED: bin/$rel has $n raw ALERTS.log write(s), $b at base ${ref:0:12} — new writers go through bin/alert-line.sh, or add '# alert-writer: by-design — <why>' to its header"
    rc=1
  done < <(rd_delta "$w.head" "$w.base")
  return $rc
}

# real_check <repo> — the check the run makes, by mode.
real_check() {
  local base
  case "$MODE" in
    strict) check "$1/bin" "$1/tests/alert-writers-ratchet-baseline" ;;
    delta)  base=$(rd_base "$1") || { echo "RED: $base"; return 1; }
            delta_check "$1" "$base" ;;
  esac
}
MODE=$(rd_mode "$@") || { echo "FAIL: $MODE"; exit 1; }

echo "--- block 1: bin/, $MODE mode"
OUT=$(real_check "$DIR"); RC=$?
[ -n "$OUT" ] && printf '%s\n' "$OUT"
[ "$RC" -eq 0 ] && ok || bad "bin/ is over its alert-writer ratchet (see RED lines above)"
python3 "$T/scan.py" "$DIR/bin" | sort > "$T/rows.tsv"
echo "by-design (exempt): $(awk -F'\t' '$3==1{printf "%s ", $1}' "$T/rows.tsv")"
echo "raw sites: $(awk -F'\t' '$3==0{s+=$2; if($2>0)n++} END{print s+0 " in " n+0 " files"}' "$T/rows.tsv")"

echo "--- block 2: what the detector counts"
F="$T/fx/bin"; mkdir -p "$F"
cat > "$F/neg.sh" <<'EOF'
#!/bin/bash
grep X "$H/logs/ALERTS.log"
tail -n 5 "$HARNESS/logs/ALERTS.log" | wc -l
# echo x >> ALERTS.log
echo "append with >> ALERTS.log"
echo 'or >> "$H/logs/ALERTS.log" in single quotes'
mv ALERTS.log ALERTS.log.1; echo y >> "$H/logs/ALERTS.log.1"
while read -r l; do :; done < "$H/logs/ALERTS.log"
LOG="$H/logs/x.log"; echo z >> "$LOG"
EOF
[ "$(count_of "$F" neg.sh)" = 0 ] && ok || bad "block 2: negatives counted $(count_of "$F" neg.sh) site(s), want 0"
cat > "$F/var.sh" <<'EOF'
#!/bin/bash
A="$H/logs/ALERTS.log"; echo z >>"$A"
EOF
[ "$(count_of "$F" var.sh)" = 1 ] && ok || bad "block 2: >>\"\$VAR\" counted $(count_of "$F" var.sh), want 1"
cat > "$F/pos.sh" <<'EOF'
#!/bin/bash
AL="${HARNESS_ALERTS:-$H/logs/ALERTS.log}"
echo "$(date) a" >> "$H/logs/ALERTS.log"
echo b >>$HARNESS/logs/ALERTS.log
echo c | tee -a "$H/logs/ALERTS.log" >/dev/null
{ echo d; } >> "${AL}"
echo "it's $(tr '\n' ' ' < f) now" >> "$AL"   # trailing comment >> ALERTS.log
EOF
[ "$(count_of "$F" pos.sh)" = 5 ] && ok || bad "block 2: positives counted $(count_of "$F" pos.sh), want 5"
printf 'X="$H/logs/ALERTS.log"\necho q >> "$X"\n' > "$F/noext"; printf '#!/usr/bin/env bash\necho q >> "$H/logs/ALERTS.log"\n' > "$F/shebang"
[ "$(count_of "$F" noext)" = "" ] && [ "$(count_of "$F" shebang)" = 1 ] \
  && ok || bad "block 2: file selection wrong (noext='$(count_of "$F" noext)' shebang='$(count_of "$F" shebang)')"

echo "--- block 3: the ratchet goes red"
# m1: one extra writer in a scratch copy of a baselined file
M="$T/m1"; mkdir -p "$M/bin" "$M/base"
cp "$DIR/bin/cost-rollup.sh" "$M/bin/"; cp "$BASE/cost-rollup.sh.txt" "$M/base/" 2>/dev/null
check "$M/bin" "$M/base" >/dev/null && ok || bad "m1: an untouched copy of bin/cost-rollup.sh is not green against its baseline"
printf '%s\n' 'echo x >> "$HARNESS/logs/ALERTS.log"' >> "$M/bin/cost-rollup.sh"
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -ne 0 ] && grep -q 'cost-rollup.sh has .* baseline' <<<"$OUT" \
  && { ok; echo "m1 red as expected: $OUT"; } || bad "m1: an extra writer in cost-rollup.sh stayed green: $OUT"
# m2: a raw writer with no baseline
M="$T/m2"; mkdir -p "$M/bin/lib" "$M/base"
printf '#!/bin/bash\n# new lane\necho x >> "$HARNESS/logs/ALERTS.log"\n' > "$M/bin/lib/new.sh"
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -ne 0 ] && grep -q 'bin/lib/new.sh has 1 .* no baseline' <<<"$OUT" \
  && { ok; echo "m2 red as expected: $OUT"; } || bad "m2: a raw writer with no baseline stayed green: $OUT"
# m3: the by-design header exempts it — but only in the header block
printf '#!/bin/bash\n# new lane\n# alert-writer: by-design — fixture\necho x >> "$HARNESS/logs/ALERTS.log"\n' > "$M/bin/lib/new.sh"
check "$M/bin" "$M/base" >/dev/null && ok || bad "m3: a by-design header was not accepted"
printf '#!/bin/bash\nset -u\n# alert-writer: by-design — too late\necho x >> "$HARNESS/logs/ALERTS.log"\n' > "$M/bin/lib/new.sh"
check "$M/bin" "$M/base" >/dev/null && bad "m3: a by-design line BELOW the header exempted the file" || ok
# stale baseline: a note, never red
rm -f "$M/bin/lib/new.sh"; echo 3 > "$M/base/gone.sh.txt"
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -eq 0 ] && grep -q 'NOTE: baseline gone.sh.txt' <<<"$OUT" && ok || bad "stale baseline: want a NOTE and rc 0, got rc=$RC: $OUT"

echo "--- block 4: delta mode, hermetic repos"
# B: bin/a.sh has one raw site and a baseline that says so; bin/b.sh has none.
dmk() {
  local R="$1"
  scratch_rm "$R" || return 1
  mkdir -p "$R/bin" "$R/tests/alert-writers-ratchet-baseline"
  printf '#!/bin/bash\necho a >> "$H/logs/ALERTS.log"\n' > "$R/bin/a.sh"
  printf '#!/bin/bash\ntrue\n' > "$R/bin/b.sh"
  echo 1 > "$R/tests/alert-writers-ratchet-baseline/a.sh.txt"
  rd_fixture_repo "$R"
}
d_main_raw()  { printf 'echo b >> "$H/logs/ALERTS.log"\n' >> "$1/bin/b.sh"; }
d_drift()     { rd_main_commit "$1" 'main: b.sh gains a raw writer' d_main_raw; }
d_pr_docs()   { echo more >> "$1/README"; rd_git "$1" commit -qam 'pr: docs'; }
d_pr_raw()    { printf 'echo c | tee -a "$H/logs/ALERTS.log"\n' >> "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: a.sh gains a writer'; }
d_pr_new()    { printf '#!/bin/bash\necho n >> "$HARNESS/logs/ALERTS.log"\n' > "$1/bin/n.sh"; rd_git "$1" add -A; rd_git "$1" commit -qm 'pr: new writer file'; }
d_pr_bydes()  { printf '#!/bin/bash\n# alert-writer: by-design — fixture\necho n >> "$H/logs/ALERTS.log"\n' > "$1/bin/n.sh"; rd_git "$1" add -A; rd_git "$1" commit -qm 'pr: by-design writer'; }
d_pr_conv()   { printf '#!/bin/bash\nbin/alert-line.sh a\n' > "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: convert a.sh'; }
d_merge()     { rd_git "$1" merge -q --no-edit refs/remotes/origin/main; }
d_nomain()    { rd_git "$1" update-ref -d refs/remotes/origin/main; }
dcase() {  # <name> <want_rc> <RATCHET_BASE: main|B|none|bogus> <mode> <steps...>
  local name="$1" want="$2" rb="$3" mode="$4" R="$T/d-$1" b step out rc
  shift 4
  dmk "$R" || { bad "D($name): repo setup failed"; return; }
  b=$(rd_git "$R" rev-parse HEAD)
  for step in "$@"; do "$step" "$R" >/dev/null || { bad "D($name): step $step failed"; return; }; done
  case "$rb" in
    main)  rb=$(rd_git "$R" rev-parse refs/remotes/origin/main) ;;
    B)     rb="$b" ;;
    none)  rb="" ;;
    bogus) rb=0123456789abcdef0123456789abcdef01234567 ;;
  esac
  out=$(MODE="$mode" RATCHET_BASE="$rb" TI_BASE= real_check "$R" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "D($name) rc=$rc want $want:"$'\n'"$out"; fi
}
dcase main-drift-pr-base       0 main  delta d_drift d_pr_docs d_merge
dcase main-drift-queue-draft   0 main  delta d_pr_docs d_drift d_merge
dcase main-drift-stale-base    0 B     delta d_drift d_pr_docs d_merge
dcase main-drift-local         0 none  delta d_drift d_pr_docs d_merge
dcase pr-adds-writer           1 main  delta d_pr_raw
dcase pr-adds-after-drift      1 main  delta d_drift d_pr_raw d_merge
dcase pr-adds-new-file         1 main  delta d_drift d_pr_new d_merge
dcase pr-by-design-exempt      0 main  delta d_pr_bydes
dcase pr-converts              0 main  delta d_pr_conv
dcase bogus-base               1 bogus delta d_pr_docs
dcase no-base-at-all           1 none  delta d_pr_docs d_nomain
dcase strict-sees-drift        1 main  strict d_drift d_pr_docs d_merge
dcase strict-clean             0 main  strict d_pr_docs

echo "alert-writers-ratchet ($MODE): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
