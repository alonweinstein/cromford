#!/bin/bash
# bin/capture-ticket-shape.sh <project> — print the STRUCTURE of one ticket
# payload for this project's board. Keys and types only. No values, ever.
#
# WHY THIS EXISTS. board-fetch.sh trims comment threads at fetch time and FAILS
# OPEN on any shape it does not recognise — an unknown shape costs tokens
# rather than losing a client's answer. That is the right default, and it also
# means wiring a project's SOP to the trimmer without knowing its real response
# shape buys nothing: the fetch would pass straight through. Verifying the
# shape is what converts the helper from safe-and-inert into safe-and-working.
#
# WHY STRUCTURE ONLY, AND WHY THAT IS NOT NEGOTIABLE. The output of this script
# gets pasted into agent transcripts to design a jq filter. Board tickets carry
# CLIENT CONTENT — what they asked for, what they complained about, what they
# were quoted. None of that is needed to write a filter, all of it would be
# copied into logs and context windows, and the person whose words they are did
# not agree to that. So every scalar is replaced by its type before anything is
# printed: strings become <string:LEN>, numbers <number>, and so on. Lengths
# survive because payload size is the thing being diagnosed; content does not.
#
# Reads the same env vars the SOPs use, resolved the same way file-health-ticket
# does, and the board prefix from fleet.conf's 4th column — so it works for
# project-1 (/api/board), project-3 (/api/feature-board) and project-4
# (/api/accounting/requests-board) without anyone having to remember which.
#
# Usage on a box:  /root/harness/bin/capture-ticket-shape.sh project-1
set -uo pipefail
# --shape-stdin: redact stdin and print it. Used by the board-discovery failure
# path so an unparseable list response can still be diagnosed, through the same
# redactor the success path uses rather than a second copy of it.
if [ "${1:-}" = "--shape-stdin" ]; then
  python3 -c "
import json, re, sys
SCHEMA_KEY = re.compile(r'^[A-Za-z_][A-Za-z0-9_]{0,29}\$')
def shape(o, depth=0):
    if depth > 6: return '<deep>'
    if isinstance(o, dict):
        out = {}
        for i, (k, v) in enumerate(o.items()):
            kk = k if SCHEMA_KEY.match(str(k)) else f'<key{i}:{len(str(k))}>'
            out[kk] = shape(v, depth + 1)
        return out
    if isinstance(o, list):
        return [shape(o[0], depth + 1), f'<...{len(o)} items total>'] if o else []
    if isinstance(o, str): return f'<string:{len(o)}>'
    if isinstance(o, bool): return '<bool>'
    if isinstance(o, (int, float)): return '<number>'
    if o is None: return '<null>'
    return '<unknown>'
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f'not JSON ({e}) — bytes NOT printed, they may be client content')
    sys.exit(0)
out = json.dumps(shape(d), indent=1)
CAP = 8000
if len(out) > CAP:
    # A CUT SHAPE MUST NOT READ AS A COMPLETE ONE. The dedupe in 71dbdec
    # silently halved this from 8000 to 4000 by routing the success path
    # through the failure path's body — on a 12.5KB project-1 payload that is
    # field_25 instead of field_51, with nothing to say the rest existed. The
    # whole output is a description of a structure; a description that stops
    # early and does not say so is a wrong description.
    print(out[:CAP])
    print(f'<truncated at {CAP} chars — {len(out) - CAP} more; the shape above is INCOMPLETE>')
else:
    print(out)
"
  exit 0
fi

PROJECT="${1:?usage: capture-ticket-shape.sh <project>}"
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

ENVF="$HENV/$PROJECT.env"
[ -r "$ENVF" ] || { echo "no env file for $PROJECT at $ENVF"; exit 1; }
set -a +u; . "$HENV/global.env" 2>/dev/null; . "$ENVF" 2>/dev/null; set +a -u

TOKEN_VAR=$(grep -oE '^[A-Z_]+_INTERNAL_API_TOKEN' "$ENVF" | head -1)
BASE_VAR=$(grep -oE '^[A-Z_]+_(API|APP)_BASE' "$ENVF" | head -1)
TOKEN="${!TOKEN_VAR:-}"; BASE="${!BASE_VAR:-}"
[ -n "$TOKEN" ] && [ -n "$BASE" ] || {
  echo "missing creds for $PROJECT (token_var=${TOKEN_VAR:-none} base_var=${BASE_VAR:-none})"; exit 1; }

# 4th column of fleet.conf is the board API prefix; "-" means this project has
# no product board.
PREFIX=$(awk -v p="$PROJECT" '$1==p {print $4}' "$H/fleet.conf" 2>/dev/null | head -1)
[ -n "$PREFIX" ] && [ "$PREFIX" != "-" ] || { echo "$PROJECT has no board prefix in fleet.conf"; exit 1; }

CURL() { curl -s --max-time 30 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "User-Agent: curl/8" "$@"; }

# Board-id discovery, widened. project-3 (/api/feature-board) and project-4
# (/api/accounting/requests-board) answer their LIST route differently from the
# two /api/board projects, and the first version could only read one shape.
#
# On failure this now prints the REDACTED SHAPE of whatever did come back,
# because that is the entire point of this script: a capture tool whose
# discovery step fails with "could not read a board id" has learned nothing,
# while one that shows the shape it could not parse has answered the question
# on the same run. The redactor is the same one used for the ticket, so a
# failure path leaks no more than a success path.
BOARDS_RAW=$(CURL "$BASE$PREFIX/boards")
# TYPE FIRST, then reach for a key — the same lesson as #82's finding 1, one
# step earlier in the pipeline. `.boards` against a top-level ARRAY is an
# ERROR in jq ("cannot index array with string"), and the caller's 2>/dev/null
# turned that error into silence. That is exactly what project-4 hit: its
# /api/accounting/requests-board/boards returns a bare array of board objects,
# so the old expression errored out and produced no id and no reason.
#
# Verified against every shape seen or plausible: bare array (project-4), {boards}
# (project-1/project-2), nested {data:{boards}}, {items}, {results}. An unrecognised
# shape still yields nothing and falls through to the redacted shape dump
# below, which is the branch that diagnosed project-4 in the first place.
BOARD=$(printf '%s' "$BOARDS_RAW" | jq -r '
  if type == "array" then .[0]
  elif type == "object" then
    ( [ .boards, .board, .data, .results, .items,
        (.data | if type == "object" then (.boards // .items // .results) else empty end) ]
      | map(select(type == "array")) | first // [] | .[0] )
  else empty end
  | if type == "object" then (.id // .boardId // ._id // .key // .slug // empty) else empty end' 2>/dev/null)
if [ -z "$BOARD" ]; then
  echo "could not read a board id from $BASE$PREFIX/boards"
  echo "--- shape of what it returned (redacted, safe to paste) ---"
  printf '%s' "$BOARDS_RAW" | SHAPE_ONLY=1 "$0" --shape-stdin 2>/dev/null
  exit 1
fi

# Pick the ticket with the MOST comments: the trimmer's behaviour only differs
# on long threads, so a 2-comment ticket would confirm nothing about the case
# that matters.
LIST=$(CURL "$BASE$PREFIX/boards/$BOARD/tickets")
TID=$(jq -r '
  (if type=="array" then . else (.tickets // []) end)
  | map({id: .id, n: ((.comments // .commentCount // []) | if type=="array" then length else . end)})
  | sort_by(-.n) | .[0].id // empty' <<<"$LIST" 2>/dev/null)
[ -n "$TID" ] || TID=$(jq -r '(if type=="array" then . else (.tickets // []) end)[0].id // empty' <<<"$LIST" 2>/dev/null)
[ -n "$TID" ] || { echo "no tickets on board $BOARD"; exit 1; }

RAW=$(CURL "$BASE$PREFIX/tickets/$TID")
BYTES=$(printf '%s' "$RAW" | wc -c | tr -d ' ')

echo "project=$PROJECT prefix=$PREFIX ticket_payload_bytes=$BYTES"
# ONE REDACTOR, not two. The success path routes through the same
# --shape-stdin body the failure path uses, via the re-entry the script already
# had. Until now there were two copies of SCHEMA_KEY + shape() with a comment
# claiming they were one — and on privacy-critical code a false claim of
# singularity is worse than an acknowledged duplicate: it tells the next reader
# that fixing one place is enough. Deduped rather than re-labelled, because the
# re-entry pattern made deduping the smaller change.
printf '%s' "$RAW" | "$0" --shape-stdin
