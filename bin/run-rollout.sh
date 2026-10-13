#!/bin/bash
# bin/run-rollout.sh — deterministic wave-style rollout parser.
# usage: run-rollout.sh <project> <ticket-id> <KEY> <build-dir>
#        run-rollout.sh --is-rollout <body-file>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/file-children.sh
. "$HERE/lib/file-children.sh" || { echo "cannot source file-children.sh" >&2; exit 1; }
# Optional (BH-4061): a tree without it refuses exactly as it did before.
# shellcheck source=bin/lib/rollout-refusal.sh
. "$HERE/lib/rollout-refusal.sh" 2>/dev/null || true

# --is-rollout cheap detector: prints nothing, exits 0/1.
if [ "${1:-}" = "--is-rollout" ]; then
  file="${2:?body file}"; [ -f "$file" ] || exit 1
  fc_has_rollout < "$file"; exit $?
fi

PROJECT="${1:?project}"; TICKET="${2:?ticket id}"; KEY="${3:?key}"; BUILD="${4:?build dir}"
mkdir -p "$BUILD"

# fail_result <reason> — every failure path from here on writes the SAME
# rollout-run.txt an operator reads after the happy path, RESULT line last,
# not stdout only. Defined before first use is fine: $BUILD is already set.
fail_result() {
  printf 'RESULT "ROLLOUT_FAILED %s"\n' "$1" >> "$BUILD/rollout-run.txt"
  printf 'RESULT "ROLLOUT_FAILED %s"\n' "$1"
  exit 1
}

# record_keys — how many children the RECORD says exist. children.txt is
# append-only and written by the filer only after GitHub returned an issue
# number, so this count is the one piece of evidence in the build dir that a
# wave is real. Blank lines are not keys.
record_keys() {
  local k
  k=$(grep -c '[^[:space:]]' "$BUILD/children.txt" 2>/dev/null || true)
  case "${k:-}" in ''|*[!0-9]*) k=0 ;; esac
  printf '%s' "$k"
}

# THE WATERMARK IS A THREE-WAY DECISION, NOT A RETURN. `[ -s children.txt ]` →
# exit 0 meant a run that died between wave 1 and wave 3 answered GREEN on
# every later tick, having filed nothing, and the waves that never existed
# never did (BH-1335 item 1). The record is compared against the SPEC instead:
# complete → say so truthfully, partial → fall through so the filer's own
# resume (bin/lib/fc-issues.sh, BH-1482) files only the missing waves, and a
# record with no readable spec refuses — absent is not zero.
if [ -s "$BUILD/children.txt" ]; then
  REC_K=$(record_keys)
  REC_N=$(jq 'length' "$BUILD/children.json" 2>/dev/null)
  case "${REC_N:-}" in ''|*[!0-9]*) REC_N=0 ;; esac
  if [ "$REC_N" -eq 0 ]; then
    fail_result "children.txt holds $REC_K key(s) but this record has no readable children.json to resume against"
  fi
  if [ "$REC_K" -ge "$REC_N" ]; then
    fc_log "$BUILD" "ROLLOUT_ALREADY_FILED $KEY ($REC_K of $REC_N waves on the record)"
    # A RESULT line of its own, every time. The old path wrote none, so the
    # hook at bin/run-build.sh:1924 read whatever the previous run left behind.
    printf 'RESULT "ROLLOUT_FILED %s"\n' "$REC_N" >> "$BUILD/rollout-run.txt"
    printf 'RESULT "ROLLOUT_FILED %s"\n' "$REC_N"
    exit 0
  fi
  fc_log "$BUILD" "ROLLOUT_RESUME $KEY ($REC_K of $REC_N waves already filed)"
fi

HARNESS="${HARNESS:-/root/harness}"; FCS="$HARNESS/bin/fleet-conf.sh"
[ -x "$FCS" ] || fail_result "fleet-conf missing"
PREFIX=$("$FCS" "$PROJECT" board_prefix 2>/dev/null || true)
[ -n "$PREFIX" ] || fail_result "fleet-conf lookup failed"

if [ "$PREFIX" = "-" ]; then
  REPO=$("$FCS" "$PROJECT" repo 2>/dev/null || true)
  [ -n "$REPO" ] || fail_result "no repo"
  # THIS READ IS GraphQL-BACKED AND THAT IS DELIBERATE. `gh issue view --json`
  # goes through GitHub's GraphQL API, which tests/gh-no-graphql-decision-guard-test.sh
  # otherwise treats as a smell. BH-1335 item 3 records it as note-only: the
  # guard's subject is a DECISION path, and this is the body fetch the lane
  # cannot make over REST without a second round trip. Left as it is on purpose
  # so the next reader does not re-litigate it.
  if ! BODY=$(PATH="${HARNESS}/bin:${PATH}" gh issue view "$TICKET" -R "$REPO" --json body -q .body 2>&1); then
    fc_log "$BUILD" "ROLLOUT_FETCH_FAILED gh issue view $TICKET -R $REPO"
    fail_result "body fetch failed"
  fi
else
  # /root/harness/env is a one-release compat symlink; bin/lib/env-path.sh is
  # the only thing that knows the real directory (bin/run-decompose.sh:84,
  # bin/lib/file-children.sh's own fc_board_base do the same resolution).
  # shellcheck source=bin/lib/env-path.sh
  . "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null \
    || . "$HERE/lib/env-path.sh" 2>/dev/null \
    || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }
  HENV=$(harness_env_dir "$HARNESS")
  ENVFILE="$HENV/$PROJECT.env"
  [ -f "$ENVFILE" ] && { set -a; . "$ENVFILE"; set +a; }
  TOKEN_VAR=$(grep -oE '^[A-Z_]+_INTERNAL_API_TOKEN' "$ENVFILE" 2>/dev/null | head -1)
  BASE_VAR=$(grep -oE '^[A-Z_]+_API_BASE' "$ENVFILE" 2>/dev/null | head -1)
  [ -n "$TOKEN_VAR" ] && [ -n "$BASE_VAR" ] || fail_result "missing env token or base"
  BASE="${!BASE_VAR}"; [ -n "$BASE" ] || fail_result "empty API base"
  URL="${BASE}${PREFIX}/tickets/${TICKET}"
  if ! RESP=$(curl -s --max-time 30 -H "Authorization: Bearer ${!TOKEN_VAR}" -H "User-Agent: curl/8" "$URL" 2>&1); then
    fc_log "$BUILD" "ROLLOUT_FETCH_FAILED $URL"
    fail_result "body fetch failed"
  fi
  BODY=$(printf '%s' "$RESP" | jq -r '.ticket // . | .description // .body // empty' 2>/dev/null)
fi

# An empty body is not a rollout: it takes the SAME no-section exit-0 path as
# any other ticket with no `## Rollout` heading (ticket item 6: "must be safe
# to call on any ticket"), not a lane failure. fc_strip_fences/fc_has_rollout
# on empty input answer "not a rollout" on their own, so nothing further is
# needed here.
printf '%s' "$BODY" | fc_strip_fences > "$BUILD/body.stripped.md"
if ! fc_has_rollout < "$BUILD/body.stripped.md"; then
  fc_log "$BUILD" "ROLLOUT_NO_SECTION $PROJECT/$KEY"
  exit 0
fi

PARSE_ERR="$BUILD/parse.err"; : > "$PARSE_ERR"
# Detection (above) runs on the fc_strip_fences output; the PARSE below runs on
# the RAW body instead, tracking its own fence and <pre>/<code> state so a
# heading-shaped or `## `-shaped line inside either never opens or closes a
# wave, and an indented (4-space/tab) heading-shaped line is body text, never
# a heading — all FOUR code forms bin/lib/file-children.sh:269-275 documents
# (fences, backtick spans, pre/code, indent). A backtick-quoted MENTION of a
# <pre>/<code> tag must not arm block state either — has_open_precode/
# has_close_precode test a backtick-masked copy of the line (strip_backticks,
# byte-identical to the library's own strip_span), the same order the
# detector already applies (backtick spans stripped per line before its
# <pre>/<code> pass). An unclosed fence or <pre>/<code> tag refuses in END
# rather than silently merging every later wave into the still-open one.
# Everything else — inline code spans, fenced blocks, pre/code blocks, any
# other HTML — reaches the child body verbatim. Only a whole-line <h2>/<h3>
# element outside all of those is mapped to ##/### for classification.
PARSED=$(printf '%s' "$BODY" | awk '
function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
function norm(s){return tolower(trim(s))}
function jqquote(s, t){t=s;gsub(/\\/,"\\\\",t);gsub(/"/,"\\\"",t);gsub(/\n/,"\\n",t);gsub(/\r/,"\\r",t);gsub(/\t/,"\\t",t);return "\"" t "\""}
function flush(){if(in_wave){waves++;wave_title[waves]=cur_title;wave_body[waves]=cur_body}in_wave=0;cur_body=""}
# fail — a fatal parse refusal. Setting `fatal` stops END from also running
# the waves==0/too-few/too-many/after: validation after an `exit` from a main
# rule: awk still runs END on an `exit` from the main body, and without this
# guard a second, misleading line (e.g. "too few waves") lands in parse.err
# after the real reason.
function fail(msg, code){print msg > errfile; fatal=1; exit code}
function fence_run(s,   m){if(!match(s,/^[ \t]*(`+|~+)/))return "";m=substr(s,RSTART,RLENGTH);sub(/^[ \t]+/,"",m);return m}
# is_indented — the same rule fc_has_rollout uses: 4+ leading spaces, or a tab
# anywhere in the leading whitespace run, is a code block, never a heading.
function is_indented(s){return (s~/^    /) || (s~/^[ ]*\t/)}
# block_marker — byte-identical to the helper of the same name in
# bin/lib/file-children.sh: the canonical open tag for the FIRST <pre/<code
# open tag in a remainder an unclosed span is about to swallow, else "".
function block_marker(rest,   lo,ip,ic){
  lo=tolower(rest)
  ip=index(lo,"<pre");ic=index(lo,"<code")
  if(ip>0&&(ic==0||ip<ic))return "<pre>"
  if(ic>0)return "<code>"
  return ""
}
# strip_backticks — byte-identical algorithm to fc_strip_fences strip_span(s,
# "`", "`"): an unclosed backtick span drops the rest of the line, EXCEPT for a
# <pre>/<code> OPEN marker it would otherwise eat, which is re-emitted so this
# pass still sees the block the author opened (BH-1335 item 2a: strip_span in
# the detector carries the identical rule, and a lone unmatched backtick in
# front of a raw <pre> used to make both of them file a phantom wave). Used ONLY to
# decide whether a line opens/closes a <pre>/<code> block — a backtick-quoted
# MENTION of a tag ("Strip `<pre><code>` spans here.") must not arm block
# state, the same way the detector already sees it (fc_strip_fences strips
# backtick spans per line BEFORE its own <pre>/<code> pass). The stored body
# text keeps the backticks; only this classification copy is masked.
function strip_backticks(s,   i,j,out,rest){
  out=""
  while(1){
    i=index(s,"`")
    if(i==0){out=out s;break}
    out=out substr(s,1,i-1)
    rest=substr(s,i+1)
    j=index(rest,"`")
    if(j==0){out=out block_marker(rest);break}
    s=substr(rest,j+1)
  }
  return out
}
function has_open_precode(s,   masked){masked=strip_backticks(s);return (tolower(masked)~/<(pre|code)[^>]*>/)}
function has_close_precode(s,   masked){masked=strip_backticks(s);return (tolower(masked)~/<\/(pre|code)>/)}
function classify(line,   t){
  t=trim(line)
  if(t~/^<[hH]2[^>]*>.*<\/[hH]2>$/){sub(/^<[hH]2[^>]*>[ \t]*/,"",t);sub(/[ \t]*<\/[hH]2>$/,"",t);return "## " t}
  if(t~/^<[hH]3[^>]*>.*<\/[hH]3>$/){sub(/^<[hH]3[^>]*>[ \t]*/,"",t);sub(/[ \t]*<\/[hH]3>$/,"",t);return "### " t}
  return line
}
{
  raw=$0; sub(/\r$/,"",raw)
  m=fence_run(raw)
  if(fence!=""){
    if(m!="" && substr(m,1,1)==fence && length(m)>=flen){fence="";flen=0}
    if(in_wave)cur_body=cur_body raw "\n"
    next
  }
  if(length(m)>=3){fence=substr(m,1,1);flen=length(m);if(in_wave)cur_body=cur_body raw "\n";next}
  if(htmlopen){
    if(has_close_precode(raw))htmlopen=0
    if(in_wave)cur_body=cur_body raw "\n"
    next
  }
  if(has_open_precode(raw) && !has_close_precode(raw)){
    htmlopen=1
    if(in_wave)cur_body=cur_body raw "\n"
    next
  }
  if(is_indented(raw)){if(in_wave)cur_body=cur_body raw "\n";next}
  # A HEADING TAG THAT IS NOT THE WHOLE LINE IS A DIVERGENCE, NOT A HEADING.
  # classify() below maps only a whole-trimmed-line <h2>/<h3> element, while
  # the DETECTOR gsubs a mid-line tag onto a heading of its own
  # (the END pass of bin/lib/file-children.sh) — so `x <h3>Wave 2: b</h3> y`
  # counts as a wave there and as body text here, and the lane files fewer
  # waves than the author wrote with a green result (BH-1335 item 2b). Scoped
  # to in_rollout on purpose: an inline <h3> in the PREAMBLE of a master is
  # prose a human wrote and never reaches a child.
  if(in_rollout && tolower(raw)~/<\/?h[23][^>]*>/){
    ht=trim(raw)
    if(!(ht~/^<[hH]2[^>]*>.*<\/[hH]2>$/) && !(ht~/^<[hH]3[^>]*>.*<\/[hH]3>$/))fail("mid-line heading tag",22)
  }
  cline=classify(raw);n=norm(cline)
  if(!in_rollout){
    if(n~/^##[ \t]+rollout$/){
      if(seen_rollout)fail("duplicate rollout section",19)
      in_rollout=1;seen_rollout=1
    }
    next
  }
  if(n~/^##[ \t]+rollout$/)fail("nested rollout",10)
  if(n~/^##[ \t]+/){flush();in_rollout=0;next}
  # `Wave:` with an optional number and an optional space before the colon is
  # the prefix: `### Wave: a`, `### Wave 2: a` and `### wave 3 : a` are all
  # titled `a`. SKILL.md teaches the unnumbered form, and requiring a number
  # left `Wave: a` as the title, so `after: a` never matched (BH-4061). A
  # letter after `wave` (`Wavefront`, `Waves:`) is a title, not the prefix.
  if(n~/^###[ \t]/){flush();in_wave=1;cur_title=cline;sub(/^[ \t]*###[ \t]*/,"",cur_title);tmp=tolower(cur_title);if(tmp~/^wave([ \t]+[0-9]+)?[ \t]*:/)sub(/^[wW][aA][vV][eE]([ \t]+[0-9]+)?[ \t]*:[ \t]*/,"",cur_title);cur_title=trim(cur_title);next}
  if(in_wave)cur_body=cur_body raw "\n"
}
END{
  # seen_rollout, not in_rollout: the section may have already been CLOSED by
  # a later ## heading (the arm above), and that is a normal end, not "never
  # opened" — this must still fall through to flush and validate the waves.
  if(!seen_rollout)exit 0
  if(fatal)exit 1
  # An unclosed fence or <pre>/<code> tag ran off the end of the body: every
  # later wave silently merged into the still-open one. Refuse rather than
  # file a short list with a green result.
  if(fence!="" || htmlopen){print "unterminated code block">errfile;exit 20}
  flush()
  if(waves==0){print "no waves">errfile;exit 11}
  if(waves<2){print "too few waves">errfile;exit 12}
  if(waves>12){print "too many waves">errfile;exit 13}
  for(i=1;i<=waves;i++){t=norm(wave_title[i]);if(t==""){print "empty title">errfile;exit 14};if(seen[t]){print "duplicate title">errfile;exit 15};seen[t]=i}
  # The titles as the author wrote them, for the unknown-dependency reason: a
  # bare "unknown dependency" did not say which name missed or what it could
  # have matched (BH-4061).
  known="";for(i=1;i<=waves;i++)known=known (i>1?", ":"") "\"" wave_title[i] "\""
  # `after:` splits on commas, so a title with a comma in it can never be
  # named. Refuse by that reason when any wave has an `after:` line, rather
  # than let it surface as an unknown dependency. With no `after:` anywhere
  # nothing is split and the title is fine.
  has_after=0
  for(i=1;i<=waves&&!has_after;i++){nl=split(wave_body[i],ls,/\n/);for(j=1;j<=nl;j++)if(norm(ls[j])!=""){if(norm(ls[j])~/^after:/)has_after=1;break}}
  if(has_after)for(i=1;i<=waves;i++)if(index(wave_title[i],",")){print "comma in wave title">errfile;exit 26}
  for(i=1;i<=waves;i++){
    b=wave_body[i];nlines=split(b,lines,/\n/);first=0
    for(j=1;j<=nlines;j++)if(norm(lines[j])!=""){first=j;break}
    afters=""
    if(first>0){
      a=lines[first];na=norm(a)
      if(na~/^after:[ \t]*/){
        # AN INDENTED after: LINE REFUSES BY ITS REAL NAME. It is DETECTED on
        # the trimmed copy, so a 4-space one used to be stripped off the RAW
        # line, come out as the whole literal `after: a`, and refuse with
        # "unknown dependency" — a wrong reason for a real shape. It is a code
        # block by the indent rule of the parser itself, so honouring it lets a
        # dependency ride on a shape the detector reads as code, and dropping
        # it silently is a wave that builds before the one it needs.
        if(is_indented(a)){print "indented after: line">errfile;exit 23}
        # The prefix comes off the TRIMMED line, so a heading-legal 1-3 space
        # indent parses the way markdown renders it.
        rest=trim(a);sub(/^[aA][fF][tT][eE][rR]:[ \t]*/,"",rest)
        # split("") returns 0, so an empty list used to be consumed in silence
        # and the dependency vanished with a green result.
        if(trim(rest)==""){print "empty after: list">errfile;exit 24}
        m=split(rest,parts,/,/)
        for(k=1;k<=m;k++){
          part=trim(parts[k]);lp=tolower(part)
          if(part==""){print "empty after: name">errfile;exit 25}
          if(lp==norm(wave_title[i])){print "self dependency">errfile;exit 16}
          if(!(lp in seen)){print "unknown dependency \"" part "\" (known: " known ")">errfile;exit 17}
          if(seen[lp]>=i){print "forward dependency">errfile;exit 18}
          # One edge per position per wave: `after: a, a` is [1], not [1,1].
          if((i SUBSEP lp) in used)continue
          used[i SUBSEP lp]=1
          if(afters!="")afters=afters ","
          afters=afters seen[lp]
        }
        newb="";for(j=1;j<=nlines;j++)if(j!=first)newb=newb lines[j] "\n";b=newb
      }
    }
    while(b~/^\n/)sub(/^\n/,"",b);while(b~/\n\n$/)sub(/\n\n$/,"\n",b)
    wave_body[i]=b;wave_after[i]=afters
  }
  for(i=1;i<=waves;i++)printf("{\"title\":%s,\"body\":%s,\"after\":[%s]}\n",jqquote(wave_title[i]),jqquote(wave_body[i]),wave_after[i])
}' errfile="$PARSE_ERR" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] || [ -s "$PARSE_ERR" ]; then
  REASON=$(head -1 "$PARSE_ERR" 2>/dev/null); [ -n "$REASON" ] || REASON="parse failed"
  fc_log "$BUILD" "ROLLOUT_PARSE_REFUSED $PROJECT/$KEY $REASON"
  printf 'RESULT "ROLLOUT_FAILED %s"\n' "$REASON" >> "$BUILD/rollout-run.txt"
  [ -s "$BUILD/rollout-run.txt" ] || printf 'RESULT "ROLLOUT_FAILED %s"\n' "$REASON" > "$BUILD/rollout-run.txt"
  # A PARSE refusal is the author's to fix, so it is said on the master once
  # per reason and the master is parked (BH-4061). Only here: a fetch, filer or
  # partial failure is not a body problem and must not park the ticket. Only on
  # the issues lane: `ai-build` is that lane's handoff. "parse failed" is awk
  # dying with no reason of its own, which the author cannot act on. Only with
  # nothing on the record: a resumed run whose body was edited after some
  # waves were filed must not be told "we did not file the waves".
  if [ "$PREFIX" = "-" ] && [ "$REASON" != "parse failed" ] && [ "$(record_keys)" -eq 0 ] \
     && command -v rollout_refusal_notify >/dev/null 2>&1; then
    rollout_refusal_notify "$REPO" "$TICKET" "$BUILD" "$REASON" >/dev/null 2>&1 || true
  fi
  exit 1
fi
[ -n "$PARSED" ] || { printf 'RESULT "ROLLOUT_FAILED no waves"\n' >> "$BUILD/rollout-run.txt"; exit 1; }
printf '%s\n' "$PARSED" | jq -s '.' > "$BUILD/children.json"
NWAVES=$(jq 'length' "$BUILD/children.json")

FC_RC=0
file_children "$PROJECT" "$TICKET" "$KEY" "$BUILD" "$BUILD/children.json" --kind rollout || FC_RC=$?
if [ "$FC_RC" -eq 3 ]; then
  fc_log "$BUILD" "ROLLOUT_FILER_UNAVAILABLE $PROJECT/$KEY"
  printf 'RESULT "ROLLOUT_FAILED filer unavailable"\n' >> "$BUILD/rollout-run.txt"; exit 1
fi
[ "$FC_RC" -eq 0 ] || fc_log "$BUILD" "ROLLOUT_FILER_ERROR $PROJECT/$KEY rc=$FC_RC"

# THE RESULT IS DERIVED FROM THE RECORD, NEVER FROM THE FILER'S rc. This is
# what makes "never a green partial" true by construction rather than by the
# filer being well behaved, and it is the arm that catches the case the resume
# alone does not: fc_file_issues returns 0 without appending anything when
# DECOMPOSE_DRY_RUN=1 meets a non-empty children.txt (bin/lib/fc-issues.sh:63-66),
# which would otherwise print ROLLOUT_FILED N over a record holding K < N.
# The count comes first so a partial refuses WITH ITS COUNT whether the filer
# reported the failure or not; a complete record under a nonzero rc still
# refuses below, because something the filer does after the last create failed.
FILED_K=$(record_keys)
if [ "$FILED_K" -lt "$NWAVES" ]; then
  fc_log "$BUILD" "ROLLOUT_PARTIAL $PROJECT/$KEY $FILED_K of $NWAVES waves"
  printf 'RESULT "ROLLOUT_FAILED filed %s of %s waves"\n' "$FILED_K" "$NWAVES" >> "$BUILD/rollout-run.txt"
  printf 'RESULT "ROLLOUT_FAILED filed %s of %s waves"\n' "$FILED_K" "$NWAVES"
  exit 1
fi
if [ "$FC_RC" -ne 0 ]; then
  printf 'RESULT "ROLLOUT_FAILED filer error"\n' >> "$BUILD/rollout-run.txt"
  printf 'RESULT "ROLLOUT_FAILED filer error"\n'; exit 1
fi

# children.txt (the idempotency watermark checked at the top of this script)
# is written by the FILER, not here: bin/run-decompose.sh:502 forbids
# "$KEY.<n>" title-label lines in that file, and #982's fc_file_issues /
# fc_file_board write the board's own keys for the filed children. Writing our
# own label lines here would collide with that contract the moment #982 lands.

{
  printf 'This request is a rollout, so I have filed %s waves as separate tickets:\n\n' "$NWAVES"
  j=1; while [ "$j" -le "$NWAVES" ]; do
    WT=$(jq -r --argjson n "$((j-1))" '.[$n].title' "$BUILD/children.json")
    WA=$(jq -r --argjson n "$((j-1))" '.[$n].after | if length>0 then " (after " + (map(tostring)|join(", ")) + ")" else "" end' "$BUILD/children.json")
    printf '%s. %s%s\n' "$j" "$WT" "$WA"; j=$((j+1))
  done
  printf '\nEach wave is built in order. I will post what-shipped comments as they land.\n'
} > "$BUILD/rollout-comment.md"

{
  printf '%s [%s/%s] ROLLOUT_FILED %s waves\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$PROJECT" "$KEY" "$NWAVES"
  printf 'RESULT "ROLLOUT_FILED %s"\n' "$NWAVES"
} >> "$BUILD/rollout-run.txt"

fc_log "$BUILD" "ROLLOUT_FILED $PROJECT/$KEY $NWAVES waves"
printf 'RESULT "ROLLOUT_FILED %s"\n' "$NWAVES"
exit 0
