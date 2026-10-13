#!/bin/bash
# bin/archie-skill-replay.sh — BH-4064 (BH-3966.3): replay Archie's skills
# against their recorded cases and check each verdict.
#
# A skill is orchestrator/skills/<name>/SKILL.md. Its frontmatter carries
# `name:` (equal to the dir) and `verdicts:`, a `|`-separated lowercase list.
# Each case is orchestrator/skills/<name>/replays/<NN-slug>/ with:
#   input.md       the recorded situation
#   expected       one line, `VERDICT: <word>`, a word from the skill's verdicts
#   recorded.txt   the recorded model reply, ending in a `VERDICT: <word>` line
#
# For each case the prompt is written to a scratch file: the SKILL.md body
# (frontmatter stripped), a `=== CASE ===` line, input.md, then
# `End with exactly one line: VERDICT: <one of …>`.
#
# The frontmatter may carry `prompt: <path> [<path> ...]`, repo-relative paths
# resolved against the runner's own repo (not --root). Then the head is those
# paths in order instead of the body: a file is its bytes plus a newline; a
# directory is its `*.md` in glob order plus one newline (prompts/archie-soul.d
# is read the way bin/archie.sh reads it). A path that is absolute, contains
# `..`, resolves outside the repo, is missing or unreadable, or is a directory
# with no `*.md` is one structural `FAIL <skill> prompt <path> <reason>`, and
# none of that skill's cases run. The model is called as
#   $ARCHIE_REPLAY_MODEL_CMD <prompt-file> <case-dir>
# and the verdict is the LAST `VERDICT: ` line of its stdout, trimmed and
# lowercased. A model that exits non-zero, or a reply with no VERDICT line, is
# got=none: a FAIL, never a pass.
#
# The default model is the recorded replayer (`cat <case>/recorded.txt`), so
# nothing calls a vendor and nothing is billed. The live model is
# bin/archie-replay-model.sh (BH-4066, through bin/agent-call.sh), which
# bin/archie-learn.sh passes in to gate a skill edit.
#
# usage: archie-skill-replay.sh [--skill <name>] [--root <skills-dir>]
#   --root  default "$(dirname "$0")/../orchestrator/skills"; env ARCHIE_SKILLS_ROOT too
# stdout, one line per case:  PASS <skill>/<case> <verdict>
#                             FAIL <skill>/<case> expected=<v> got=<v|none>
# one line per structural fault: FAIL <skill>[/<case>] <reason>
# last line: archie-skill-replay: <n> skills, <p> passed, <f> failed
# rc 0 = every case passed; 1 = any FAIL (an empty root is one); 2 = usage
set -uo pipefail
ROOT="${ARCHIE_SKILLS_ROOT:-$(dirname "$0")/../orchestrator/skills}"
REPO=$(cd "$(dirname "$0")/.." && pwd)
REPOR=$(realpath -e "$REPO")
ONLY=
usage() { echo "usage: archie-skill-replay.sh [--skill <name>] [--root <skills-dir>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --skill) [ $# -ge 2 ] || usage; ONLY="$2"; shift 2 ;;
    --root)  [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -d "$ROOT" ] || { echo "archie-skill-replay: no skills dir at $ROOT" >&2; usage; }
if [ -n "$ONLY" ] && [ ! -d "$ROOT/$ONLY" ]; then
  echo "archie-skill-replay: no skill $ONLY under $ROOT" >&2; usage
fi

SCR=$(mktemp -d "${TMPDIR:-/tmp}/archie-replay.XXXXXX") || exit 2
trap 'rm -rf "$SCR"' EXIT

MODEL=()
[ -n "${ARCHIE_REPLAY_MODEL_CMD:-}" ] && read -ra MODEL <<<"$ARCHIE_REPLAY_MODEL_CMD"

model() { # model <prompt-file> <case-dir>: the reply on stdout, rc of the model
  if [ ${#MODEL[@]} -gt 0 ]; then "${MODEL[@]}" "$1" "$2"
  else cat "$2/recorded.txt" 2>/dev/null; fi
}

# The word after the last `VERDICT:` at a line start, trimmed and lowercased.
verdict_of() { tr -d '\r' | sed -n 's/^VERDICT:[[:space:]]*//p' | tail -1 | tr -d '[:space:]' | tr 'A-Z' 'a-z'; }

SK=0 P=0 F=0
fail() { echo "FAIL $*"; F=$((F+1)); }

for D in "$ROOT"/*/; do
  [ -d "$D" ] || continue
  S=$(basename "$D")
  [ -n "$ONLY" ] && [ "$S" != "$ONLY" ] && continue
  SK=$((SK+1))
  M="$D/SKILL.md"
  [ -f "$M" ] || { fail "$S no SKILL.md"; continue; }
  FM=$(awk 'NR==1 && /^---[[:space:]]*$/ {f=1; next} f && /^---[[:space:]]*$/ {exit} f' "$M" | tr -d '\r')
  if ! grep -qE "^name: *$S *\$" <<<"$FM" || ! [[ $S =~ ^[a-z0-9-]+$ ]]; then
    fail "$S SKILL.md has no name: $S"; continue
  fi
  VL=$(sed -n 's/^verdicts:[[:space:]]*//p' <<<"$FM" | head -1)
  VOCAB=$(tr '|' '\n' <<<"$VL" | tr -d ' \t\r' | grep -v '^$' | tr '\n' ' ')
  [ -n "$VOCAB" ] || { fail "$S SKILL.md has no verdicts: line"; continue; }
  [ -d "$D/replays" ] || { fail "$S no replays/ dir"; continue; }
  NC=0; for C in "$D"/replays/*/; do [ -d "$C" ] && NC=$((NC+1)); done
  [ "$NC" -ge 2 ] || { fail "$S needs at least 2 replay cases, has $NC"; continue; }

  # The prompt head: the `prompt:` files when the key is set, else the body
  # after the frontmatter. The case separator follows it.
  PL=$(sed -n 's/^prompt:[[:space:]]*//p' <<<"$FM" | head -1)
  if [ -z "$PL" ]; then
    awk 'NR==1 && /^---[[:space:]]*$/ {f=1; next} f==1 && /^---[[:space:]]*$/ {f=2; next} f!=1' "$M" > "$SCR/head"
  else
    read -ra PATHS <<<"$PL"
    : > "$SCR/head"; BADP=
    for PP in "${PATHS[@]}"; do
      case "$PP" in
        /*)    BADP="$PP absolute path" ;;
        *..*)  BADP="$PP contains .." ;;
        *) BADP="$PP not a readable file under the repo"
           R=$(realpath -e "$REPO/$PP" 2>/dev/null) || break
           case "$R" in "$REPOR"/*) ;; *) break ;; esac
           if [ -f "$R" ] && [ -r "$R" ]; then
             { cat "$R"; echo; } >> "$SCR/head"; BADP=
           elif [ -d "$R" ]; then
             for MD in "$R"/*.md; do [ -f "$MD" ] && [ -r "$MD" ] || break 2; done
             { cat "$R"/*.md; echo; } >> "$SCR/head"; BADP=
           fi ;;
      esac
      [ -z "$BADP" ] || break
    done
    [ -z "$BADP" ] || { fail "$S prompt $BADP"; continue; }
  fi
  CLOSE="End with exactly one line: VERDICT: <one of $(sed 's/ $//; s/ / | /g' <<<"$VOCAB")>"

  for C in "$D"/replays/*/; do
    [ -d "$C" ] || continue
    C="${C%/}"; CN=$(basename "$C")
    [ -f "$C/input.md" ] || { fail "$S/$CN missing input.md"; continue; }
    [ -f "$C/expected" ] || { fail "$S/$CN missing expected"; continue; }
    E=$(verdict_of < "$C/expected")
    [ -n "$E" ] || { fail "$S/$CN expected has no VERDICT: line"; continue; }
    case " $VOCAB" in *" $E "*) ;; *) fail "$S/$CN expected $E not in verdicts: $VL"; continue ;; esac
    PF="$SCR/prompt-$S-$CN.md"
    { cat "$SCR/head"; echo; echo "=== CASE ==="; cat "$C/input.md"; echo; echo "$CLOSE"; } > "$PF"
    if REPLY=$(model "$PF" "$C"); then G=$(verdict_of <<<"$REPLY"); else G=; fi
    if [ -n "$G" ] && [ "$G" = "$E" ]; then echo "PASS $S/$CN $G"; P=$((P+1))
    else fail "$S/$CN expected=$E got=${G:-none}"; fi
  done
done

[ "$SK" -gt 0 ] || fail "no skills under $ROOT"
echo "archie-skill-replay: $SK skills, $P passed, $F failed"
[ "$F" -eq 0 ]
